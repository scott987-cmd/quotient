import Foundation

/// 办公室里发生过什么。
///
/// 加这个是因为手机上要做一个「数字员工在办公」的动态画面，而现有数据
/// **撑不起来**：任务记录里只有整体的 startedAt/endedAt，跨平台接力
/// 只留下一个 `triedPlatforms: [claude, qwen, kimi]` 的名单和一串原因，
/// 每一棒具体什么时候交出去的没有记。
///
/// 没有这个日志，画面就只能靠编时间点 —— 那就成了装饰，而不是在反映
/// 真实发生的事。这套东西从一开始的取向就是：**屏幕上动的每一下，
/// 背后都得有一件真事**。
///
/// 记录本身很便宜：这些时刻代码里本来就知道，只是原来没落盘。
public struct OfficeEvent: Codable, Sendable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        /// 老板派活：任务被派给某个平台。
        case dispatched
        /// 交接：这个平台干不动了，活交给下一个。**这是真实的「同事之间协作」**。
        case handoff
        /// 举手提问，然后停下等回答。
        case asked
        /// 答复到了，回去接着干。
        case answered
        /// 交活。
        case finished
        /// 累趴下了：额度用尽或者进了冷却。
        case exhausted
        /// **一个人都没在干活，原因是这个。**
        ///
        /// 老板 2026-08-22 一天里问了八次「任务停了」，八次原因都不同：
        /// 磁盘满、评审判不合入、每小时限流、菜单栏 App 挂了、
        /// 队里的活全被依赖或落地闸挡着……而他在手机上看到的永远
        /// 只是一片安静。**看不见原因本身，就是那个要修的问题。**
        /// 静默超过一定时间就记一条，说清是哪一种。
        case idle
        /// 另一台更新的机器写了这台还不认识的种类。**整份文件不能因此解不出来。**
        /// 契约评审实锤(2026-08-23):merged() 对每机文件整份 `try? decode`,一个
        /// 未知 kind 就把那台机器的全部事件从合并结果里抹掉,手机上那个工位永远安静。
        case other
    }

    public var id: String
    public var at: Date
    public var kind: Kind
    public var taskID: String
    /// 主角。handoff 时是**交出去**的那个。
    public var platform: Platform?
    /// handoff 时接手的那个。
    public var toPlatform: Platform?
    public var machineID: String
    /// 一句话说清发生了什么，手机上直接显示。
    public var detail: String
    /// 任务原文的开头，用来在画面上认出是哪件活。
    public var taskTitle: String

    /// 派这件活时，谁本来也在候选里、却被规则挡掉了，以及为什么。
    ///
    /// **这是「规则如何体现」的关键。** 岗位职责写在配置文件里是死的，
    /// 只有在它真正拦下某个 agent 的那一刻才看得见 —— 比如
    /// 「Qwen 也闲着，但这是高危活，开发岗接不了」。
    /// 不记下来的话，手机上看到的只是「派给了 Claude」，
    /// 完全不知道系统替你排除了什么。
    public var excluded: [Excluded]

    public struct Excluded: Codable, Sendable {
        public var platform: Platform
        public var agentName: String
        public var reason: String
        public init(platform: Platform, agentName: String, reason: String) {
            self.platform = platform
            self.agentName = agentName
            self.reason = reason
        }
    }

    /// 容错解码。新增字段时，老事件不能因为少一个字段就整条丢掉 ——
    /// 这个坑刚在 TaskProfile 上踩过一次：缺 classifiedAt 导致整条任务记录
    /// 被静默跳过，排查时看到的现象是「文件里明明写了，程序就是读不到」。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? UUID().uuidString.prefix(12).lowercased().description
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        // 未知的 rawValue 不抛:退成 .other(见 Kind.other 的说明)。
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.map { Kind(rawValue: $0) ?? .other } ?? .finished
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        toPlatform = try c.decodeIfPresent(Platform.self, forKey: .toPlatform)
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        taskTitle = try c.decodeIfPresent(String.self, forKey: .taskTitle) ?? ""
        excluded = try c.decodeIfPresent([Excluded].self, forKey: .excluded) ?? []
    }

    public init(kind: Kind, taskID: String, platform: Platform? = nil,
                toPlatform: Platform? = nil, detail: String, taskTitle: String,
                excluded: [Excluded] = [],
                at: Date = Date(), machineID: String = Paths.machineID()) {
        self.excluded = excluded
        self.id = UUID().uuidString.prefix(12).lowercased().description
        self.at = at
        self.kind = kind
        self.taskID = taskID
        self.platform = platform
        self.toPlatform = toPlatform
        self.machineID = machineID
        self.detail = detail
        self.taskTitle = String(taskTitle.prefix(60))
    }
}

public enum OfficeLog {

    /// 测试用。
    public static var dirOverride: URL?

    static var localFile: URL {
        (dirOverride ?? Paths.appSupport).appendingPathComponent("office-events.jsonl")
    }
    static var publishedFile: URL? {
        if let dirOverride { return dirOverride.appendingPathComponent("office.json") }
        return Paths.iCloudConfigDir?.deletingLastPathComponent()
            .appendingPathComponent("office.json")
    }

    /// 保留多少条。
    ///
    /// 手机上的画面只回放最近发生的事，留太多既没人看也白占 iCloud。
    /// 200 条大概是几天的量。
    public static let keep = 200

