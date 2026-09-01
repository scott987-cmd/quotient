import Foundation

/// 平台健康：**每台机器把自己探到的结果写下来，汇总给所有人看。**
///
/// ## 这东西为什么存在
///
/// 探针（`llmq work probe`）原先是「谁跑谁知道」—— 结果只打在跑它的
/// 那台机器的终端上，不落盘、不共享。后果是**一台机器上平台坏了，
/// 别的地方完全看不见**。
///
/// 实测（2026-08-19）两个真实代价：
///
/// - MacBook 上的 codex 是 0.142.5（Mac mini 是 0.147.0），
///   老到服务端直接拒：`requires a newer version of Codex`。
///   系统照旧往它派活，**连着失败 27 次**才被人从原始任务记录里翻出来 ——
///   而推到手机的看板上那一栏是空的。
/// - 同一次探针还顺带发现 MacBook 上 **Qwen 和 MiniMax 压根没装**。
///   这不是新坏的，是一直如此 —— 只是从来没人在那台机器上跑过探针。
///
/// 一个平台在某台机器上彻底坏掉，本该是一眼可见的事实，
/// 而不是靠几十次失败堆出来的推论。
///
/// ## 布局
///
/// `probes/<machineID>.json`，每台机器只写自己那份 —— 和
/// `reviews/`、`snapshots/` 同一套办法。共享单文件多写者的坑
/// 今天已经踩过一次（手机待审清单被另一台机器推成空），不再犯。
public enum PlatformHealth {

    /// 调度真正关心的是执行能力，不是供应商商标。
    public enum Capability: String, Codable, Sendable, Hashable {
        case text
        case code
        case review
        case media
    }

    public enum State: String, Codable, Sendable {
        /// 有新鲜的被动事实证明最近成功过。
        case available
        case unavailable
        /// 只知道本机配置存在，远端认证、额度和服务状态没有事实。
        case unknown
    }

    public enum Source: String, Codable, Sendable {
        case taskAttempt
        case localConfiguration
        case legacyActiveProbe
    }

    /// 一个平台在一台机器上的探测结果。
    public struct Entry: Codable, Sendable {
        /// 平台显示名（`Platform.displayName`）。
        public var platform: String
        /// 同一平台可以注册代码、评审、媒体等多个完全不同的执行器。
        public var runnerID: String
        public var capability: Capability
        public var state: State
        public var source: Source
        public var observedAt: Date?
        public var expiresAt: Date?
        /// `可用` / `不可用` / `未安装`。
        public var status: String
        /// 不可用时的原因；可用时是回话内容。
        public var detail: String
        public var seconds: Double

        public init(platform: String, status: String,
                    detail: String, seconds: Double) {
            self.platform = platform
            self.runnerID = "legacy." + platform.lowercased()
                .replacingOccurrences(of: " ", with: "-")
            self.capability = .text
            self.state = status == "可用" ? .available
                : (status == "不可用" || status == "未安装" ? .unavailable : .unknown)
            self.source = .legacyActiveProbe
            self.observedAt = nil
            self.expiresAt = nil
            self.status = status
            self.detail = detail
            self.seconds = seconds
        }

        public init(platform: String, runnerID: String, capability: Capability,
                    state: State, source: Source, observedAt: Date,
                    expiresAt: Date?, detail: String, seconds: Double = 0) {
            self.platform = platform
            self.runnerID = runnerID
            self.capability = capability
            self.state = state
            self.source = source
            self.observedAt = observedAt
            self.expiresAt = expiresAt
            self.status = switch state {
            case .available: "可用"
            case .unavailable: source == .localConfiguration ? "未安装" : "不可用"
            case .unknown: "未知"
            }
            self.detail = detail
            self.seconds = seconds
        }

        /// 这台机器上**以前**这个平台能用过吗。
        ///
        /// 由 `record` 在覆盖前对比上一份报告自动填，不用人配。
        public var wasUsableHere: Bool = false

        public var key: String { runnerID + "|" + capability.rawValue }

        public var isUsable: Bool { state == .available }

        public func isFresh(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return now < expiresAt
        }

        /// 这条算不算**故障**。
        ///
        /// 老板（2026-08-20）：「不需要装，每台电脑本来安装的东西就不一样」。
        ///
        /// 所以「没装」本身不是故障 —— 那是这台机器的配置。
        /// 但**装过又没了**是故障：要么被误删，要么 PATH 断了，
        /// 而系统会继续往它派活。
        ///
        /// 不用人手工声明「这台不装什么」：上一份探针报告就是答案。
        /// 要人维护一份清单，清单迟早和现实对不上 ——
        /// 那时候它报的就不是现实，是那份清单。
        public var isFault: Bool {
            if isUsable { return false }
            if status == "未安装" { return wasUsableHere }
            return true      // 装着却跑不通 —— 一律算故障
        }

