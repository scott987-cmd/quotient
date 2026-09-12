import Foundation

/// 撞顶观测：服务端说「你用完了」的那一刻，窗口里到底用掉了多少。
///
/// ## 为什么这是最值钱的样本
///
/// 估算上限一共只有三种依据，可信度差着数量级：
///
/// 1. **官方百分比反解** —— 最好，但只有 Codex 报，而且实测离散度 36%
///    （拟合不可信，不会自动写入）
/// 2. **历史最大用量**（现在的 `lowerBound`）—— 只能说「至少这么多」。
///    从没撞过顶的平台，这个数可能只有真实上限的一半，等于没估。
/// 3. **撞顶观测** ← 这个文件。服务端拒绝的那一刻是**唯一一个已知点**：
///    此刻窗口用量就在上限上。不需要拟合，不需要样本量。
///
/// 而在此之前，撞顶信号只被写进冷却台账用来「暂停派活」，学完就扔 ——
/// 台账还是 `[Platform: Cooldown]`，每个平台只留最新一条，撞过几次都被覆盖了。
/// 最硬的证据反而是保留时间最短的。
///
/// ## 为什么在「撞顶之后」采样，而不是撞顶的瞬间
///
/// 因为撞顶之后用量就不涨了 —— 请求全被拒。所以撞顶后的第一次采集反而是
/// 最干净的读数：不用抢在那一毫秒，也不会被后续增量污染。
public enum QuotaCeiling {

    public struct Observation: Codable, Sendable {
        public var platform: Platform
        public var quotaPoolID: String?
        public var at: Date
        public var windowMinutes: Int
        public var windowLabel: String
        /// 窗口起点。同一个窗口只记一条 —— 不然一次打满会被反复采样成十几条，
        /// 看着样本很多，其实全是同一个事实。
        public var windowStart: Date
        /// 撞顶时各口径的用量。哪个口径是平台真正的计费单位并不知道，
        /// 所以全都留着，交给上限学习器去比。
        public var usage: [String: Double]
        public var detail: String

        private enum CodingKeys: String, CodingKey {
            case platform, quotaPoolID, at, windowMinutes, windowLabel
            case windowStart, usage, detail
        }

        public init(platform: Platform, quotaPoolID: String? = nil, at: Date,
                    windowMinutes: Int, windowLabel: String, windowStart: Date,
                    usage: [String: Double], detail: String) {
            self.platform = platform; self.quotaPoolID = quotaPoolID; self.at = at
            self.windowMinutes = windowMinutes; self.windowLabel = windowLabel
            self.windowStart = windowStart; self.usage = usage; self.detail = detail
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? .codex
            quotaPoolID = try c.decodeIfPresent(String.self, forKey: .quotaPoolID)
            at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
            windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? 0
            windowLabel = try c.decodeIfPresent(String.self, forKey: .windowLabel) ?? ""
            windowStart = try c.decodeIfPresent(Date.self, forKey: .windowStart) ?? .distantPast
            usage = try c.decodeIfPresent([String: Double].self, forKey: .usage) ?? [:]
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        }
    }

    static var path: URL {
        Paths.appSupport.appendingPathComponent("quota-ceilings.jsonl")
    }

