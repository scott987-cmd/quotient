import Foundation

// MARK: - Usage event

/// 一次真实的 API 调用。适配器解析日志后产出这个，再由 Collector 去重、装桶。
public struct UsageEvent: Codable, Sendable {
    /// 全局去重键。Claude Code 会为同一个 requestId 写好几行（正文一行、每个
    /// tool_use 一行），而且续接会话时会把旧消息原样抄进新文件，所以必须去重。
    public var id: String
    public var timestamp: Date
    public var platform: Platform
    public var model: String
    /// 这次调用吃的是哪个额度池。
    public var lane: UsageLane
    /// 算几次 API 调用。真人消息事件是 0（它本身不打 API）。
    public var requests: Int
    /// 算几条"人发的消息"。
    ///
    /// 这个口径和 requests 必须分开：各家套餐公布的上限数的是**你发了几条消息**，
    /// 而一条消息背后是整个工具循环的几十次 API 调用。
    /// 实测本机 425 条真人消息对应 4767 条工具结果回填，
    /// 混为一谈会让"已用百分比"偏出十几倍。
    public var prompts: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    enum CodingKeys: String, CodingKey {
        case id = "i"
        case timestamp = "t"
        case platform = "p"
        case model = "m"
        case lane = "l"
        case requests = "rq"
        case prompts = "pr"
        case inputTokens = "in"
        case outputTokens = "o"
        case cacheReadTokens = "cr"
        case cacheWriteTokens = "cw"
    }

    public init(
        id: String,
        timestamp: Date,
        platform: Platform,
        model: String,
        lane: UsageLane = .interactive,
        requests: Int = 1,
        prompts: Int = 0,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.platform = platform
        self.model = model
        self.lane = lane
        self.requests = requests
        self.prompts = prompts
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        platform = try c.decode(Platform.self, forKey: .platform)
        model = try c.decode(String.self, forKey: .model)
        lane = try c.decodeIfPresent(UsageLane.self, forKey: .lane)
            ?? UsageLane.conservativeDefault
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 1
        prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try c.decode(Int.self, forKey: .cacheWriteTokens)
    }

    /// 同一个 requestId 的多行里，通常只有一行带真实数字、其余是全零。
    /// 逐字段取最大值，既能合并"完全一致"的重复，也能捞出被零行盖掉的真值。
    public func mergingDuplicate(_ other: UsageEvent) -> UsageEvent {
        UsageEvent(
            id: id,
            timestamp: min(timestamp, other.timestamp),
            platform: platform,
            model: model.isEmpty ? other.model : model,
            lane: lane,
            requests: max(requests, other.requests),
            prompts: max(prompts, other.prompts),
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            cacheReadTokens: max(cacheReadTokens, other.cacheReadTokens),
            cacheWriteTokens: max(cacheWriteTokens, other.cacheWriteTokens)
        )
    }
}

/// 单个文件的解析结果。
public struct ParsedFile: Codable, Sendable {
    public var events: [UsageEvent]
    public var quotas: [OfficialQuota]
    public var lastEventAt: Date?

    public init(events: [UsageEvent] = [], quotas: [OfficialQuota] = [], lastEventAt: Date? = nil) {
        self.events = events
        self.quotas = quotas
        self.lastEventAt = lastEventAt
    }
}

// MARK: - Adapter protocol

public protocol UsageAdapter: Sendable {
    /// 缓存文件名用，必须稳定。
    var id: String { get }
    var displayName: String { get }
    /// 模型名认不出来时归到哪个平台 —— 也就是这个 CLI 默认服务的平台。
    var homePlatform: Platform { get }
    /// 数据源根目录，`~` 未展开。用于"有没有装"的探测。
    var roots: [String] { get }
    /// 这个适配器是否已用真实数据验证过。没验证过的会在报告里标出来。
    var verified: Bool { get }

    func discoverFiles() -> [URL]
    func parse(file: URL, data: Data) -> ParsedFile
}

