import Foundation

/// 任务画像：入队时分析一次，之后每轮派发都靠它，不再重复调 LLM。
///
/// 为什么不在派发时调 LLM：派发每 30 秒跑一次，为「决定怎么花一次调用」
/// 再花一次调用本身就是浪费；而且非确定性会让调度没法测试、出问题没法复现。
/// 分类一次、路由无数次 —— LLM 只在任务生命周期里出现一次。
///
/// 分类失败不阻塞入队。拿不到画像时调度退化成纯额度排序，也就是现在的行为。
public struct TaskProfile: Codable, Sendable {

    /// 需要多强的模型才干得动。
    public enum Tier: String, Codable, Sendable, Comparable {
        /// 改文档、改注释、重命名、格式化。任何平台都行。
        case trivial
        /// 常规改动：加个函数、补测试、修一个明确的 bug。
        case standard
        /// 跨模块重构、要先读懂现有架构才能动手、涉及并发或数据一致性。
        case complex

        public var displayName: String {
            switch self {
            case .trivial: return "简单"
            case .standard: return "常规"
            case .complex: return "复杂"
            }
        }

        public var rankValue: Int { rank }

        var rank: Int {
            switch self {
            case .trivial: return 0
            case .standard: return 1
            case .complex: return 2
            }
        }
        public static func < (a: Tier, b: Tier) -> Bool { a.rank < b.rank }
    }

    /// 改动会碰到什么。决定要不要转人工确认。
    /// Comparable 是给调度用的：角色里写「最多接常规」，就要能判断
    /// 一个高危任务超不超线。Tier 已经是 Comparable，Risk 一直不是 ——
    /// 也正因为不能比大小，风险这一维在调度里被彻底跳过了。
    public enum Risk: String, Codable, Sendable, Comparable {
        /// 只动文档和测试。
        case safe
        /// 动源码。
        case normal
        /// 动构建配置、脚本、CI、依赖清单、权限位 —— 这类改错了影响面远超单个文件。
        case sensitive

        private var rank: Int {
            switch self {
            case .safe: return 0
            case .normal: return 1
            case .sensitive: return 2
            }
        }
        public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }

        public var displayName: String {
            switch self {
            case .safe: return "低危"
            case .normal: return "常规"
            case .sensitive: return "高危"
            }
        }
        public var needsApproval: Bool { self == .sensitive }
    }

    public var tier: Tier
    public var risk: Risk
    /// 预估耗时（分钟）。用来设单次超时，避免给简单任务留 10 分钟白等。
    public var estimatedMinutes: Int
    /// 任务是否自洽。
    ///
    /// 「任务尽量独立」这条要求靠这个字段落地：描述里出现「上次那个」「继续之前的」
    /// 这类指代，或者缺少判断完成标准的信息时，agent 只能靠猜 ——
    /// 猜错就是整轮额度白烧。宁可入队时就标出来让人改，也不要跑完才发现跑偏。
    public var isSelfContained: Bool
    /// 不自洽时缺了什么。直接给用户看。
    public var missingContext: String?
    /// 分类依据，一句话。让判断可审、可反驳。
    public var rationale: String
    /// 谁分的类。分类本身也消耗额度，要记账。
    public var classifiedBy: Platform?
    public var classifiedAt: Date

    /// 容错解码。
    ///
    /// 合成的解码器要求每个非可选字段都在 —— 少一个就整条 WorkTask 解不出来，
    /// 而 TaskStore.all() 对解不出来的行是**静默 continue**，再加上
    /// last-write-wins，结果是任务悄悄退回到更早的那个版本。
    ///
    /// 这个坑真踩到了：往任务记录里补 profile 时漏了 classifiedAt，
    /// 整行被丢掉，风险闸门因此拿不到 risk、静默放行了一个高危任务。
    /// 排查时看到的现象是「字段明明写进文件了，程序就是读不到」。
    ///
    /// 画像是**可选的优化信息**，缺字段最坏的后果应该是「这一项不知道」，
    /// 而不是「整个任务记录作废」。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? .standard
        risk = try c.decodeIfPresent(Risk.self, forKey: .risk) ?? .normal
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 5
        isSelfContained = try c.decodeIfPresent(Bool.self, forKey: .isSelfContained) ?? true
        missingContext = try c.decodeIfPresent(String.self, forKey: .missingContext)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        classifiedBy = try c.decodeIfPresent(Platform.self, forKey: .classifiedBy)
        classifiedAt = try c.decodeIfPresent(Date.self, forKey: .classifiedAt) ?? Date()
    }

    public init(
        tier: Tier, risk: Risk, estimatedMinutes: Int,
        isSelfContained: Bool, missingContext: String? = nil,
        rationale: String, classifiedBy: Platform? = nil,
        classifiedAt: Date = Date()
    ) {
        self.tier = tier
        self.risk = risk
        self.estimatedMinutes = max(1, min(estimatedMinutes, 60))
        self.isSelfContained = isSelfContained
        self.missingContext = missingContext
        self.rationale = rationale
        self.classifiedBy = classifiedBy
        self.classifiedAt = classifiedAt
    }

    /// 这一档任务的单次执行超时。
    ///
    /// 给足预估的 3 倍再加个下限 —— 估得再准也会有偏差，
    /// 但简单任务不该占着 10 分钟的坑，那会拖垮整个候选轮转。
    /// 这次尝试给多少时间。
    ///
    /// 估时的三倍留够余量，但要封顶 —— 一个跑不完的任务不能永远占着执行槽。
    ///
    /// **上限按档次分，不是一刀切 20 分钟。**
    /// 原来所有任务共用 20 分钟硬顶，于是「实玩验收」这类活必然撞墙：
    /// 它要反复截图、逐帧核对动画、还要凑齐三种卡牌类型，20 分钟刚够它
    /// 计划完动作。实测 1201 秒被掐断，日志显示它当时还在写
    ///「继续翻牌直到出现诅咒和警觉」—— 活没问题，是墙太近。
    ///
    /// 复杂档给 40 分钟：这类任务本来就稀少（分诊判复杂才给），
    /// 而重跑一次的代价远高于多等二十分钟。简单和常规档维持 20 分钟，
    /// 它们跑到那么久基本就是卡住了，早点换人比干等强。
    public var timeout: TimeInterval {
        // 上限按档次分层。**别把三倍预算掐回一倍出头** ——
        // 分诊估 15 分钟的常规任务，三倍是 45 分钟（估时天生乐观，
        // 三倍就是为此留的），而旧的 20 分钟硬顶只给到 1.3 倍，
        // 等于把留的余量又收回去了。实测被它掐死两次：
        // 一次实玩验收正翻牌翻到一半，一次视觉验收正在抓截图。
        let capMinutes: Int
        switch tier {
        case .trivial:  capMinutes = 20   // 改注释改文案，跑那么久就是卡住了
        case .standard: capMinutes = 30
        case .complex:  capMinutes = 45   // 整包任务住在这一档
        }
        return TimeInterval(max(180, min(estimatedMinutes * 3, capMinutes) * 60))
    }
}

