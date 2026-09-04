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
    /// nil 是旧版平台级记录；新记录落到真实订阅池，避免一份账号撞限额后
    /// 冻结同平台的其他账号。
    public var quotaPoolID: String? = nil
    /// nil 表示旧版平台级记录。新记录必须尽量落到具体 Runner + 能力。
    public var runnerID: String? = nil
    public var capability: String? = nil
    public var cause: Cause
    public var since: Date
    public var until: Date
    /// 连续失败次数。用来做指数退避 —— 一直失败的平台没必要每 15 分钟试一次。
    public var strikes: Int
    public var detail: String

    public init(platform: Platform, quotaPoolID: String? = nil, runnerID: String? = nil,
                capability: String? = nil, cause: Cause,
                since: Date, until: Date, strikes: Int, detail: String) {
        self.platform = platform
        self.quotaPoolID = quotaPoolID
        self.runnerID = runnerID
        self.capability = capability
        self.cause = cause
        self.since = since
        self.until = until
        self.strikes = strikes
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case platform, quotaPoolID, runnerID, capability, cause, since, until, strikes, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(Platform.self, forKey: .platform)
        quotaPoolID = try c.decodeIfPresent(String.self, forKey: .quotaPoolID)
        runnerID = try c.decodeIfPresent(String.self, forKey: .runnerID)
        capability = try c.decodeIfPresent(String.self, forKey: .capability)
        cause = try c.decode(Cause.self, forKey: .cause)
        since = try c.decode(Date.self, forKey: .since)
        until = try c.decode(Date.self, forKey: .until)
        strikes = try c.decodeIfPresent(Int.self, forKey: .strikes) ?? 1
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

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

    /// 多机事实来源。每次变化一份不可变事件，由镜像做集合并集；
    /// `cooldowns.json` 只保留给旧二进制和手机读取的兼容视图。
    static var eventDirectory: URL {
        Paths.sharedRoot.appendingPathComponent("cooldown-events", isDirectory: true)
    }

    struct Event: Codable, Sendable {
        enum Action: String, Codable, Sendable { case upsert, clear }

        var schemaVersion: Int
        var id: String
        var action: Action
        var writerMachineID: String
        var createdAt: Date
        // 兼容时间字段使用 ISO8601（秒精度）。事件排序另外保留亚秒，
        // 否则同一秒内 record → clear → record 会退化成按随机 UUID 排序。
        var createdAtUnixSeconds: TimeInterval
        var platform: Platform
        var quotaPoolID: String?
        var runnerID: String?
        var capability: String?
        var platformWide: Bool
        var includeLegacyPool: Bool
        var cooldown: Cooldown?

        init(action: Action, platform: Platform, quotaPoolID: String? = nil,
             runnerID: String? = nil, capability: String? = nil,
             platformWide: Bool = false, includeLegacyPool: Bool = false,
             cooldown: Cooldown? = nil, createdAt: Date = Date(),
             writerMachineID: String = Paths.machineID()) {
            schemaVersion = 1
            id = UUID().uuidString.lowercased()
            self.action = action
            self.writerMachineID = writerMachineID
            self.createdAt = createdAt
            self.createdAtUnixSeconds = createdAt.timeIntervalSince1970
            self.platform = platform
            self.quotaPoolID = quotaPoolID
            self.runnerID = runnerID
            self.capability = capability
            self.platformWide = platformWide
            self.includeLegacyPool = includeLegacyPool
            self.cooldown = cooldown
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, id, action, writerMachineID, createdAt, createdAtUnixSeconds
            case platform, quotaPoolID, runnerID, capability, platformWide
            case includeLegacyPool, cooldown
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            action = try c.decodeIfPresent(Action.self, forKey: .action) ?? .upsert
            writerMachineID = try c.decodeIfPresent(
                String.self, forKey: .writerMachineID) ?? "unknown"
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
            createdAtUnixSeconds = try c.decodeIfPresent(
                TimeInterval.self, forKey: .createdAtUnixSeconds) ?? createdAt.timeIntervalSince1970
            platform = try c.decode(Platform.self, forKey: .platform)
            quotaPoolID = try c.decodeIfPresent(String.self, forKey: .quotaPoolID)
            runnerID = try c.decodeIfPresent(String.self, forKey: .runnerID)
            capability = try c.decodeIfPresent(String.self, forKey: .capability)
            platformWide = try c.decodeIfPresent(Bool.self, forKey: .platformWide) ?? false
            includeLegacyPool = try c.decodeIfPresent(
                Bool.self, forKey: .includeLegacyPool) ?? false
            cooldown = try c.decodeIfPresent(Cooldown.self, forKey: .cooldown)
        }

        func clears(_ item: Cooldown) -> Bool {
            guard item.platform == platform else { return false }
            if platformWide { return true }
            let poolMatches = item.quotaPoolID == quotaPoolID
                || (includeLegacyPool && item.quotaPoolID == nil)
            return poolMatches && item.runnerID == runnerID
                && item.capability == capability
        }
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
    public static func loadEntries() -> [Cooldown] {
        // `file` 可能在 iCloud 上。这一行卡死过整个菜单栏 App。
        let legacy = ICloudSafe.read(file).flatMap {
            try? SnapshotCoding.decoder().decode([Cooldown].self, from: $0)
        } ?? []
        let events = loadEvents().sorted(by: eventOrder)
        guard !events.isEmpty else { return legacy }

        // 兼容文件可能刚被另一台旧机器用不完整视图覆盖。凡是事件账已经
        // 接管的 key，都不能再让兼容文件复活；其余旧 key 继续兼容读取。
        var byKey = Dictionary(legacy.map { (key($0), $0) },
                               uniquingKeysWith: { a, b in a.since >= b.since ? a : b })
        let platformWide = Set(events.filter(\.platformWide).map(\.platform))
        var ownedKeys = Set<String>()
        for event in events where !event.platformWide {
            ownedKeys.insert(eventKey(event))
            // 没有显式账号池时，`platform:default` 是旧版 nil-pool 记录的稳定身份。
            // 离线旧机器可能在事件写入后又同步回 nil-pool 兼容视图；若不把这两个
            // key 视为同一条，手机会同时看到“旧额度未恢复”和“新额度已更新”。
            if event.includeLegacyPool
                || event.quotaPoolID == "\(event.platform.rawValue):default" {
                ownedKeys.insert([
                    event.platform.rawValue, "legacy",
                    event.runnerID ?? "*", event.capability ?? "*",
                ].joined(separator: "|"))
            }
        }
        byKey = byKey.filter { key, value in
            !platformWide.contains(value.platform) && !ownedKeys.contains(key)
        }

        for event in events {
            switch event.action {
            case .upsert:
                if let cooldown = event.cooldown { byKey[key(cooldown)] = cooldown }
            case .clear:
                byKey = byKey.filter { _, cooldown in
                    !event.clears(cooldown)
                }
            }
        }
        return Array(byKey.values)
    }

    /// 旧消费端仍按平台看冷却时，选该平台当前最晚结束的一条；不再用
    /// `Dictionary(uniqueKeysWithValues:)`，否则同平台两个 Runner 会直接崩溃。
    public static func load() -> [Platform: Cooldown] {
        var out: [Platform: Cooldown] = [:]
        for item in loadEntries() {
            if let current = out[item.platform], current.until >= item.until { continue }
            out[item.platform] = item
        }
        return out
    }

    static func save(_ entries: [Cooldown]) {
        try? Paths.ensureDirectories()
        guard let data = try? SnapshotCoding.prettyEncoder()
            .encode(entries.sorted {
                if $0.platform != $1.platform {
                    return $0.platform.sortIndex < $1.platform.sortIndex
                }
                if ($0.quotaPoolID ?? "") != ($1.quotaPoolID ?? "") {
                    return ($0.quotaPoolID ?? "") < ($1.quotaPoolID ?? "")
                }
                if ($0.runnerID ?? "") != ($1.runnerID ?? "") {
                    return ($0.runnerID ?? "") < ($1.runnerID ?? "")
                }
                return ($0.capability ?? "") < ($1.capability ?? "")
            })
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
    public static func active(now: Date = Date(), config: PlansConfig? = nil)
        -> [Platform: Cooldown] {
        var out: [Platform: Cooldown] = [:]
        for item in activeEntries(now: now, config: config) {
            if let current = out[item.platform], current.until >= item.until { continue }
            out[item.platform] = item
        }
        return out
    }

    /// 完整的 Runner 级冷却，不折叠同平台记录。
    public static func activeEntries(now: Date = Date(), config: PlansConfig? = nil)
        -> [Cooldown] {
        var entries = loadEntries()
        let plans = config ?? PlansStore.load()

        // 旧记录里 Kimi 明说的是「current 7-day window ends」，但没有给绝对
        // 时间。旧版一律只冻 5 小时，于是周额度还没恢复，看板却提前撤掉
        // “已用尽”。只修复仍属于当前周窗的这类记录；跨过窗口后绝不续冻。
        for index in entries.indices {
            let cooldown = entries[index]
            let platform = cooldown.platform
            guard cooldown.cause == .quotaExhausted,
                  !cooldown.isActive(now: now) else { continue }
            guard let window = configuredQuotaWindow(
                platform: platform, detail: cooldown.detail, config: plans, now: now),
                  cooldown.since >= window.start, cooldown.since < window.end else { continue }
            var repaired = cooldown
            repaired.until = window.end
            entries[index] = repaired
        }
        return entries.filter { $0.isActive(now: now) }
    }

    /// 只查询指定执行器能力。旧版没有 Runner 维度的记录仍作为平台兜底，
    /// 但绝不会拿同平台另一个 Runner 的故障来挡当前候选。
    public static func active(platform: Platform, runnerID: String, capability: String,
                              quotaPoolID: String? = nil,
                              now: Date = Date(), config: PlansConfig? = nil) -> Cooldown? {
        let plans = config ?? PlansStore.load()
        let resolvedPoolID = quotaPoolID ?? plans.quotaPoolID(
            for: platform, machineID: Paths.machineID(), runnerID: runnerID)
        let entries = activeEntries(now: now, config: plans)
        let exact = entries.first {
            $0.platform == platform && $0.quotaPoolID == resolvedPoolID
                && $0.runnerID == runnerID && $0.capability == capability
        }
        guard exact == nil, !plans.hasExplicitQuotaPool(for: platform) else { return exact }
        return entries.first {
            // 滚动升级：旧 Runner 级记录没有 poolID，只作为当前执行器的兜底。
            $0.platform == platform && $0.quotaPoolID == nil
                && $0.runnerID == runnerID && $0.capability == capability
        } ?? entries.first {
            $0.platform == platform && $0.quotaPoolID == nil
                && $0.runnerID == nil && $0.capability == nil
        }
    }

    /// 只从平台明确说出的窗口类型推断重置时刻。没有窗口提示仍走 5 小时
    /// 保守兜底，不能把一句含糊的 “next cycle” 擅自解释成周额度。
    static func configuredQuotaWindow(platform: Platform, detail: String,
                                      config: PlansConfig, now: Date)
        -> (start: Date, end: Date)? {
        let text = detail.lowercased()
        let weeklyMarkers = ["7-day window", "7 day window", "weekly quota",
                             "weekly limit", "week window", "每周", "周额度",
                             "7 天窗口", "七天窗口"]
        guard weeklyMarkers.contains(where: text.contains),
              let plan = config.plan(for: platform),
              let limit = plan.limits.first(where: {
                  $0.kind == .periodic
                      && ($0.id == "weekly" || $0.windowMinutes == 10_080)
              }) else { return nil }
        return QuotaEngine(config: config).window(for: limit, now: now)
    }

    /// 记一次失败，返回这次定下的冷却。
    ///
    /// 由真实任务或持久日志在 `classify()` 判定属于平台侧问题后调用。
    /// 连续失败（上一次冷却未过期或原因相同）则 strikes 递增、退避梯度加长；
    /// 中间恢复过则 strikes 归 1。平台报了确切的重置时间就直接采信，比退避猜得准。
    /// 永久性故障（`needsHumanFix`）直接冷却 30 天，等人工处理后用 `resume()` 解除。
    @discardableResult
    public static func record(
        platform: Platform, runnerID: String? = nil, capability: String? = nil,
        quotaPoolID: String? = nil,
        cause: Cooldown.Cause, detail: String,
        knownResetAt: Date? = nil, now: Date = Date()
    ) -> Cooldown {
        var entries = loadEntries()
        let plans = PlansStore.load()
        let resolvedPoolID = quotaPoolID ?? plans.quotaPoolID(
            for: platform, machineID: Paths.machineID(), runnerID: runnerID)
        let allowLegacyFallback = !plans.hasExplicitQuotaPool(for: platform)
        // 上一次的记录还没过期就算连续失败；已经过期说明中间恢复过，重新计数。
        var priorIndex = entries.firstIndex {
            $0.platform == platform && $0.quotaPoolID == resolvedPoolID
                && $0.runnerID == runnerID && $0.capability == capability
        }
        if priorIndex == nil, allowLegacyFallback {
            priorIndex = entries.firstIndex {
                $0.platform == platform && $0.quotaPoolID == nil
                    && $0.runnerID == runnerID && $0.capability == capability
            }
        }
        let prior = priorIndex.map { entries[$0] }
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
        } else if cause == .quotaExhausted,
                  let window = configuredQuotaWindow(
                    platform: platform, detail: detail,
                    config: PlansStore.load(), now: now) {
            until = window.end
        } else if cause == .quotaExhausted {
            // **额度用尽不做指数退避。**
            //
            // 退避的前提是「重试大概率还是失败，而且重试本身有代价」。
            // 额度用尽不满足这个前提：它有确定的恢复时刻，最坏也就是
            // 窗口长度。实测代价 —— strikes 堆到 4 之后 Claude 被冻
            // 1 天 16 小时，而它是 5 小时窗，那 35 小时是白冻的，
            // 期间所有依赖 Claude 主力开发的高危实现任务全线停摆。
            //
            // 没拿到确切重置时间就按 5 小时保守估：猜早了下次撞 429 再记
            // 一条（而且现在撞顶还会被 QuotaCeiling 采成上限样本，不算白撞），
            // 猜晚了才是纯浪费。宁可多撞几次，不要白冻一整天。
            until = now.addingTimeInterval(5 * 3600)
        } else {
            until = now.addingTimeInterval(backoff[min(strikes - 1, backoff.count - 1)])
        }

        let cd = Cooldown(
            platform: platform, quotaPoolID: resolvedPoolID,
            runnerID: runnerID, capability: capability,
            cause: cause, since: now, until: until,
            strikes: strikes, detail: String(detail.prefix(200))
        )
        if let priorIndex { entries[priorIndex] = cd } else { entries.append(cd) }
        append(Event(action: .upsert, platform: platform,
                     quotaPoolID: resolvedPoolID, runnerID: runnerID,
                     capability: capability, cooldown: cd, createdAt: now))
        save(entries)
        return cd
    }

    /// 手动解除冷却。永久性故障处理完之后用。
    ///
    /// 由 `llmq work resume <平台>` 调用。永久性故障被 `record()` 冷却 30 天，
    /// 退避不会让它提前结束 -- 用户改了账号或换了工具之后，手动调这里把条目删掉，
    /// 调度器下一轮就能重新选这个平台。返回 false 说明本来就没在冷却中。
    public static func resume(_ platform: Platform) -> Bool {
        var entries = loadEntries()
        let before = entries.count
        entries.removeAll { $0.platform == platform }
        append(Event(action: .clear, platform: platform, platformWide: true))
        save(entries)
        return entries.count != before
    }

    /// 跑成功了就清掉，让计数从头开始。
    ///
    /// `runOneTask()` 真实任务成功时调用；一次成功只清理对应 Runner 能力，
    /// 不得顺手清掉同平台其他执行器的故障。
    public static func clear(_ platform: Platform, runnerID: String? = nil,
                             capability: String? = nil, quotaPoolID: String? = nil) {
        var entries = loadEntries()
        if let runnerID {
            let plans = PlansStore.load()
            let resolvedPoolID = quotaPoolID ?? plans.quotaPoolID(
                for: platform, machineID: Paths.machineID(), runnerID: runnerID)
            let includeLegacy = !plans.hasExplicitQuotaPool(for: platform)
            entries.removeAll {
                $0.platform == platform && $0.runnerID == runnerID
                    && $0.capability == capability
                    && ($0.quotaPoolID == resolvedPoolID
                        || (includeLegacy && $0.quotaPoolID == nil))
            }
            append(Event(action: .clear, platform: platform,
                         quotaPoolID: resolvedPoolID, runnerID: runnerID,
                         capability: capability, includeLegacyPool: includeLegacy))
        } else {
            // 手动恢复和旧调用保留平台级语义。
            entries.removeAll { $0.platform == platform }
            append(Event(action: .clear, platform: platform, platformWide: true))
        }
        save(entries)
    }

    private static func key(_ cooldown: Cooldown) -> String {
        [cooldown.platform.rawValue, cooldown.quotaPoolID ?? "legacy",
         cooldown.runnerID ?? "*", cooldown.capability ?? "*"]
            .joined(separator: "|")
    }

    private static func eventKey(_ event: Event) -> String {
        [event.platform.rawValue, event.quotaPoolID ?? "legacy",
         event.runnerID ?? "*", event.capability ?? "*"]
            .joined(separator: "|")
    }

    private static func loadEvents() -> [Event] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventDirectory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return files.compactMap { file -> Event? in
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = ICloudSafe.read(file) else { return nil }
            return try? SnapshotCoding.decoder().decode(Event.self, from: data)
        }
    }

    private static func eventOrder(_ lhs: Event, _ rhs: Event) -> Bool {
        if lhs.createdAtUnixSeconds != rhs.createdAtUnixSeconds {
            return lhs.createdAtUnixSeconds < rhs.createdAtUnixSeconds
        }
        // 旧记录丢掉的精度不能复原；完全相同时让清除墓碑最后生效。
        // 新记录有亚秒顺序，清除后真正的新故障不会被这个兜底吞掉。
        if lhs.action != rhs.action { return lhs.action == .upsert }
        if lhs.writerMachineID != rhs.writerMachineID {
            return lhs.writerMachineID < rhs.writerMachineID
        }
        return lhs.id < rhs.id
    }

    private static func append(_ event: Event) {
        try? FileManager.default.createDirectory(
            at: eventDirectory, withIntermediateDirectories: true)
        guard let data = try? SnapshotCoding.prettyEncoder().encode(event) else { return }
        let safeWriter = event.writerMachineID.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_"
        }
        let filename = "event--\(String(safeWriter))--\(event.id).json"
        _ = ICloudSafe.write(data, to: eventDirectory.appendingPathComponent(filename))
    }

    /// 从 agent 的报错文本里判断该不该进冷却、进哪种。
    ///
    /// 只认平台侧的问题。agent 自己把任务干砸了不该让整个平台停摆 --
    /// 那是任务的问题，换个平台大概率一样砸。
    ///
    /// 由真实任务和持久日志恢复调用，传入 agent 的 stdout+stderr。
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
                           "you've hit your session limit",
                           "you've hit your weekly limit",
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
                   "no deployments available",
                   "cannot combine", "stream disconnected before completion",
                   "error sending request for url"]
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
    /// 只认高置信的绝对时间，或服务端明确给出的 retry-after 时长；解析不出
    /// 就返回 nil 走退避 ——
    /// 宁可退避也别把误解析的时间当真。
    public static func parseResetTime(_ text: String, now: Date = Date()) -> Date? {
        // OpenCode/火山方舟："Try again in 120 seconds"。这是服务端给出的
        // 明确 retry-after，按它恢复比统一冻结 15 分钟更准确。
        let retryAfter = #"try again in\s+(\d+)\s*(second|minute|hour)s?\b"#
        if let regex = try? NSRegularExpression(pattern: retryAfter,
                                                 options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let amount = Double(text[amountRange]), amount > 0 {
            let unit = text[unitRange].lowercased()
            let multiplier: TimeInterval = unit == "hour" ? 3600
                : (unit == "minute" ? 60 : 1)
            let delay = amount * multiplier
            if delay <= 7 * 86400 { return now.addingTimeInterval(delay) }
        }

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

        // Claude Code 2.1.246："resets 5:50pm (Asia/Shanghai)"；2.1.247
        // 在整点会省略分钟，写成 "resets 7am (Asia/Shanghai)"。
        // 日期省略时按报错所带时区取“今天”；若该时刻已过，则取次日。
        let localClock = #"resets?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: localClock,
                                                 options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let hourRange = Range(match.range(at: 1), in: text),
           let meridiemRange = Range(match.range(at: 3), in: text),
           let zoneRange = Range(match.range(at: 4), in: text),
           let rawHour = Int(text[hourRange]),
           let zone = TimeZone(identifier: String(text[zoneRange])) {
            let minute = Range(match.range(at: 2), in: text)
                .flatMap { Int(text[$0]) } ?? 0
            guard (1...12).contains(rawHour), (0...59).contains(minute) else { return nil }
            let meridiem = text[meridiemRange].lowercased()
            let hour = (rawHour % 12) + (meridiem == "pm" ? 12 : 0)
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = zone
            var components = localCalendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            if var reset = localCalendar.date(from: components) {
                if reset <= now {
                    reset = localCalendar.date(byAdding: .day, value: 1, to: reset) ?? reset
                }
                if reset > now, reset.timeIntervalSince(now) < 40 * 86400 { return reset }
            }
        }
        return nil
    }
}
