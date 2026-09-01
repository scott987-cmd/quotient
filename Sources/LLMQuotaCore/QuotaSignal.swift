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
    /// 这一行是不是**服务端真的拒绝了我们**。
    ///
    /// ## 为什么不能用关键词匹配
    ///
    /// 会话日志一行是一整个 JSON，装着 agent 执行的命令、读到的文件、
    /// 写出的代码、甚至它的思考过程。在一个**专门处理额度**的项目里，
    /// 这些内容几乎必然包含「额度」「429」「quota」。
    ///
    /// 今天连撞三次，一次比一次讽刺：
    /// 1. agent 跑的 grep 命令被当成额度信号
    /// 2. 加了「服务端措辞」过滤后，agent 的**思考内容**又中了 ——
    ///    因为它在思考里引用了那句错误消息
    /// 3. 查到的所谓「真 429 行」其实是 `type: user` 的工具结果，
    ///    也就是某个工具读到的文本
    ///
    /// 结论：**内容判断在自指场景下永远不安全**，必须看结构。
    ///
    /// ## 现在的判据
    ///
    /// 1. 这一行能解析成 JSON，且 `type` 是模型侧的消息（assistant/system），
    ///    不是 user/tool_result —— 后者装的是我们喂进去的东西
    /// 2. 文本部分（跳过 thinking 块）里有服务端专有措辞 + 429 + 额度词
    /// 3. 调用方只看文件尾部：**真打满之后会话就断了**，
    ///    所以信号必然在最后几条里。中间出现的都是内容不是事件。
    static func looksExhausted(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        // 只认模型侧的消息。user / tool_result 里装的是我们喂进去的东西 ——
        // 我们读了一个写着 429 的文件，不代表我们被限流了。
        let type = (obj["type"] as? String)?.lowercased() ?? ""
        guard type == "assistant" || type == "system" || type == "error" else { return false }

        let text = plainText(of: obj).lowercased()
        guard !text.isEmpty else { return false }

        let serverMarkers = ["api error", "request rejected", "rate_limit_error"]
        guard serverMarkers.contains(where: { text.contains($0) }) else { return false }
        guard text.contains("429") || text.contains("rate_limit") else { return false }
        let quotaWords = ["使用上限", "限额", "额度", "quota", "exhaust",
                          "usage limit", "insufficient"]
        return quotaWords.contains { text.contains($0) }
    }

    /// 一条消息里**模型说出来的文字**，跳过 thinking 和工具调用。
    ///
    /// thinking 必须跳过：模型在思考里引用一句错误消息，不等于真的撞上了。
    static func plainText(of obj: [String: Any]) -> String {
        var out = ""
        func walk(_ any: Any) {
            if let s = any as? String { out += s + " "; return }
            if let arr = any as? [Any] { arr.forEach(walk); return }
            guard let d = any as? [String: Any] else { return }
            let kind = (d["type"] as? String)?.lowercased() ?? ""
            // thinking：模型的内心活动，不是发生过的事
            // tool_use / tool_result：agent 干的事和读到的东西
            if ["thinking", "tool_use", "tool_result", "redacted_thinking"].contains(kind) {
                return
            }
            if let t = d["text"] as? String { out += t + " " }
            if let c = d["content"] { walk(c) }
            if let m = d["message"] { walk(m) }
        }
        if let m = obj["message"] { walk(m) }
        if let c = obj["content"] { walk(c) }
        return out
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
        // 明确带 UTC / Z 的时间不能先交给“本地时间”解析，否则上海机器会
        // 把 Qwen 的重置点提前 8 小时。先走统一的 UTC 解析器。
        let explicitUTC = #"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?\s*(?:UTC|Z)"#
        if line.range(of: explicitUTC,
                      options: [.regularExpression, .caseInsensitive]) != nil,
           let reset = CooldownLedger.parseResetTime(line, now: now) {
            return reset
        }

        // 中文：本地时区（服务端按用户所在时区报）
        if let r = line.range(of: #"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"#,
                              options: .regularExpression) {
            let s = String(line[r]).replacingOccurrences(of: "T", with: " ")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
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
                // **只看最后几条。** 真打满之后会话就断了 —— 信号必然在尾部。
                // 中间出现的额度字样是内容不是事件（agent 读了一个写着 429
                // 的文件、或者在讨论额度代码）。看 400 行等于把整个会话
                // 的内容都当成候选信号。
                for line in lines.reversed().prefix(12) {
                    let s = String(line)
                    guard looksExhausted(s) else { continue }
                    // **打满记在谁头上，看这个文件里跑的是谁的模型。**
                    //
                    // ~/.claude 里跑的不一定是 Claude：用 Claude CLI 接 GLM
                    // 端点（ANTHROPIC_BASE_URL 指过去）是常见玩法，日志照样落在
                    // ~/.claude 下，而模型名是 glm-5.2。按目录归属会把 GLM 的
                    // 打满算到 Claude 头上会错误冻结主力开发额度；真实模型
                    // 可能是 GLM，必须按会话内容归属。宁可多花一次扫描。
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

    /// 从不可覆盖的执行尝试台账恢复额度信号。
    ///
    /// Runner 的原始会话日志不一定写进平台自己的目录（Qwen 这次就是由 worker
    /// 外壳收到 429），但终态 attempt 一定会保存 `handoffReason`。过去只在执行
    /// 当下写 cooldown；当时二进制较旧、iCloud 写失败或进程被杀，事实就留在
    /// attempts 里、额度台账却是空的，看板和调度随即把“已打空”误报成“可用”。
    ///
    /// 每个平台只看最新一次终态：后来的成功会证明旧 429 已经失效，不能翻旧账。
    static func hitsFromAttempts(
        _ attempts: [WorkAttempt], now: Date = Date(), within: TimeInterval = 14 * 86400
    ) -> [Hit] {
        var latestByID: [String: (index: Int, value: WorkAttempt)] = [:]
        for (index, attempt) in attempts.enumerated() {
            latestByID[attempt.attemptID] = (index, attempt)
        }

        var latestByPlatform: [Platform: (index: Int, value: WorkAttempt)] = [:]
        for item in latestByID.values where item.value.outcome != .running {
            let at = item.value.endedAt ?? item.value.startedAt
            guard now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) <= within else {
                continue
            }
            if let current = latestByPlatform[item.value.platform] {
                let currentAt = current.value.endedAt ?? current.value.startedAt
                if currentAt > at || (currentAt == at && current.index > item.index) { continue }
            }
            latestByPlatform[item.value.platform] = item
        }

        return latestByPlatform.values.compactMap { item in
            let attempt = item.value
            guard attempt.outcome == .failed,
                  let reason = attempt.handoffReason,
                  CooldownLedger.classify(reason) == .quotaExhausted else { return nil }
            let at = attempt.endedAt ?? attempt.startedAt
            let reset = parseReset(reason, now: at)
            // 没有重置时间的信号只在默认 5 小时保守窗内有效；有明确时间则
            // 一直保留到那个时刻。这样重启能恢复，过期后又不会继续误冻。
            guard reset.map({ $0 > now }) ?? (now.timeIntervalSince(at) <= 5 * 3600) else {
                return nil
            }
            return Hit(platform: attempt.platform, at: at, resetsAt: reset,
                       message: String(reason.prefix(200)))
        }
        .sorted { $0.at < $1.at }
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
        // 先收 attempts，再收平台会话日志。两条都是持久事实来源；谁能提供
        // 更晚、更精确的重置时间，下面的 active-until 比较就采信谁。
        var candidates = hitsFromAttempts(WorkAttemptStore.all(), now: now)
        for (p, roots) in sources {
            if let hit = scan(roots: roots, platform: p, now: now) {
                candidates.append(hit)
            }
        }

        var hits: [Hit] = []
        for hit in candidates.sorted(by: { $0.at < $1.at }) {
            // **别覆盖更晚的重置时间。** 已经在冷却且冷得更久的，
            // 说明有更权威的信息（比如我们自己撞到的 429），不动它。
            if let existing = CooldownLedger.active(now: now)[hit.platform],
               existing.until >= (hit.resetsAt ?? now) { continue }
            CooldownLedger.record(platform: hit.platform, cause: .quotaExhausted,
                                  detail: "从持久记录恢复：" + hit.message.prefix(120),
                                  knownResetAt: hit.resetsAt, now: hit.at)
            hits.append(hit)
        }
        return hits
    }
}
