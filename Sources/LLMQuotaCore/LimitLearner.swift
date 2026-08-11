import Foundation

/// 从真实用量里把「额度上限到底是多少」学出来。
///
/// 为什么需要它：套餐的上限经常查不到。Claude 根本不公布 5 小时窗口能发多少次请求，
/// 而没有上限就算不出剩余、算不出会作废多少，整个调度也就无从谈起。
/// 让用户去猜一个数字比留空更糟 —— 猜错会让作废预警系统性失真。
///
/// 两条路子：
///
/// 1. **反解**（可信）。平台回报了已用百分比时，它和我自己算出的同期用量构成一个方程：
///    `上限 = 用量 ÷ (百分比 / 100)`。Codex 会把 `used_percent` 写进会话日志，
///    本机就有 2793 条这样的观测，足够解出一个稳的值。
///
/// 2. **下限估计**（保守）。没有官方百分比时，取历史上任意一个完整窗口内的最大用量。
///    真实上限一定不低于它 —— 因为那次确实用出去了没被拒。
///
/// 反解还有个副产品：**能反推平台按什么计费**。分别按次数、按 token 去解，
/// 哪个口径解出来的一组估计值最集中，哪个就是平台真正的计量单位。
public enum LimitLearner {

    /// 候选计量口径。平台到底按哪个计费是未知的，所以每个都试一遍。
    public static let candidateMetrics: [QuotaMetric] = [
        // prompts 排第一：各家套餐公布的「每 5 小时 X 次」数的就是人发的消息条数，
        // 不是 API 调用次数。两者差十几倍。
        .prompts, .requests, .billableTokens, .totalTokens, .outputTokens
    ]

    public enum Method: String, Codable, Sendable {
        /// 由官方回报的百分比反解得出。
        case calibrated
        /// 历史最大观测用量，真实上限不会低于它。
        case lowerBound
    }

    public struct Estimate: Sendable {
        public var platform: Platform
        public var windowMinutes: Int
        public var windowLabel: String
        public var metric: QuotaMetric
        public var value: Double
        public var method: Method
        public var samples: Int
        /// 变异系数（标准差 / 均值）。越小说明这个口径越可能是平台真正的计量单位。
        public var spread: Double?
        public var note: String
        /// 其余候选口径的拟合情况。只有把这张对照表摊开，才能判断"最优口径"是真的
        /// 显著更好，还是四个都不像、只是矮子里拔将军。
        public var alternatives: [MetricFit] = []

        /// 拟合可信到能直接写进配置吗。
        ///
        /// 两个条件：绝对拟合要够紧（同一口径多次反解结果别乱跳），
        /// 而且要显著优于次优口径 —— 否则说明平台的计费口径根本不在候选集里，
        /// 比如按模型加权、或者按输入输出混合计价。这种时候写进去就是在制造假精度。
        public var isTrustworthy: Bool {
            guard let cv = spread, cv <= 0.15 else { return false }
            guard let runnerUp = alternatives
                .filter({ $0.metric != metric })
                .map(\.spread).min() else { return true }
            return cv <= runnerUp * 0.6
        }
    }

    public struct MetricFit: Sendable {
        public var metric: QuotaMetric
        public var value: Double
        public var spread: Double
    }

    // MARK: - 配置自检

    /// 配置里的上限和实测数据矛盾。
    ///
    /// 判据很硬：某个窗口内实际用出去了 N，而且没被拒，那真实上限就 ≥ N。
    /// 如果配置写的上限 < N，这个数字**一定是错的**。
    ///
    /// 这个检查值得单独做，是因为错的方向不对称：
    /// 上限配高了顶多让你撞一次限流；配低了会让工具一直显示"快满了"，
    /// 你于是不敢用 —— 正好造成这个工具本来要防的那种浪费。
    /// 而各家公布的数字很多是"约数"，配低完全可能发生。
    public struct Contradiction: Sendable {
        public var platform: Platform
        public var limitID: String
        public var windowLabel: String
        public var metric: QuotaMetric
        public var configured: Double
        public var observed: Double
    }

