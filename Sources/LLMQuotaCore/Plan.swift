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
            // Kimi 官方**不公布**可换算的数字（2026-08 查过帮助中心
            // kimi.com/zh-cn/help/kimi-code/benefits）：只说存在「每 5 小时的
            // 滚动频率窗口」和「以订阅日为起点每 7 天刷新」的额度，
            // 各档具体多少要看自己的订阅页。第三方评测给的是 300–1200 次/5h
            // 这种区间，不能当上限用。
            //
            // 好消息是它超限时的报错**自带重置时间**（"refreshed in the next
            // cycle"，我们的探针已经据此算出冷却），所以即使没有上限值，
            // 「什么时候能再用」这件事仍然是准的。
            PlatformPlan(
                platform: .kimi, planName: "Kimi", currency: "CNY",
                limits: [
                    fiveHour(.requests,
                             hint: "官方不公布具体数字，只说有 5 小时滚动窗口。"
                                 + "网上流传的 300–1200 次/5h 是第三方区间，不是上限。"),
                    // **是每周不是每月。**
                    // 官方原文：「Agent Credits 以订阅日为起点每 7 天刷新」。
                    // 写成每月的话，作废预警会按 30 天算剩余 —— 而实际每 7 天
                    // 就清零一次，于是「还早着呢」这个判断整整错了四倍，
                    // 正好把这个工具最该抓的那种浪费漏掉。
                    weekly(.billableTokens,
                           hint: "官方是以订阅日为起点每 7 天刷新的额度，"
                               + "各档具体数字不公布，看自己的订阅页。"),
                    // **还有一层月额度。** 老板 2026-08-21 升到「全年尊享」后
                    // 订阅页上明确有月额度和到期日（当次到 2026-09-21）。
                    // 公开帮助中心没写这一层，所以模板原来只有两档；
                    // 到期时刻按订阅日对齐，锚点从用户配置搬（reconcile 会搬）。
                    // 窗口长度要贴**这一期**的真实天数：锚点是到期时刻，引擎从锚点
                    // 按窗口长度往回切边界 —— 8-21→9-21 是 31 天，用 30 天的话
                    // 8-22 就会多切出一道「明天重置」（实测踩到）。自然月的长度
                    // 不固定，彻底解法是引擎支持「按月按日锚定」，先按 31 天、到期再校。
                    QuotaLimit(id: "monthly", label: "每月", windowMinutes: 31 * 1440,
                               kind: .periodic, metric: .billableTokens,
                               hint: "订阅页上的月额度，官方不公布绝对值；到期日按订阅日"
                                   + "（锚点填在配置里），本期按 31 天，到期后再校。"),
                ]
            ),
            // GLM 是**唯一公布了确切数字、但我们仍然填不进去**的一家。
            //
            // 官方文档（docs.bigmodel.cn/cn/coding-plan/overview，2026-08 查）：
            //   Lite  5 小时 2,000 积分 / 每周 10,000 积分
            //   Pro   5 小时 12,000    / 每周 60,000
            //   Max   5 小时 28,000    / 每周 140,000
            //
            // 单位是**积分**，不是次数也不是 token：积分按 token 消耗折算，
            // 而且工作日 14:00–18:00（UTC+8）按 3 倍系数扣。
            // 把 2000 填进 `.requests` 或 `.billableTokens` 都是错的 ——
            // 那正是 Claude「225」那个教训的翻版：一个来源可靠、口径对不上的
            // 数字，比没有数字更危险，因为它看起来像已经配好了。
            //
            // 要真正支持它，得先有 credits 口径 + 折算规则（含高峰系数），
            // 或者找到官方回报已用积分的接口（像 Codex 那样）。在那之前留空。
            PlatformPlan(
                platform: .glm, planName: "GLM Coding Plan", currency: "CNY",
                limits: [
                    fiveHour(.requests,
                             hint: "官方按「积分」计：Lite 2,000/5h、Pro 12,000、Max 28,000。"
                                 + "积分按 token 折算且工作日 14–18 点 3 倍，"
                                 + "和这里的「次数」口径对不上，别直接填那个数。"),
                    // 同样是每周不是每月：官方叫「周积分」，7 天一个周期。
                    weekly(.billableTokens,
                           hint: "官方是每 7 天刷新的周积分：Lite 10,000、Pro 60,000、Max 140,000。"
                               + "积分口径，和这里的 token 对不上，别直接填。"),
                ]
            ),
            // MiniMax **自己报官方额度**（`mmx quota show`），和 Codex 一样
            // 不需要手填上限。它按模型给出两个窗口：general 是 5 小时、
            // video 是 24 小时，都另有一个每周窗口。
            //
            // 这两条用 .percent 口径 —— 数字直接来自平台，不从本地日志推。
            // 在接上它之前，MiniMax 一直报「30 天 0 次」，还被列进
            // 「装了没在用，每月 119 元空烧」，而实际上每次派活的分诊都是它做的。
            // 「在烧额度但看不见」是这套工具最该消灭的状态。
            PlatformPlan(
                platform: .minimax, planName: "MiniMax", currency: "CNY",
                limits: [
                    QuotaLimit(id: "5h", label: "5 小时", windowMinutes: 300,
                               kind: .session, metric: .percent,
                               hint: "平台直报，不用填"),
                    QuotaLimit(id: "weekly", label: "每周", windowMinutes: 10080,
                               kind: .periodic, metric: .percent,
                               hint: "平台直报，不用填"),
                ]
            ),
            PlatformPlan(
                platform: .deepseek, planName: "DeepSeek", currency: "CNY",
                limits: [monthly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .volcark, planName: "火山方舟", currency: "CNY",
                limits: [monthly(.billableTokens, hint: h)]
            ),
            PlatformPlan(
                platform: .openrouter, planName: "Ox Alpha 免费预览", currency: "USD",
                pricing: Pricing(currency: "USD")
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

/// 额度数字的来源层。冷却和健康探测不属于额度数字，分别留在各自字段。
public enum QuotaSourceKind: String, Codable, Sendable {
    case officialFact
    case localEstimate
    case unknown
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

    /// 没配上限时的**实测下限**：历史上任意一个同长度窗口里用出去过的最大量，
    /// 而且那次没被拒 —— 所以真实上限一定不低于它。
    ///
    /// 为什么值得单独显示：查完各家官方文档之后，能填的上限几乎没有
    /// （Claude/Kimi 不公布，GLM 公布的是对不上口径的「积分」）。
    /// 「未填」什么都不说，而「实测至少用到过 394 次」是硬信息 ——
    /// 它至少能告诉你这个平台的量级，也是学习器唯一能给的保守结论。
    public var observedFloor: Double?

    public var health: QuotaHealth
    /// true 表示这个数字来自平台官方回报，不是本地推算。
    public var isOfficial: Bool
    /// **仅供参考：显示，但不参与「这个平台还能不能派活」的判断。**
    ///
    /// MiniMax 的视频额度用光了不代表跑不了文本任务。拿它去拦调度，
    /// 会因为「今天生了 3 张图」把整个平台冻住 —— 而它还是本机的分诊器。
    public var advisory: Bool = false
    public var sourceNote: String
    public var sourceKind: QuotaSourceKind
    /// 这条数字实际在什么时候被看到或计算。
    public var observedAt: Date?
    /// 超过此时刻后只能展示为过期事实，不能再参与“可调度”判断。
    public var expiresAt: Date?
    /// 各机器的用量拆分，用于"哪台电脑在吃额度"。
    public var byMachine: [String: Double]

    public var id: String { "\(platform.rawValue).\(limitID)" }

    public var timeToReset: TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSinceNow)
    }

    /// 原始计量单位下的剩余量。没有上限就明确未知，不返回伪造的 100%。
    public var remaining: Double? {
        guard let limit else { return nil }
        return max(0, limit - used)
    }

    public func isFresh(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now <= expiresAt
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
        byMachine: [String: Double] = [:],
        observedFloor: Double? = nil,
        advisory: Bool = false,
        sourceKind: QuotaSourceKind? = nil,
        observedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.advisory = advisory
        self.observedFloor = observedFloor
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
        self.sourceKind = sourceKind ?? (isOfficial ? .officialFact : .localEstimate)
        self.observedAt = observedAt ?? windowStart
        self.expiresAt = expiresAt ?? resetsAt
        self.byMachine = byMachine
    }

    private enum CodingKeys: String, CodingKey {
        case platform, planName, limitID, label, metric, kind, used, limit, usedFraction
        case windowStart, resetsAt, windowElapsedFraction, projectedUsedFraction
        case projectedWaste, observedFloor, health, isOfficial, advisory, sourceNote
        case sourceKind, observedAt, expiresAt, byMachine
    }

    /// 看板记录会由不同版本的 Mac 互相读取；所有新增字段都必须显式降级。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(Platform.self, forKey: .platform)
        planName = try c.decode(String.self, forKey: .planName)
        limitID = try c.decode(String.self, forKey: .limitID)
        label = try c.decode(String.self, forKey: .label)
        metric = try c.decode(QuotaMetric.self, forKey: .metric)
        kind = try c.decode(WindowKind.self, forKey: .kind)
        used = try c.decode(Double.self, forKey: .used)
        limit = try c.decodeIfPresent(Double.self, forKey: .limit)
        usedFraction = try c.decodeIfPresent(Double.self, forKey: .usedFraction)
        windowStart = try c.decode(Date.self, forKey: .windowStart)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        windowElapsedFraction = try c.decode(Double.self, forKey: .windowElapsedFraction)
        projectedUsedFraction = try c.decodeIfPresent(Double.self, forKey: .projectedUsedFraction)
        projectedWaste = try c.decodeIfPresent(Double.self, forKey: .projectedWaste)
        observedFloor = try c.decodeIfPresent(Double.self, forKey: .observedFloor)
        health = try c.decode(QuotaHealth.self, forKey: .health)
        isOfficial = try c.decode(Bool.self, forKey: .isOfficial)
        advisory = try c.decodeIfPresent(Bool.self, forKey: .advisory) ?? false
        sourceNote = try c.decodeIfPresent(String.self, forKey: .sourceNote) ?? "来源未知"
        sourceKind = try c.decodeIfPresent(QuotaSourceKind.self, forKey: .sourceKind)
            ?? (isOfficial ? .officialFact : .localEstimate)
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt) ?? windowStart
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt) ?? resetsAt
        byMachine = try c.decodeIfPresent([String: Double].self, forKey: .byMachine) ?? [:]
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

    /// 人最后一次在**本机**用它。
    ///
    /// ## 为什么必须和上面那个分开
    ///
    /// `lastHumanActivity` 是跨机聚合的 —— 看板要的就是这个。
    /// 但调度器拿它当「让开」的判据就错了：人在 A 机器上敲代码，
    /// B 机器的调度器也跟着让开，于是 B 上那个完全空闲的 agent 永远派不出活。
    ///
    /// 实测就是这样：用户明确要求「本机的 Claude 不调度、另一台的要调度」，
    /// 结果另一台的调度器因为看到本机的人工活动，把它自己的 Claude 也让开了，
    /// 那台机器上唯一可用的 agent 就此闲置。
    ///
    /// 「让开」要挡的是**打扰正在敲键盘的人**（抢延迟、先撞限流），
    /// 这件事天然是本机的。而「共用一个额度池」是另一回事，
    /// 由 exhausted / atRisk 那两道闸门管，不该混进来。
    public var lastHumanActivityHere: Date?

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

    /// 空窗统计：每个窗口长度一条。
    ///
    /// **这是「浪费了多少」在没有上限时唯一能站住的口径。**
    /// 实测 13 个额度窗口里只有 3 个有 limit，其余全是 unconfigured
    /// （而且填不得：GLM 公布积分口径对不上、Kimi/Claude 不公布）。
    /// 没有分母就算不出「浪费量」，但「这个窗口一次都没用」跟分母无关。
    ///
    /// 在 Mac 端算好发出去，不让手机去推 —— 手机拿不到逐个用量桶，
    /// 而且两台设备各算各的会得出不同的数。
    public var idleWindows: [WasteMeter.Report]

    /// 这个平台正在冷却吗，为什么，到什么时候。
    ///
    /// **不发这个的话，空窗数会撒谎。**
    /// 实测：Kimi 连续空了 19 个 5 小时窗 —— 看起来是「我们没在用它」，
    /// 真相是它**额度用尽被限流**，我们试过、被拒了、退避了。
    /// 那是订阅被用满，正好是浪费的反面。
    /// 把它显示成「在漏的」，会让人去给一个正在限流的平台塞更多活。
    public var cooldownUntil: Date?
    public var cooldownReason: String?

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
        lastHumanActivityHere: Date? = nil,
        agentName: String = "",
        agentBinary: String = "",
        machines: [String],
        lastActivity: Date?,
        statuses: [QuotaStatus],
        last30dRequests: Int,
        last30dBillableTokens: Int,
        last7dRequests: Int,
        topModels: [ModelUsage],
        idleWindows: [WasteMeter.Report] = [],
        cooldownUntil: Date? = nil,
        cooldownReason: String? = nil
    ) {
        self.platform = platform
        self.planName = planName
        self.monthlyCost = monthlyCost
        self.currency = currency
        self.detected = detected
        self.installed = installed
        self.enabled = enabled
        self.lastHumanActivity = lastHumanActivity
        self.lastHumanActivityHere = lastHumanActivityHere
        // 发布版：留白填**生效值**，不是配置里那个「nil 表示继承默认」的覆盖值。
        // 看板是要发给手机的，而手机解析不了「继承」—— 发 nil 过去，
        // 界面上就是一片空白，用户以为一个都没设，实际每个都在按 25% 拦。
        // 这里是整个看板里唯一给 role 赋值的地方，收口在这。
        self.role = AgentRoles.published(
            for: platform, default: WorkScheduler.defaultHumanReserve)
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
        self.idleWindows = idleWindows
        self.cooldownUntil = cooldownUntil
        self.cooldownReason = cooldownReason
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

/// 手机端要看的**一条任务**，只留显示需要的那几个字段。
///
/// # 为什么不直接发 `WorkTask`
///
/// `WorkTask` 里有 prompt 全文、仓库绝对路径、handoff、pendingAsk……
/// 一条就可能几 KB，而这份文件要走 iCloud 同步到手机。更要紧的是
/// **prompt 里带着 `/Users/<你>/...` 这种本机路径**，发到手机上既没意义
/// 也没必要。所以这里是一份显式的、窄的投影：加字段要有人动手加，
/// 不会因为 Mac 侧给 WorkTask 加了个字段就悄悄跟着漏出去。
public struct TaskBrief: Codable, Sendable, Hashable, Identifiable {
    /// 标题最多多少个**字符**（不是字节）。
    ///
    /// 按字节截会把一个多字节的汉字劈成两半，输出是 `锟斤拷` 那种乱码；
    /// Swift 的 `prefix` 按 Character（字素簇）走，汉字和 emoji 都不会被切开。
    public static let titleMaxCharacters = 80

    public var id: String
    /// 短标题：优先 `stepTitle`，没有就取 prompt 的第一行，再截到 80 字符。
    public var title: String
    public var state: WorkTask.State
    public var waitReason: WorkTask.WaitReason?
    /// 还没派出去的时候没有。
    public var platform: Platform?
    /// 哪台机器在跑它。
    public var machineName: String
    public var startedAt: Date?
    /// 跑了多久。running 是「到现在为止」，终态是「一共跑了」。
    public var elapsedSeconds: Int?
    public var graphID: String?
    public var stepIndex: Int?
    /// 这张图一共几步。**按 graphID 数出来的**，不是记录里存的。
    public var stepTotal: Int?
    public var repoAlias: String?
    public var progressPhase: String?
    public var progressSummary: String?
    public var progressNextStep: String?
    public var progressUpdatedAt: Date?
    public var progressEvidenceCount: Int?
    /// 新客户端可直接渲染；旧客户端仍会看到下方 progress* 的兼容投影。
    public var productionStage: String?
    public var deliverableKind: String?
    public var productionBlockedReason: String?

    public init(
        id: String,
        title: String,
        state: WorkTask.State,
        waitReason: WorkTask.WaitReason? = nil,
        platform: Platform? = nil,
        machineName: String,
        startedAt: Date? = nil,
        elapsedSeconds: Int? = nil,
        graphID: String? = nil,
        stepIndex: Int? = nil,
        stepTotal: Int? = nil,
        repoAlias: String? = nil,
        progressPhase: String? = nil,
        progressSummary: String? = nil,
        progressNextStep: String? = nil,
        progressUpdatedAt: Date? = nil,
        progressEvidenceCount: Int? = nil,
        productionStage: String? = nil,
        deliverableKind: String? = nil,
        productionBlockedReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.waitReason = waitReason
        self.platform = platform
        self.machineName = machineName
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.graphID = graphID
        self.stepIndex = stepIndex
        self.stepTotal = stepTotal
        self.repoAlias = repoAlias
        self.progressPhase = progressPhase
        self.progressSummary = progressSummary
        self.progressNextStep = progressNextStep
        self.progressUpdatedAt = progressUpdatedAt
        self.progressEvidenceCount = progressEvidenceCount
        self.productionStage = productionStage
        self.deliverableKind = deliverableKind
        self.productionBlockedReason = productionBlockedReason
    }

    /// 手写解码，可选字段一律 `decodeIfPresent`。
    ///
    /// 合成解码器对缺键零容忍 —— 缺一个键抛 `keyNotFound`，
    /// 而这个类型是数组元素，一条解不出来，**整个 Dashboard 都解不出来**。
    /// 给属性写默认值救不了合成解码器，这个坑在这个项目里翻过五次车。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        // 状态用字符串接，认不出来的当 queued。
        // 将来 Mac 侧加了新状态时，老客户端显示得不准，但**还能显示**——
        // 比整份看板解不出来强。
        state = (try c.decodeIfPresent(String.self, forKey: .state))
            .flatMap(WorkTask.State.init(rawValue:)) ?? .queued
        waitReason = try c.decodeIfPresent(WorkTask.WaitReason.self, forKey: .waitReason)
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        elapsedSeconds = try c.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
        graphID = try c.decodeIfPresent(String.self, forKey: .graphID)
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex)
        stepTotal = try c.decodeIfPresent(Int.self, forKey: .stepTotal)
        repoAlias = try c.decodeIfPresent(String.self, forKey: .repoAlias)
        progressPhase = try c.decodeIfPresent(String.self, forKey: .progressPhase)
        progressSummary = try c.decodeIfPresent(String.self, forKey: .progressSummary)
        progressNextStep = try c.decodeIfPresent(String.self, forKey: .progressNextStep)
        progressUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .progressUpdatedAt)
        progressEvidenceCount = try c.decodeIfPresent(Int.self, forKey: .progressEvidenceCount)
        productionStage = try c.decodeIfPresent(String.self, forKey: .productionStage)
        deliverableKind = try c.decodeIfPresent(String.self, forKey: .deliverableKind)
        productionBlockedReason = try c.decodeIfPresent(
            String.self, forKey: .productionBlockedReason)
    }

    /// 按**字符**截断，超了就用省略号收尾（收尾之后总长仍然 ≤ 上限）。
    public static func clampTitle(_ raw: String, limit: Int = titleMaxCharacters) -> String {
        // 换行会把手机上的一行标题撑成一段，先压平。
        let flat = raw.split(whereSeparator: \.isNewline).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard flat.count > limit else { return flat }
        guard limit > 1 else { return String(flat.prefix(limit)) }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// 一条任务显示成什么标题。
    ///
    /// **这不是脱敏。** prompt 前 80 个字符里如果就写着 `/Users/…/项目`，
    /// 它会跟着标题过去 —— 截断挡掉的是「长」和「80 字之后的东西」，
    /// 不是路径本身。想要干净的标题就给任务写 `stepTitle`
    /// （拆解出来的图节点本来就都有）。
    public static func title(for task: WorkTask) -> String {
        let stepTitle = task.stepTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = stepTitle.isEmpty ? task.prompt : stepTitle
        let clamped = clampTitle(raw)
        // prompt 可能整个是空白 / 只有换行，那样标题会是空的 ——
        // 手机上一行空白比一个 id 更没用。
        return clamped.isEmpty ? "任务 \(task.id.prefix(8))" : clamped
    }
}

