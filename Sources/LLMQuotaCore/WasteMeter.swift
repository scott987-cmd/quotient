import Foundation

/// 「到底浪费了多少」—— 一个**不需要知道上限**就能算的口径。
///
/// ## 为什么必须换口径
///
/// 这套系统存在的唯一理由是「一分不浪费」，可它到现在都答不出「浪费了多少」。
/// 原因是硬的：浪费量 = 上限 − 已用，而实测 13 个额度窗口里**只有 3 个有上限**
/// （Codex 周、MiniMax 两个，都是平台直报的百分比），其余全是 unconfigured。
/// 而且那不是没填，是**填不得**：GLM 公布的是积分（按 token 折算还带工作日
/// 三倍，口径对不上）、Kimi 和 Claude 不公布、Qwen 的免费层已经关停。
/// 见 STATUS.md 里那张「能填什么、不能填什么」的表。
///
/// 一个来源可靠但口径对不上的分母，比没有分母更危险 —— 它让整个百分比
/// 看起来像真的。
///
/// ## 换成什么
///
/// **空窗**：一个完整过去的额度窗口，期间一次调用都没有。
///
/// 这个判定跟上限完全无关，而它照样是明确的损失：5 小时窗滚过去了、
/// 一次都没用，那段配额永久没了，无论天花板是 200 次还是 2000 次。
///
/// 而且它比「用了百分之几」更能驱动行动：看到「过去 7 天有 19 个 5 小时窗
/// 是空的」，下一步很清楚 —— 往里塞活。看到「已用 1%」则什么也推不出来，
/// 因为不知道 100% 是多少。
public enum WasteMeter {

    public struct Report: Codable, Sendable, Equatable {
        /// 窗口长度（分钟）。
        public var windowMinutes: Int
        /// 统计区间里有多少个**完整过去**的窗口。
        public var total: Int
        /// 其中一次调用都没有的有多少个。
        public var idle: Int
        /// 到现在为止，连续空了几个窗口。
        ///
        /// 单独给这个数是因为它和总体空窗率回答的是不同问题：
        /// 空窗率说「长期用得够不够」，连续空窗说「**现在**是不是正闲着」——
        /// 后者才是「要不要马上塞活进去」的依据。
        public var currentStreak: Int

        public var idleFraction: Double {
            total > 0 ? Double(idle) / Double(total) : 0
        }

        public init(windowMinutes: Int, total: Int, idle: Int, currentStreak: Int) {
            self.windowMinutes = windowMinutes
            self.total = total
            self.idle = idle
            self.currentStreak = currentStreak
        }
    }

    /// 算某一个窗口长度的空窗情况。
    ///
    /// - Parameters:
    ///   - buckets: 这个平台的全部用量桶（跨机器合并后的）。
    ///   - windowMinutes: 窗口长度。
    ///   - since: 统计起点，通常是快照的 retentionStart。
    ///     **不能往前算过头** —— 采集只保留 30 天，更早的窗口在数据里
    ///     一律是空的，算进去会把空窗率虚高到接近 100%，
    ///     而那个数字看起来像「这个订阅完全没在用」。
    ///   - now: 现在。
    public static func measure(
        buckets: [UsageBucket], windowMinutes: Int,
        since: Date, now: Date = Date()
    ) -> Report {
        let w = Double(windowMinutes) * 60
        guard w > 0 else { return Report(windowMinutes: windowMinutes, total: 0, idle: 0,
                                         currentStreak: 0) }

        // **一个桶都没有 ≠ 一次都没用。**
        //
        // 拿真实数据一跑就撞上了：MiniMax 报「153 个窗口全空、连续空 153 个」，
        // 而它其实一直在被用 —— `mmx quota show` 显示 5 小时窗已用 1%、
        // 周窗已用 5%。它只是**不产生本地用量日志**（没有 Claude Code 那种
        // 会话文件），所以桶数是 0。
        //
        // 零个桶意味着「这条路子测不了这个平台」，而不是「这个平台闲着」。
        // 把没有证据当成证据表明没有，正好是这个项目里反复出现的那类错误。
        //
        // 真正没在用的平台由已有的「装了但没在用」那条预警负责，
        // 不需要这里也去猜 —— 猜错的代价是给一个正在花钱的服务扣上
        // 「完全没用」的帽子，而那会让人去退订它。
        guard !buckets.isEmpty else {
            return Report(windowMinutes: windowMinutes, total: 0, idle: 0, currentStreak: 0)
        }

        func slot(_ d: Date) -> Int64 {
            Int64((d.timeIntervalSince1970 / w).rounded(.down))
        }

        // 有调用的窗口。判据是 requests > 0，不看 token ——
        // 一次调用哪怕只花几十个 token，那个窗口也**被用过了**，不算空窗。
        var used: Set<Int64> = []
        for b in buckets where b.requests > 0 { used.insert(slot(b.start)) }

        let firstSlot = slot(since)
        // **当前那个窗口不算。**
        //
        // 它还没结束，现在为空不代表最终为空。算进去的话，
        // 每个窗口刚开始的几分钟空窗率都会跳一下，
        // 而一个自己会抖的指标没人会信。
        let currentSlot = slot(now)
        guard currentSlot > firstSlot else {
            return Report(windowMinutes: windowMinutes, total: 0, idle: 0, currentStreak: 0)
        }

        var total = 0, idle = 0
        for s in firstSlot..<currentSlot {
            total += 1
            if !used.contains(s) { idle += 1 }
        }

        // 连续空窗：从当前窗口的前一个往回数。
        var streak = 0
        var s = currentSlot - 1
        while s >= firstSlot, !used.contains(s) { streak += 1; s -= 1 }

        return Report(windowMinutes: windowMinutes, total: total, idle: idle,
                      currentStreak: streak)
    }