public extension UsageAdapter {
    var expandedRoots: [URL] {
        roots.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    var isInstalled: Bool {
        expandedRoots.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 在根目录下递归找出所有 .jsonl 文件。
    func jsonlFiles(under subpaths: [String]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in expandedRoots {
            for sub in subpaths {
                let dir = sub.isEmpty ? root : root.appendingPathComponent(sub)
                guard fm.fileExists(atPath: dir.path) else { continue }
                guard let en = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    out.append(url)
                }
            }
        }
        return out
    }
}

// MARK: - Byte-level line scanning

/// 逐行切分不做 String 转换 —— 本机 Claude Code 的日志有 1GB 出头，
/// 全量转 String 既慢又吃内存。直接在 Data 上按 \n 切，再对命中预筛的行做 JSON 解析。
public enum LineScanner {
    private static let newline: UInt8 = 0x0A

    public static func forEachLine(_ data: Data, _ body: (Data) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var start = 0
            var i = 0
            while i < count {
                if base[i] == newline {
                    if i > start {
                        body(Data(bytes: base + start, count: i - start))
                    }
                    start = i + 1
                }
                i += 1
            }
            if start < count {
                body(Data(bytes: base + start, count: count - start))
            }
        }
    }

    /// 便宜的子串预筛，避免对每一行都跑 JSON 解析。
    public static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let n = raw.count
            let m = needle.count
            let first = needle[0]
            var i = 0
            while i <= n - m {
                if base[i] == first {
                    var j = 1
                    while j < m, base[i + j] == needle[j] { j += 1 }
                    if j == m { return true }
                }
                i += 1
            }
            return false
        }
    }
}

// MARK: - JSON helpers