    public static func all() -> [Observation] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return SafeDecode.json(d, as: Observation.self,
                                   from: "quota-ceilings.jsonl", decoder: dec)
        }
    }

    /// 采集后调用：把此刻处于「额度打满」冷却中的平台，各窗口的用量记下来。
    ///
    /// - Returns: 这次新记下的观测（已存在的窗口不重复记）。
    @discardableResult
    public static func capture(dashboard: Dashboard, now: Date = Date()) -> [Observation] {
        let cooling = CooldownLedger.activeEntries(now: now)
        var existing = Set(all().map {
            key($0.platform, $0.quotaPoolID, $0.windowStart, $0.windowMinutes)
        })
        var fresh: [Observation] = []

        for report in dashboard.reports {
            let poolID = report.localQuotaPoolID
            let statuses = poolID.flatMap { report.quotaPool(id: $0)?.statuses }
                ?? report.statuses
            guard let cd = cooling.filter({
                $0.platform == report.platform
                    && ($0.quotaPoolID == poolID
                        || (poolID == "\(report.platform.rawValue):default"
                            && $0.quotaPoolID == nil))
            }).max(by: { $0.until < $1.until }), cd.cause == .quotaExhausted else { continue }
            for s in statuses {
                // **只记真正打满的那个窗口。** 冷却是平台级的，打满的却是
                // 某一个窗口：Claude 5 小时窗打满时周窗可能才用了三成，
                // 把周窗也记成撞顶，学出来的周上限会比真值低一大截。
                //
                // 怎么知道是哪个窗口？**服务端那句话里通常直接写了** ——
                //「已达到 5 小时的使用上限」「1-week quota exhausted」。
                // 不能拿冷却的 until 去对：实测台账里的 until 大多是退避猜的
                //（服务端只说 "refreshed in the next cycle" 不给时刻），
                // 拿猜的时间去匹配窗口，等于用噪音当基准。
                guard let hinted = windowHint(cd.detail),
                      abs(hinted - minutesOf(s, now: now)) <= max(60, hinted / 10)
                else { continue }
                // 百分比是我们自己注入的状态指示器，不是用量绝对值，
                // 从 100% 反解不出「100% 是多少次」。
                guard s.metric != .percent else { continue }
                let start = s.windowStart
                let minutes = windowMinutes(s, now: now)
                guard minutes > 0 else { continue }
                let k = key(report.platform, poolID, start, minutes)
                guard !existing.contains(k) else { continue }
                // 用量为 0 说明这个窗口根本没跑过东西 —— 打满的是别的窗口，
                // 记下来只会污染样本。
                guard s.used > 0 else { continue }
                existing.insert(k)
                fresh.append(Observation(
                    platform: report.platform, quotaPoolID: poolID, at: now,
                    windowMinutes: minutes, windowLabel: s.label,
                    windowStart: start,
                    usage: [s.metric.rawValue: s.used],
                    detail: String(cd.detail.prefix(160))))
            }
        }
        guard !fresh.isEmpty else { return [] }
        append(fresh)
        return fresh
    }

    /// 把已经结束的额度耗尽事件补算成容量样本。
    ///
    /// 冷却只描述“现在能不能用”，过期后会从当前视图消失；共享事件账则保留了
    /// 真正的撞顶时刻。用撞顶前同一额度窗口的日志回算用量，才能让运行数周后的
    /// 历史形成经验上限，而不是每次恢复后从零开始。
    @discardableResult
    public static func captureHistorical(
        scan: RawScan, config: PlansConfig, now: Date = Date(),
        snapshots: [MachineSnapshot]? = nil
    ) -> [Observation] {
        let snapshots = snapshots ?? SnapshotStore.loadAll()
        var existing: [String: Observation] = [:]
        for observation in all() {
            let observationKey = key(
                observation.platform, observation.quotaPoolID,
                observation.windowStart, observation.windowMinutes)
            if let old = existing[observationKey] {
                let oldPeak = old.usage.values.max() ?? 0
                let newPeak = observation.usage.values.max() ?? 0
                if newPeak > oldPeak { existing[observationKey] = observation }
            } else {
                existing[observationKey] = observation
            }
        }
        var fresh: [Observation] = []

        for cooldown in CooldownLedger.quotaExhaustionHistory(config: config) {
            let events = scan.events[cooldown.platform] ?? []
            let plan = cooldown.quotaPoolID.flatMap {
                config.plan(for: cooldown.platform, quotaPoolID: $0)
            } ?? config.plan(for: cooldown.platform)
            guard cooldown.since <= now,
                  let hinted = windowHint(cooldown.detail),
                  let plan,
                  let limit = plan.limits.min(by: {
                    abs($0.windowMinutes - hinted) < abs($1.windowMinutes - hinted)
                  }),
                  abs(limit.windowMinutes - hinted) <= max(60, hinted / 10),
                  limit.metric != .percent
            else { continue }

            let relevant = events.filter {
                $0.timestamp <= cooldown.since
                    && (limit.lane == nil || $0.lane == limit.lane)
            }
            let sharedBuckets = snapshots.flatMap { snapshot in
                snapshot.platforms.filter { platformSnapshot in
                    guard platformSnapshot.platform == cooldown.platform else { return false }
                    if let pool = cooldown.quotaPoolID {
                        return platformSnapshot.quotaPoolID == pool
                            || (pool == "\(cooldown.platform.rawValue):default"
                                && platformSnapshot.quotaPoolID == nil)
                    }
                    return platformSnapshot.quotaPoolID == nil
                        || platformSnapshot.quotaPoolID
                            == "\(cooldown.platform.rawValue):default"
                }.flatMap(\.buckets)
            }.filter {
                $0.start <= cooldown.since
                    && (limit.lane == nil || $0.lane == limit.lane)
            }
            guard !relevant.isEmpty || !sharedBuckets.isEmpty else { continue }

            let start: Date
            let resetSpan = cooldown.until.timeIntervalSince(cooldown.since)
            if CooldownLedger.hasReliableQuotaWindowEnd(cooldown, config: config),
               resetSpan > 0, resetSpan <= limit.windowSeconds {
                // 服务端给出的恢复时刻同时确定了窗口边界。额度可能在网页端或
                // 另一台机器先被启用，本机“第一次看到调用”不能覆盖这个真值。
                start = cooldown.until.addingTimeInterval(-limit.windowSeconds)
            } else if limit.kind == .session {
                let timestamps = sharedBuckets.isEmpty
                    ? relevant.filter { $0.requests > 0 }.map(\.timestamp)
                    : sharedBuckets.filter { $0.requests > 0 }.map(\.start)
                guard let sessionStart = historicalSessionStart(
                    timestamps: timestamps, length: limit.windowSeconds, at: cooldown.since)
                else { continue }
                start = sessionStart
            } else {
                start = QuotaEngine(config: config)
                    .window(for: limit, now: cooldown.since).start
            }
            let poolID = cooldown.quotaPoolID
            let sampleKey = key(cooldown.platform, poolID, start, limit.windowMinutes)
            let used: Double
            if sharedBuckets.isEmpty {
                used = LimitLearner.usage(
                    relevant, from: start, to: cooldown.since, metric: limit.metric)
            } else {
                used = limit.metric.value(from: sharedBuckets.filter {
                    $0.start >= start && $0.start < cooldown.since
                }, pricing: plan.pricing)
            }
            guard used > 0 else { continue }
            if let old = existing[sampleKey],
               (old.usage[limit.metric.rawValue] ?? 0) >= used { continue }

            let observation = Observation(
                platform: cooldown.platform, quotaPoolID: poolID, at: cooldown.since,
                windowMinutes: limit.windowMinutes, windowLabel: limit.label,
                windowStart: start, usage: [limit.metric.rawValue: used],
                detail: String(cooldown.detail.prefix(160)))
            existing[sampleKey] = observation
            fresh.append(observation)
        }
        guard !fresh.isEmpty else { return [] }
        append(fresh)
        return fresh
    }

    private static func historicalSessionStart(
        timestamps: [Date], length: TimeInterval, at: Date
    ) -> Date? {
        let used = timestamps.filter { $0 <= at }.sorted()
        guard var start = used.first else { return nil }
        for timestamp in used.dropFirst()
            where timestamp >= start.addingTimeInterval(length) {
            start = timestamp
        }
        guard at < start.addingTimeInterval(length) else { return nil }
        return start
    }

    /// 从服务端的拒绝消息里认出「是哪个窗口满了」，单位分钟。
    ///
    /// 认不出就返回 nil，那一次撞顶就不采样 —— 宁可少一个样本，
    /// 也不能把 5 小时窗的用量记成周上限。
    static func windowHint(_ detail: String) -> Int? {
        let d = detail.lowercased()
        // 顺序有讲究：先认更长的窗口。"1-week" 里也含 "week"，
        // 但 "5 小时" 和 "hour" 要在 "day" 之前判，否则 "5-hour" 会被漏掉。
        if d.contains("月") || d.contains("month") { return 30 * 24 * 60 }
        if d.contains("周") || d.contains("week")
            || d.contains("7-day") || d.contains("7 day") { return 7 * 24 * 60 }
        for h in [5, 3, 1] {
            if d.contains("\(h) 小时") || d.contains("\(h)小时")
                || d.contains("\(h)-hour") || d.contains("\(h) hour") { return h * 60 }
        }
        if d.contains("日") || d.contains("天") || d.contains("daily")
            || d.contains("per day") || d.contains("24-hour") { return 24 * 60 }
        return nil
    }

    /// 这条状态代表多长的窗口（分钟）。
    static func minutesOf(_ s: QuotaStatus, now: Date) -> Int {
        windowMinutes(s, now: now)
    }

    static func key(_ p: Platform, _ poolID: String?, _ start: Date,
                    _ minutes: Int) -> String {
        "\(p.rawValue)|\(poolID ?? "legacy")|\(Int(start.timeIntervalSince1970))|\(minutes)"
    }

    /// 窗口长度。有重置时间就用「重置 − 起点」，否则退回状态自带的标签解析。
    static func windowMinutes(_ s: QuotaStatus, now: Date) -> Int {
        let start = s.windowStart
        if let resets = s.resetsAt {
            return Int(resets.timeIntervalSince(start) / 60)
        }
        return Int(now.timeIntervalSince(start) / 60)
    }

    static func append(_ items: [Observation]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var blob = ""
        for i in items {
            guard let d = try? enc.encode(i),
                  let s = String(data: d, encoding: .utf8) else { continue }
            blob += s + "\n"
        }
        guard !blob.isEmpty, let data = blob.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: path)
        }
    }

    /// 每个 (平台, 窗口长度, 口径) 的上限估计。
    ///
    /// 多次撞顶取**最大值**：每次观测都是真实上限的下界（我们可能漏采了一部分
    /// 用量），取最大的那个最接近真相。取平均反而会被漏采的那几次拉低。
    public static func estimates(quotaPoolIDs: [Platform: String] = [:])
        -> [(platform: Platform, windowMinutes: Int,
                                        windowLabel: String, metric: String,
                                        value: Double, samples: Int)] {
        var best: [String: (Platform, Int, String, String, Double, Int)] = [:]
        // 同一周期可能先由单机日志生成下界，等其他机器快照同步回来后又得到
        // 更完整的值。它们仍是一个周期，取较大值但不能虚增样本数。
        var byWindow: [String: Observation] = [:]
        for observation in all() {
            let observationKey = key(
                observation.platform, observation.quotaPoolID,
                observation.windowStart, observation.windowMinutes)
            if var old = byWindow[observationKey] {
                for (metric, value) in observation.usage {
                    old.usage[metric] = max(old.usage[metric] ?? 0, value)
                }
                if observation.at > old.at { old.at = observation.at }
                byWindow[observationKey] = old
            } else {
                byWindow[observationKey] = observation
            }
        }
        for o in byWindow.values {
            // 一旦配置了真实额度池，无法归属的 legacy 样本宁可不用，也不能
            // 猜给当前订阅；否则另一账号过去的撞顶值会把本池上限抬高几十倍。
            if let expectedPool = quotaPoolIDs[o.platform] {
                let syntheticDefault = expectedPool == "\(o.platform.rawValue):default"
                guard o.quotaPoolID == expectedPool
                        || (syntheticDefault && o.quotaPoolID == nil) else { continue }
            } else {
                guard o.quotaPoolID == nil else { continue }
            }
            for (metric, value) in o.usage {
                let k = "\(o.platform.rawValue)|\(o.windowMinutes)|\(metric)"
                if let cur = best[k] {
                    best[k] = (cur.0, cur.1, cur.2, cur.3, max(cur.4, value), cur.5 + 1)
                } else {
                    best[k] = (o.platform, o.windowMinutes, o.windowLabel, metric, value, 1)
                }
            }
        }
        return best.values
            .map { (platform: $0.0, windowMinutes: $0.1, windowLabel: $0.2,
                    metric: $0.3, value: $0.4, samples: $0.5) }
            .sorted { $0.platform.sortIndex == $1.platform.sortIndex
                ? $0.windowMinutes < $1.windowMinutes
                : $0.platform.sortIndex < $1.platform.sortIndex }
    }
}