        private enum CodingKeys: String, CodingKey {
            case platform, runnerID, capability, state, source, observedAt, expiresAt
            case status, detail, seconds, wasUsableHere
        }

        /// 探针报告会跨机器滚动升级；旧报告缺少 Runner 维度时降级成 legacy 键，
        /// 不能因为一个新字段让整台机器从汇总里消失。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            platform = try c.decode(String.self, forKey: .platform)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "未知"
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            runnerID = try c.decodeIfPresent(String.self, forKey: .runnerID)
                ?? "legacy." + platform.lowercased().replacingOccurrences(of: " ", with: "-")
            capability = try c.decodeIfPresent(Capability.self, forKey: .capability) ?? .text
            state = try c.decodeIfPresent(State.self, forKey: .state)
                ?? (status == "可用" ? .available
                    : (status == "不可用" || status == "未安装" ? .unavailable : .unknown))
            source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .legacyActiveProbe
            observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt)
            expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
            wasUsableHere = try c.decodeIfPresent(Bool.self, forKey: .wasUsableHere) ?? false
        }
    }

    /// 一台机器的一次完整探测。
    public struct Report: Codable, Sendable {
        public var machineID: String
        public var machineName: String
        public var at: Date
        public var entries: [Entry]
    }

    public static func capability(for runner: AgentRunner) -> Capability {
        if runner.mediaOnly { return .media }
        if runner.reviewOnly { return .review }
        if runner.canEdit { return .code }
        return .text
    }

    /// 零 token、零工具、零文件副作用的第一层检查。
    ///
    /// 二进制存在只说明本地配置齐全，不能证明远端认证或额度可用，因此保持
    /// `unknown`。真正的 `available` 只能由近期真实任务成功这类被动事实产生。
    public static func passiveEntries(runners: [AgentRunner], now: Date = Date()) -> [Entry] {
        runners.map { runner in
            let capability = capability(for: runner)
            let installed = runner.isAvailable
            return Entry(
                platform: runner.platform.displayName,
                runnerID: runner.runnerID,
                capability: capability,
                state: installed ? .unknown : .unavailable,
                source: .localConfiguration,
                observedAt: now,
                expiresAt: now.addingTimeInterval(3600),
                detail: installed
                    ? "本地执行器存在；远端认证、额度和服务状态尚无被动事实"
                    : runner.binaryName + " 没装或不可执行")
        }
    }

    /// 低置信本地扫描不能覆盖仍新鲜的真实任务事实。
    public static func mergedEntries(incoming: [Entry], previous: [Entry],
                                     now: Date = Date()) -> [Entry] {
        let previousByKey = Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0) })
        return incoming.map { entry in
            guard entry.source == .localConfiguration,
                  let old = previousByKey[entry.key],
                  old.source == .taskAttempt, old.isFresh(now: now) else { return entry }
            return old
        }
    }

    /// 真实任务结果是健康状态的首选被动来源。
    public static func recordObservation(
        runner: AgentRunner, state: State, detail: String,
        expiresAt: Date? = nil, now: Date = Date()
    ) {
        let id = Paths.machineID()
        let before = all().first { $0.machineID == id }?.entries ?? []
        let entry = Entry(
            platform: runner.platform.displayName,
            runnerID: runner.runnerID,
            capability: capability(for: runner),
            state: state,
            source: .taskAttempt,
            observedAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(3600),
            detail: detail)
        record(before.filter { $0.key != entry.key } + [entry], now: now)
    }

    static var dir: URL {
        Paths.sharedRoot.appendingPathComponent("probes", isDirectory: true)
    }

    /// 记下本机这一轮的探测结果。
    public static func record(_ entries: [Entry], now: Date = Date()) {
        // 覆盖前先看上一份：哪些平台在这台机器上**曾经**是可用的。
        // 「一直没装」和「装过又没了」是两回事，只有后者是故障。
        let id = Paths.machineID()
        let before = all().first { $0.machineID == id }
        var everUsable = Set(before?.entries.filter(\.isUsable).map(\.key) ?? [])
        // 上一份里已经标过的也要传下去 —— 否则平台坏掉的第二轮，
        // 「以前能用」这个事实就丢了，故障会自己降级成「本来就没装」。
        for e in before?.entries ?? [] where e.wasUsableHere {
            everUsable.insert(e.key)
        }
        let merged = mergedEntries(incoming: entries, previous: before?.entries ?? [], now: now)
        let stamped = merged.map { e -> Entry in
            var e = e
            e.wasUsableHere = e.isUsable || everUsable.contains(e.key)
            return e
        }
        let r = Report(machineID: id,
                       machineName: Paths.machineName(),
                       at: now, entries: stamped)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(r) else { return }
        try? d.write(to: dir.appendingPathComponent(r.machineID + ".json"))
    }

    /// 读回所有机器的探测结果。
    public static func all() -> [Report] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap {
                try? dec.decode(Report.self, from: $0)
            }
        }.sorted { $0.machineName < $1.machineName }
    }

    /// 超过这个时长的探测结果不再当成「现状」。
    ///
    /// 被动事实也会过时；太老的结果比没有更糟 ——
    /// 平台可能早就修好了，而这里还在报「坏着」，人会学会忽略它。
    public static let staleAfter: TimeInterval = 24 * 3600

    /// 汇总成人能一眼看懂的几句话。
    ///
    /// **只报坏消息。** 全都好的时候一个字都不说 —— 每天都出现的
    /// 「一切正常」会被训练成背景噪音，真出事那天也一样被忽略。
    ///
    /// - Parameter staleAfter: 多久之前的结果算过期（默认 24 小时）。
    /// - Parameter excusedBy: 已经在别处报过的平台（显示名），这里不再重复。
    ///   典型是**冷却中**的：额度用尽是已知的、会自愈的状态，
    ///   `brief` 已经有专门一行写着「还有几天恢复」。同一件事报两遍，
    ///   人会开始跳过整段 —— 那时真正的故障（CLI 坏了、版本太老、没装）
    ///   也一起被跳过了。
    ///
    ///   这一条不是洁癖：这套机制存在的全部理由就是让**真故障**一眼可见，
    ///   而冷却混进来会稀释它。
    public static func problems(reports: [Report] = all(),
                                excusedBy: Set<String> = [],
                                excusedKeys: Set<String> = [],
                                staleAfter: TimeInterval = staleAfter,
                                now: Date = Date()) -> [String] {
        var out: [String] = []
        for r in reports {
            let age = now.timeIntervalSince(r.at)
            if age > staleAfter {
                // 过期的不报平台状态，只报「这台机器很久没探了」——
                // 拿三天前的结果当现状，比没有结果更容易误导人。
                out.append("\(r.machineName)：探针结果是 "
                    + Format.duration(age) + "前的，已过期")
                continue
            }
            let expired = r.entries.filter {
                $0.expiresAt != nil && !$0.isFresh(now: now)
            }
            if !expired.isEmpty {
                let names = expired.map {
                    $0.runnerID + "/" + $0.capability.rawValue
                }.joined(separator: " · ")
                out.append("\(r.machineName)：健康事实已过期：" + names)
            }
            // **冷却只豁免「不可用」，不豁免「未安装」。**
            //
            // 额度用尽产生的是「不可用」，那确实是冷却那一行在讲的事。
            // 但「未安装」是另一回事：那台机器上根本没有这个 CLI，
            // 等多久都不会好。第一版把两者一起豁免了，于是
            // 「MacBook 上 Qwen 压根没装」被 Mac mini 的冷却记录盖住 ——
            // **豁免规则把一个真问题藏了起来**，正好是这套机制要防的事。
            let bad = r.entries.filter {
                guard $0.expiresAt == nil || $0.isFresh(now: now) else { return false }
                guard $0.isFault else { return false }
                // 冷却只豁免「不可用」（额度用尽有专门一行讲）；
                // 「装过又没了」冷却解释不了，照报。
                if $0.status == "未安装" { return true }
                if excusedKeys.contains($0.key) { return false }
                // 旧报告没有 Runner 身份，只能继续用平台级豁免。
                if $0.source == .legacyActiveProbe,
                   excusedBy.contains($0.platform) { return false }
                return true
            }
            guard !bad.isEmpty else { continue }
            // 去重：同一个平台可能注册了多个执行器（MiniMax 有媒体和评审
            // 两个），显示名一样，报两遍纯属噪音。
            var seen = Set<String>()
            let names = bad.compactMap { e -> String? in
                let key = e.key + "|" + e.status
                guard seen.insert(key).inserted else { return nil }
                return "\(e.platform) · \(e.runnerID)/\(e.capability.rawValue)（\(e.status)）"
            }.joined(separator: " · ")
            out.append("\(r.machineName)：" + names)
        }
        return out
    }

    /// 从来没探过的机器。
    ///
    /// 单独列出来，因为它和「探过、有平台坏了」是两件事：
    /// 前者是**我们不知道那台机器怎么样**，后者是我们知道它有问题。
    /// 把「不知道」显示成「没问题」正是这次 27 次失败的成因。
    public static func neverProbed(known: [String],
                                   reports: [Report] = all()) -> [String] {
        let probed = Set(reports.map(\.machineName))
        return known.filter { !probed.contains($0) }.sorted()
    }
}
