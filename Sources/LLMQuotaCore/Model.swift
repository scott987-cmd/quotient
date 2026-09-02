import Foundation

// MARK: - Platform

/// 一个 LLM 订阅平台。用量最终都归一到这里，无论它是通过哪个 CLI 消费的。
public enum Platform: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case gemini
    case qwen
    case kimi
    case glm
    case minimax
    case deepseek
    case volcark
    case openrouter

    /// 已退役平台仍需保留枚举值，才能读取历史快照、任务和审计记录；
    /// 但不得再进入当前额度、看板、配置或调度候选。
    public var isRetired: Bool { self == .openrouter }

    public static var activeCases: [Platform] {
        allCases.filter { !$0.isRetired }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .qwen: return "Qwen"
        case .kimi: return "Kimi"
        case .glm: return "GLM"
        case .minimax: return "MiniMax"
        case .deepseek: return "DeepSeek"
        case .volcark: return "火山方舟"
        case .openrouter: return "OpenRouter · Ox Alpha"
        }
    }

    /// 菜单栏窄空间用的短标签。
    public var tag: String {
        switch self {
        case .claude: return "CLD"
        case .codex: return "CDX"
        case .gemini: return "GEM"
        case .qwen: return "QWN"
        case .kimi: return "KMI"
        case .glm: return "GLM"
        case .minimax: return "MMX"
        case .deepseek: return "DSK"
        case .volcark: return "ARK"
        case .openrouter: return "OXA"
        }
    }

    /// 固定展示顺序，避免菜单项每次刷新都跳来跳去。
    public var sortIndex: Int {
        Platform.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - Usage lane

/// 区分「人在用」还是「调度器在用」。
///
/// 一开始建这个维度是因为 Anthropic 宣布 2026-06-15 起把 `claude -p` / Agent SDK
/// 的用量剥离到独立月度信用池。**但查一手来源确认该改动已被暂停** ——
/// 官方原文：`claude -p` 和 Agent SDK 用量仍然计入订阅额度。
/// 所以现在两条通道吃的是同一份配额，limit 上不做 lane 隔离。
///
/// 保留这个维度仍然值钱，而且是两个理由：
/// 一是能看清「机器人吃了多少、我自己吃了多少」；
/// 二是 Anthropic 恢复分离时，改一个 limit 的 lane 字段就切过去了。
///
/// 判据见 LaneRouter —— 不靠 entrypoint（实测 `claude -p` 也写 claude-desktop），
/// 靠调度器自己的 worktree 路径。
public enum UsageLane: String, Codable, Sendable, CaseIterable {
    /// 人在交互式使用，吃订阅额度。
    case interactive
    /// 无头调用（claude -p / Agent SDK / CI），吃独立的信用池。
    case headless

    public var displayName: String {
        switch self {
        case .interactive: return "交互式"
        case .headless: return "无头调用"
        }
    }

    /// 认不出来时一律算交互式。
    ///
    /// 这个默认值是有意选的保守方向：宁可把 headless 的量误记进订阅池
    /// （表现为订阅额度显得比实际紧），也不能反过来 —— 反过来会让工具以为
    /// 订阅还很宽裕，怂恿你继续用，结果撞上真实限流。
    public static let conservativeDefault: UsageLane = .interactive
}

/// 判定一次调用属于哪个额度池。
public enum LaneRouter {
    private static let headlessMarkers = [
        "sdk", "headless", "print", "github-action", "ci", "non-interactive", "batch"
    ]

    /// 调度器执行任务的工作区根目录。
    ///
    /// **这是最可靠的判据，优先于 entrypoint。**
    /// 原因是实测发现 `claude -p` 写进日志的 entrypoint 仍然是 `claude-desktop`
    /// —— 那个字段反映的是"哪个客户端"，不是"是不是无头"。
    /// 而调度器永远在自己开的 worktree 里跑，这个路径是我自己控制的，
    /// 不依赖任何平台的字段语义，也不会随它们改版而失效。
    static var schedulerWorkspaceRoot: String {
        Paths.appSupport.appendingPathComponent("worktrees").path
    }

    public static func lane(forEntrypoint entrypoint: String?, cwd: String? = nil) -> UsageLane {
        if let cwd, cwd.hasPrefix(schedulerWorkspaceRoot) { return .headless }
        guard let e = entrypoint?.lowercased(), !e.isEmpty else {
            return UsageLane.conservativeDefault
        }
        return headlessMarkers.contains(where: { e.contains($0) }) ? .headless : .interactive
    }
}

// MARK: - Model routing

/// 把模型名映射到平台。
///
/// 这是整套工具的关键一环：GLM / Kimi / MiniMax / DeepSeek / 火山 的编码套餐，
/// 绝大多数是把 Claude Code 或 Codex 的 BASE_URL 指到对方的兼容端点来用的。
/// 那种情况下用量会落在 ~/.claude 或 ~/.codex 的日志里，只有模型名不一样。
/// 所以采集器不能按"哪个 CLI"归类，必须按模型名归类。
/// 按模型名判断这次调用烧的是谁的额度。
///
/// ## 为什么不按 base_url —— 因为记不到
///
/// 待办里一直挂着「按 provider/base_url 归类而非模型名」。对 Qwen 能做
/// （它的 settings.json 里有 modelProviders，模型→端点是明写的，
/// 见 EndpointRouter），但**对 Claude Code 做不到**：
///
/// 会话日志的顶层字段只有 entrypoint / cwd / gitBranch / version / requestId
/// 这些，message 里只有 model —— 全库搜不到任何端点字段。历史会话里
/// 根本没记过它当时打的是哪个 base_url。
///
/// 所以模型名是**唯一的逐条证据**，这不是偷懒，是没有别的可用。
///
/// ## 这带来的真实风险
///
/// 实测过一台真机：只有一个 `~/.claude` 目录，而 `ANTHROPIC_BASE_URL`
/// 指向第三方端点。那个月最大的一笔用量就出自这里，
/// 而它没被算到 Claude 头上，全靠模型名里恰好带着第三方的名字。
///
/// 也就是说：**哪个第三方端点要是回一个不带自己名字的模型名**
/// （比如为了兼容而原样回 `claude-sonnet-x`），那它的用量就会被算成
/// Claude 的，两边同时错 —— Claude 的额度显示虚高、那个平台的显示虚低。
///
/// 目前没有更好的办法。能做的是：新会话可以顺手记下当时的
/// `ANTHROPIC_BASE_URL`（采集时读配置），但那只对**今后**的会话有效，
/// 补不了历史。
public enum ModelRouter {
    /// 前缀匹配优先，命中即返回。
    private static let prefixRules: [(String, Platform)] = [
        ("claude", .claude),
        ("anthropic", .claude),
        ("gpt", .codex),
        ("chatgpt", .codex),
        ("codex", .codex),
        ("o1", .codex),
        ("o3", .codex),
        ("o4", .codex),
        ("gemini", .gemini),
        ("gemma", .gemini),
        ("qwen", .qwen),
        ("qwq", .qwen),
        ("qvq", .qwen),
        ("tongyi", .qwen),
        ("kimi", .kimi),
        ("moonshot", .kimi),
        ("glm", .glm),
        ("chatglm", .glm),
        ("codegeex", .glm),
        ("minimax", .minimax),
        ("abab", .minimax),
        ("deepseek", .deepseek),
        ("doubao", .volcark),
        ("skylark", .volcark),
        // opencode 经本地 LiteLLM 网关转到火山，模型名是网关侧起的别名
        //（volc-coding / volc-agent），不带 doubao/skylark 这些原厂名字。
        ("volc", .volcark),
        ("ark-code", .volcark),
        ("ep-", .volcark),
        ("stealth/ox-alpha", .openrouter),
        ("ox-alpha", .openrouter),
    ]

    /// 前缀没命中时再按子串找。只放足够独特、不会误伤的词。
    private static let containsRules: [(String, Platform)] = [
        ("claude", .claude),
        ("deepseek", .deepseek),
        ("moonshot", .kimi),
        ("kimi", .kimi),
        ("minimax", .minimax),
        ("doubao", .volcark),
        ("qwen", .qwen),
        ("glm", .glm),
        ("gemini", .gemini),
        ("ox-alpha", .openrouter),
    ]

    /// - Parameter fallback: 模型名为空或认不出来时，归给采集它的那个 CLI 自己的平台。
    /// 认不出来就返回 nil 的版本。给「必须确定归属才敢动作」的调用方用
    /// —— 比如把额度打满记进冷却台账：猜错平台会冻住一个还能用的 agent。
    public static func platformIfKnown(forModel model: String) -> Platform? {
        let m = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, m != "<synthetic>" else { return nil }
        return prefixRules.first { m.contains($0.0) }?.1
    }

    public static func platform(forModel model: String, fallback: Platform) -> Platform {
        let m = model.lowercased().trimmingCharacters(in: .whitespaces)
        // Claude Code 用 "<synthetic>" 标记本地合成的消息，不是真实 API 调用。
        guard !m.isEmpty, m != "<synthetic>" else { return fallback }

        for (needle, platform) in prefixRules where m.hasPrefix(needle) {
            return platform
        }
        for (needle, platform) in containsRules where m.contains(needle) {
            return platform
        }
        return fallback
    }

    /// 判断一次调用是否真的打到了 API（用于过滤合成消息）。
    public static func isRealAPICall(model: String) -> Bool {
        let m = model.lowercased()
        return !m.isEmpty && m != "<synthetic>" && m != "unknown"
    }
}

// MARK: - Usage buckets

/// 用量按 5 分钟对齐的稀疏时间桶存储。
///
/// 为什么是桶而不是原始事件：本机 Claude Code 就有 4151 个 jsonl，
/// 逐条事件同步到 iCloud 体积太大。桶把同一 5 分钟、同一模型的调用合并，
/// 而 5 分钟的粒度又足够精确地还原任意滚动窗口（含 Claude 的 5 小时窗口）。
/// 稀疏存储 —— 没有调用的时间段根本不产生记录。
public struct UsageBucket: Codable, Sendable, Hashable {
    public static let intervalSeconds: TimeInterval = 300

    public var start: Date
    public var model: String
    /// 这批用量落进哪个额度池。
    public var lane: UsageLane
    /// 人发的消息条数。各家套餐公布的上限数的是这个，不是 API 调用次数。
    public var prompts: Int
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(
        start: Date,
        model: String,
        lane: UsageLane = .interactive,
        prompts: Int = 0,
        requests: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) {
        self.start = start
        self.model = model
        self.lane = lane
        self.prompts = prompts
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    /// 计费口径的总 token。缓存读取单独留在 cacheReadTokens 里，
    /// 因为各平台对缓存命中的计价差异很大，混进总数会让跨平台对比失真。
    public var billableTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    // 旧快照没有 lane 字段，缺了就按保守方向当交互式。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        model = try c.decode(String.self, forKey: .model)
        lane = try c.decodeIfPresent(UsageLane.self, forKey: .lane)
            ?? UsageLane.conservativeDefault
        prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
        requests = try c.decode(Int.self, forKey: .requests)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try c.decode(Int.self, forKey: .cacheWriteTokens)
    }

    public static func alignedStart(for date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / intervalSeconds).rounded(.down) * intervalSeconds)
    }

    public mutating func merge(_ other: UsageBucket) {
        prompts += other.prompts
        requests += other.requests
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
    }
}

