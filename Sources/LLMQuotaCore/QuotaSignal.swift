import Foundation

/// 从会话日志里学「额度打没打完」。
///
/// ## 为什么必须有它
///
/// 在此之前，系统只在**自己派的活**撞上 429 时才知道额度用尽 ——
/// 而人在终端里手工跑掉的额度，它一无所知。真实后果（2026-08-15）：
/// MacBook 上 GLM 被手工跑到 5 小时窗打满，日志里躺着 154 个 429、
/// 92 个 RateLimit，而看板上 GLM 显示「正常，5 小时窗 0 次」——
/// 用户的原话是「额度已经用完了，但是你却没有统计到」。
///
/// 更根本的是：**光数请求数和 token 判断不出额度用没用完**。
/// GLM 官方按「积分」计费，积分按 token 折算、工作日 14–18 点还是 3 倍，
/// 和我们数的「次数」根本不是一个口径。唯一可靠的地面真相是
/// **服务端自己说的那句话** —— 而它就写在日志里：
///
///     API Error: Request rejected (429) · [1308][已达到 5 小时的使用上限。
///     您的限额将在 2026-08-15 12:00:47 重置。]
///
/// 连重置时间都给了。不读它，等于守着答案不看。
public enum QuotaSignal {

    public struct Hit: Sendable {
        public var platform: Platform
        public var at: Date
        public var resetsAt: Date?
        public var message: String
    }

    /// 一条日志行里有没有「额度打满」的信号。
    ///
    /// 只认高置信关键词，宁可漏也不错报 —— 错报的代价是把一个还能用的
    /// 平台冻起来，那比漏报更糟（漏报只是少知道一件事，错报是主动少干活）。
    static func looksExhausted(_ line: String) -> Bool {
        let l = line.lowercased()
        // 429 单独出现不算数：正常重试里也会有。要配合额度类措辞。
        let hasCode = l.contains("429") || l.contains("rate_limit")
            || l.contains("ratelimit")
        guard hasCode else { return false }
        let quotaWords = ["使用上限", "限额", "额度", "quota", "exhaust",
                          "usage limit", "insufficient"]
        return quotaWords.contains { l.contains($0.lowercased()) }
    }

