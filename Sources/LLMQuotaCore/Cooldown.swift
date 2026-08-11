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

        public var displayName: String {
            switch self {
            case .quotaExhausted: return "额度用尽"
            case .authFailed: return "认证失败"
            case .environmentBroken: return "环境异常"
            case .permanentlyUnsupported: return "不再受支持"
            }
        }

        /// 需要人介入才可能恢复，别再自动重试。
        public var needsHumanFix: Bool { self == .permanentlyUnsupported }
    }

    public var platform: Platform
    public var cause: Cause
    public var since: Date
    public var until: Date
    /// 连续失败次数。用来做指数退避 —— 一直失败的平台没必要每 15 分钟试一次。
    public var strikes: Int
    public var detail: String

    public func isActive(now: Date = Date()) -> Bool { now < until }
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

    public static func load() -> [Platform: Cooldown] {
        guard let data = try? Data(contentsOf: file),
              let list = try? SnapshotCoding.decoder().decode([Cooldown].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.platform, $0) })
    }

    static func save(_ map: [Platform: Cooldown]) {
        try? Paths.ensureDirectories()
        guard let data = try? SnapshotCoding.prettyEncoder()
            .encode(map.values.sorted { $0.platform.sortIndex < $1.platform.sortIndex })
        else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// 当前处于冷却中的平台。
    public static func active(now: Date = Date()) -> [Platform: Cooldown] {
        load().filter { $0.value.isActive(now: now) }
    }

    /// 记一次失败。返回这次定下的冷却。
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
    public static func resume(_ platform: Platform) -> Bool {
        var map = load()
        guard map.removeValue(forKey: platform) != nil else { return false }
        save(map)
        return true
    }

    /// 跑成功了就清掉，让计数从头开始。
    public static func clear(_ platform: Platform) {
        var map = load()
        guard map[platform] != nil else { return }
        map.removeValue(forKey: platform)
        save(map)
    }

    /// 从 agent 的报错文本里判断该不该进冷却、进哪种。
    ///
    /// 只认平台侧的问题。agent 自己把任务干砸了不该让整个平台停摆 ——
    /// 那是任务的问题，换个平台大概率一样砸。
    public static func classify(_ text: String) -> Cooldown.Cause? {
        let t = text.lowercased()
        let quota = ["quota", "rate limit", "429", "usage limit", "insufficient",
                     "refreshed in the next cycle", "upgrade your plan", "额度", "配额"]
        if quota.contains(where: { t.contains($0) }) { return .quotaExhausted }

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