    public static func contradictions(
        scan: RawScan, config: PlansConfig, now: Date = Date()
    ) -> [Contradiction] {
        var out: [Contradiction] = []
        for plan in config.plans {
            let events = scan.events[plan.platform] ?? []
            guard !events.isEmpty else { continue }

            for limit in plan.limits {
                guard let configured = limit.limit, configured > 0 else { continue }
                let peak = peakUsage(events, windowSeconds: limit.windowSeconds,
                                     metric: limit.metric, now: now)
                if peak > configured {
                    out.append(Contradiction(
                        platform: plan.platform, limitID: limit.id,
                        windowLabel: limit.label, metric: limit.metric,
                        configured: configured, observed: peak
                    ))
                }
            }
        }
        return out
    }

    // MARK: - 入口

    public static func learn(from scan: RawScan, now: Date = Date()) -> [Estimate] {
        var out: [Estimate] = []
        for platform in Platform.allCases {
            let events = scan.events[platform] ?? []
            guard !events.isEmpty else { continue }

            let quotas = scan.quotas[platform] ?? []
            if !quotas.isEmpty {
                out.append(contentsOf: calibrate(platform: platform, events: events, quotas: quotas))
            }
            out.append(contentsOf: lowerBounds(platform: platform, events: events, now: now))
        }
        return out.sorted {
            $0.platform.sortIndex == $1.platform.sortIndex
                ? $0.windowMinutes < $1.windowMinutes
                : $0.platform.sortIndex < $1.platform.sortIndex
        }
    }

    // MARK: - 反解

    static func calibrate(
        platform: Platform, events: [UsageEvent], quotas: [OfficialQuota]
    ) -> [Estimate] {
        var out: [Estimate] = []
        let byWindow = Dictionary(grouping: quotas) { "\($0.id)|\($0.windowMinutes)" }

        for (_, group) in byWindow {
            guard let first = group.first, first.windowMinutes > 0 else { continue }
            let windowSeconds = TimeInterval(first.windowMinutes) * 60

            // 同一个百分比会被重复上报几十次。按 (重置时刻, 百分比) 去重，
            // 留最早那次 —— 那是用量刚跨过这个百分比的时刻，读数最贴近。
            var seen: [String: OfficialQuota] = [:]
            for q in group {
                guard let resets = q.resetsAt else { continue }
                let key = "\(Int(resets.timeIntervalSince1970))|\(Int(q.usedPercent.rounded()))"
                if let cur = seen[key], cur.observedAt <= q.observedAt { continue }
                seen[key] = q
            }

            // 百分比是整数上报的，太低时相对误差过大；100% 已经饱和（用量≥上限），
            // 反解会把上限算小。两头都掐掉。
            let usable = seen.values
                .filter { $0.usedPercent >= 10 && $0.usedPercent <= 90 }
                .sorted { $0.observedAt < $1.observedAt }
            guard usable.count >= 3 else { continue }

            var best: Estimate?
            var fits: [MetricFit] = []
            for metric in candidateMetrics {
                var samples: [Double] = []
                for q in usable {
                    guard let resets = q.resetsAt else { continue }
                    let windowStart = resets.addingTimeInterval(-windowSeconds)
                    let used = usage(events, from: windowStart, to: q.observedAt, metric: metric)
                    guard used > 0 else { continue }
                    samples.append(used / (q.usedPercent / 100))
                }
                guard samples.count >= 3 else { continue }

                let m = median(samples)
                let cv = coefficientOfVariation(samples)
                guard m > 0 else { continue }
                fits.append(MetricFit(metric: metric, value: m, spread: cv))

                let est = Estimate(
                    platform: platform,
                    windowMinutes: first.windowMinutes,
                    windowLabel: first.label,
                    metric: metric,
                    value: m,
                    method: .calibrated,
                    samples: samples.count,
                    spread: cv,
                    note: "由 \(samples.count) 条官方百分比观测反解"
                )
                // 离散度最小的口径最可能是平台真正的计量单位。
                if best == nil || cv < (best!.spread ?? .infinity) { best = est }
            }
            if var best {
                best.alternatives = fits.sorted { $0.spread < $1.spread }
                out.append(best)
            }
        }
        return out
    }

    // MARK: - 下限估计

    /// 各平台套餐常见的三层窗口。没有官方百分比时，对每一层给一个下限。
    static let commonWindows: [(minutes: Int, label: String)] = [
        (300, "5 小时"), (10080, "每周"), (43200, "每月")
    ]