    /// 从整行日志里抠出**服务端那句话**。
    ///
    /// 会话日志一行就是一整个 JSON 对象，直接取前 200 字符会得到
    /// `{"parentUuid":"a0d60529-..."` —— 全是无关的头部字段。实测后果：
    /// 冷却台账里的 detail 全是 UUID，人看不出为什么被冻，
    /// 程序也认不出是哪个窗口满了（撞顶采样因此一条都记不下来）。
    ///
    /// 做法是以额度关键词为锚，向两边各取一段。
    static func excerpt(_ line: String, span: Int = 90) -> String {
        let anchors = ["使用上限", "限额", "额度", "quota", "usage limit",
                       "rate limit", "429", "exhaust"]
        for a in anchors {
            guard let r = line.range(of: a, options: .caseInsensitive) else { continue }
            let lo = line.index(r.lowerBound,
                                offsetBy: -span,
                                limitedBy: line.startIndex) ?? line.startIndex
            let hi = line.index(r.upperBound,
                                offsetBy: span,
                                limitedBy: line.endIndex) ?? line.endIndex
            return String(line[lo..<hi])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(line.prefix(200))
    }

    /// 从消息里抠重置时间。中文「将在 YYYY-MM-DD HH:MM:SS 重置」和
    /// 英文 ISO 两种都认 —— 前者是 GLM 的写法，后者是 Qwen 的。
    static func parseReset(_ line: String, now: Date = Date()) -> Date? {
        // 中文：本地时区（服务端按用户所在时区报）
        if let r = line.range(of: #"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"#,
                              options: .regularExpression) {
            let s = String(line[r]).replacingOccurrences(of: "T", with: " ")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            df.locale = Locale(identifier: "en_US_POSIX")
            // 中文措辞用本地时区，带 Z/UTC 的走 UTC
            df.timeZone = line.contains("UTC") || line.contains("Z]")
                ? TimeZone(identifier: "UTC") : TimeZone.current
            if let d = df.date(from: s), d > now,
               d.timeIntervalSince(now) < 40 * 86400 { return d }
        }
        return CooldownLedger.parseResetTime(line, now: now)
    }

    /// 这个会话文件里占主导的是哪个平台的模型。
    /// 判据是出现次数最多的模型名 —— 一个会话里混用多个模型很少见，
    /// 混用时也该算给用得最多的那个。
    static func dominantPlatform(in lines: [Substring]) -> Platform? {
        var counts: [Platform: Int] = [:]
        for line in lines.suffix(600) {
            guard let r = line.range(of: #""model"\s*:\s*"[^"]+""#,
                                     options: .regularExpression) else { continue }
            let raw = String(line[r])
                .split(separator: "\"").last.map(String.init) ?? ""
            guard !raw.isEmpty, raw != "<synthetic>" else { continue }
            if let p = ModelRouter.platformIfKnown(forModel: raw) {
                counts[p, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// 扫一个平台的会话日志，找最近的额度打满信号。
    ///
    /// - Parameter within: 只看这么久以内的文件（默认 6 小时）。更老的信号
    ///   多半早就重置了，读进来只会误冻平台。
    public static func scan(roots: [String], platform: Platform,
                            within: TimeInterval = 6 * 3600,
                            now: Date = Date()) -> Hit? {
        let fm = FileManager.default
        var newest: Hit?
        for root in roots {
            let path = NSString(string: root).expandingTildeInPath
            guard let e = fm.enumerator(at: URL(fileURLWithPath: path),
                                        includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for case let f as URL in e where f.pathExtension == "jsonl" {
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard now.timeIntervalSince(mod) < within else { continue }
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n")
                // 从后往前找：最近的那条才算数
                for line in lines.reversed().prefix(400) {
                    let s = String(line)
                    guard looksExhausted(s) else { continue }
                    // **打满记在谁头上，看这个文件里跑的是谁的模型。**
                    //
                    // ~/.claude 里跑的不一定是 Claude：用 Claude CLI 接 GLM
                    // 端点（ANTHROPIC_BASE_URL 指过去）是常见玩法，日志照样落在
                    // ~/.claude 下，而模型名是 glm-5.2。按目录归属会把 GLM 的
                    // 打满算到 Claude 头上 —— 而 Claude 是本机的指挥兼架构师，
                    // 冻住它等于高危任务全线停摆。宁可多花一次扫描。
                    let owner = dominantPlatform(in: lines) ?? platform
                    let hit = Hit(platform: owner, at: mod,
                                  resetsAt: parseReset(s, now: now),
                                  message: excerpt(s))
                    if newest == nil || hit.at > newest!.at { newest = hit }
                    break
                }
            }
        }
        return newest
    }

    /// 采集时顺手学一遍：把发现的额度打满写进冷却台账。
    ///
    /// 写进台账而不是只报告，是因为台账已经是**调度和看板共用的那份事实**
    ///（上午刚接好：quotaExhausted 未到期会注入 exhausted 状态置顶）。
    /// 学到之后三件事同时成立：调度不再派给它、手机上显示打空、
    /// 报表里给出重置时间。
    @discardableResult
    public static func learnFromLogs(now: Date = Date()) -> [Hit] {
        // 哪些目录属于哪个平台。和适配器用同一份认知，别另写一套。
        let sources: [(Platform, [String])] = [
            (.glm, ["~/.glm", "~/.claude-glm", "~/.zai"]),
            (.claude, ["~/.claude"]),
            (.kimi, ["~/.kimi-code"]),
            (.qwen, ["~/.qwen"]),
        ]
        var hits: [Hit] = []
        for (p, roots) in sources {
            guard let hit = scan(roots: roots, platform: p, now: now) else { continue }
            // **别覆盖更晚的重置时间。** 已经在冷却且冷得更久的，
            // 说明有更权威的信息（比如我们自己撞到的 429），不动它。
            if let existing = CooldownLedger.active(now: now)[p],
               existing.until >= (hit.resetsAt ?? now) { continue }
            CooldownLedger.record(platform: p, cause: .quotaExhausted,
                                  detail: "从会话日志学到：" + hit.message.prefix(120),
                                  knownResetAt: hit.resetsAt, now: now)
            hits.append(hit)
        }
        return hits
    }
}

