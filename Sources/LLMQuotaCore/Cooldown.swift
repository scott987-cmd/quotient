import Foundation

/// 平台冷却账本：撞过的墙不再撞第二次。
///
/// 由一次真实事故催生 —— Kimi 的额度早就用完了，但因为它的套餐数值查不到、
/// `limit` 是空的，调度器完全无从判断，只能白建 worktree、白跑一趟才发现。
///
/// 关键洞察是：**平台自己在报错里把答案说了**
/// （"Your quota will be refreshed in the next cycle"）。
/// 与其继续去猜各家的确切上限，不如撞一次就记下来，在冷却期内跳过它。
/// 这条路对「数值查不到」的平台同样有效，而查数值那条路对它们无效。
public struct Cooldown: Codable, Sendable {
    public enum Cause: String, Codable, Sendable {
        case quotaExhausted
        case authFailed
        case environmentBroken
        /// 不会自己好的那种：账号类型被停止支持、CLI 被下线。
        /// 退避重试对它毫无意义，只是每隔几小时白烧一次。
        case permanentlyUnsupported

        /// 冷却原因的中文展示名。
        ///
        /// 在 `Work.decide()` 里拼成 "额度用尽，2h后重试" 这样的拒绝理由；
        /// 在 `llmq work cooldowns` 里作为表格列；在 `QuotaEngine.report` 里
        /// 写入 `PlatformReport.cooldownReason`；任务失败时打印到终端并记入 OfficeEvent。
        public var displayName: String {
            switch self {
            case .quotaExhausted: return "额度用尽"
            case .authFailed: return "认证失败"
            case .environmentBroken: return "环境异常"
            case .permanentlyUnsupported: return "不再受支持"
            }
        }

        /// 需要人介入才可能恢复，别再自动重试。
        ///
        /// `record()` 据此把冷却时长直接设为 30 天而不是走退避梯度 --
        /// 反正自己不会好，每隔几小时重试只是白烧额度。
        /// `llmq work cooldowns` 据此把剩余时间列显示成红色的"需人工处理"而非倒计时，
        /// 提醒用户去改账号或换工具，处理完用 `llmq work resume <平台>` 手动解除。
        public var needsHumanFix: Bool { self == .permanentlyUnsupported }
    }

    public var platform: Platform
    public var cause: Cause
    public var since: Date
    public var until: Date
    /// 连续失败次数。用来做指数退避 —— 一直失败的平台没必要每 15 分钟试一次。
    public var strikes: Int
    public var detail: String

    /// 冷却是否尚未过期。`CooldownLedger.active()` 用它过滤掉已过期的条目；
    /// `record()` 用它判断上一次失败是否还在冷却期内 -- 在期内则算连续失败，
    /// strikes +1；不在则说明中间恢复过，strikes 归 1 重新计数。
    public func isActive(now: Date = Date()) -> Bool { now < until }

    /// 距离冷却结束还有多久。调度器把它写进拒绝理由（"2h后重试"），
    /// CLI 和任务失败提示用它告诉用户多久后才会再给这个平台派活，
    /// OfficeEvent 也记一份用于办公室可视化。
    public var remaining: TimeInterval { max(0, until.timeIntervalSinceNow) }
}

public enum CooldownLedger {
    /// 冷却状态也是账号级的：Kimi 额度用尽，在哪台机器上都一样用尽。
    /// A 机器撞到之后 B 机器不该再白撞一次。
    static var file: URL {
        Paths.iCloudConfigDir?.appendingPathComponent("cooldowns.json")
            ?? Paths.appSupport.appendingPathComponent("cooldowns.json")
    }

    /// 退避梯度。第一次撞墙只等一小会儿（可能只是瞬时抖动），
    /// 连续撞就越等越久，避免把时间耗在一个已经躺平的平台上。
    static let backoff: [TimeInterval] = [
        15 * 60,      // 15 分钟
        60 * 60,      // 1 小时
        4 * 3600,     // 4 小时
        12 * 3600,    // 12 小时
    ]

