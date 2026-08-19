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

    /// 一个平台在一台机器上的探测结果。
    public struct Entry: Codable, Sendable {
        /// 平台显示名（`Platform.displayName`）。
        public var platform: String
        /// `可用` / `不可用` / `未安装`。
        public var status: String
        /// 不可用时的原因；可用时是回话内容。
        public var detail: String
        public var seconds: Double

        public init(platform: String, status: String,
                    detail: String, seconds: Double) {
            self.platform = platform
            self.status = status
            self.detail = detail
            self.seconds = seconds
        }

        public var isUsable: Bool { status == "可用" }
    }

    /// 一台机器的一次完整探测。
    public struct Report: Codable, Sendable {
        public var machineID: String
        public var machineName: String
        public var at: Date
        public var entries: [Entry]
    }

    static var dir: URL {
        Paths.sharedRoot.appendingPathComponent("probes", isDirectory: true)
    }

    /// 记下本机这一轮的探测结果。
    public static func record(_ entries: [Entry], now: Date = Date()) {
        let r = Report(machineID: Paths.machineID(),
                       machineName: Paths.machineName(),
                       at: now, entries: entries)
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
    /// 探针会真发请求、花真额度，所以不能跑太勤；但太老的结果比没有更糟 ——
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
            // **冷却只豁免「不可用」，不豁免「未安装」。**
            //
            // 额度用尽产生的是「不可用」，那确实是冷却那一行在讲的事。
            // 但「未安装」是另一回事：那台机器上根本没有这个 CLI，
            // 等多久都不会好。第一版把两者一起豁免了，于是
            // 「MacBook 上 Qwen 压根没装」被 Mac mini 的冷却记录盖住 ——
            // **豁免规则把一个真问题藏了起来**，正好是这套机制要防的事。
            let bad = r.entries.filter {
                guard !$0.isUsable else { return false }
                return $0.status == "未安装" || !excusedBy.contains($0.platform)
            }
            guard !bad.isEmpty else { continue }
            // 去重：同一个平台可能注册了多个执行器（MiniMax 有媒体和评审
            // 两个），显示名一样，报两遍纯属噪音。
            var seen = Set<String>()
            let names = bad.compactMap { e -> String? in
                let key = e.platform + "|" + e.status
                guard seen.insert(key).inserted else { return nil }
                return "\(e.platform)（\(e.status)）"
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
