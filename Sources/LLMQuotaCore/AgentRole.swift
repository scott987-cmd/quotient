import Foundation

/// 每个 agent 的岗位职责。
///
/// ## 为什么需要这个
///
/// 分诊器认认真真给每个任务判了风险等级（safe / normal / sensitive，
/// sensitive 的定义是「动构建配置、脚本、CI、依赖清单、权限位」），
/// 而调度器**一次都没用过这个字段** —— 全文搜 `.risk` 命中 0 处。
///
/// 后果很具体：一个要改 `Package.swift` 或 launchd plist 的任务，
/// 可以被派给 Qwen —— 而 Qwen 在无头模式下有已知的失控重试问题
/// （`consecutive_identical_tool_calls`，Work.swift 里记过）。
/// 改砸构建配置和改砸一句注释，代价差得很远。
///
/// ## 和已有的能力档次是什么关系
///
/// `PlatformCapability.effectiveTier` 管的是**难度**上限，而且它会从历史
/// 成绩自己往上长。角色管的是**职责边界**：能碰多敏感的东西、擅长哪一类活。
/// 两者是不同的维度，不是一件事的两种说法：
///
/// - 一个平台可能很能干（complex），但你就是不想让它碰 CI 配置。
/// - 一个平台可能只能干 standard，但它专门用来批量写文档最划算。
///
/// 所以角色**不替换**能力档次，而是在它之上加一道你可以手动划的线。
/// 角色里的 `maxTier` 留空时沿用学出来的档次，填了就以你填的为准 ——
/// 学习器只会往上长，它不知道「我不想让它干这个」。
public struct AgentRole: Codable, Sendable {

    public var platform: Platform
    /// 岗位名。手机上的办公室会显示它。
    public var title: String
    /// 最高能接多敏感的活。**这是这个结构存在的主要理由。**
    public var maxRisk: TaskProfile.Risk
    /// 手动划定的难度上限。nil 表示沿用 PlatformCapability 学出来的。
    public var maxTier: TaskProfile.Tier?
    /// 偏好哪一档的活。**软加分，不是硬约束** ——
    /// 硬约束会在别人都不可用时把队列卡死。
    public var prefers: [TaskProfile.Tier]
    public var note: String

    /// 在这些机器上不派活给它。存机器名（`llmq machines` 里看到的那个），
    /// 不存 machineID —— 后者是一串 UUID，配置文件里没法读。
    ///
    /// 为什么按机器分而不是全局关掉：同一个平台在不同机器上的处境不一样。
    /// 比如这台 Mac 的 Claude 是控制面（就是那个决定「该干什么」的环节），
    /// 派活给它等于自己饿死自己；而另一台机器上同一个 Claude 完全空着，
    /// 该用就得用。全局开关表达不了这件事。
    public var mutedOn: [String]
    public var muteReason: String?

    /// 调度器最多能吃掉这个平台额度的多少 —— 剩下的留给你自己用。
    ///
    /// 存的是**留白比例**：0.20 表示至少留 20% 不动，调度最多用到 80%。
    /// 0 表示随便用光，1 表示一点都不许自动化用。
    ///
    /// 为什么按平台而不是一个全局值：不同订阅的处境完全不同。
    /// MiniMax 那份额度你还要拿去生图、跑别的程序，吃光了自己就没得用；
    /// 而 Qwen 的日额度本来就是不用即作废，留白反而是浪费。
    /// 一个全局 25% 同时把这两种情况都照顾错了。
    ///
    /// nil = 沿用全局默认（`WorkScheduler.humanReserve`，当前 0.25）。
    /// **不能给它一个非 nil 的默认值** —— 那等于把所有平台一次性钉死在某个数上，
    /// 而全局默认将来调整时它们不会跟着动。
    public var reserveFraction: Double?

