import Foundation

// MARK: - Quota metric & window

/// 额度按什么计量。各家套餐口径不同：
/// 有的按"次数/5小时"（多数国产编码套餐），有的按 token，有的按金额。
public enum QuotaMetric: String, Codable, Sendable {
    /// 人发的消息条数。**各家套餐公布的「每 5 小时 X 次」数的是这个。**
    case prompts
    case requests
    case billableTokens
    case totalTokens
    case outputTokens
    case cost
    /// 平台官方直接回报的已用百分比。不从本地桶计算，只是原样转述。
    case percent

    public var displayName: String {
        switch self {
        case .prompts: return "消息数"
        case .requests: return "API 调用"
        case .billableTokens: return "计费 token"
        case .totalTokens: return "总 token"
        case .outputTokens: return "输出 token"
        case .cost: return "金额"
        case .percent: return "官方额度"
        }
    }

    public func value(from buckets: [UsageBucket], pricing: Pricing?) -> Double {
        switch self {
        case .percent:
            return 0
        case .prompts:
            return Double(buckets.reduce(0) { $0 + $1.prompts })
        case .requests:
            return Double(buckets.reduce(0) { $0 + $1.requests })
        case .billableTokens:
            return Double(buckets.reduce(0) { $0 + $1.billableTokens })
        case .totalTokens:
            return Double(buckets.reduce(0) { $0 + $1.totalTokens })
        case .outputTokens:
            return Double(buckets.reduce(0) { $0 + $1.outputTokens })
        case .cost:
            guard let pricing else { return 0 }
            return buckets.reduce(0) { $0 + pricing.cost(for: $1) }
        }
    }
}

/// 窗口类型决定了"额度会不会作废"，以及窗口从哪一刻开始算。
public enum WindowKind: String, Codable, Sendable {
    /// 滚动窗口：过去 N 分钟。用完就等最早的调用滚出窗口，没有"作废"一说。
    case rolling
    /// 周期窗口：按自然日/周/月对齐，到点清零。没用完的部分会作废。
    case periodic
    /// 会话窗口：**从你这一轮的第一次请求开始**算 N 分钟，到点清零。
    ///
    /// 各家编码套餐的「5 小时额度」是这种。它既不是滚动窗口（额度会作废），
    /// 也不是自然周期（窗口起点取决于你什么时候开始用，不是整点）。
    /// 用错类型会让重置倒计时和作废量全都算歪 —— 而 5 小时窗口一天翻好几轮，
    /// 恰恰是作废最频繁、最该被盯住的那一层。
    case session

    public var canExpire: Bool { self != .rolling }

    public var displayName: String {
        switch self {
        case .rolling: return "滚动"
        case .periodic: return "周期"
        case .session: return "会话"
        }
    }
}

/// 一条额度上限。一个套餐可以有多条（比如同时有 5 小时限和周限）。
public struct QuotaLimit: Codable, Sendable {
    public var id: String
    public var label: String
    public var windowMinutes: Int
    public var kind: WindowKind
    public var metric: QuotaMetric
    /// nil 表示还没配上限。工具照样统计用量，只是算不出剩余百分比和作废量。
    public var limit: Double?
    /// 周期窗口的对齐锚点（比如订阅的账单日）。nil 则从 Unix 纪元起按窗口长度对齐。
    public var anchor: Date?
    /// 提示用户去哪儿查这个数，填 plans.json 时有用。
    public var hint: String?
    /// 这条上限只管哪个额度池。nil = 不区分，全算。
    ///
    /// Claude 必须区分：订阅的 5 小时/周额度只管交互式，
    /// `claude -p` 走的是另一个月度信用池，两者互不占用。
    public var lane: UsageLane?

    public init(
        id: String,
        label: String,
        windowMinutes: Int,
        kind: WindowKind,
        metric: QuotaMetric,
        limit: Double? = nil,
        anchor: Date? = nil,
        hint: String? = nil,
        lane: UsageLane? = nil
    ) {
        self.id = id
        self.label = label
        self.windowMinutes = windowMinutes
        self.kind = kind
        self.metric = metric
        self.limit = limit
        self.anchor = anchor
        self.hint = hint
        self.lane = lane
    }

    /// 旧配置没有 lane 字段。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        windowMinutes = try c.decode(Int.self, forKey: .windowMinutes)
        kind = try c.decode(WindowKind.self, forKey: .kind)
        metric = try c.decode(QuotaMetric.self, forKey: .metric)
        limit = try c.decodeIfPresent(Double.self, forKey: .limit)
        anchor = try c.decodeIfPresent(Date.self, forKey: .anchor)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        lane = try c.decodeIfPresent(UsageLane.self, forKey: .lane)
    }

    public var windowSeconds: TimeInterval { TimeInterval(windowMinutes) * 60 }
}