/// 整个仪表盘的数据。
public struct Dashboard: Codable, Sendable {
    public var generatedAt: Date
    public var machines: [MachineInfo]
    public var reports: [PlatformReport]

    /// 现在有哪些活。见 `TaskBoard` —— 范围、排序和上限都在那儿定。
    ///
    /// 这份数据以前根本不存在：手机拿到的只有机器和额度，
    /// 「办公室」里那些机器人在动全靠用量活跃度**推**出来，不是真的任务记录。
    public var tasks: [TaskBrief]

    /// `tasks` 被上限截掉过。
    ///
    /// **静默截断是不能接受的**：手机上「一共 3 个任务」会变成一句假话，
    /// 而且是那种没人会去核对的假话。宁可界面上多一行「还有更多」。
    public var tasksTruncated: Bool

    public init(generatedAt: Date, machines: [MachineInfo], reports: [PlatformReport],
                tasks: [TaskBrief] = [], tasksTruncated: Bool = false) {
        self.generatedAt = generatedAt
        self.machines = machines
        self.reports = reports
        self.tasks = tasks
        self.tasksTruncated = tasksTruncated
    }

    /// 手写解码：`tasks` / `tasksTruncated` 走 `decodeIfPresent`。
    ///
    /// 集群里各台机器的二进制版本不一定同步，老机器发出来的看板里
    /// **没有这两个键**。合成解码器遇到缺键直接抛 `keyNotFound`，
    /// 于是整份看板解不出来 —— 手机上不是「少了任务列表」，
    /// 而是连额度都没了。给属性写默认值救不了它，必须手写。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        machines = try c.decode([MachineInfo].self, forKey: .machines)
        reports = try c.decode([PlatformReport].self, forKey: .reports)
        tasks = try c.decodeIfPresent([TaskBrief].self, forKey: .tasks) ?? []
        tasksTruncated = try c.decodeIfPresent(Bool.self, forKey: .tasksTruncated) ?? false
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
        // 兜底名。**本机到底是谁在跑 GLM,由 name(for:) 现场判**(见下面) ——
        // 老板的 MacBook 上「Claude Code 配 GLM 模型」和「官方 ZCode」是并存的两个东西,
        // 2026-08-23 我一刀切改成 ZCode 是错的,他当场指出来了。
        .glm:      "Claude Code · GLM",
        .deepseek: "Claude Code · DeepSeek",
        .volcark:  "opencode · 火山",
        .openrouter: "opencode · Ox Alpha",
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
        .openrouter: "opencode",
    ]

    /// 干活的 agent 名。**GLM 要看本机实际能用的是哪个客户端。**
    ///
    /// 老板的 MacBook 上两样并存:Claude Code 配了 GLM 模型,另外还装了官方 ZCode。
    /// mini 上只有前者。写死任何一个都会在另一台上撒谎 —— 2026-08-23 我写死成
    /// 「ZCode · GLM」,他的回话是「不是说改个名就可以了,要确保真实可调度」。
    /// 名字跟着**这台机器真正调得起来的那个**走(ZcodeRunner.binaryPath 已经把
    /// 「装了 ≠ 调得起来」判全了:脚本/node/CLI 配置/凭据四样齐才算)。
    public static func name(for p: Platform) -> String {
        if p == .glm, glmRunsOnZcode() { return "ZCode · GLM" }
        return map[p] ?? p.displayName
    }
    public static func binaryName(for p: Platform) -> String {
        if p == .glm, glmRunsOnZcode() { return "zcode" }
        return binary[p] ?? p.rawValue
    }

    /// 这个**集群里**跑 GLM 的是官方 ZCode 吗。
    ///
    /// **不能只看本机。** dashboard.json 是单文件、后写覆盖,而两台机器装的东西不一样:
    /// mini 没装 ZCode、MacBook 装了。只看本机的话,mini 每写一次就把名字盖回
    /// 「Claude Code · GLM」—— 老板在手机上又看不到 ZCode 了(2026-08-23 他连问两次)。
    ///
    /// 判据用已经在同步的事实:任何一台机器的快照里,GLM 的来源目录含 `.zcode`
    /// 就说明这个集群的 GLM 是 ZCode 在跑。本机装了也直接算。
    static func glmRunsOnZcode(now: Date = Date()) -> Bool {
        if ZcodeRunner().binaryPath != nil { return true }
        let dir = Paths.sharedRoot.appendingPathComponent("snapshots", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        for f in files where f.hasSuffix(".json") && !f.hasPrefix(".") {
            guard let d = FileManager.default.contents(atPath: dir.appendingPathComponent(f).path),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let plats = obj["platforms"] as? [[String: Any]] else { continue }
            for pl in plats where (pl["platform"] as? String) == "glm" {
                let srcs = (pl["sources"] as? [String]) ?? []
                if srcs.contains(where: { $0.contains(".zcode") }) { return true }
            }
        }
        return false
    }

    /// 是不是「借用别人客户端」的那种。
    ///
    /// 这一类的额度归属最容易搞错 —— 光看模型名会把整整一个套餐的用量
    /// 算到 Claude 头上，实际烧的是第三方那份。
    public static func isBorrowedClient(_ p: Platform) -> Bool {
        binary[p] == "claude" && p != .claude
    }
}