    /// 在这些机器上，这个平台是**指挥**（控制面），不是干活的。
    ///
    /// ## 为什么不能继续用 mutedOn 表达
    ///
    /// 「不接活」和「负责发活」是两回事，混在一起有三个后果：
    ///
    /// 1. 界面上是个空白角色 —— 办公室里那个「调度」是个匿名吉祥物，
    ///    跟任何真实平台都没绑定，同时 Claude 又作为闲着的员工坐在工位上。
    ///    同一个东西画了两遍，一遍没身份，一遍没意义。
    /// 2. 污染死锁判定 —— 判「所有平台都接不了」时，指挥是以「被拒绝的候选」
    ///    身份混在里面的。可它没有「接不了」，它是发活的那个。
    /// 3. 把配置说成故障 ——「被静音了」听起来像出了什么事，
    ///    而这是有意的架构选择。
    ///
    /// 和 mutedOn 一样按机器名存：Mac mini 上的 Claude 是指挥，
    /// MacBook 上同一个 Claude 可以干活。全局开关会把后者一起误伤。
    public var dispatcherOn: [String] = []

    public init(platform: Platform, title: String, maxRisk: TaskProfile.Risk,
                maxTier: TaskProfile.Tier? = nil,
                prefers: [TaskProfile.Tier] = [], note: String = "",
                mutedOn: [String] = [], muteReason: String? = nil,
                dispatcherOn: [String] = [], reserveFraction: Double? = nil) {
        self.platform = platform
        self.title = title
        self.maxRisk = maxRisk
        self.maxTier = maxTier
        self.prefers = prefers
        self.note = note
        self.mutedOn = mutedOn
        self.muteReason = muteReason
        self.dispatcherOn = dispatcherOn
        self.reserveFraction = reserveFraction
    }

    /// 和另一个角色是不是等价。用来判断「这条要不要存」。
    func sameAs(_ o: AgentRole) -> Bool {
        title == o.title && maxRisk == o.maxRisk && maxTier == o.maxTier
            && prefers == o.prefers && note == o.note
            && Set(mutedOn) == Set(o.mutedOn) && muteReason == o.muteReason
            && Set(dispatcherOn) == Set(o.dispatcherOn)
            && reserveFraction == o.reserveFraction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(Platform.self, forKey: .platform)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未分配"
        maxRisk = try c.decodeIfPresent(TaskProfile.Risk.self, forKey: .maxRisk) ?? .safe
        maxTier = try c.decodeIfPresent(TaskProfile.Tier.self, forKey: .maxTier)
        prefers = try c.decodeIfPresent([TaskProfile.Tier].self, forKey: .prefers) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        mutedOn = try c.decodeIfPresent([String].self, forKey: .mutedOn) ?? []
        muteReason = try c.decodeIfPresent(String.self, forKey: .muteReason)
        dispatcherOn = try c.decodeIfPresent([String].self, forKey: .dispatcherOn) ?? []
        // 越界的值当没配。写了 1.5 或 -0.2 的话，照单全收会让调度要么
        // 一个平台都挑不出来、要么把额度吃光 —— 而两者都不会报错。
        if let r = try c.decodeIfPresent(Double.self, forKey: .reserveFraction),
           r >= 0, r <= 1 {
            reserveFraction = r
        }

        // **一次性迁移：控制面原来是用 mute 表达的。**
        //
        // 老配置里是 mutedOn:[机器名] + muteReason:"…是控制面…"。
        // 在这里就地转成 dispatcherOn 并摘掉那条 mute，
        // 用户不用改文件，也不会出现「既是指挥又被静音」的重影。
        if dispatcherOn.isEmpty, let why = muteReason, why.contains("控制面") {
            dispatcherOn = mutedOn
            mutedOn = []
        }
    }
}

public enum AgentRoles {

    /// 测试用。
    ///
    /// `didSet` 里清缓存是必需的：换了配置文件却还读着 30 秒前的缓存，
    /// 测试之间会互相串（上一条存的角色被下一条读到）。
    public static var fileOverride: URL? {
        didSet { cached = nil; cachedAt = nil }
    }