/// 桶的聚合键。
public struct BucketKey: Hashable, Sendable {
    public var start: Date
    public var model: String
    public var lane: UsageLane

    public init(start: Date, model: String, lane: UsageLane) {
        self.start = start
        self.model = model
        self.lane = lane
    }
}

// MARK: - Official quota

/// 平台自己回报的额度状态。比我们本地算的可信，能拿到就优先用。
///
/// 目前已证实 Codex 会把它写进会话日志（rate_limits.primary/secondary，
/// 含 used_percent / window_minutes / resets_at）。
public struct OfficialQuota: Codable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?
    public var planType: String?
    /// 这条额度是什么时候被观测到的 —— 日志是历史记录，可能已经过时。
    public var observedAt: Date
    /// 官方给的**绝对计数**（用了几次 / 一共几次），有就带上。
    ///
    /// 百分比够用来判断「快满了没有」，但不够用来做决定：
    /// 「已用 58%」不告诉你还能生几张图，「12 / 21 次」告诉你。
    /// MiniMax 的 `mmx quota show` 一直在给这两个数，我们只取了百分比 ——
    /// 手上有更好的数据却扔掉了。
    public var usedCount: Double?
    public var totalCount: Double?
    /// 计数的单位（"次"）。不同平台可能不一样，别写死在显示层。
    public var countUnit: String?
    /// **仅供参考：显示，但不参与「这个平台还能不能派活」的判断。**
    ///
    /// MiniMax 的视频额度用光了，不代表跑不了文本任务 —— 拿它去拦调度
    /// 会把一个能干活的平台冻住。但完全不采又会让人看不见生图用了多少
    /// （那是它的主要用途）。所以：采、显示、不参与判断。
    public var advisory: Bool = false

    // **加字段必须自己写 init(from:)。**
    //
    // Swift 合成的 Decodable **不会用属性默认值** —— 老快照里没有
    // `advisory` 这个键，解码就直接抛 keyNotFound，整份快照作废。
    // 实测后果：另一台机器还在正常采集、文件也同步过来了，
    // 而汇总里它凭空消失，调度以为那台机器上的平台全都没在用。
    // 跨机同步的结构体只要还会被老版本写出来，就得对缺字段免疫。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        usedPercent = try c.decode(Double.self, forKey: .usedPercent)
        windowMinutes = try c.decode(Int.self, forKey: .windowMinutes)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        planType = try c.decodeIfPresent(String.self, forKey: .planType)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        usedCount = try c.decodeIfPresent(Double.self, forKey: .usedCount)
        totalCount = try c.decodeIfPresent(Double.self, forKey: .totalCount)
        countUnit = try c.decodeIfPresent(String.self, forKey: .countUnit)
        advisory = try c.decodeIfPresent(Bool.self, forKey: .advisory) ?? false
    }

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Date? = nil,
        planType: String? = nil,
        observedAt: Date,
        usedCount: Double? = nil,
        totalCount: Double? = nil,
        countUnit: String? = nil,
        advisory: Bool = false
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.planType = planType
        self.observedAt = observedAt
        self.usedCount = usedCount
        self.totalCount = totalCount
        self.countUnit = countUnit
        self.advisory = advisory
    }

    /// 观测已经太旧就别拿来当真 —— 窗口早就滚过去了。
    public func isStale(now: Date = Date()) -> Bool {
        guard let resetsAt else {
            return now.timeIntervalSince(observedAt) > 6 * 3600
        }
        return now > resetsAt
    }
}