    /// 记一笔。
    ///
    /// 失败一律吞掉：这是给画面用的，**记不上不能影响任务执行**。
    /// 反过来（让日志写失败拖垮一次真实的任务执行）是完全不能接受的。
    public static func record(_ e: OfficeEvent) {
        guard let data = try? SnapshotCoding.encoder().encode(e) else { return }
        try? Paths.ensureDirectories()
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: localFile.path),
           let h = try? FileHandle(forWritingTo: localFile) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: localFile)
        }
    }

    public static func all() -> [OfficeEvent] {
        guard let raw = try? Data(contentsOf: localFile) else { return [] }
        let dec = SnapshotCoding.decoder()
        return String(decoding: raw, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                guard let d = line.data(using: .utf8) else { return nil }
                return try? dec.decode(OfficeEvent.self, from: d)
            }
            .sorted { $0.at < $1.at }
    }

    /// 发布最近的事件给手机。顺带把本地日志截短。
    /// 每台机器自己那份:sharedRoot/office/<machineID>.json,由镜像同步到各机。
    static var perMachineDir: URL {
        (dirOverride ?? Paths.sharedRoot).appendingPathComponent("office", isDirectory: true)
    }

    /// 把本地 + 其它机器的事件并在一起(按时间),给根上的 office.json 用。
    /// 谁来写都是同一个集合 —— last-writer-wins 也就不再互相覆盖。
    /// 现在还活着的机器身份:本机 + 有每机事件文件的 + 有在线状态文件的。
    /// 不在这个集合里的 machineID 是漂移期留下的旧身份(同一台机器换过 ID)。
    static func liveMachineIDs(selfID: String) -> Set<String> {
        var live: Set<String> = [selfID]
        for dir in [perMachineDir, Paths.sharedRoot.appendingPathComponent("presence", isDirectory: true)] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where f.hasSuffix(".json") && !f.hasPrefix(".") {
                live.insert(String(f.dropLast(5)))
            }
        }
        return live
    }

    public static func merged(local: [OfficeEvent], machineID: String = Paths.machineID(),
                              liveIDs: Set<String>? = nil) -> [OfficeEvent] {
        // **旧身份的事件不进合并结果。**
        //
        // 老板 2026-08-23 晚:「办公室出现了一台未知的机器」。MacBook 换过 machineID
        // (D127… → 9FBD…),它本地事件日志里还有 110 条旧 ID 的历史;它发布根 office.json
        // 时原样带上,而旧 ID 的 presence 刚被 StaleIdentitySweep 清掉 —— 手机解析不出
        // 名字,就多出一个「未知机器」工位。身份已死的事件只是噪音,按现存身份过滤。
        let live = liveIDs ?? liveMachineIDs(selfID: machineID)
        func alive(_ e: OfficeEvent) -> Bool { e.machineID.isEmpty || live.contains(e.machineID) }
        var byKey: [String: OfficeEvent] = [:]
        func key(_ e: OfficeEvent) -> String {
            "\(e.at.timeIntervalSince1970)|\(e.kind.rawValue)|\(e.taskID)|\(e.detail.prefix(40))"
        }
        for e in local where alive(e) { byKey[key(e)] = e }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: perMachineDir.path) {
            let dec = SnapshotCoding.decoder()
            for f in files where f.hasSuffix(".json") && !f.hasPrefix(machineID) {
                guard let d = try? Data(contentsOf: perMachineDir.appendingPathComponent(f)),
                      let evs = try? dec.decode([OfficeEvent].self, from: d) else { continue }
                for e in evs where alive(e) { byKey[key(e)] = e }
            }
        }
        return Array(byKey.values.sorted { $0.at < $1.at }.suffix(keep))
    }

    public static func publish() {
        let mine = Array(all().suffix(keep))
        // ① 本机那份(给别的机器拉)
        try? FileManager.default.createDirectory(at: perMachineDir, withIntermediateDirectories: true)
        if let d = try? SnapshotCoding.prettyEncoder().encode(mine) {
            ICloudSafe.write(d, to: perMachineDir.appendingPathComponent(Paths.machineID() + ".json"))
        }
        // ② 根上合并的那份(手机读的)
        if let out = publishedFile,
           let d = try? SnapshotCoding.prettyEncoder().encode(merged(local: mine)) {
            ICloudSafe.write(d, to: out)
        }
        // ③ 截短本地 append-only 日志 —— **只在真的超长时,而且解出来的不能比
        //    文件里少得离谱**。对账实锤(2026-08-23):Mac mini 的事件日志只剩
        //    2 行,历史全没了 —— 原来这里无条件把 all() 的结果回写,all() 因为
        //    任何原因解空(半行、并发写),整份日志就被一次 publish 清空。
        let rawLines = (try? String(contentsOf: localFile, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        if rawLines > keep, mine.count >= keep / 2,
           let d = try? SnapshotCoding.encoder().encodeLines(mine) {
            ICloudSafe.write(d, to: localFile)
        }
    }
}

extension JSONEncoder {
    /// 把一批对象编成 JSONL。
    func encodeLines<T: Encodable>(_ items: [T]) throws -> Data {
        var out = Data()
        for i in items {
            out.append(try encode(i))
            out.append(0x0A)
        }
        return out
    }
}