    /// 从 `cooldowns.json` 读出全部冷却记录，按平台索引成字典。
    ///
    /// 文件在 iCloud 配置目录下（跨机器同步），读不到或解析失败时返回空字典 --
    /// 首次运行或文件损坏时不阻塞调度，只是没有冷却保护而已。
    /// `active()`、`record()`、`resume()`、`clear()` 都先调它拿到当前账本再改。
    public static func load() -> [Platform: Cooldown] {
        // `file` 可能在 iCloud 上。这一行卡死过整个菜单栏 App。
        guard let data = ICloudSafe.read(file),
              let list = try? SnapshotCoding.decoder().decode([Cooldown].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.platform, $0) })
    }

    static func save(_ map: [Platform: Cooldown]) {
        try? Paths.ensureDirectories()
        guard let data = try? SnapshotCoding.prettyEncoder()
            .encode(map.values.sorted { $0.platform.sortIndex < $1.platform.sortIndex })
        else { return }
        // 这一行卡死过 worker：跑完任务记冷却时写 iCloud，永久阻塞。
        ICloudSafe.write(data, to: file)
    }

    /// 当前处于冷却中的平台。
    ///
    /// 加载全部记录后用 `isActive()` 过滤掉已过期的。三处调用：
    /// - `Work.decide()` 拿它决定调度时跳过哪些平台（撞过的墙不再撞）；
    /// - `QuotaEngine.report()` 拿它在额度报告里标注 `cooldownUntil` / `cooldownReason`，
    ///   否则冷却中的平台会显示成"连续空闲"让人误以为只是没派活；
    /// - `llmq work cooldowns` 拿它给用户列出当前冷却表。
    public static func active(now: Date = Date()) -> [Platform: Cooldown] {
        load().filter { $0.value.isActive(now: now) }
    }

    /// 记一次失败，返回这次定下的冷却。
    ///
    /// 由 `runOneTask()` 和 `probePlatforms()` 在 `classify()` 判定属于平台侧问题后调用。
    /// 连续失败（上一次冷却未过期或原因相同）则 strikes 递增、退避梯度加长；
    /// 中间恢复过则 strikes 归 1。平台报了确切的重置时间就直接采信，比退避猜得准。
    /// 永久性故障（`needsHumanFix`）直接冷却 30 天，等人工处理后用 `resume()` 解除。
    @discardableResult
    public static func record(
        platform: Platform, cause: Cooldown.Cause, detail: String,
        knownResetAt: Date? = nil, now: Date = Date()
    ) -> Cooldown {
        var map = load()
        // 上一次的记录还没过期就算连续失败；已经过期说明中间恢复过，重新计数。
        let prior = map[platform]
        let strikes = (prior?.isActive(now: now) == true || prior?.cause == cause)
            ? min((prior?.strikes ?? 0) + 1, backoff.count) : 1

        // 平台明确告诉我们什么时候恢复时，直接采信 —— 比退避猜得准。
        let until: Date
        if cause.needsHumanFix {
            // 这类要你去改账号或换工具才能好。退避重试只是每隔几小时白烧一次，
            // 所以直接冷却 30 天，等你处理完手动 `llmq work resume <平台>`。
            until = now.addingTimeInterval(30 * 86400)
        } else if let knownResetAt, knownResetAt > now {
            until = knownResetAt
        } else if cause == .quotaExhausted {
            // **额度用尽不做指数退避。**
            //
            // 退避的前提是「重试大概率还是失败，而且重试本身有代价」。
            // 额度用尽不满足这个前提：它有确定的恢复时刻，最坏也就是
            // 窗口长度。实测代价 —— strikes 堆到 4 之后 Claude 被冻
            // 1 天 16 小时，而它是 5 小时窗，那 35 小时是白冻的，
            // 期间所有高危任务（Claude 是本机指挥兼架构师）全线停摆。
            //
            // 没拿到确切重置时间就按 5 小时保守估：猜早了下次撞 429 再记
            // 一条（而且现在撞顶还会被 QuotaCeiling 采成上限样本，不算白撞），
            // 猜晚了才是纯浪费。宁可多撞几次，不要白冻一整天。
            until = now.addingTimeInterval(5 * 3600)
        } else {
            until = now.addingTimeInterval(backoff[min(strikes - 1, backoff.count - 1)])
        }

        let cd = Cooldown(
            platform: platform, cause: cause, since: now, until: until,
            strikes: strikes, detail: String(detail.prefix(200))
        )
        map[platform] = cd
        save(map)
        return cd
    }

    /// 手动解除冷却。永久性故障处理完之后用。
    ///
    /// 由 `llmq work resume <平台>` 调用。永久性故障被 `record()` 冷却 30 天，
    /// 退避不会让它提前结束 -- 用户改了账号或换了工具之后，手动调这里把条目删掉，
    /// 调度器下一轮就能重新选这个平台。返回 false 说明本来就没在冷却中。
    public static func resume(_ platform: Platform) -> Bool {
        var map = load()
        guard map.removeValue(forKey: platform) != nil else { return false }
        save(map)
        return true
    }

    /// 跑成功了就清掉，让计数从头开始。
    ///
    /// `probePlatforms()` 探测成功时调它清掉旧冷却；`runOneTask()` 任务状态为 `.done`
    /// 时也调它 -- 一次成功就证明平台恢复了，连续失败计数归零，下次失败从第一档退避重新开始。
    public static func clear(_ platform: Platform) {
        var map = load()
        guard map[platform] != nil else { return }
        map.removeValue(forKey: platform)
        save(map)
    }

    /// 从 agent 的报错文本里判断该不该进冷却、进哪种。
    ///
    /// 只认平台侧的问题。agent 自己把任务干砸了不该让整个平台停摆 --
    /// 那是任务的问题，换个平台大概率一样砸。
    ///
    /// 由 `runOneTask()` 和 `probePlatforms()` 调用，传入 agent 的 stdout+stderr。
    /// 返回 nil 表示不是平台的问题，不进冷却。注意永久性故障要先于环境故障检查 --
    /// "no longer supported" 里也含 "not found"，顺序反了会把永久故障降级成临时故障。
    public static func classify(_ text: String) -> Cooldown.Cause? {
        let t = text.lowercased()
        let lines = t.split(separator: "\n").map(String.init)

        // **额度用尽要「错误信号 + 额度措辞」同时出现在同一行。**
        //
        // 早先是对整段输出做关键词包含判断，代价实测到了：火山方舟跑一个
        // 游戏任务超时被杀，45 分钟的输出里撞上 "insufficient"（英文里
        // "insufficient contrast"「对比度不足」这种说法极常见），整段就被
        // 判成额度用尽 —— 一个还能用的平台被冻了 1 天 16 小时。
        // 在这个项目里更糟：agent 天天读写额度相关的代码和文档，
        // 输出里必然出现「额度」「quota」，等于让干活的人自己把自己冻上。
        //
        // 双条件之后，误报要求同一行里既有 HTTP 错误码/明确的拒绝措辞，
        // 又有额度措辞 —— 那基本只有服务端自己会这么说话。
        let errorSignals = ["429", "rate_limit", "ratelimit", "error", "rejected",
                            "exhausted", "exceeded", "已达到", "用尽", "超出"]
        // 这些词单独出现毫无意义（"quota" 在这个项目的代码里满地都是），
        // 必须配合上面的错误信号才作数。
        let quotaWords = ["quota", "usage limit", "insufficient", "配额", "额度",
                          "使用上限", "限额"]
        for line in lines {
            guard errorSignals.contains(where: { line.contains($0) }),
                  quotaWords.contains(where: { line.contains($0) }) else { continue }
            return .quotaExhausted
        }
        // 整段里出现明确到不可能误伤的措辞，也认。
        // 只有服务端会这么说话的整句，单条件即可 —— agent 的正常输出里
        // 不会冒出「购买额外用量」这种话。
        let unambiguous = ["rate limit exceeded", "quota exhausted",
                           "you've reached your usage limit",
                           "refreshed in the next cycle", "upgrade your plan",
                           "purchase extra usage", "已达到 5 小时的使用上限"]
        if unambiguous.contains(where: { t.contains($0) }) { return .quotaExhausted }

        let auth = ["not logged in", "oauth", "authenticate", "unauthorized", "401", "403",
                    "invalid api key", "no credentials", "please run /login"]
        if auth.contains(where: { t.contains($0) }) { return .authFailed }

        // 先判永久性的 —— 它的文本里也可能带 env 的关键词，顺序不能反。
        let permanent = ["no longer supported", "ineligible", "has been deprecated",
                         "end of life", "please migrate to"]
        if permanent.contains(where: { t.contains($0) }) { return .permanentlyUnsupported }

        let env = ["command not found", "enoent", "econnrefused", "enotfound",
                   "cannot combine"]
        if env.contains(where: { t.contains($0) }) { return .environmentBroken }

        return nil
    }
}