// MARK: - Snapshots

/// 单个平台在某台机器上的采集结果。
public struct PlatformSnapshot: Codable, Sendable {
    public var platform: Platform
    /// 保留窗口内有没有实际用量。
    public var detected: Bool
    /// 这台机器上装没装这个平台的 CLI。
    ///
    /// 和 detected 分开是有意的：「装了但一直没用」正是该退订的信号，
    /// 跟「压根没装」是两回事，不能混成一个"未检测到"。
    public var installed: Bool
    /// 数据来自哪些路径，方便排查"为什么数字不对"。
    public var sources: [String]
    public var buckets: [UsageBucket]
    public var officialQuotas: [OfficialQuota]
    public var lastActivity: Date?
    public var note: String?

    public init(
        platform: Platform,
        detected: Bool,
        installed: Bool = false,
        sources: [String] = [],
        buckets: [UsageBucket] = [],
        officialQuotas: [OfficialQuota] = [],
        lastActivity: Date? = nil,
        note: String? = nil
    ) {
        self.platform = platform
        self.detected = detected
        self.installed = installed
        self.sources = sources
        self.buckets = buckets
        self.officialQuotas = officialQuotas
        self.lastActivity = lastActivity
        self.note = note
    }

    // 多机场景下各台电脑上的版本会不一致，新增字段必须容忍旧快照缺键。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(Platform.self, forKey: .platform)
        detected = try c.decode(Bool.self, forKey: .detected)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        buckets = try c.decodeIfPresent([UsageBucket].self, forKey: .buckets) ?? []
        officialQuotas = try c.decodeIfPresent([OfficialQuota].self, forKey: .officialQuotas) ?? []
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// 一台机器的完整快照。这就是同步到 iCloud 的那个文件。
public struct MachineSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var machineID: String
    public var machineName: String
    public var generatedAt: Date
    /// 桶数据的保留起点，读取端据此判断历史覆盖范围。
    public var retentionStart: Date
    public var platforms: [PlatformSnapshot]