    static func lowerBounds(platform: Platform, events: [UsageEvent], now: Date) -> [Estimate] {
        var out: [Estimate] = []
        guard let earliest = events.first?.timestamp else { return [] }

        for w in commonWindows {
            let windowSeconds = TimeInterval(w.minutes) * 60
            // 历史太短就给不出有意义的下限 —— 至少要覆盖两个完整窗口。
            guard now.timeIntervalSince(earliest) >= windowSeconds * 2 else { continue }

            let peakPrompts = peakUsage(events, windowSeconds: windowSeconds,
                                        metric: .prompts, now: now)
            let peakRequests = peakUsage(events, windowSeconds: windowSeconds,
                                         metric: .requests, now: now)
            let peakTokens = peakUsage(events, windowSeconds: windowSeconds,
                                       metric: .billableTokens, now: now)
            guard peakRequests > 0 else { continue }

            if peakPrompts > 0 {
                out.append(Estimate(
                    platform: platform, windowMinutes: w.minutes, windowLabel: w.label,
                    metric: .prompts, value: peakPrompts, method: .lowerBound, samples: 1,
                    spread: nil,
                    note: "历史峰值窗口发了 \(Int(peakPrompts)) 条消息 —— 这一档才是能和官方公布数字直接对照的"
                ))
            }
            out.append(Estimate(
                platform: platform, windowMinutes: w.minutes, windowLabel: w.label,
                metric: .requests, value: peakRequests, method: .lowerBound, samples: 1,
                spread: nil,
                note: "历史峰值窗口用了 \(Int(peakRequests)) 次，真实上限不会低于它"
            ))
            out.append(Estimate(
                platform: platform, windowMinutes: w.minutes, windowLabel: w.label,
                metric: .billableTokens, value: peakTokens, method: .lowerBound, samples: 1,
                spread: nil,
                note: "历史峰值窗口用了 \(Format.compact(peakTokens)) token"
            ))
        }
        return out
    }

    // MARK: - 工具

    /// 找出历史上任意一个窗口内的最大用量。
    ///
    /// 滑的是窗口的**结束时刻**，不是开始时刻。这个区别是被测试逼出来的：
    /// 原先写成 `while start + window <= now`，等于只评估已经走完的完整窗口，
    /// 当前这一窗永远看不到。而"上限配低了"最可能暴露的时刻恰恰是当下 ——
    /// 一堆调用挤在最近几小时里、还没满一个窗，检查就直接跳过了。
    /// 历史比窗口还短时同理，那时一个窗口都凑不满，旧写法一个样本都取不到。
    static func peakUsage(
        _ events: [UsageEvent], windowSeconds: TimeInterval, metric: QuotaMetric, now: Date
    ) -> Double {
        guard let earliest = events.first?.timestamp else { return 0 }
        let step = max(60, windowSeconds / 12)
        var peak = 0.0
        var end = min(now, earliest.addingTimeInterval(windowSeconds))
        while end < now {
            peak = max(peak, usage(events, from: end.addingTimeInterval(-windowSeconds),
                                   to: end, metric: metric))
            end = end.addingTimeInterval(step)
        }
        // 步长可能刚好跨过 now，当前这一窗必须单独补一次。
        return max(peak, usage(events, from: now.addingTimeInterval(-windowSeconds),
                               to: now, metric: metric))
    }

    static func usage(
        _ events: [UsageEvent], from: Date, to: Date, metric: QuotaMetric
    ) -> Double {
        var total = 0.0
        for e in events {
            if e.timestamp < from { continue }
            if e.timestamp >= to { break }   // events 已按时间升序
            switch metric {
            case .prompts: total += Double(e.prompts)
            case .requests: total += Double(e.requests)
            case .outputTokens: total += Double(e.outputTokens)
            case .billableTokens:
                total += Double(e.inputTokens + e.outputTokens + e.cacheWriteTokens)
            case .totalTokens:
                total += Double(e.inputTokens + e.outputTokens
                    + e.cacheReadTokens + e.cacheWriteTokens)
            case .cost, .percent: total += 0
            }
        }
        return total
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func coefficientOfVariation(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return .infinity }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return .infinity }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count - 1)
        return variance.squareRoot() / mean
    }
}
