import Foundation

/// 把多台机器的原始快照 + 用户填的套餐配置，算成可以直接显示的仪表盘。
public struct QuotaEngine: Sendable {
    public var config: PlansConfig
    /// 机器快照超过这个时长没更新，就认为那台机器没在跑采集。
    public var machineStaleAfter: TimeInterval = 6 * 3600

    public init(config: PlansConfig) {
        self.config = config
    }

    // MARK: - Entry point

    public func buildDashboard(snapshots: [MachineSnapshot], now: Date = Date()) -> Dashboard {
        let machines = snapshots.map {
            MachineInfo(
                machineID: $0.machineID,
                machineName: $0.machineName,
                lastSeen: $0.generatedAt,
                isStale: now.timeIntervalSince($0.generatedAt) > machineStaleAfter
            )
        }.sorted { $0.machineName < $1.machineName }

        var reports: [PlatformReport] = []
        for platform in Platform.allCases {
            guard let plan = config.plan(for: platform), plan.enabled else { continue }
            reports.append(buildReport(plan: plan, snapshots: snapshots, now: now))
        }

        return Dashboard(generatedAt: now, machines: machines, reports: reports)
    }

    // MARK: - Per platform

    private func buildReport(
        plan: PlatformPlan,
        snapshots: [MachineSnapshot],
        now: Date
    ) -> PlatformReport {
        var byMachineBuckets: [String: [UsageBucket]] = [:]
        var allBuckets: [UsageBucket] = []
        var officials: [OfficialQuota] = []
        var detected = false
        var installed = false
        var lastActivity: Date?
        var machineNames: [String] = []

        for snap in snapshots {
            guard let ps = snap.platforms.first(where: { $0.platform == plan.platform }) else { continue }
            if ps.installed { installed = true }
            guard ps.detected else { continue }
            detected = true
            machineNames.append(snap.machineName)
            byMachineBuckets[snap.machineName, default: []].append(contentsOf: ps.buckets)
            allBuckets.append(contentsOf: ps.buckets)
            officials.append(contentsOf: ps.officialQuotas)
            if let la = ps.lastActivity, lastActivity == nil || la > lastActivity! {
                lastActivity = la
            }
        }

        // 官方额度是账号级的，不分机器 —— 同一条只留观测时间最新的那次。
        var latestOfficial: [String: OfficialQuota] = [:]
        for q in officials {
            if let cur = latestOfficial[q.id], cur.observedAt >= q.observedAt { continue }
            latestOfficial[q.id] = q
        }
        let liveOfficial = latestOfficial.values
            .filter { !$0.isStale(now: now) }
            .sorted { $0.windowMinutes < $1.windowMinutes }

        var statuses: [QuotaStatus] = []
        var coveredWindows: Set<Int> = []

        if plan.preferOfficialQuota {
            for q in liveOfficial {
                statuses.append(officialStatus(q, plan: plan, now: now))
                coveredWindows.insert(q.windowMinutes)
            }
        }

        for limit in plan.limits {
            // 官方已经给了同长度窗口的真实数字，就不再用本地推算的那份覆盖它。
            if coveredWindows.contains(limit.windowMinutes) { continue }
            // **窗口长度对不上，也不要再摆一条「未配置上限」。**
            //
            // 只按分钟数精确匹配是不够的：MiniMax 报的区间长度会变
            // （实测出现过 300 和 240 分钟），于是模板里写死的「5 小时」
            // 永远匹配不上官方的「4 小时」，两条并排显示 ——
            // 一条是真实数字，另一条写着「未配置上限」。
            //
            // 用户看到的是同一个东西的两行自相矛盾的说法，
            // 而那条空行不提供任何信息：官方已经直接告诉我们用了多少，
            // 本地根本不需要上限就能算。
            let isShortWindow = limit.windowMinutes < 24 * 60
            if plan.preferOfficialQuota, limit.limit == nil,
               liveOfficial.contains(where: {
                   ($0.windowMinutes < 24 * 60) == isShortWindow
               }) {
                continue
            }
            statuses.append(localStatus(
                limit: limit, plan: plan,
                buckets: allBuckets, byMachine: byMachineBuckets, now: now
            ))
        }

        statuses.sort { $0.windowStart > $1.windowStart }

        let d30 = now.addingTimeInterval(-30 * 86400)
        let d7 = now.addingTimeInterval(-7 * 86400)
        let b30 = allBuckets.filter { $0.start >= d30 }
        let b7 = allBuckets.filter { $0.start >= d7 }

        // 这几个先算出来再传。多加一个参数之后整块表达式就把类型检查器
        // 拖到超时了（"unable to type-check in reasonable time"）——
        // reduce 的闭包每个都要独立推导，堆在一个初始化器里成本是乘起来的。
        // 人最后一次亲手用它。只看 interactive，调度器自己跑的不算。
        let humanLast = allBuckets
            .filter { $0.lane != .headless && ($0.requests > 0 || $0.prompts > 0) }
            .map(\.start).max()
        // 同一件事，但只看**本机**。调度器的「让开」判据要用这个 ——
        // 人在另一台上敲代码，不该让这台的 agent 跟着闲置。
        let humanLastHere = (byMachineBuckets[Paths.machineName()] ?? [])
            .filter { $0.lane != .headless && ($0.requests > 0 || $0.prompts > 0) }
            .map(\.start).max()

        let cooling = CooldownLedger.active(now: now)[plan.platform]
        let req30 = b30.reduce(0) { $0 + $1.requests }
        let tok30 = b30.reduce(0) { $0 + $1.billableTokens }
        let req7 = b7.reduce(0) { $0 + $1.requests }
        let models = topModels(b30)

        return PlatformReport(
            platform: plan.platform,
            planName: plan.planName,
            monthlyCost: plan.monthlyCost,
            currency: plan.currency,
            detected: detected,
            installed: installed,
            enabled: plan.enabled,
            lastHumanActivity: humanLast,
            lastHumanActivityHere: humanLastHere,
            machines: Array(Set(machineNames)).sorted(),
            lastActivity: lastActivity,
            statuses: statuses,
            last30dRequests: req30,
            last30dBillableTokens: tok30,
            last7dRequests: req7,
            topModels: models,
            // 空窗按**这个平台配置里真实存在的窗口长度**算 ——
            // 给一个只有周额度的平台算「5 小时空窗率」，
            // 只是把一个不存在的窗口摆出来充数。
            //
            // 起点用所有快照里最早的 retentionStart：往前算过头的话，
            // 采集覆盖不到的那段一律是空的，空窗率会虚高到接近 100%，
            // 而那个数字看起来像「这个订阅完全没在用」。
            idleWindows: WasteMeter.measureAll(
                buckets: allBuckets,
                windows: plan.limits.map(\.windowMinutes),
                since: snapshots.map(\.retentionStart).min() ?? now.addingTimeInterval(-30 * 86400),
                now: now),
            // 冷却状态要跟着发出去 —— 手机上看不到它的话，
            // 「连续空 19 个窗口」会被当成「快去塞活」，
            // 而真相是这个平台正被限流，塞了也进不去。
            cooldownUntil: cooling?.until,
            cooldownReason: cooling.map {
                $0.cause.displayName
                    + ($0.strikes > 1 ? "（连续第 \($0.strikes) 次）" : "")
            }
        )
    }