    /// 写这份快照的那个二进制认识哪些采集器。
    ///
    /// 存在的理由是踩过的一个坑：菜单栏 App 和 llmq 是两个独立二进制，
    /// 写的却是同一个快照文件。只更新了 CLI 而 App 还是旧版时，
    /// App 每隔几分钟就用它那套旧适配器把快照覆盖一遍，
    /// 新接的平台数据就这么被静默抹掉了 —— 表面上看是"适配器不工作"，
    /// 极难排查。把采集器清单记进快照，就能直接发现是版本漂移。
    public var collectorAdapters: [String]

    public init(
        schemaVersion: Int = MachineSnapshot.currentSchemaVersion,
        machineID: String,
        machineName: String,
        generatedAt: Date,
        retentionStart: Date,
        platforms: [PlatformSnapshot],
        collectorAdapters: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.machineID = machineID
        self.machineName = machineName
        self.generatedAt = generatedAt
        self.retentionStart = retentionStart
        self.platforms = platforms
        self.collectorAdapters = collectorAdapters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        machineID = try c.decode(String.self, forKey: .machineID)
        machineName = try c.decode(String.self, forKey: .machineName)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        retentionStart = try c.decode(Date.self, forKey: .retentionStart)
        platforms = try c.decode([PlatformSnapshot].self, forKey: .platforms)
        collectorAdapters = try c.decodeIfPresent([String].self, forKey: .collectorAdapters) ?? []
    }
}

// MARK: - JSON coding

public enum SnapshotCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func prettyEncoder() -> JSONEncoder {
        let e = encoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