/// 简易计价表，用于 .cost 口径和跨平台性价比对比。单位：每百万 token 的价格。
public struct Pricing: Codable, Sendable {
    public var currency: String
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cacheReadPerMTok: Double
    public var cacheWritePerMTok: Double

    public init(
        currency: String = "USD",
        inputPerMTok: Double = 0,
        outputPerMTok: Double = 0,
        cacheReadPerMTok: Double = 0,
        cacheWritePerMTok: Double = 0
    ) {
        self.currency = currency
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
    }

    public func cost(for b: UsageBucket) -> Double {
        let m = 1_000_000.0
        return Double(b.inputTokens) / m * inputPerMTok
            + Double(b.outputTokens) / m * outputPerMTok
            + Double(b.cacheReadTokens) / m * cacheReadPerMTok
            + Double(b.cacheWriteTokens) / m * cacheWritePerMTok
    }
}

/// 一个平台的订阅套餐配置。
public struct PlatformPlan: Codable, Sendable {
    public var platform: Platform
    public var planName: String
    public var enabled: Bool
    /// 月费，用于"这个平台每块钱换来多少产出"的性价比排序。
    public var monthlyCost: Double?
    public var currency: String
    public var limits: [QuotaLimit]
    public var pricing: Pricing?
    /// 平台自己回报了额度时（如 Codex），是否优先采信官方数字而不是本地推算。
    public var preferOfficialQuota: Bool

    public init(
        platform: Platform,
        planName: String,
        enabled: Bool = true,
        monthlyCost: Double? = nil,
        currency: String = "CNY",
        limits: [QuotaLimit] = [],
        pricing: Pricing? = nil,
        preferOfficialQuota: Bool = true
    ) {
        self.platform = platform
        self.planName = planName
        self.enabled = enabled
        self.monthlyCost = monthlyCost
        self.currency = currency
        self.limits = limits
        self.pricing = pricing
        self.preferOfficialQuota = preferOfficialQuota
    }
}

public struct PlansConfig: Codable, Sendable {
    public var plans: [PlatformPlan]
    /// 用量低于这个比例且窗口已过半，就判为"正在浪费"。
    public var wasteThreshold: Double
    /// 预测用量超过这个比例，就判为"有超额风险"。
    public var riskThreshold: Double

    public init(plans: [PlatformPlan], wasteThreshold: Double = 0.6, riskThreshold: Double = 0.95) {
        self.plans = plans
        self.wasteThreshold = wasteThreshold
        self.riskThreshold = riskThreshold
    }

    public func plan(for platform: Platform) -> PlatformPlan? {
        plans.first { $0.platform == platform }
    }

    /// 生成一份包含全部平台的模板。
    ///
    /// 所有 limit 一律留空 —— 各家套餐的具体数字会变，而且不同档位差别很大，
    /// 与其写死一个可能是错的数字让用户误信，不如让用户从自己的订阅页面抄进来。
    /// 没填上限时工具仍然统计用量和活跃度，只是不显示剩余百分比。
    /// 有几条上限是真填了值的。用来判断「这份配置是不是空模板」。
    public var filledLimitCount: Int {
        plans.reduce(0) { $0 + $1.limits.filter { $0.limit != nil }.count }
    }