    /// 给一个平台算它所有窗口长度的空窗情况。
    ///
    /// 窗口长度从这个平台**配置里真实存在的窗口**来，不是随便挑几个 ——
    /// 一个只有周额度的平台，算它的「5 小时空窗率」没有任何意义，
    /// 那只是把一个不存在的窗口的统计摆出来充数。
    public static func measureAll(
        buckets: [UsageBucket], windows: [Int],
        since: Date, now: Date = Date()
    ) -> [Report] {
        Set(windows).sorted().map {
            measure(buckets: buckets, windowMinutes: $0, since: since, now: now)
        }
    }

    /// 一句人话。
    ///
    /// 刻意不说「浪费了多少 token」—— 那个数算不出来，说了就是编。
    /// 只说「多少个窗口空着过去了」，这是能站住的。
    public static func sentence(_ r: Report) -> String {
        let name = label(minutes: r.windowMinutes)
        guard r.total > 0 else {
            return "\(name)：算不出来（这个平台没有本地用量日志，或者数据还不够一个窗口）"
        }
        let pct = Int((r.idleFraction * 100).rounded())
        var s = "\(name)：过去 \(r.total) 个窗口里 \(r.idle) 个一次都没用（\(pct)%）"
        if r.currentStreak > 0 {
            s += "，**已经连续空了 \(r.currentStreak) 个**"
        }
        return s
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时窗"
        case 240: return "4 小时窗"
        case 1440: return "每日窗"
        case 10080: return "每周窗"
        case 43200: return "每月窗"
        default: return minutes >= 60 ? "\(minutes / 60) 小时窗" : "\(minutes) 分钟窗"
        }
    }

    // MARK: - 多机聚合入口

    /// 单个平台的空窗结论。
    ///
    /// **刻意把「算不出来」和「算出来是空的」分成互斥的分支。**
    /// 「没有任何用量桶」和「窗口全空」是两件完全不同的事：
    /// 前者是这条路子测不了这个平台（比如 MiniMax 不产生本地用量日志），
    /// 后者才是真的闲着。混进同一条路，测不了的平台就会被输出成
    /// 「100% 空窗」—— 把没有证据当成证据表明没有，正好是
    /// measure() 里 MiniMax 那个坑的复刻。
    public enum Verdict: Sendable, Equatable {
        /// 算出来了。个别 Report 的 total 仍可能是 0
        ///（数据还不够一个完整窗口），sentence 会如实说明。
        case measured([Report])
        /// 探测到了平台，但所有机器的桶加在一起还是零个。
        /// 这是「测不出来」，不是「没用过」。
        case noBuckets
        /// 配置里查不到这个平台的任何窗口长度（windowMinutes）。
        case noWindowConfigured
        /// 拿不到任何一个快照的数据保留起点。
        case noRetentionStart
    }

    /// 一个平台的空窗结论 + 它是哪种情况。
    public struct PlatformWaste: Sendable, Equatable {
        public var platform: Platform
        public var verdict: Verdict

        public init(platform: Platform, verdict: Verdict) {
            self.platform = platform
            self.verdict = verdict
        }
    }

    /// 把各机器的快照按平台聚合，对每个**至少一台机器探测到了**的平台
    /// 给出空窗结论。纯函数，不读盘 —— 快照和配置都从外面传进来。
    ///
    /// 聚合规则：
    /// - 桶按平台跨机器合并成一份，不是只取第一台。只收 detected 的，
    ///   和 QuotaEngine 同一条判据。
    /// - 窗口长度取该平台 plan.limits 里的 windowMinutes。
    /// - 起点取**探测到该平台的快照**里最早的 retentionStart。
    ///   往前算过头的话，采集覆盖不到的那段一律是空的，
    ///   空窗率会虚高到接近 100%。
    ///
    /// 查不到窗口长度、拿不到保留起点时，分别落到对应的 Verdict，
    /// **绝不退回默认值悄悄算一个数出来**。
    public static func assessAll(
        snapshots: [MachineSnapshot], config: PlansConfig, now: Date = Date()
    ) -> [PlatformWaste] {
        var out: [PlatformWaste] = []
        for platform in Platform.activeCases {
            var detected = false
            var buckets: [UsageBucket] = []
            var retentionStarts: [Date] = []
            for snap in snapshots {
                guard let ps = snap.platforms.first(where: { $0.platform == platform })
                else { continue }
                guard ps.detected else { continue }
                detected = true
                buckets.append(contentsOf: ps.buckets)
                retentionStarts.append(snap.retentionStart)
            }
            guard detected else { continue }

            let verdict: Verdict
            if buckets.isEmpty {
                // 先判这个：零个桶时窗口配置再全也算不出来。
                verdict = .noBuckets
            } else if retentionStarts.isEmpty {
                // detected 为真时这里实际到不了 —— 留着这条分支是为了
                // 哪天快照结构变了（比如 retentionStart 变可选），
                // 坏数据得到的是明说，而不是一个编造的默认起点。
                verdict = .noRetentionStart
            } else {
                let windows = config.plan(for: platform)?.limits.map(\.windowMinutes) ?? []
                if windows.isEmpty {
                    verdict = .noWindowConfigured
                } else {
                    verdict = .measured(measureAll(
                        buckets: buckets, windows: windows,
                        since: retentionStarts.min()!, now: now))
                }
            }
            out.append(PlatformWaste(platform: platform, verdict: verdict))
        }
        return out
    }
}