    // MARK: - Status from platform-reported quota

    private func officialStatus(_ q: OfficialQuota, plan: PlatformPlan, now: Date) -> QuotaStatus {
        let windowSeconds = TimeInterval(q.windowMinutes) * 60
        let resets = q.resetsAt
        let start = resets.map { $0.addingTimeInterval(-windowSeconds) }
            ?? q.observedAt.addingTimeInterval(-windowSeconds)

        let elapsed = clamp01(now.timeIntervalSince(start) / max(windowSeconds, 1))
        let usedFraction = q.usedPercent / 100
        let projected = project(usedFraction: usedFraction, elapsed: elapsed)
        let health = judge(
            usedFraction: usedFraction, projectedFraction: projected,
            elapsed: elapsed, kind: .periodic, hasLimit: true
        )

        let observedText = Format.relative(q.observedAt, now: now)
        var note = "平台回报，截至 \(observedText)"
        if let p = q.planType { note = "\(p) 档 · " + note }

        return QuotaStatus(
            platform: plan.platform,
            planName: plan.planName,
            limitID: "official-\(q.id)",
            label: q.label,
            metric: .percent,
            kind: .periodic,
            used: q.usedPercent,
            limit: 100,
            usedFraction: usedFraction,
            windowStart: start,
            resetsAt: resets,
            windowElapsedFraction: elapsed,
            projectedUsedFraction: projected,
            projectedWaste: projected.map { max(0, 100 - $0 * 100) },
            health: health,
            isOfficial: true,
            sourceNote: note
        )
    }