// MARK: - 平台能力

/// 平台能不能吃下某一档任务。
///
/// 这张表是**保守的先验**，不是永久判决：一旦历史记录里出现某平台成功完成过
/// 更高档的任务，`PlatformCapability.effectiveTier` 会把它提上去。
/// 写死一张表然后再也不改，等于永远学不到东西。
public enum PlatformCapability {
    static let priorTier: [Platform: TaskProfile.Tier] = [
        .claude: .complex,
        .codex: .complex,
        .glm: .standard,
        .kimi: .standard,
        .minimax: .standard,
        .deepseek: .standard,
        .qwen: .standard,
        .volcark: .standard,
        .gemini: .standard,
    ]

    /// 结合历史成绩得出的实际能力上限。
    public static func effectiveTier(
        for platform: Platform, history: [WorkTask]
    ) -> TaskProfile.Tier {
        let prior = priorTier[platform] ?? .standard
        // 这个平台真正成功完成过的最高档次。
        let proven = history
            .filter { $0.platform == platform && $0.state == .done && ($0.changedFiles ?? 0) > 0 }
            .compactMap { $0.profile?.tier }
            .max()
        guard let proven else { return prior }
        return max(prior, proven)
    }
}

// MARK: - 历史成绩

/// 从任务历史里算出的平台成绩单，喂给分类器当上下文。
public struct PlatformRecord: Sendable {
    public var platform: Platform
    public var attempts: Int
    public var succeeded: Int
    public var medianSeconds: Int
    public var commonFailure: String?

    public var successRate: Double {
        attempts == 0 ? 0 : Double(succeeded) / Double(attempts)
    }
}

public enum TaskHistory {
    public static func records(from tasks: [WorkTask]) -> [PlatformRecord] {
        var byPlatform: [Platform: [WorkTask]] = [:]
        for t in tasks where t.platform != nil && t.state != .queued && t.state != .running {
            byPlatform[t.platform!, default: []].append(t)
        }
        return byPlatform.map { platform, list in
            let done = list.filter { $0.state == .done }
            let durations = list.compactMap { $0.duration }.sorted()
            let median = durations.isEmpty ? 0 : Int(durations[durations.count / 2])
            // 最常见的失败原因，截短了给分类器看。
            var reasons: [String: Int] = [:]
            for t in list where t.state == .failed {
                let key = String((t.note ?? "").prefix(40))
                reasons[key, default: 0] += 1
            }
            return PlatformRecord(
                platform: platform, attempts: list.count, succeeded: done.count,
                medianSeconds: median,
                commonFailure: reasons.max(by: { $0.value < $1.value })?.key)
        }.sorted { $0.platform.sortIndex < $1.platform.sortIndex }
    }

    /// 给分类器看的历史摘要。控制在很短 —— 它只是参考，不该喧宾夺主。
    public static func summary(from tasks: [WorkTask], limit: Int = 8) -> String {
        let recent = tasks
            .filter { $0.state == .done || $0.state == .failed }
            .suffix(limit)
        guard !recent.isEmpty else { return "（还没有历史任务）" }
        return recent.map { t in
            let mark = t.state == .done ? "成功" : "失败"
            let dur = t.duration.map { "\(Int($0))s" } ?? "—"
            let tier = t.profile?.tier.displayName ?? "?"
            return "- [\(mark)] \(tier) · \(t.platform?.displayName ?? "?") · \(dur) · "
                + String(t.prompt.prefix(50))
        }.joined(separator: "\n")
    }
}