public enum JSONHelp {
    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func int(_ any: Any?) -> Int {
        switch any {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v) ?? 0
        default: return 0
        }
    }

    public static func double(_ any: Any?) -> Double? {
        switch any {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

// MARK: - Per-file cache

/// 一个文件的缓存记录。
///
/// 保留窗口内仍有 3171 个文件、约 1GB，每次采集全量重解析太浪费。
/// 用 (size, mtime) 判断文件有没有变，没变就直接复用上次解析出来的事件。
/// 变了就整个文件重新解析 —— 而不是从上次的 offset 续读。
/// 这点很重要：Claude Code 同一个 requestId 会跨多行，续读会把一次请求
/// 劈成两次运行的两半，去重就失效了。整文件重解析没有这个问题，
/// 而且真正会变的只有当前正在写的那几个会话文件，成本可以忽略。
struct FileCacheEntry: Codable {
    var size: UInt64
    /// 存原始 Unix 时间戳而不是 Date。
    ///
    /// Date 走 ISO8601 编码会丢掉亚秒精度，回读后跟文件系统给的 mtime 永远对不上，
    /// 结果就是缓存 100% 不命中、每次都把 1GB 日志重解析一遍。
    var modifiedEpoch: Double
    var parsed: ParsedFile
    /// 整个文件都已滚出保留窗口。留个墓碑记住 size/mtime，之后直接跳过不再解析。
    var prunedOutOfWindow: Bool

    init(size: UInt64, modified: Date, parsed: ParsedFile, prunedOutOfWindow: Bool = false) {
        self.size = size
        self.modifiedEpoch = modified.timeIntervalSince1970
        self.parsed = parsed
        self.prunedOutOfWindow = prunedOutOfWindow
    }

    func matches(size: UInt64, modified: Date) -> Bool {
        self.size == size && self.modifiedEpoch == modified.timeIntervalSince1970
    }
}

struct AdapterCache: Codable {
    /// 解析器版本。**改了任何适配器的解析逻辑就要 +1。**
    ///
    /// 缓存存的是解析结果，不是原始文件。所以解析逻辑一变，旧缓存就是错的 ——
    /// 而文件本身没动，(size, mtime) 判定会命中，于是静默复用旧结果，
    /// 新加的字段永远是空的。加 prompts 口径时就踩了这个坑。
    static let parserVersion = 2

    var adapterID: String
    var parserVersion: Int
    var files: [String: FileCacheEntry]

    init(adapterID: String, files: [String: FileCacheEntry] = [:]) {
        self.adapterID = adapterID
        self.parserVersion = Self.parserVersion
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adapterID = try c.decode(String.self, forKey: .adapterID)
        parserVersion = try c.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 0
        files = try c.decode([String: FileCacheEntry].self, forKey: .files)
    }
}

// MARK: - Paths

public enum Paths {
    public static let appName = "LLMQuotaBar"

    /// 测试用：把整个数据目录挪到临时位置。产品代码里永远是 nil。
    ///
    /// 加这个是因为踩到了：worktree 相关的测试直接在**真实的**
    /// Application Support 里建 worktree，和正在跑的 worker 抢同一个位置，
    /// 于是整套测试偶发失败（一次 5 个），而单跑每一条都过。
    /// 测试污染生产状态，最后总会变成一个查不出原因的怪问题。
    public static var appSupportOverride: URL?

    public static var appSupport: URL {
        if let appSupportOverride { return appSupportOverride }
        // **`LLMQ_HOME` 可以把整个数据目录挪走。**
        //
        // 为什么需要它：`FileManager.homeDirectoryForCurrentUser` 在 macOS 上
        // 从 passwd 读，**不受 `HOME` 影响** —— 所以没法靠改 HOME 造一个
        // 干净环境。而干净环境是三件事的前提：新用户想先试试不弄脏自己的配置、
        // CI 要跑端到端、演示要可复现。
        //
        // 优先级在 appSupportOverride 之后：那个是测试用的进程内开关，
        // 优先级最高，免得环境变量把测试沙盒顶掉。
        if let custom = ProcessInfo.processInfo.environment["LLMQ_HOME"],
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath,
                       isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var cacheDir: URL { appSupport.appendingPathComponent("cache", isDirectory: true) }
    public static var plansFile: URL { appSupport.appendingPathComponent("plans.json") }
    public static var machineIDFile: URL { appSupport.appendingPathComponent("machine-id") }
    public static var localSnapshotsDir: URL {
        appSupport.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 本地共享暂存根：`Application Support/LLMQuotaBar/shared/`。
    ///
    /// ## 为什么 CLI 不再直接碰 iCloud
    ///
    /// launchd 起的常驻进程访问 iCloud Drive 会**永久挂起**
    /// （TCC 的 FileProviderDomain 闸门，完全磁盘访问覆盖不了它，实测过多次）。
    /// 靠看门狗兜底的代价是工作循环每轮白等 8–45 秒、当轮发布失败。
    ///
    /// 所以现在：CLI 只读写这个本地目录（不受任何闸门管），
    /// 菜单栏 App 里的 MirrorService 负责它和 iCloud 真身之间的镜像 ——
    /// App 是有界面的进程，能用 NSOpenPanel + security-scoped bookmark
    /// 拿到用户亲手授出的 iCloud 目录访问权。代价（用户已接受）：
    /// App 不在跑就不同步。目录结构和 iCloud 的 LLMQuotaBar/ 完全一致，
    /// 见 `SharedLayout`。
    public static var sharedRoot: URL {
        appSupport.appendingPathComponent("shared", isDirectory: true)
    }

    /// 共享配置目录。
    ///
    /// 套餐上限、月费、冷却状态都是**账号级**的，不该按机器各存一份：
    /// 换台机器就要重填一遍上限，而 Kimi 额度用尽在 A 机器撞到之后，
    /// B 机器不该再白撞一次。
    ///
    /// **属性名保留，指向变了**：现在是本地暂存（`sharedRoot/config`），
    /// 由菜单栏 App 镜像到 iCloud。`ICloudSafe.isICloud` 对它返回 false，
    /// 所有原来的看门狗包裹自动变成零开销直通 ——
    /// 这就是消掉每轮 8–45 秒 iCloud 税的机制。
    public static var iCloudConfigDir: URL? {
        sharedRoot.appendingPathComponent("config", isDirectory: true)
    }

    /// 共享快照目录 —— 多机汇总就靠它，不需要任何服务器。
    /// 同上：本地暂存（`sharedRoot/snapshots`），由菜单栏 App 镜像。
    public static var iCloudSnapshotsDir: URL? {
        sharedRoot.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 快照写到哪。共享暂存永远可用（本地目录），兜底分支只是保住类型。
    public static var snapshotsDir: URL { iCloudSnapshotsDir ?? localSnapshotsDir }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupport, cacheDir, localSnapshotsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // 共享暂存的整套子目录一次建齐 —— CLI 和 App 靠这个结构对话。
        SharedLayout.ensure(at: sharedRoot)
    }

    /// 这台机器的身份。**优先从硬件派生,文件只是缓存。**
    ///
    /// ## 为什么不能只靠文件
    ///
    /// 原来是「读文件,没有就随机生成一个再写进去」—— 那么**文件一丢就换个
    /// 身份**,而快照是按机器 ID 存的,于是同一台机器在看板上变成好几台。
    ///
    /// 实锤(2026-08-23 早):老板「手机展示了好几个 mac mini」——
    /// 共享目录里躺着**同一台机器的 9 个 ID**,每份快照的桶数完全相同(187),
    /// 说明是同一份数据被反复写入,每次带一个新身份。
    ///
    /// 硬件 UUID(IOPlatformUUID)在同一台机器上永远一样,重装系统也不变。
    /// 从它派生就不再有「身份漂移」这回事:文件丢了、目录被清了、
    /// 哪个进程先跑,算出来都是同一个 ID。
    ///
    /// 文件保留作缓存(省一次 ioreg),但**以硬件为准** —— 缓存和硬件对不上
    /// 时以硬件为准并改写缓存,这样历史上那些漂移过的 ID 会自动收敛回来。
    /// 测试用:模拟「另一台机器」。生产永远是 nil。
    public static var machineIDOverride: String?

    public static func machineID() -> String {
        if let o = machineIDOverride { return o }
        if let hw = hardwareUUID() {
            // 硬件 ID 直接用,顺手把缓存对齐(下次别人读缓存也是对的)。
            if (try? String(contentsOf: machineIDFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) != hw {
                try? Paths.ensureDirectories()
                try? hw.write(to: machineIDFile, atomically: true, encoding: .utf8)
            }
            return hw
        }
        // 拿不到硬件 ID(非 macOS / ioreg 不可用)才退回老办法。
        if let s = try? String(contentsOf: machineIDFile, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let new = UUID().uuidString
        try? Paths.ensureDirectories()
        try? new.write(to: machineIDFile, atomically: true, encoding: .utf8)
        return new
    }

    /// 硬件 UUID。取不到就返回 nil,调用方自己兜底。
    static func hardwareUUID() -> String? {
        let r = Proc.run("/usr/sbin/ioreg",
                         ["-rd1", "-c", "IOPlatformExpertDevice"],
                         cwd: "/", env: [:], timeout: 10)
        guard r.exitCode == 0 else { return nil }
        guard let line = r.stdout.split(separator: "\n")
            .first(where: { $0.contains("IOPlatformUUID") }) else { return nil }
        // **Swift 的 split 默认丢掉空片段** —— 按引号切
        // `"IOPlatformUUID" = "0A9B…"` 得到的是 3 段不是 5 段,
        // 按下标取会取错(2026-08-23 被测试当场抓到)。
        // 直接挑「长得像 UUID」的那一段,不依赖段数。
        return line.split(separator: "\"")
            .map(String.init)
            .first { $0.count == 36 && $0.filter { $0 == "-" }.count == 4 }
    }

    public static func machineName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

// MARK: - Collector

public struct CollectStats: Sendable {
    public var adapterID: String
    public var filesSeen: Int
    public var filesParsed: Int
    public var filesReused: Int
    public var bytesParsed: Int
    public var rawEvents: Int
    public var dedupedEvents: Int
    public var installed: Bool
}

public struct CollectResult: Sendable {
    public var snapshot: MachineSnapshot
    public var stats: [CollectStats]
    public var duration: TimeInterval
    /// 快照有没有成功同步到 iCloud。由写入方填。
    public var iCloudSync: ICloudSyncStatus = .unavailable
    /// 从 iCloud 镜像到本地的其他机器数量。
    public var mirroredMachines: Int = 0
    /// 上一份快照里有、但当前二进制不认识的采集器。
    /// 非空说明本机还有另一个更新的二进制也在写同一份快照 —— 数据会来回打架。
    public var staleBinaryWarning: [String] = []
}

/// 未经合并的原始扫描结果，专供上限学习使用。
public struct RawScan: Sendable {
    /// 按平台分组、已全局去重、按时间升序的调用事件。
    public var events: [Platform: [UsageEvent]]
    /// 按平台分组的**全部**官方额度观测，按观测时刻升序。
    public var quotas: [Platform: [OfficialQuota]]

    public init(events: [Platform: [UsageEvent]], quotas: [Platform: [OfficialQuota]]) {
        self.events = events
        self.quotas = quotas
    }
}

public final class Collector {
    public static let retentionDays = 32

    private let adapters: [UsageAdapter]
    private let fm = FileManager.default

    public init(adapters: [UsageAdapter] = AdapterRegistry.all) {
        self.adapters = adapters
    }

    public func collect(now: Date = Date()) throws -> CollectResult {
        let started = Date()
        try Paths.ensureDirectories()
        let retentionStart = now.addingTimeInterval(-Double(Self.retentionDays) * 86400)

        var perPlatformEvents: [Platform: [String: UsageEvent]] = [:]
        var perPlatformQuotas: [Platform: [OfficialQuota]] = [:]
        var perPlatformSources: [Platform: Set<String>] = [:]
        var detectedPlatforms: Set<Platform> = []
        var installedPlatforms: Set<Platform> = []
        var notes: [Platform: String] = [:]
        var stats: [CollectStats] = []

        for adapter in adapters {
            var st = CollectStats(
                adapterID: adapter.id, filesSeen: 0, filesParsed: 0, filesReused: 0,
                bytesParsed: 0, rawEvents: 0, dedupedEvents: 0, installed: adapter.isInstalled
            )

            guard adapter.isInstalled else {
                stats.append(st)
                if notes[adapter.homePlatform] == nil {
                    notes[adapter.homePlatform] = "本机未检测到 \(adapter.displayName)"
                }
                continue
            }

            installedPlatforms.insert(adapter.homePlatform)
            var cache = loadCache(adapter.id)
            var nextFiles: [String: FileCacheEntry] = [:]
            let files = adapter.discoverFiles()
            st.filesSeen = files.count

            for url in files {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }

                let key = url.path
                if let cached = cache.files[key], cached.matches(size: size, modified: mtime) {
                    st.filesReused += 1
                    nextFiles[key] = cached
                    if !cached.prunedOutOfWindow {
                        absorb(cached.parsed, adapter: adapter, into: &perPlatformEvents,
                               quotas: &perPlatformQuotas, sources: &perPlatformSources,
                               detected: &detectedPlatforms, url: url,
                               retentionStart: retentionStart, stats: &st)
                    }
                    continue
                }

                // 文件没见过或已改动：整个重新解析。
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                st.filesParsed += 1
                st.bytesParsed += data.count

                var parsed = adapter.parse(file: url, data: data)
                parsed.events.removeAll { $0.timestamp < retentionStart }

                let outOfWindow = parsed.events.isEmpty
                    && (parsed.lastEventAt.map { $0 < retentionStart } ?? true)
                if outOfWindow {
                    nextFiles[key] = FileCacheEntry(
                        size: size, modified: mtime,
                        parsed: ParsedFile(events: [], quotas: [], lastEventAt: parsed.lastEventAt),
                        prunedOutOfWindow: true
                    )
                    continue
                }

                nextFiles[key] = FileCacheEntry(size: size, modified: mtime, parsed: parsed)
                absorb(parsed, adapter: adapter, into: &perPlatformEvents,
                       quotas: &perPlatformQuotas, sources: &perPlatformSources,
                       detected: &detectedPlatforms, url: url,
                       retentionStart: retentionStart, stats: &st)
            }

            cache.files = nextFiles
            saveCache(cache)

            st.dedupedEvents = perPlatformEvents.values.reduce(0) { $0 + $1.count }
            stats.append(st)
        }

        // MiniMax 有官方额度接口（mmx quota show），直接问比从日志推靠谱得多。
        // 这是继 Codex 之后第二个不用猜的额度源。
        if MiniMaxProbe.isAvailable {
            let q = MiniMaxProbe.fetch(now: now)
            if !q.isEmpty {
                perPlatformQuotas[.minimax, default: []].append(contentsOf: q)
                installedPlatforms.insert(.minimax)
                detectedPlatforms.insert(.minimax)
                perPlatformSources[.minimax, default: []].insert("mmx quota show")
            }
        }

        // 事件装桶
        var snapshots: [PlatformSnapshot] = []
        for platform in Platform.activeCases {
            let events = perPlatformEvents[platform]?.values ?? Dictionary<String, UsageEvent>().values
            var buckets: [BucketKey: UsageBucket] = [:]
            var lastActivity: Date?

            for e in events {
                let start = UsageBucket.alignedStart(for: e.timestamp)
                let key = BucketKey(start: start, model: e.model, lane: e.lane)
                var b = buckets[key] ?? UsageBucket(start: start, model: e.model, lane: e.lane)
                b.merge(UsageBucket(
                    start: start, model: e.model, lane: e.lane,
                    prompts: e.prompts, requests: e.requests,
                    inputTokens: e.inputTokens, outputTokens: e.outputTokens,
                    cacheReadTokens: e.cacheReadTokens, cacheWriteTokens: e.cacheWriteTokens
                ))
                buckets[key] = b
                if lastActivity == nil || e.timestamp > lastActivity! { lastActivity = e.timestamp }
            }

            let quotas = dedupeQuotas(perPlatformQuotas[platform] ?? [])
            let detected = detectedPlatforms.contains(platform) || !quotas.isEmpty
            let installed = installedPlatforms.contains(platform)

            guard detected || !buckets.isEmpty else {
                snapshots.append(PlatformSnapshot(
                    platform: platform, detected: false, installed: installed,
                    note: installed
                        ? "已安装，但最近 \(Self.retentionDays) 天没有用量"
                        : (notes[platform] ?? "本机未检测到数据源")
                ))
                continue
            }

            snapshots.append(PlatformSnapshot(
                platform: platform,
                detected: true,
                installed: installed,
                sources: Array(perPlatformSources[platform] ?? []).sorted(),
                buckets: buckets.values.sorted { $0.start < $1.start },
                officialQuotas: quotas,
                lastActivity: lastActivity,
                note: notes[platform]
            ))
        }

        let snapshot = MachineSnapshot(
            machineID: Paths.machineID(),
            machineName: Paths.machineName(),
            generatedAt: now,
            retentionStart: retentionStart,
            platforms: snapshots,
            collectorAdapters: adapters.map(\.id).sorted()
        )

        return CollectResult(
            snapshot: snapshot,
            stats: stats,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// 原始扫描：拿到去重后的全部事件 + **全部**额度观测（不做"只留最新一条"的合并）。
    ///
    /// 正常采集只保留每条额度的最新观测，因为仪表盘只关心此刻的状态。
    /// 但要反解出"上限到底是多少"，需要的恰恰是历史序列 ——
    /// 每一条 (观测时刻, 已用百分比) 配上我自己算出的同期用量，就是一个方程。
    /// 本机 Codex 日志里有 2793 条这样的观测。
    ///
    /// 只读：不写缓存、不写快照。缓存命中时很快。
    public func scanRaw(now: Date = Date()) throws -> RawScan {
        let retentionStart = now.addingTimeInterval(-Double(Self.retentionDays) * 86400)
        var events: [Platform: [String: UsageEvent]] = [:]
        var quotas: [Platform: [OfficialQuota]] = [:]

        for adapter in adapters where adapter.isInstalled {
            let cache = loadCache(adapter.id)
            for url in adapter.discoverFiles() {
                var parsed: ParsedFile
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = (attrs[.size] as? NSNumber)?.uint64Value,
                   let mtime = attrs[.modificationDate] as? Date,
                   let cached = cache.files[url.path],
                   cached.matches(size: size, modified: mtime) {
                    if cached.prunedOutOfWindow { continue }
                    parsed = cached.parsed
                } else {
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                    parsed = adapter.parse(file: url, data: data)
                }

                for e in parsed.events where e.timestamp >= retentionStart {
                    if let existing = events[e.platform]?[e.id] {
                        events[e.platform]?[e.id] = existing.mergingDuplicate(e)
                    } else {
                        events[e.platform, default: [:]][e.id] = e
                    }
                }
                quotas[adapter.homePlatform, default: []].append(contentsOf: parsed.quotas)
            }
        }

        var out = RawScan(events: [:], quotas: [:])
        for (p, dict) in events {
            out.events[p] = dict.values.sorted { $0.timestamp < $1.timestamp }
        }
        for (p, list) in quotas {
            out.quotas[p] = list.sorted { $0.observedAt < $1.observedAt }
        }
        return out
    }

    private func absorb(
        _ parsed: ParsedFile,
        adapter: UsageAdapter,
        into events: inout [Platform: [String: UsageEvent]],
        quotas: inout [Platform: [OfficialQuota]],
        sources: inout [Platform: Set<String>],
        detected: inout Set<Platform>,
        url: URL,
        retentionStart: Date,
        stats: inout CollectStats
    ) {
        detected.insert(adapter.homePlatform)
        sources[adapter.homePlatform, default: []].insert(shortSource(url, adapter: adapter))

        for e in parsed.events where e.timestamp >= retentionStart {
            stats.rawEvents += 1
            detected.insert(e.platform)
            sources[e.platform, default: []].insert(shortSource(url, adapter: adapter))
            if let existing = events[e.platform]?[e.id] {
                events[e.platform]?[e.id] = existing.mergingDuplicate(e)
            } else {
                events[e.platform, default: [:]][e.id] = e
            }
        }

        quotas[adapter.homePlatform, default: []].append(contentsOf: parsed.quotas)
    }

    /// 报告里显示的是数据源根目录，不是每个文件的完整路径 —— 4000 个路径没人看。
    private func shortSource(_ url: URL, adapter: UsageAdapter) -> String {
        for root in adapter.expandedRoots where url.path.hasPrefix(root.path) {
            return root.path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
            )
        }
        return adapter.displayName
    }

    /// 同一条额度（同 id）只留观测时间最新的那条。
    private func dedupeQuotas(_ quotas: [OfficialQuota]) -> [OfficialQuota] {
        var latest: [String: OfficialQuota] = [:]
        for q in quotas {
            if let cur = latest[q.id], cur.observedAt >= q.observedAt { continue }
            latest[q.id] = q
        }
        return latest.values.sorted { $0.windowMinutes < $1.windowMinutes }
    }

    // MARK: Cache IO

    private func cacheURL(_ adapterID: String) -> URL {
        Paths.cacheDir.appendingPathComponent("\(adapterID).json")
    }

    private func loadCache(_ adapterID: String) -> AdapterCache {
        guard let data = try? Data(contentsOf: cacheURL(adapterID)),
              let cache = try? SnapshotCoding.decoder().decode(AdapterCache.self, from: data),
              cache.parserVersion == AdapterCache.parserVersion
        else { return AdapterCache(adapterID: adapterID) }
        return cache
    }

    private func saveCache(_ cache: AdapterCache) {
        guard let data = try? SnapshotCoding.encoder().encode(cache) else { return }
        ICloudSafe.write(data, to: cacheURL(cache.adapterID))
    }
}