    static var file: URL {
        fileOverride
            ?? Paths.iCloudConfigDir?.appendingPathComponent("roles.json")
            ?? Paths.appSupport.appendingPathComponent("roles.json")
    }

    /// 出厂默认。
    ///
    /// 每一条的依据都来自这个项目里**实际观察到的行为**，不是凭印象排座次：
    ///
    /// - Claude Code 是唯一被放行到 sensitive 的。它是这套系统里被验证过
    ///   最多次、成功率最高的那个，而 sensitive 任务改砸的代价最大。
    /// - GLM 走的是同一个 Claude Code 二进制，但额度池完全不同：实测一个月
    ///   用量比第二名高一个数量级，而且**这就是日常真正在用的那个** ——
    ///   也就是说它扛得住真实工作量，
    ///   这比任何档次推断都硬。所以复杂活优先给它：不然复杂任务全落到
    ///   Claude 那个最紧张的池子上，正好和「别浪费」反着来。
    ///   不给 sensitive 是因为烧的是另一份订阅，出了事没有
    ///   「同一个账号好排查」这个便利。
    /// - Qwen 接常规编码活。它曾经有失控重试的问题（`consecutive_identical_tool_calls`），
    ///   但那次的**根因是审批拦住了文件编辑**，加上 `--approval-mode yolo`
    ///   之后已经修掉；修复之后它唯一一次执行是成功的（改 1 个文件、80 行）。
    ///   拿一个已经修好的故障继续把它按在文档岗上，是拿过期证据做决定。
    ///   不给 sensitive 只是因为样本还太少（修复后一共才跑过 1 次），
    ///   不是因为它不行 —— 等成绩攒够了再放。
    /// - MiniMax **不是编码 agent**。`mmx` 的能力是 image / video / music /
    ///   speech / vision / search，text 只是其中一个子命令，而且没有文件访问、
    ///   不认识仓库。它在这套系统里能干的只有分诊这类纯文本进出的活 ——
    ///   它真正的本事（媒体生成）这个调度器现在**够不着**。
    /// - Codex 的额度和 ChatGPT 网页版共用，本地看不见网页那部分消耗，
    ///   账算不准，所以不当主力，只在别人都忙时顶上。
    public static func defaults() -> [AgentRole] {
        [
            AgentRole(platform: .claude, title: "架构师", maxRisk: .sensitive,
                      prefers: [.complex],
                      note: "唯一放行改构建配置/CI 的。额度最贵，别拿它写注释。"),
            AgentRole(platform: .glm, title: "主力", maxRisk: .normal,
                      maxTier: .complex, prefers: [.standard, .complex],
                      note: "额度最富余（实测用量比第二名高一个数量级），"
                          + "也是你日常真正在用的那个。复杂活优先给它。"),
            AgentRole(platform: .codex, title: "替补", maxRisk: .normal,
                      prefers: [.standard],
                      note: "额度和 ChatGPT 网页版共用，本地算不准，别当主力。"),
            AgentRole(platform: .kimi, title: "主力", maxRisk: .normal,
                      maxTier: .complex, prefers: [.standard, .complex],
                      note: "跑的是 kimi-code/k3，编码能力够扛复杂活。"),
            AgentRole(platform: .qwen, title: "开发", maxRisk: .normal,
                      maxTier: .complex, prefers: [.standard],
                      note: "qwen3.8-max，正经写代码没问题。当初那次失控重试的根因是"
                          + "审批拦住了编辑，加 --approval-mode yolo 之后已修复。"),
            AgentRole(platform: .minimax, title: "媒体与分诊", maxRisk: .safe,
                      prefers: [],
                      note: "mmx 的本事是图片/视频/音乐/语音/图片理解/联网搜索，"
                          + "没有文件访问也不认识仓库。编码任务它接不了，"
                          + "现在只用它跑分诊。媒体那块产能这个调度器还够不着。"),
            AgentRole(platform: .deepseek, title: "备用", maxRisk: .safe, prefers: []),
            AgentRole(platform: .volcark, title: "新人", maxRisk: .safe,
                      prefers: [.trivial],
                      note: "opencode 跑的，经本地 LiteLLM 网关转到火山方舟。"
                          + "刚接进来还没跑过任务，先只给低危的活攒成绩。"),
            AgentRole(platform: .gemini, title: "备用", maxRisk: .safe, prefers: []),
        ]
    }