    // MARK: - Status computed from local logs

    /// 历史上任意一个 `windowSeconds` 长的窗口里，这个口径用出去过的最大量。
    ///
    /// **这是一个下限，不是估计**：那次确实用出去了、而且没被拒，
    /// 所以真实上限一定不低于它。查完各家官方文档之后（大多不公布、
    /// 或者口径对不上），这往往是唯一能给出的硬数字。
    ///
    /// 步长取窗口的 1/12：太密了白算，太疏了会漏掉峰值刚好落在两步之间的情况。
    static func peakInWindow(_ buckets: [UsageBucket], windowSeconds: TimeInterval,
                             metric: QuotaMetric, pricing: Pricing?, now: Date) -> Double? {
        guard let earliest = buckets.map(\.start).min(),
              now.timeIntervalSince(earliest) >= windowSeconds * 2 else { return nil }
        let step = max(60, windowSeconds / 12)
        var peak = 0.0
        var end = earliest.addingTimeInterval(windowSeconds)
        while end <= now {
            let from = end.addingTimeInterval(-windowSeconds)
            let inWindow = buckets.filter { $0.start >= from && $0.start < end }
            peak = max(peak, metric.value(from: inWindow, pricing: pricing))
            end = end.addingTimeInterval(step)
        }
        return peak > 0 ? peak : nil
    }