    public static func template() -> PlansConfig {
        func fiveHour(_ metric: QuotaMetric, hint: String) -> QuotaLimit {
            QuotaLimit(
                // 套餐制的 5 小时额度是从这一轮第一次请求起算的，到点清零会作废。
                id: "5h", label: "5 小时", windowMinutes: 300,
                kind: .session, metric: metric, hint: hint
            )
        }
        func weekly(_ metric: QuotaMetric, hint: String) -> QuotaLimit {
            QuotaLimit(
                id: "weekly", label: "每周", windowMinutes: 10080,
                kind: .periodic, metric: metric, hint: hint
            )
        }
        func monthly(_ metric: QuotaMetric, hint: String) -> QuotaLimit {
            QuotaLimit(
                id: "monthly", label: "每月", windowMinutes: 43200,
                kind: .periodic, metric: metric, hint: hint
            )
        }

        let h = "去该平台的订阅/用量页面查你这一档的上限，填进 limit 字段；留空则只统计用量不算剩余"

        return PlansConfig(plans: [
            PlatformPlan(
                platform: .claude, planName: "Claude 订阅", currency: "USD",
                limits: [fiveHour(.requests, hint: h), weekly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .codex, planName: "ChatGPT 订阅", currency: "USD",
                limits: [fiveHour(.requests, hint: h), weekly(.requests, hint: h)],
                preferOfficialQuota: true
            ),
            PlatformPlan(
                platform: .gemini, planName: "Gemini", currency: "USD",
                limits: [QuotaLimit(id: "daily", label: "每日", windowMinutes: 1440,
                                    kind: .periodic, metric: .requests, hint: h)]
            ),
            PlatformPlan(
                platform: .qwen, planName: "Qwen", currency: "CNY",
                limits: [QuotaLimit(id: "daily", label: "每日", windowMinutes: 1440,
                                    kind: .periodic, metric: .requests, hint: h)]
            ),
            PlatformPlan(
                platform: .kimi, planName: "Kimi", currency: "CNY",
                limits: [fiveHour(.requests, hint: h), monthly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .glm, planName: "GLM Coding Plan", currency: "CNY",
                limits: [fiveHour(.requests, hint: h), monthly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .minimax, planName: "MiniMax", currency: "CNY",
                limits: [monthly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .deepseek, planName: "DeepSeek", currency: "CNY",
                limits: [monthly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .volcark, planName: "火山方舟", currency: "CNY",
                limits: [monthly(.billableTokens, hint: h)]
            ),
        ])
    }
}

// MARK: - Computed status

public enum QuotaHealth: String, Codable, Sendable {
    /// 没填上限，算不出剩余。
    case unconfigured
    /// 这个窗口内完全没用过。
    case idle
    /// 按当前速度，到重置时会剩下一大截 —— 钱白花了。
    case wasting
    case healthy
    /// 按当前速度会超额。
    case atRisk
    case exhausted

    public var displayName: String {
        switch self {
        case .unconfigured: return "未配置上限"
        case .idle: return "闲置"
        case .wasting: return "将作废"
        case .healthy: return "正常"
        case .atRisk: return "将超额"
        case .exhausted: return "已用尽"
        }
    }

    /// 菜单栏排序用，数字越大越该被看见。
    public var urgency: Int {
        switch self {
        case .healthy: return 0
        case .unconfigured: return 1
        case .exhausted: return 2
        case .atRisk: return 3
        case .idle: return 4
        case .wasting: return 5
        }
    }
}

/// 某个平台某条额度在当前时刻的完整状态。这是给 UI 的最终产物。
public struct QuotaStatus: Codable, Sendable, Identifiable {
    public var platform: Platform
    public var planName: String
    public var limitID: String
    public var label: String
    public var metric: QuotaMetric
    public var kind: WindowKind

    public var used: Double
    public var limit: Double?
    public var usedFraction: Double?

    public var windowStart: Date
    public var resetsAt: Date?
    /// 窗口已经走过的比例，0...1。
    public var windowElapsedFraction: Double

    /// 按当前燃烧速度，到窗口结束时的预计用量占比。
    public var projectedUsedFraction: Double?
    /// 按当前速度预计会作废的额度（原始计量单位）。仅周期窗口有意义。
    public var projectedWaste: Double?

    public var health: QuotaHealth
    /// true 表示这个数字来自平台官方回报，不是本地推算。
    public var isOfficial: Bool
    public var sourceNote: String
    /// 各机器的用量拆分，用于"哪台电脑在吃额度"。
    public var byMachine: [String: Double]

    public var id: String { "\(platform.rawValue).\(limitID)" }

    public var timeToReset: TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSinceNow)
    }

    public init(
        platform: Platform,
        planName: String,
        limitID: String,
        label: String,
        metric: QuotaMetric,
        kind: WindowKind,
        used: Double,
        limit: Double?,
        usedFraction: Double?,
        windowStart: Date,
        resetsAt: Date?,
        windowElapsedFraction: Double,
        projectedUsedFraction: Double?,
        projectedWaste: Double?,
        health: QuotaHealth,
        isOfficial: Bool,
        sourceNote: String,
        byMachine: [String: Double] = [:]
    ) {
        self.platform = platform
        self.planName = planName
        self.limitID = limitID
        self.label = label
        self.metric = metric
        self.kind = kind
        self.used = used
        self.limit = limit
        self.usedFraction = usedFraction
        self.windowStart = windowStart
        self.resetsAt = resetsAt
        self.windowElapsedFraction = windowElapsedFraction
        self.projectedUsedFraction = projectedUsedFraction
        self.projectedWaste = projectedWaste
        self.health = health
        self.isOfficial = isOfficial
        self.sourceNote = sourceNote
        self.byMachine = byMachine
    }
}

/// 一个平台的汇总视图。
public struct PlatformReport: Codable, Sendable, Identifiable {
    public var platform: Platform
    public var planName: String
    public var monthlyCost: Double?
    public var currency: String
    public var detected: Bool
    /// 至少有一台电脑装了这个平台的 CLI。
    public var installed: Bool
    /// **人**最后一次用这个平台是什么时候（交互式，不含调度器跑的）。
    ///
    /// LaneRouter 早就能按 worktree 路径分辨每一笔用量是人烧的还是
    /// 调度器烧的，但调度路径一直没读它。后果很具体：实测最近 6 小时
    /// Claude 上人工 1271 次、机器 6 次 —— 人正在用。这时候调度要是
    /// 判「额度将作废」开始派活，就是直接跟人抢同一个 5 小时窗口。
    public var lastHumanActivity: Date?

    /// 这个 agent 的岗位。跟着看板一起发给手机 ——
    /// 规则只写在 Mac 的配置文件里的话，手机上就看不见调度为什么这么派。
    public var role: AgentRole?

    /// 真正执行任务的那个 agent 的名字。见 AgentIdentity。
    public var agentName: String = ""
    /// 它跑的可执行文件。
    public var agentBinary: String = ""

    /// 你在套餐配置里有没有把它关掉。
    ///
    /// 关掉的平台不该出现在「办公室」和「员工」里 —— 比如 Gemini，
    /// 账号被平台方停了之后已经用不了，还画一个打盹的小人在那儿纯属噪音。
    public var enabled: Bool = true
    public var machines: [String]
    public var lastActivity: Date?
    public var statuses: [QuotaStatus]

    /// 最近 30 天的用量，用于活跃度与性价比。
    public var last30dRequests: Int
    public var last30dBillableTokens: Int
    public var last7dRequests: Int
    public var topModels: [ModelUsage]

    public var id: String { platform.rawValue }

    /// 装了却一直没用 —— 在所有平台里，这是最该考虑退订的那种。
    public var installedButIdle: Bool { installed && !detected }

    /// 最该被提醒的那条额度。
    public var headline: QuotaStatus? {
        statuses.max { a, b in
            if a.health.urgency != b.health.urgency { return a.health.urgency < b.health.urgency }
            return (a.usedFraction ?? 0) < (b.usedFraction ?? 0)
        }
    }

    public init(
        platform: Platform,
        planName: String,
        monthlyCost: Double?,
        currency: String,
        detected: Bool,
        installed: Bool = false,
        enabled: Bool = true,
        lastHumanActivity: Date? = nil,
        agentName: String = "",
        agentBinary: String = "",
        machines: [String],
        lastActivity: Date?,
        statuses: [QuotaStatus],
        last30dRequests: Int,
        last30dBillableTokens: Int,
        last7dRequests: Int,
        topModels: [ModelUsage]
    ) {
        self.platform = platform
        self.planName = planName
        self.monthlyCost = monthlyCost
        self.currency = currency
        self.detected = detected
        self.installed = installed
        self.enabled = enabled
        self.lastHumanActivity = lastHumanActivity
        self.role = AgentRoles.role(for: platform)
        self.agentName = agentName.isEmpty ? AgentIdentity.name(for: platform) : agentName
        self.agentBinary = agentBinary.isEmpty
            ? AgentIdentity.binaryName(for: platform) : agentBinary
        self.machines = machines
        self.lastActivity = lastActivity
        self.statuses = statuses
        self.last30dRequests = last30dRequests
        self.last30dBillableTokens = last30dBillableTokens
        self.last7dRequests = last7dRequests
        self.topModels = topModels
    }
}

public struct ModelUsage: Codable, Sendable, Hashable {
    public var model: String
    public var requests: Int
    public var billableTokens: Int

    public init(model: String, requests: Int, billableTokens: Int) {
        self.model = model
        self.requests = requests
        self.billableTokens = billableTokens
    }
}

/// 整个仪表盘的数据。
public struct Dashboard: Codable, Sendable {
    public var generatedAt: Date
    public var machines: [MachineInfo]
    public var reports: [PlatformReport]

    public init(generatedAt: Date, machines: [MachineInfo], reports: [PlatformReport]) {
        self.generatedAt = generatedAt
        self.machines = machines
        self.reports = reports
    }

    /// 按紧急度排出来的额度告警，菜单栏标题取第一条。
    /// 需要你看一眼的那些额度。
    ///
    /// **`.idle` 必须收进来**，这一条曾经漏掉过，而且漏的正好是最严重的那批：
    ///
    /// judge() 里 `usedFraction <= 0 → .idle` 排在 wasting 判定之前，
    /// 所以一个周期窗口整段一次都没用过时，health 是 `.idle` 而不是 `.wasting`
    /// —— 尽管它的浪费是 100%，比任何一条 `.wasting`（顶多浪费到
    /// wasteThreshold 那条线）都严重。
    ///
    /// 结果就是：用了 30% 预计剩 50% 的会报警，一口没动的反而静悄悄地
    /// 整份作废。对一个立身之本是「防止浪费」的工具来说，这是把最该看见的
    /// 那批藏了起来。
    ///
    /// 只收「会过期且填了上限」的 idle —— 滚动窗口不存在作废，
    /// 没填上限的本来就归 `.unconfigured` 管。
    public var alerts: [QuotaStatus] {
        reports
            .flatMap(\.statuses)
            .filter {
                $0.health == .wasting || $0.health == .atRisk || $0.health == .exhausted
                    || ($0.health == .idle && $0.kind.canExpire && $0.limit != nil)
            }
            .sorted { a, b in
                if a.health.urgency != b.health.urgency { return a.health.urgency > b.health.urgency }
                return (a.projectedWaste ?? 0) > (b.projectedWaste ?? 0)
            }
    }
}

public struct MachineInfo: Codable, Sendable, Hashable, Identifiable {
    public var machineID: String
    public var machineName: String
    public var lastSeen: Date
    /// 快照太久没更新，说明那台机器没在跑采集。
    public var isStale: Bool

    public var id: String { machineID }

    public init(machineID: String, machineName: String, lastSeen: Date, isStale: Bool) {
        self.machineID = machineID
        self.machineName = machineName
        self.lastSeen = lastSeen
        self.isStale = isStale
    }
}

// MARK: - 谁在干活

/// 每个平台背后**真正执行任务的那个 agent**。
///
/// 这个区分是必要的：干活的是 CLI，模型只是它当时接的哪个端点。
///
/// ## 一台机器只有一个 claude 二进制
///
/// 实测过两台真机：`-cc` 那几个独立配置目录（`~/.glm`、`~/.zai`、
/// `~/.claude-glm` …）基本都不存在，只有一个 `~/.claude`。
/// 第三方端点的用量就是从**那一个目录**里出来的 —— 同一个 Claude Code，
/// `ANTHROPIC_BASE_URL` 指向别处，会话照样写进 `~/.claude`。
///
/// 所以：
///
/// - 「员工」的名字用 agent，端点作后缀。三个 Claude Code 并排，
///   你一眼知道干活的是同一个工具、额度池不同 —— 那正是这套系统
///   最要紧的那件事。合成一个反而会让第三方端点烧的量看起来像 Claude 烧的。
/// - **归属只能靠模型名**。会话日志里没有任何端点字段（顶层只有
///   entrypoint / cwd / gitBranch / version 这些，message 里只有 model），
///   所以「按 base_url 归类而不是模型名」这条对 Claude Code 做不到 ——
///   历史会话里根本没记过端点。模型名是唯一的逐条证据。
///   风险写在 ModelRouter 那边。
public enum AgentIdentity {

    /// 平台 → 干活的 agent 名。
    static let map: [Platform: String] = [
        .claude:   "Claude Code",
        .glm:      "Claude Code · GLM",
        .deepseek: "Claude Code · DeepSeek",
        .volcark:  "opencode · 火山",
        .codex:    "Codex CLI",
        .qwen:     "Qwen Code",
        .kimi:     "Kimi Code",
        .minimax:  "MiniMax CLI",
        .gemini:   "Gemini CLI",
    ]

    /// 它跑的是哪个可执行文件。用来在详情里说清「到底是谁」。
    static let binary: [Platform: String] = [
        .claude: "claude", .glm: "claude", .deepseek: "claude",
        .codex: "codex", .qwen: "qwen", .kimi: "kimi",
        .minimax: "mmx", .gemini: "gemini",
        // 火山方舟现在有专属客户端了：opencode 经本地 LiteLLM 网关转过去。
        // 原来它挂在 claude 名下（Claude Code 改 BASE_URL 那种用法）。
        .volcark: "opencode",
    ]

    public static func name(for p: Platform) -> String {
        map[p] ?? p.displayName
    }
    public static func binaryName(for p: Platform) -> String {
        binary[p] ?? p.rawValue
    }

    /// 是不是「借用别人客户端」的那种。
    ///
    /// 这一类的额度归属最容易搞错 —— 光看模型名会把整整一个套餐的用量
    /// 算到 Claude 头上，实际烧的是第三方那份。
    public static func isBorrowedClient(_ p: Platform) -> Bool {
        binary[p] == "claude" && p != .claude
    }
}