    /// 缓存。调度每 30 秒跑一轮，每轮都读一次 iCloud 目录没有意义。
    private static var cached: [Platform: AgentRole]?
    private static var cachedAt: Date?

    public static func all() -> [Platform: AgentRole] {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < 30 { return cached }
        var out = Dictionary(defaults().map { ($0.platform, $0) }, uniquingKeysWith: { a, _ in a })
        if let data = try? Data(contentsOf: file),
           let saved = try? SnapshotCoding.decoder().decode([AgentRole].self, from: data) {
            // 用户配置覆盖默认，但**不删默认里有而配置里没有的** ——
            // 否则新增一个平台之后，老配置文件会让它一个角色都没有，
            // 然后 role(for:) 返回 nil、风险闸门失效，静默放行。
            for r in saved { out[r.platform] = r }
        }
        cached = out
        cachedAt = Date()
        return out
    }

    public static func role(for p: Platform) -> AgentRole {
        all()[p] ?? AgentRole(platform: p, title: "未分配", maxRisk: .safe)
    }

    /// 只存**和默认不一样**的那些。
    ///
    /// 全存的话会有个不容易发现的后果：你改一个角色，其余全部被冻结在
    /// 当时的默认值上，以后默认值再怎么改进都到不了你这儿。
    /// 这个坑刚踩到 —— 给 Claude 设了本机静音，volcark 就被钉死在旧的
    /// 「备用」上，而代码里它早已经改成「新人」了。
    ///
    /// 只存差异之后，没动过的角色永远跟着默认走，动过的永远听你的。
    public static func save(_ roles: [AgentRole]) throws {
        try Paths.ensureDirectories()
        let base = Dictionary(defaults().map { ($0.platform, $0) },
                              uniquingKeysWith: { a, _ in a })
        let changed = roles.filter { r in
            guard let d = base[r.platform] else { return true }
            return !r.sameAs(d)
        }
        let data = try SnapshotCoding.prettyEncoder().encode(changed.sorted {
            $0.platform.rawValue < $1.platform.rawValue
        })
        try data.write(to: file, options: .atomic)
        cached = nil
    }

    /// 这个平台在**本机**是不是被静音了。
    public static func isMuted(_ p: Platform, machine: String = Paths.machineName()) -> Bool {
        role(for: p).mutedOn.contains(machine)
    }

    /// 这个平台的留白比例。没配就用全局默认。
    public static func reserve(for p: Platform, default fallback: Double) -> Double {
        role(for: p).reserveFraction ?? fallback
    }

    /// 这个平台在**本机**是不是指挥。
    public static func isDispatcher(_ p: Platform,
                                    machine: String = Paths.machineName()) -> Bool {
        role(for: p).dispatcherOn.contains(machine)
    }

    /// 本机的指挥是谁。没配就是 nil ——
    /// 那种机器退回「谁有额度谁上」。**不能因为找不到指挥就不干活。**
    public static func dispatcher(machine: String = Paths.machineName()) -> AgentRole? {
        all().values.first { $0.dispatcherOn.contains(machine) }
    }

    /// 这个角色接不接得了这份风险。
    public static func accepts(_ risk: TaskProfile.Risk, platform: Platform) -> Bool {
        risk <= role(for: platform).maxRisk
    }
}