    private func localStatus(
        limit: QuotaLimit,
        plan: PlatformPlan,
        buckets: [UsageBucket],
        byMachine: [String: [UsageBucket]],
        now: Date
    ) -> QuotaStatus {
        // lane 为 nil 表示这条上限不区分额度池；指定了就只算那个池子的用量。
        // 少了这层过滤，Claude 的订阅额度会把 claude -p 的消耗也算进去，
        // 而那部分其实走的是另一个池子。
        // 必须先过滤再算窗口：会话窗口的起点取决于「这个池子」第一次被用的时刻，
        // 拿全部用量去找起点会把别的池子的调用误当成本轮开端。
        let laneMatched = limit.lane == nil
            ? buckets
            : buckets.filter { $0.lane == limit.lane }

        // 会话窗口的起点由用量本身决定，所以不能只看时钟，得先找出这一轮是什么时候开的。
        let start: Date
        let end: Date
        let windowActive: Bool
        if limit.kind == .session {
            if let ws = Self.sessionWindowStart(
                buckets: laneMatched, length: limit.windowSeconds, now: now
            ) {
                start = ws
                end = ws.addingTimeInterval(limit.windowSeconds)
                windowActive = true
            } else {
                // 上一轮已经结束、这一轮还没开始 —— 额度是满的，也没有任何东西在倒计时。
                start = now
                end = now.addingTimeInterval(limit.windowSeconds)
                windowActive = false
            }
        } else {
            (start, end) = window(for: limit, now: now)
            windowActive = true
        }

        let inWindow = laneMatched.filter { $0.start >= start && $0.start < end }
        let used = limit.metric.value(from: inWindow, pricing: plan.pricing)

        var machineSplit: [String: Double] = [:]
        for (name, mb) in byMachine {
            let v = limit.metric.value(
                from: mb.filter {
                    (limit.lane == nil || $0.lane == limit.lane)
                        && $0.start >= start && $0.start < end
                },
                pricing: plan.pricing
            )
            if v > 0 { machineSplit[name] = v }
        }

        let elapsed: Double
        let resets: Date?
        switch limit.kind {
        case .rolling:
            // 滚动窗口在时间上永远是"满"的，当前用量就是稳态用量，不需要外推。
            elapsed = 1.0
            // 窗口里最早那次调用滚出去的时刻，就是额度开始回血的时刻。
            resets = inWindow.map(\.start).min()?.addingTimeInterval(limit.windowSeconds)
        case .periodic:
            // 自然月长度是 28~31 天不等，必须用实际窗口长度，不能用配置里的固定秒数。
            let windowLength = max(1, end.timeIntervalSince(start))
            elapsed = clamp01(now.timeIntervalSince(start) / windowLength)
            resets = end

        case .session:
            // 没开窗就没有倒计时可言，也不该显示成"刚开始用了 0%"。
            elapsed = windowActive
                ? clamp01(now.timeIntervalSince(start) / limit.windowSeconds)
                : 0
            resets = windowActive ? end : nil
        }

        let usedFraction = limit.limit.map { $0 > 0 ? used / $0 : 0 }
        let projected = usedFraction.flatMap { project(usedFraction: $0, elapsed: elapsed) }
        let health = judge(
            usedFraction: usedFraction ?? 0, projectedFraction: projected,
            elapsed: elapsed, kind: limit.kind, hasLimit: limit.limit != nil
        )

        var waste: Double?
        if limit.kind.canExpire, let cap = limit.limit, let p = projected {
            waste = max(0, cap - p * cap)
        }

        // 没配上限时给一个实测下限：历史上同长度窗口里用出去过的最大量。
        // 配了上限就不算 —— 那时候真实的剩余百分比已经有了，下限是多余信息，
        // 而滑窗扫描是有成本的。
        let floor: Double? = limit.limit == nil
            ? Self.peakInWindow(laneMatched, windowSeconds: limit.windowSeconds,
                                metric: limit.metric, pricing: plan.pricing, now: now)
            : nil

        return QuotaStatus(
            platform: plan.platform,
            planName: plan.planName,
            limitID: limit.id,
            label: limit.label,
            metric: limit.metric,
            kind: limit.kind,
            used: used,
            limit: limit.limit,
            usedFraction: usedFraction,
            windowStart: start,
            resetsAt: resets,
            windowElapsedFraction: elapsed,
            projectedUsedFraction: projected,
            projectedWaste: waste,
            health: health,
            isOfficial: false,
            sourceNote: limit.limit == nil
                ? (limit.hint ?? "未配置上限，仅统计用量")
                : "由本地日志推算",
            byMachine: machineSplit,
            observedFloor: floor
        )
    }

    // MARK: - Window math

    func window(for limit: QuotaLimit, now: Date, calendar: Calendar = .current)
        -> (start: Date, end: Date) {
        switch limit.kind {
        case .rolling:
            return (now.addingTimeInterval(-limit.windowSeconds), now.addingTimeInterval(1))

        case .session:
            // 会话窗口要看用量才知道起点，localStatus 会直接处理，不走这里。
            // 真被调到（比如外部直接调用）时退化成滚动窗口，至少不会算出荒谬的区间。
            return (now.addingTimeInterval(-limit.windowSeconds), now.addingTimeInterval(1))

        case .periodic:
            // 用户显式给了账单日就按它推，周期长度固定。
            if let anchor = limit.anchor {
                let elapsed = now.timeIntervalSince(anchor)
                let n = (elapsed / limit.windowSeconds).rounded(.down)
                let start = anchor.addingTimeInterval(n * limit.windowSeconds)
                return (start, start.addingTimeInterval(limit.windowSeconds))
            }

            // 没给锚点时，按**本地时区**的自然日/周/月对齐。
            // 从 Unix 纪元按固定秒数推是错的：那样"每日"额度会在北京时间早上 8 点
            // （UTC 午夜）重置，而各家平台实际都是按本地自然日算的。
            // 自然月还必须用日历，因为 28~31 天不是固定长度。
            if let natural = naturalWindow(minutes: limit.windowMinutes, now: now, cal: calendar) {
                return natural
            }

            // 非自然周期（比如 3 天）退回纪元对齐。
            let anchor = Date(timeIntervalSince1970: 0)
            let n = (now.timeIntervalSince(anchor) / limit.windowSeconds).rounded(.down)
            let start = anchor.addingTimeInterval(n * limit.windowSeconds)
            return (start, start.addingTimeInterval(limit.windowSeconds))
        }
    }