// MARK: - 从错误文本里抠重置时间

extension CooldownLedger {
    /// 从平台的报错原文里解析「什么时候恢复」。
    ///
    /// 429 的原文经常自带答案（Qwen：「The quota will reset at
    /// 08-17 01:36:00 UTC」），而在此之前**没有任何调用方**把它传给
    /// `record(knownResetAt:)` —— 于是一个明说了「周日凌晨才恢复」的平台
    /// 被按 59 分钟退避反复重试，整个周末每小时白撞一次，
    /// 手机上还一直显示「可调度」。
    ///
    /// 只认两种高置信格式，解析不出就返回 nil 走退避 ——
    /// 宁可退避也别把误解析的时间当真。
    public static func parseResetTime(_ text: String, now: Date = Date()) -> Date? {
        // 形态一：ISO8601（带 T 或空格，带不带秒/时区都试）
        let isoLike = #"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2})?)\s*(UTC|Z)?"#
        // 形态二：无年份 MM-dd HH:mm:ss UTC（Qwen 的写法）
        let short = #"(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s*UTC"#

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        if let m = text.range(of: isoLike, options: .regularExpression) {
            let s = String(text[m])
            let fmts = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
                        "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"]
            let cleaned = s.replacingOccurrences(of: "UTC", with: "")
                .replacingOccurrences(of: "Z", with: "")
                .trimmingCharacters(in: .whitespaces)
            for f in fmts {
                let df = DateFormatter()
                df.dateFormat = f
                df.timeZone = TimeZone(identifier: "UTC")
                df.locale = Locale(identifier: "en_US_POSIX")
                if let d = df.date(from: cleaned), d > now,
                   d.timeIntervalSince(now) < 40 * 86400 {
                    return d
                }
            }
        }
        if let m = text.range(of: short, options: .regularExpression) {
            let parts = String(text[m])
                .replacingOccurrences(of: "UTC", with: "")
                .trimmingCharacters(in: .whitespaces)
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm:ss"
            df.timeZone = TimeZone(identifier: "UTC")
            df.locale = Locale(identifier: "en_US_POSIX")
            if let partial = df.date(from: parts) {
                // 无年份：套今年，如果算出来在过去就是跨年，加一年。
                var comps = cal.dateComponents([.month, .day, .hour, .minute, .second],
                                               from: partial)
                comps.year = cal.component(.year, from: now)
                if var d = cal.date(from: comps) {
                    if d <= now { comps.year! += 1; d = cal.date(from: comps) ?? d }
                    if d > now, d.timeIntervalSince(now) < 40 * 86400 { return d }
                }
            }
        }
        return nil
    }
}