    /// 找出当前这一轮会话窗口是什么时候开的。
    ///
    /// 规则：第一次调用开一轮窗，窗口长度固定；这一轮结束后，
    /// 下一次调用才开新的一轮。所以要顺着用量往前走，一轮一轮地链下去。
    ///
    /// - Returns: 当前活跃窗口的起点；如果上一轮已经结束、这一轮还没开始（额度是满的），返回 nil。
    static func sessionWindowStart(
        buckets: [UsageBucket], length: TimeInterval, now: Date
    ) -> Date? {
        let used = buckets.filter { $0.requests > 0 }.map(\.start).sorted()
        guard !used.isEmpty else { return nil }

        var windowStart = used[0]
        for t in used where t >= windowStart.addingTimeInterval(length) {
            windowStart = t
        }
        // 最后一轮已经走完了，现在处于两轮之间。
        guard now < windowStart.addingTimeInterval(length) else { return nil }
        return windowStart
    }

    private func naturalWindow(minutes: Int, now: Date, cal: Calendar)
        -> (start: Date, end: Date)? {
        let unit: Calendar.Component
        switch minutes {
        case 1440: unit = .day
        case 10080: unit = .weekOfYear
        case 43200: unit = .month
        default: return nil
        }
        guard let interval = cal.dateInterval(of: unit, for: now) else { return nil }
        return (interval.start, interval.end)
    }

    /// 按当前速度线性外推到窗口结束时的用量占比。
    private func project(usedFraction: Double, elapsed: Double) -> Double? {
        guard elapsed > 0.001 else { return nil }
        return usedFraction / elapsed
    }

    private func judge(
        usedFraction: Double,
        projectedFraction: Double?,
        elapsed: Double,
        kind: WindowKind,
        hasLimit: Bool
    ) -> QuotaHealth {
        guard hasLimit else { return .unconfigured }
        if usedFraction >= 1.0 { return .exhausted }

        switch kind {
        case .rolling:
            if usedFraction <= 0 { return .idle }
            if usedFraction > config.riskThreshold { return .atRisk }
            return .healthy

        case .session, .periodic:
            // 窗口刚开头，样本太少，外推没有意义，先不下结论。
            guard elapsed > 0.15 else { return .healthy }
            if usedFraction <= 0 { return .idle }
            guard let p = projectedFraction else { return .healthy }
            if p > config.riskThreshold { return .atRisk }
            if p < config.wasteThreshold { return .wasting }
            return .healthy
        }
    }

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    private func topModels(_ buckets: [UsageBucket], limit: Int = 5) -> [ModelUsage] {
        var agg: [String: (Int, Int)] = [:]
        for b in buckets {
            var cur = agg[b.model] ?? (0, 0)
            cur.0 += b.requests
            cur.1 += b.billableTokens
            agg[b.model] = cur
        }
        return agg
            .map { ModelUsage(model: $0.key, requests: $0.value.0, billableTokens: $0.value.1) }
            .sorted { $0.billableTokens == $1.billableTokens
                ? $0.requests > $1.requests
                : $0.billableTokens > $1.billableTokens }
            .prefix(limit)
            .map { $0 }
    }
}
