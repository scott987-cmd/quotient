import Foundation

// MARK: - 任务

public struct WorkTask: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, running, done, failed
        /// 在等人回答。**不在 queued 里**，所以 nextQueued 天然跳过它 ——
        /// 它不占额度槽，这正是「一分不浪费」要的效果。
        case blocked
    }

    public var id: String
    public var prompt: String
    /// 仓库路径。agent 在它的一个独立 worktree 里干活，不碰你的工作区。
    public var repo: String
    public var state: State
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?

    /// 调度器最终选了哪个平台。
    public var platform: Platform?
    /// 产出分支。
    public var branch: String?
    public var exitCode: Int32?
    public var changedFiles: Int?
    public var note: String?
    /// 入队时分析一次的画像。拿不到就是 nil，调度退化成纯额度排序。
    public var profile: TaskProfile?
    /// 已经在这个任务上失败过的平台，避免接力时又转回去。
    ///
    /// **提问不算失败**：agent 问了问题就退出的话，这个平台要从这里摘掉，
    /// 否则回答之后它被第一道硬排除挡住，只能换个更弱的平台重头做。
    public var triedPlatforms: [Platform] = []

    /// 任务形成上下文之后由哪个精确执行器继续负责。
    /// `platform` 不够：MiniMax 同一平台同时有媒体和评审执行器。
    public var ownerPlatform: Platform?
    public var ownerRunnerID: String?
    public var ownerAssignedAt: Date?
    /// 所有真实上下文转移，包括人工停用。
    public var handoffCount: Int = 0
    /// 只有系统因故障自动发起的交接；人工停用不占这一个救火名额。
    public var automaticHandoffCount: Int = 0

    /// 这个产出**落地**的时间 —— 合进目标分支了。
    ///
    /// 和 `state == .done` 是两件事，而且区别很关键：
    /// done 只说明「agent 跑完并提交到自己的分支」，那时候它还只是一个
    /// 待审的候选；只有合进 main 才算真的产生了价值。
    ///
    /// 分不开的话有两个后果。一是将来做去重时，一条**被你否决**的任务
    /// 会被永久当成「这事做过了」拉黑，那个真实缺陷再也不会被生成第二次，
    /// 而且没人知道。二是没法回答「我这一堆 done 里有多少真的进 main 了」——
    /// 而这正是「一分不浪费」该被检验的地方：跑完了但没人要，
    /// 那份额度一样是浪费掉了。
    public var landedAt: Date?
    /// 你把它丢掉的时间和理由。被丢掉的任务**允许**重新生成 ——
    /// 缺陷还在，只是这次的解法你不满意。
    public var discardedAt: Date?
    public var discardReason: String?

    /// 这条任务是从哪个**结构化事实**生成的（储备池用）。
    ///
    /// 人手写的任务这里是 nil。有值时它就是去重键 —— 见
    /// `ReservePool.pending`：同一个事实不重复生成，但被你丢弃过的允许重来。
    public var origin: String?

    /// 你在手机的办公室里点名让谁干。只影响排序，不绕过任何一道闸门。
    public var preferredPlatform: Platform?

    /// 正在等回答的那个问题。答案必须带着它的 id 回来才会被采纳。
    public var pendingAsk: Ask?
    /// 已经问过几轮。封顶见 Ask.Policy.maxRounds。
    public var askRounds: Int = 0
    /// 答复回来之后，等着被带进下一轮的上下文。
    /// 用完就清空（在 runOneTask 里落盘时），避免第二轮又把同一份答复塞一遍。
    public var answeredAsk: AskAnswer?

    /// 跨进程恢复用的交接信息。
    ///
    /// 原来 Handoff 只是 runOneTask 里的一个局部变量，进程一退就没了 ——
    /// 于是恢复时 `existingWorkspace` 那条分支进不去，转而走 prepare，
    /// 而 prepare 会 `worktree remove --force` 把上一轮的进度**铲掉**。
    /// 存进任务记录才能真的跨进程接上。
    public var handoff: Handoff?

    // MARK: - 任务图

    /// 所属任务图。nil = 它自己就是一整个任务（今天绝大多数任务都是这种）。
    ///
    /// 图存在的理由是**粒度**：一个任务里往往只有一小步是高危的，
    /// 或者只有一步是真难的。整包派给一个平台的后果实测过 ——
    /// 「在 build-app.sh 末尾加一行注释」整体被判高危，
    /// 于是所有角色都够不着，整个任务卡死。拆开之后只有碰构建脚本的那步转人工。
    ///
    /// 另一半理由是额度：机械的步骤给便宜的平台，难的那步给贵的，
    /// 这直接就是「一分不浪费」。
    public var graphID: String?

    /// 必须先完成的节点 id。空 = 可以立刻开跑。
    public var dependsOn: [String] = []

    /// 在图里的短标题。prompt 仍然是给 agent 的完整指令，这个只用于显示。
    public var stepTitle: String?

    /// 在图里的序号。**顺序不能靠 createdAt。**
    ///
    /// 拆解时用「相差 1 毫秒」来保序，而 createdAt 编码成 ISO8601 之后
    /// 秒以下被抹平 —— 落盘再读回来所有节点时间戳完全相同，
    /// 「第一步」变成随机的哪一步。显式存序号才稳。
    public var stepIndex: Int?

    /// 被上游冻结时，记下是哪个上游。
    ///
    /// **必须和「人工闸门拦下的 blocked」分开。** 两者状态相同但含义相反：
    /// 前者是「上游还没好，等一等」，后者是「等人做决定」。
    /// 不分开的话，解冻逻辑会把一个**人正在审的**高危任务偷偷放回队列。
    public var frozenBy: String?

    /// 黄金样板生产关系。nil = 旧任务/普通任务，不受阶段 1 的批量扩张闸影响。
    public var production: ProductionContext?

    /// 最近一次把这条任务重新打开的视觉否决任务 ID。
    ///
    /// 视觉验收失败后必须让原任务、原 owner、原会话接着整改，而不是另造一条
    /// 从零认识项目的任务。它也是对账幂等键：同一份否决只能重开一次。
    public var visualRemediationReviewID: String?

    /// 跑到一半被打断过几次（worker 重启、进程被杀）。
    ///
    /// **打断和失败是两回事**，但原来的孤儿回收把两者合并成 `failed`，
    /// 于是被打断的任务躺在那儿等人手动 retry。真实代价：一次 334 秒的
    /// Qwen 产出、一次 26 分钟的图节点，全都白跑。
    /// 有了这个计数就能默认重排、又不至于让「每次都跑一半就死」的任务无限循环。
    public var interruptedCount: Int?

    /// 哪个进程正在跑它。
    ///
    /// 存这个是为了让「回收孤儿」从猜变成确定。worker 被重启时（`llmq update`
    /// 每次都会重启它）in-flight 的任务会永远停在 `.running`，
    /// 必须有人回收 —— 但**不能靠「跑了多久」来判**：
    /// 那会在同时跑着两个 worker 时，把另一个正在干的活当成孤儿抢掉。
    ///
    /// 有 pid 就能精确判断：进程还在 → 别动；进程没了 → 孤儿。
    /// pid 被复用会让我们误判成「还在」，那是安全的方向（只是晚回收一轮）。
    public var runnerPID: Int32?

    /// 这一步产出的、要交给下游的东西（文件路径，相对仓库根）。
    ///
    /// 这是「MiniMax 出图 → Qwen 写代码」那类协作的载体。
    /// 它们是不同厂商的不同 CLI、不同进程，**不可能共享一个会话** ——
    /// 能传递的只有产物。下游节点的 briefing 里会带上这些路径。
    public var outputs: [String] = []

    /// 「这一轮是接着答复继续干」时要用的一对上下文。
    /// 两者缺一就不算恢复 —— 光有答案没有原问题的话，拼不出 briefing。
    public var resumeContext: (AskAnswer, Ask)? {
        guard let a = answeredAsk, let q = pendingAsk, a.askID == q.id else { return nil }
        return (a, q)
    }

    public init(id: String, prompt: String, repo: String) {
        self.id = id
        self.prompt = prompt
        self.repo = repo
        self.state = .queued
        self.createdAt = Date()
    }

    // 旧记录没有这两个字段。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        prompt = try c.decode(String.self, forKey: .prompt)
        repo = try c.decode(String.self, forKey: .repo)
        state = try c.decode(State.self, forKey: .state)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        profile = try c.decodeIfPresent(TaskProfile.self, forKey: .profile)
        triedPlatforms = try c.decodeIfPresent([Platform].self, forKey: .triedPlatforms) ?? []
        ownerPlatform = try c.decodeIfPresent(Platform.self, forKey: .ownerPlatform)
        ownerRunnerID = try c.decodeIfPresent(String.self, forKey: .ownerRunnerID)
        ownerAssignedAt = try c.decodeIfPresent(Date.self, forKey: .ownerAssignedAt)
        handoffCount = try c.decodeIfPresent(Int.self, forKey: .handoffCount) ?? 0
        automaticHandoffCount = try c.decodeIfPresent(Int.self,
            forKey: .automaticHandoffCount) ?? 0
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        landedAt = try c.decodeIfPresent(Date.self, forKey: .landedAt)
        discardedAt = try c.decodeIfPresent(Date.self, forKey: .discardedAt)
        discardReason = try c.decodeIfPresent(String.self, forKey: .discardReason)
        preferredPlatform = try c.decodeIfPresent(Platform.self, forKey: .preferredPlatform)
        pendingAsk = try c.decodeIfPresent(Ask.self, forKey: .pendingAsk)
        askRounds = try c.decodeIfPresent(Int.self, forKey: .askRounds) ?? 0
        handoff = try c.decodeIfPresent(Handoff.self, forKey: .handoff)
        answeredAsk = try c.decodeIfPresent(AskAnswer.self, forKey: .answeredAsk)
        // 图相关的四个字段全部 decodeIfPresent。
        //
        // 合成解码器对缺键零容忍，而**写默认值救不了它** ——
        // 缺键照样抛 keyNotFound，整条记录解不出来然后静默消失。
        // 任务记录消失意味着一个正在跑的任务凭空不见，比崩溃难查得多。
        // 这个坑在这个项目里踩过五次，不重蹈。
        graphID = try c.decodeIfPresent(String.self, forKey: .graphID)
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        stepTitle = try c.decodeIfPresent(String.self, forKey: .stepTitle)
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
        runnerPID = try c.decodeIfPresent(Int32.self, forKey: .runnerPID)
        frozenBy = try c.decodeIfPresent(String.self, forKey: .frozenBy)
        production = try c.decodeIfPresent(ProductionContext.self, forKey: .production)
        visualRemediationReviewID = try c.decodeIfPresent(
            String.self, forKey: .visualRemediationReviewID)
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex)
        interruptedCount = try c.decodeIfPresent(Int.self, forKey: .interruptedCount)
    }

    public var duration: TimeInterval? {
        guard let s = startedAt, let e = endedAt else { return nil }
        return e.timeIntervalSince(s)
    }
}

/// 任务存成 JSONL，一行一个任务的最新状态。
///
/// 没用 Hermes 的 kanban：它自带调度器会去抢着执行，而我需要的是「由额度决定派给谁」。
/// 两个调度器同时管同一批任务只会打架。Hermes 在这里只负责飞书通道。
public enum TaskStore {
    /// **写 tasks.jsonl 的进程内锁。**
    ///
    /// 2026-08-23 复审(第三轮)逮到:landingRound 挪到后台线程之后,
    /// 它(经 Review.autoLand)和主派活线程**同进程并发写 tasks.jsonl**,
    /// 而 append 是 seekToEnd + write 无锁 —— 两个线程各自 seek 到同一
    /// 偏移,第二个覆盖第一个,丢一条任务状态。丢的可能正是某个图节点的
    /// done,于是下游永远等一个不再到来的上游(「图卡住」查无原因)。
    /// verifyMerge 要同步跑整套测试,这个重叠窗口有好几分钟,不是理论风险。
    private static let writeLock = NSLock()

    public static var file: URL { Paths.appSupport.appendingPathComponent("tasks.jsonl") }

    /// 上一次 all() 里有几行没解出来。非 0 说明任务记录有损坏。
    public private(set) static var skippedLines = 0

    public static func all() -> [WorkTask] {
        skippedLines = 0
        // 走 ICloudSafe：这个文件今天在本地（appSupport 不同步、也不受 TCC 管），
        // 它认出本地路径就直接读、零开销。但**看板现在每次构建都要读它**，
        // 而看板在工作循环里每轮都构建 —— 万一哪天这条路径挪到 iCloud 下，
        // 一次不返回的 open() 就足够把整条流水线冻住，和之前那四次一模一样。
        guard let data = ICloudSafe.read(file) else { return [] }
        let dec = SnapshotCoding.decoder()
        var latest: [String: WorkTask] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let t = try? dec.decode(WorkTask.self, from: Data(line)) else {
                // **解不出来的行要计数。**
                //
                // 这个 `continue` 原来是光秃秃的，而上面那个 `skippedLines`
                // 的注释写着「上一次 all() 里有几行没解出来」—— 它永远是 0。
                // 也就是说：损坏的任务记录**静默消失**，没有任何地方会提。
                //
                // 后果不是理论上的。这个文件是 append-only 的，
                // 而写它的进程今天被杀过很多次（超时、发布重启、机器崩了十小时）。
                // 写到一半被杀就会留下半行。一条任务从此不存在，
                // 而它的下游节点会永远等一个再也不会到来的上游 ——
                // 从外面看是「图卡住了」，查不到任何原因。
                //
                // 空行不算损坏：文件末尾天然有一个。
                if !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) {
                    skippedLines += 1
                }
                continue
            }
            latest[t.id] = t   // 后写的覆盖先写的
        }
        return latest.values.sorted { $0.createdAt < $1.createdAt }
    }

    public static func append(_ task: WorkTask) throws {
        try Paths.ensureDirectories()
        var data = try SnapshotCoding.encoder().encode(task)
        data.append(UInt8(ascii: "\n"))
        writeLock.lock()
        defer { writeLock.unlock() }
        if FileManager.default.fileExists(atPath: file.path) {
            // O_APPEND:内核保证每次 write 原子追加到末尾,即便另一个
            // **进程**(worker 和菜单栏 App 都可能跑到 collect/落地)也在写。
            // 进程内的 writeLock 挡同进程多线程,O_APPEND 挡跨进程 —— 两层都要。
            let fd = open(file.path, O_WRONLY | O_APPEND)
            if fd >= 0 {
                defer { close(fd) }
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            } else {
                let fh = try FileHandle(forWritingTo: file)
                try fh.seekToEnd(); try fh.write(contentsOf: data); try fh.close()
            }
        } else {
            try data.write(to: file)
        }
    }

    /// 下一个该跑的任务。
    ///
    /// 不是「第一个 queued」而是「第一个**就绪**的 queued」：
    /// 图里的节点要等上游做完。没有图的任务 dependsOn 为空，
    /// 判定自然退化成今天的行为 —— 这条很要紧，
    /// 绝大多数任务仍然走完全一样的路，图那套东西一旦有 bug，
    /// 爆炸半径被限制在少数任务上。
    public static func nextQueued() -> WorkTask? {
        TaskGraph.nextReady(all())
    }

    /// 所有**就绪**的排队任务（图内依赖已满足的才算），按队列顺序。
    ///
    /// 给调度循环用：队头没人能接时接着试下一个 ——
    /// 修「队头阻塞」用（一个没人能接的任务堵死整条队，
    /// 排在后面的媒体任务明明 MiniMax 闲着也轮不到）。
    public static func readyQueue() -> [WorkTask] {
        var out: [WorkTask] = []
        var pool = all()
        // nextReady 每次给一个；把它临时标记成非 queued 再要下一个，
        // 复用图依赖判定逻辑而不是在这里重写一遍。
        while let t = TaskGraph.nextReady(pool), out.count < 32 {
            out.append(t)
            for i in pool.indices where pool[i].id == t.id {
                pool[i].state = .running
            }
        }
        return out
    }
}

// MARK: - 调度

/// 挑一个平台来跑这个任务。
///
/// 当前的目标函数很朴素，因为现在只值得朴素：真实上限大多还没确认，
/// 复杂的评分在没有 limit 的情况下会退化成常数。所以先做对两件事 ——
/// **排除跑不了的**，**在能跑的里面挑最闲的**。
public struct WorkScheduler: Sendable {
    /// 没给平台单独配留白时用的那个数。
    ///
    /// 提成常量是因为它有第二个读者：看板要把**生效值**发给手机
    /// （`AgentRoles.published`），而那条路径上没有 scheduler 实例。
    /// 在那边另写一个 0.25 的话，改这里就会改出「手机上显示 30%、
    /// Mac 上实际按 25% 拦」——两个数都不报错，只是不一致。
    public static let defaultHumanReserve: Double = 0.25

    /// 给人类留出的额度比例。调度器不能把额度吃光让你自己没得用。
    ///
    /// 这条不是可选项：实测确认 `claude -p` 仍然计入订阅额度
    /// （Anthropic 那个独立信用池在 2026-06-15 被暂停了），
    /// 也就是说调度器和你抢的是同一份配额。
    public var humanReserve: Double = WorkScheduler.defaultHumanReserve

    /// 人停手多久之后才允许调度插进来。
    ///
    /// 短了会在人思考的间隙插进来（改一行代码想两分钟很正常），
    /// 长了则整个工作日都不敢派活。20 分钟是「他大概真的走开了」。
    public var humanIdleGrace: TimeInterval = 20 * 60

    public init(humanReserve: Double = WorkScheduler.defaultHumanReserve,
                humanIdleGrace: TimeInterval = 20 * 60) {
        self.humanReserve = humanReserve
        self.humanIdleGrace = humanIdleGrace
    }

    public struct Pick: Sendable {
        public var platform: Platform
        public var runner: AgentRunner
        public var reason: String
    }

    public struct Rejection: Sendable {
        /// 这个「不行」是等一等就好，还是等多久都没用。
        ///
        /// 分不开的代价实测过：一个改到高危路径的任务，所有平台的角色上限
        /// 都够不着它，于是每 5 分钟重试一次、永远派不出去；
        /// 而储备池又因为「队列里还有任务在排」拒绝生成新活 ——
        /// **一个永远跑不了的任务把整条流水线堵死了**，
        /// 表现是几个平台的额度眼看着过期作废。
        ///
        /// 而日志里那句「等冷却过去」是彻头彻尾的误导：没有冷却，
        /// 等下去也不会变。
        public enum Kind: Sendable {
            /// 冷却中、额度耗尽、还没采到用量 —— 时间能解决。
            case temporary
            /// 风险/复杂度超出角色上限、没装、改不了文件、被静音 ——
            /// 时间解决不了，要么改配置，要么人来处理。
            case permanent
        }
        public var platform: Platform
        public var reason: String
        public var kind: Kind = .temporary
    }

    public struct Decision: Sendable {
        /// 按额度充裕度排好序的候选，不是只给一个。
        ///
        /// 只给一个的话，那个平台认证过期或环境坏掉，整个任务就失败了 ——
        /// 而其他平台明明是好的。这直接违背「充分利用所有平台」。
        public var candidates: [Pick]
        public var rejected: [Rejection]
        /// 本机的指挥（控制面）。**它不参与竞选，也不算被拒绝。**
        ///
        /// 单独记一条而不是塞进 rejected，有两个理由：
        ///
        /// - 死锁判定看的是「所有候选都被永久性拒绝」。指挥混进去会让判定
        ///   看起来像「连 Claude 都接不了」，而真相是「Claude 压根没被问」。
        /// - 但也不能就这么藏了：一个高危任务转人工时，
        ///   「这台机器上唯一够得着它的角色被指定去做别的事了」
        ///   恰恰是最该让人看见的那条信息。
        public var dispatcher: Platform?
        public var pick: Pick? { candidates.first }
    }

    /// - Parameter requiresEditing: 这次派的活需不需要改文件。
    ///   编码任务要 true；分类、总结这类纯推理传 false ——
    ///   否则只能生成文本的执行器（MiniMax）会被一并排除，
    ///   而它恰恰是额度最富余、最该承担这类小活的那个。
    public func decide(
        dashboard: Dashboard, runners: [AgentRunner], now: Date = Date(),
        task: WorkTask? = nil, history: [WorkTask] = [],
        requiresEditing: Bool = true
    ) -> Decision {
        var rejected: [Rejection] = []
        var dispatcherPlatform: Platform?
        var candidates: [(Pick, Double)] = []
        let cooling = CooldownLedger.active(now: now)

        let isMediaTask = TaskKind.isMedia(task?.prompt ?? "")
        let isReviewTask = TaskKind.isReview(task?.prompt ?? "")
        let needsEyes = TaskKind.needsEyes(task?.prompt ?? "")
        for runner in runners {
            let p = runner.platform

            // **媒体任务和编码任务是两个世界，方向都要闸。**
            //
            // 编码任务派给媒体执行器必然产出垃圾（它只会调 mmx 生成资产）；
            // 媒体任务派给编码执行器则白跑一轮 —— agent 会试图「写代码生成图片」。
            // 以【媒体】开头的任务只给 mediaOnly 执行器，反之亦然。
            // 【看效果】也归媒体执行器 —— 它要的是「看图/看录屏」这个本事,
            // 和生成媒体是同一个多模态模型,只是方向反过来。
            if runner.mediaOnly != (isMediaTask || needsEyes) {
                rejected.append(Rejection(
                    platform: p,
                    reason: runner.mediaOnly ? "只接【媒体】任务" : "媒体任务要媒体执行器",
                    kind: .permanent))
                continue
            }

            // 审查/测试分析是 MiniMax 的固定岗位，双向隔离：
            // - 评审执行器不接编码；
            // - 开发执行器也不接评审。
            // 以前第二条故意留了兜底，结果 MiniMax 暂时不可用时会偷偷烧
            // Claude/Kimi 的额度。现在宁可排队等 MiniMax 恢复，也不跨岗。
            // 【看效果】在上面的媒体闸单独处理，不走这里。
            if !needsEyes, runner.reviewOnly != isReviewTask {
                rejected.append(Rejection(
                    platform: p,
                    reason: runner.reviewOnly ? "只接【评审/测试】任务"
                        : "评审/测试固定交给 MiniMax",
                    kind: .permanent))
                continue
            }

            // **看不见图就别评判图。** 任务点名要看录屏/截图（【看效果】前缀）
            // 时，只有多模态平台能接。opencode 那条线是 GLM，纯文本 ——
            // 它对着文件名硬编一份「看起来没问题」的报告，比不派更糟。
            if needsEyes, !runner.canSeeMedia {
                rejected.append(Rejection(
                    platform: p, reason: "看不了图片/录屏（纯文本模型）",
                    kind: .permanent))
                continue
            }

            // 接力时别转回已经失败过的平台 —— 它刚在同一个任务上栽过。
            if let task, task.triedPlatforms.contains(p),
               !(task.ownerRunnerID == runner.runnerID && task.ownerPlatform == p) {
                rejected.append(Rejection(platform: p, reason: "本任务已在该平台失败过", kind: .permanent))
                continue
            }

            // 能力不够就别派。派了也是白烧一轮额度，还占着执行槽。
            // 风险闸门。分诊器一直在判 safe/normal/sensitive，
            // 而这里以前**一次都没用过**它 —— 一个要改构建配置、CI、权限位的
            // 任务可以被派给任何平台，包括有已知失控重试问题的那个。
            // 改砸一句注释和改砸 launchd plist，代价差得很远。
            if let risk = task?.profile?.risk, !AgentRoles.accepts(risk, platform: p) {
                let role = AgentRoles.role(for: p)
                rejected.append(Rejection(
                    platform: p,
                    reason: "任务风险是\(risk.displayName)，"
                        + "而\(role.title)最多只接\(role.maxRisk.displayName)的活",
                    kind: .permanent))
                continue
            }

            if let tier = task?.profile?.tier {
                // 角色里手填的上限优先。学习器只会往上长 ——
                // 它不知道「这个平台我就是不想让它干这么难的活」。
                let capable = AgentRoles.role(for: p).maxTier
                    ?? PlatformCapability.effectiveTier(for: p, history: history)
                if capable < tier {
                    rejected.append(Rejection(
                        platform: p,
                        reason: "任务是\(tier.displayName)档，该平台目前只被验证到\(capable.displayName)档",
                        kind: .permanent))
                    continue
                }
            }
            // 冷却优先于一切判断：撞过的墙不再撞。
            // 这是唯一对「上限数值查不到」的平台也有效的避让手段。
            if let cd = cooling[p] {
                rejected.append(Rejection(
                    platform: p,
                    reason: "\(cd.cause.displayName)，\(Format.duration(cd.remaining))后重试"
                        + "（连续第 \(cd.strikes) 次）"))
                continue
            }
            guard runner.isAvailable else {
                rejected.append(Rejection(platform: p, reason: "\(runner.binaryName) 没装或不可执行", kind: .permanent))
                continue
            }
            // 编码任务必须能改文件。纯文本生成的执行器派过去必然零改动。
            guard !requiresEditing || runner.canEdit else {
                rejected.append(Rejection(
                    platform: p, reason: "\(runner.binaryName) 只能生成文本，改不了文件",
                    kind: .permanent))
                continue
            }
            // 这台机器上把它留给别的用途了。
            //
            // 比这个更细的自动判断（「人最近在不在用」）也有，见下面一条。
            // 但静音是**常驻策略**，不是猜：比如这台 Mac 的 Claude 是控制面，
            // 派活给它等于饿死那个决定「该干什么」的环节。
            // **指挥不进候选枚举。** 它不是「接不了」，它是发活的那个。
            // 记在 Decision.dispatcher 上，诊断里单独一行。
            if AgentRoles.isDispatcher(p) {
                dispatcherPlatform = p
                continue
            }

            if AgentRoles.isMuted(p) {
                rejected.append(Rejection(
                    platform: p,
                    reason: "在 \(Paths.machineName()) 上被静音了"
                        + (AgentRoles.role(for: p).muteReason.map { "：" + $0 } ?? ""),
                    kind: .permanent))
                continue
            }

            guard let report = dashboard.reports.first(where: { $0.platform == p }) else {
                rejected.append(Rejection(platform: p, reason: "没有这个平台的用量数据"))
                continue
            }

            // 用尽 = 硬排除。「预计超额」（atRisk）不再一票否决 ——
            // 它是把突发烧速外推成整周常态的**预测**，实测把只用了 27% 的
            // Codex 拦在场外整晚，而真正的契约是留白线（实际用量）。
            // 现在：实际用量还没碰调度停手线就放行，外推只作参考；
            // 真到线了自有 reserve 闸拦（下面那道）。
            // advisory 的不算 —— MiniMax 的视频额度用光了，不代表
            // 跑不了文本任务。不排除的话，「今天生了 3 张图」就会把
            // 整个平台拦在场外，而它还是本机的分诊器。
            if let bad = report.statuses.first(where: {
                $0.health == .exhausted && !$0.advisory
            }) {
                rejected.append(Rejection(
                    platform: p,
                    reason: "\(bad.label)额度\(bad.health.displayName)"
                        + (bad.timeToReset.map { "，\(Format.duration($0))后重置" } ?? "")))
                continue
            }

            // 人正在用它 —— 让开。
            //
            // 5 小时窗口是账号级的：人和调度器烧的是同一份。人在敲代码的
            // 时候后台再插一个 agent 进去，等于直接从他碗里抢，
            // 而且他会先撞到限流。
            //
            // 实测过这不是假想：某个时刻 Claude 上最近 6 小时人工 1271 次、
            // 机器 6 次 —— 人一直在用，而调度那时候完全不知道。
            //
            // 判据是「最近还有交互式用量」。20 分钟没动静就认为他停了 ——
            // 短了会在人思考的间隙插进来（改一行想两分钟很正常），
            // 长了则整个工作日都不敢派活。
            // **只看本机**。跨机聚合的那个用在这里会让另一台机器上
            // 完全空闲的 agent 跟着一起闲置 —— 实测就是这么把用户
            // 唯一可用的那台机器给锁死的。
            // **别把调度器自己的用量当成人的。**
            //
            // 实测：Qwen 的适配器建 UsageEvent 时没传 lane，于是取了保守默认值
            // `interactive` —— 调度器刚跑完一个 Qwen 任务，
            // 那笔用量转头就被认成「人在用」，于是同一个平台被自己挡 20 分钟。
            // 在 Kimi 耗尽、Claude 是指挥、火山档次不够的情况下，等于自锁。
            //
            // 修法不是去猜各家日志格式（每家字段都不一样，而且会改版），
            // 而是用**我们自己拥有的事实**：调度器知道它什么时候、在哪个平台
            // 跑过活。落在自己那段执行窗口里的「人类活动」，一律不算。
            let last = report.lastHumanActivityHere.flatMap { t -> Date? in
                let ranByUs = history.contains { h in
                    h.platform == p
                        && (h.startedAt.map { $0 <= t } ?? false)
                        && ((h.endedAt ?? now).addingTimeInterval(60) >= t)
                }
                return ranByUs ? nil : t
            }
            if let last, now.timeIntervalSince(last) < humanIdleGrace {
                rejected.append(Rejection(
                    platform: p,
                    reason: "你 \(Int(now.timeIntervalSince(last) / 60)) 分钟前还在用它，先让着你"))
                continue
            }

            // 配了上限的额度里，剩余最少的那条决定这个平台还能不能接活。
            //
            // **advisory 的不算。** MiniMax 的视频额度天天打满（生图就是
            // 在用它），拿它当「剩余最少的那条」，整个平台就永远够不着 ——
            // 实测评审任务因此一直派不出去，而评审根本不消耗视频额度。
            let configured = report.statuses.compactMap { s -> (QuotaStatus, Double)? in
                guard !s.advisory, let f = s.usedFraction else { return nil }
                return (s, f)
            }
            if let tightest = configured.max(by: { $0.1 < $1.1 }) {
                let headroom = 1 - tightest.1
                // 留白比例按平台取，没配才用全局默认。
                // MiniMax 那份额度你还要拿去生图，吃光了自己没得用；
                // 而 Qwen 的日额度不用即作废，留白反而是浪费。
                let reserve = AgentRoles.reserve(for: p, default: humanReserve)
                guard headroom > reserve else {
                    rejected.append(Rejection(
                        platform: p,
                        reason: "\(tightest.0.label)已用 \(Format.percent(tightest.1))"
                            + "，剩余不足为它预留的 \(Format.percent(reserve))"))
                    continue
                }
                let pin = pinBonus(platform: p, task: task)
                candidates.append((Pick(
                    platform: p, runner: runner,
                    reason: (pin > 0 ? "点名优先；" : "")
                        + "\(tightest.0.label)已用 \(Format.percent(tightest.1))"
                        + "，剩 \(Format.percent(headroom))，是当前最闲的"
                ), headroom + pin
                    + overkillPenalty(platform: p, task: task, history: history)
                    + rolePreferenceBonus(platform: p, task: task)
                    + stickinessBonus(platform: p, task: task, history: history)))
            } else {
                // 一条上限都没配。不能因此排除它 —— 那是默认状态，
                // 排除的话调度器一个平台都挑不出来。给个中性分，排在有数据的后面。
                let pin = pinBonus(platform: p, task: task)
                candidates.append((Pick(
                    platform: p, runner: runner,
                    reason: (pin > 0 ? "点名优先；" : "")
                        + "未配额度上限，按中性优先级参与调度"
                ), 0.5 + pin
                    + overkillPenalty(platform: p, task: task, history: history)
                    + stickinessBonus(platform: p, task: task, history: history)))
            }
        }

        var ordered = candidates.sorted { $0.1 > $1.1 }.map(\.0)

        // **高危无人接时，指挥亲自上。**
        //
        // 角色规则里高危只有架构师（Claude）能接，而本机 Claude 是指挥、
        // 不参与竞选 —— 于是每个高危任务都「没有平台能接」，转人工。
        // 更糟的是储备池还自动生成碰构建脚本的维护任务：
        // 系统自己制造它自己干不了的活，然后堆给人。实测一次堆了 5 个，
        // 用户的原话是「不是 auto 模式，为啥有这么多需要我确认的」。
        //
        // 指挥不竞选的本意是保住控制面的额度，不是让高危活饿死 ——
        // 高危任务本来稀少，兜底不动摇那个初衷。
        // 兜底同样过角色的风险闸：指挥自己的 maxRisk 也够不着时，
        // 该转人工就转人工，不能因为「总得有人干」硬塞。
        if ordered.isEmpty,
           task?.profile?.risk == .sensitive,
           let dp = dispatcherPlatform,
           AgentRoles.accepts(.sensitive, platform: dp),
           let dr = runners.first(where: { $0.platform == dp && $0.canEdit && !$0.mediaOnly }) {
            ordered.append(Pick(platform: dp, runner: dr,
                reason: "高危只有架构师能接，其余角色都够不着 —— 指挥兼任"))
        }
        return Decision(candidates: ordered, rejected: rejected,
                        dispatcher: dispatcherPlatform)
    }

    /// 点名(`--platform` / `preferredPlatform`)的平台优先。
    ///
    /// ## 这条对应的真实失效(2026-08-20)
    ///
    /// 这个字段有**五处写入**(work add/手机/证据/刷新/拆图继承)、
    /// 调度端**零处读取** —— 和当天早上「审核结论写了没人读」一模一样的
    /// 形状:两侧各自正确,字段本身是死的。上线以来点名从没生效过,
    /// 实锤是 `--platform volcark` 的零碎活被 Kimi 抢走
    /// (e4e35d32,首选理由里点名只字未提),老板「烧掉快到期的 opencode
    /// 套餐」的指令因此落空。
    ///
    /// +1.0 盖过额度余量(0..1)和所有软加分(粘性 0.12 等):
    /// 点名的只要**活着**就赢。硬闸(用尽/静音/没装/角色上限/媒体向)
    /// 都在打分之前,点名压不倒它们 —— **优先仍然不是命令**。
    func pinBonus(platform: Platform, task: WorkTask?) -> Double {
        task?.preferredPlatform == platform ? 1.0 : 0
    }

    /// 上次干过这个仓库的人优先。
    ///
    /// ## 为什么值得给分
    ///
    /// 换人的真实代价不是切换本身，是**重新认识这个项目**：
    /// 新 agent 要把相关代码重读一遍才敢动手，而那部分探索烧的额度
    /// 不产生任何产出。同一个人接着做，至少在它自己的会话缓存和
    /// 「刚看过这块代码」的记忆还热的时候，省下的是实打实的。
    ///
    /// ## 为什么是加分而不是硬绑定
    ///
    /// 硬绑定会让一个仓库永远只由一个平台做 —— 那个平台额度耗尽时，
    /// 整个仓库就停摆了。而这套系统存在的理由恰恰是「谁有额度谁上」。
    /// 所以只给一点倾斜：额度相当时优先老人，额度差得多时该换还是换。
    ///
    /// 0.12 这个量级是刻意调小的：它大约相当于 12% 的额度余量差距，
    /// 能在「都还宽裕」时决定人选，但拦不住「一个快满了、一个空着」。
    ///
    /// 只看最近 24 小时：更早的记忆早就凉了，给分等于凭空偏袒。
    func stickinessBonus(platform: Platform, task: WorkTask?,
                         history: [WorkTask], now: Date = Date()) -> Double {
        guard let task else { return 0 }
        let recent = history.filter {
            $0.platform == platform
                && $0.repo == task.repo
                && $0.id != task.id
                && ($0.endedAt ?? $0.createdAt) > now.addingTimeInterval(-24 * 3600)
        }
        // 只认**干成过**的：失败的那次说明它在这个仓库上不顺，
        // 再优先给它等于把同一堵墙撞第二遍。
        return recent.contains { $0.state == .done } ? 0.12 : 0
    }

    /// 用强平台干简单活要扣分。
    ///
    /// 不扣的话简单任务永远抢走 Claude —— 而 Claude 是唯一能吃复杂任务的，
    /// 把它耗在改文档上，真正需要它的任务就得排队或降级。
    /// 扣的是排序分不是硬排除：所有平台都忙时，强平台照样顶上。
    /// 角色偏好的加分。
    ///
    /// **只加分，不排除。** 硬约束会在别人都不可用时把队列卡死：
    /// 你标了「文档活只给 Qwen」，Qwen 一进冷却，所有文档任务就全停了。
    /// 加分让偏好在有得选时生效，没得选时自动让路。
    private func rolePreferenceBonus(platform: Platform, task: WorkTask?) -> Double {
        var bonus = 0.0
        if let tier = task?.profile?.tier,
           AgentRoles.role(for: platform).prefers.contains(tier) { bonus += 0.2 }
        // 你在办公室里点的名。
        //
        // 加的是**分**不是豁免权 —— 它排在所有排除逻辑之后，所以点名一个
        // 接不了这活的人（比如把高危交给只接低危的），他照样进不了候选，
        // 只是别人会顶上。手机上点一下就能绕开刚定的规则，那规则就白定了。
        //
        // 分给得足够大（10）是为了压过额度余量：你既然点了名，
        // 就是明确要他干，而不是「在他和另一个之间看谁更闲」。
        if task?.preferredPlatform == platform { bonus += 10 }
        return bonus
    }

    private func overkillPenalty(
        platform: Platform, task: WorkTask?, history: [WorkTask]
    ) -> Double {
        guard let need = task?.profile?.tier else { return 0 }
        let capable = PlatformCapability.effectiveTier(for: platform, history: history)
        let gap = Double(capable.rankValue - need.rankValue)
        return gap > 0 ? -0.15 * gap : 0
    }
}

// MARK: - 执行器

public enum SessionSupport: String, Codable, Sendable {
    case none
    /// 只能恢复当前工作目录最近一次会话，例如 Qwen `-c`。
    case projectLatest
    /// 可以显式创建/恢复指定 ID，例如 Claude。
    case stableID
    /// 首轮必须 fresh，CLI 在真实输出里报告 ID，后续才能精确恢复，例如 ZCode。
    case reportedID
}

public protocol AgentRunner: Sendable {
    var platform: Platform { get }
    /// 稳定代码身份，不随展示名变化。
    var runnerID: String { get }
    var sessionSupport: SessionSupport { get }
    var binaryName: String { get }
    /// 这个执行器在本机的可执行文件(或脚本)在哪;不可用返回 nil。
    ///
    /// **必须写在协议里,不能只留在扩展里。** 只在扩展里的话,通过 `any AgentRunner`
    /// 调 `isAvailable` 会**静态派发**到扩展的默认实现(`Proc.which(binaryName)`),
    /// 各执行器自己那套判断永远不会被调用 —— ZcodeRunner 从加进来那天起就是这样:
    /// 它精心判了「脚本在不在」,而调度问的却是「zcode 在不在 PATH 上」(ZCode 是
    /// .app 里的脚本,永远不在 PATH),于是 GLM 一条活都派不出去,而日志只说
    /// 「zcode 没装或不可执行」—— 装了的人怎么查都查不出来(2026-08-23 实锤,
    /// 老板连问三次「ZCode 没在移动端展示」)。
    var binaryPath: String? { get }
    /// 能不能改文件、跑命令。
    ///
    /// 纯文本生成型的 CLI（比如 mmx text chat）只能进出文本，
    /// 派编码任务给它必然产出零改动。这个标志让调度器提前排除它，
    /// 而不是白跑一轮才发现。
    var canEdit: Bool { get }
    /// 只接【媒体】任务（生成图片/音乐）。**必须在协议里声明**：
    /// 只写在扩展里的话，通过存在类型调用永远走扩展默认值，
    /// 子类型的覆盖静默失效 —— 方向闸就是这么被测试抓出来没生效的。
    var mediaOnly: Bool { get }
    /// 只接【评审】任务（方案评审、项目验收）。
    ///
    /// 和 mediaOnly 一样是闸：编码任务派给评审执行器必然产出垃圾 ——
    /// 它只会写报告。而评审恰恰是 MiniMax 唯一能干好的那类活：
    /// 不用改代码、不用跑命令，材料给全就是纯推理。
    ///
    /// **这一行以前漏了，闸从来没关上过。**
    ///
    /// 上面 `mediaOnly` 的注释已经把这个坑写得清清楚楚 ——「必须在协议里
    /// 声明，只写在扩展里的话，通过存在类型调用永远走扩展默认值，
    /// 子类型的覆盖静默失效」—— 而 `reviewOnly` 自己正好踩了它：
    /// 注释写了，声明没写。`MiniMaxReviewRunner` 里的 `{ true }`
    /// 从来没被读到过，`runner.reviewOnly` 恒为 false。
    ///
    /// 代价（2026-08-18 盘点）：**12 个非评审任务被派给了评审执行器**，
    /// 而它把任何提示词都当评审处理。最典型的一次 ——
    /// 「把 Maw 里的临时调试入口清干净」，20 秒写了一份
    /// `reviews/EVAL-项目-*.md` 就报「完成」，一行调试代码都没删；
    /// 任务状态 done、有提交、有分支，外面看一切正常。
    /// 那批一直合不进去的 EVAL-*.md 分支，大半就是这么来的。
    var reviewOnly: Bool { get }

    /// **看得见图片和录屏吗。**
    ///
    /// 老板 2026-08-22 指出：审查员岗位上的 opencode 走的是 GLM，
    /// **纯文本模型**——让它评审录屏/截图等于让瞎子看画，
    /// 而它给出的结论会被当成正式否决记进名单。
    /// MiniMax（mmx）的本事里就有图片/视频理解，这类活该走它。
    ///
    /// 默认 false：宁可漏派，也不要让看不见的平台去评判看得见的东西。
    var canSeeMedia: Bool { get }

    /// 无头执行。cwd 是独立 worktree，不是用户的工作区。
    func command(prompt: String, cwd: String) -> (launchPath: String, args: [String], env: [String: String])

    /// 带会话延续的版本。默认实现忽略 session —— 不支持的执行器不用改。
    func command(prompt: String, cwd: String, session: GraphSession.Mode)
        -> (launchPath: String, args: [String], env: [String: String])

    /// 只有 `.reportedID` 执行器覆盖；不得从提示词或自造随机值猜会话 ID。
    func discoveredSessionID(from output: String) -> String?
}

public extension AgentRunner {
    /// 测试替身和外部扩展的兼容默认值。产品内置执行器必须显式声明稳定 ID；
    /// 默认值只保证旧 conformer 不因协议扩展而源码不兼容。
    var runnerID: String { "legacy.\(platform.rawValue).\(String(reflecting: Self.self))" }

    /// 默认忽略会话延续。**只有真支持的执行器才覆盖它** ——
    /// 给一个不认识 --resume 的 CLI 塞这个参数，它会直接报参数错误，
    /// 而那看起来像任务失败。
    func command(prompt: String, cwd: String, session: GraphSession.Mode)
        -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd)
    }

    /// 绝大多数执行器都是能改文件的编码 agent。
    var canEdit: Bool { true }
    var sessionSupport: SessionSupport { .none }
    /// 只接【媒体】任务的执行器（生成图片/音乐这类）。
    /// 编码任务派给它必然产出垃圾，媒体任务派给编码执行器则白跑 ——
    /// 两个方向都要闸。
    var mediaOnly: Bool { false }
    var reviewOnly: Bool { false }
    var canSeeMedia: Bool { false }
    var binaryPath: String? { Proc.which(binaryName) }
    var isAvailable: Bool { binaryPath != nil }
    func discoveredSessionID(from output: String) -> String? { nil }
}

public struct ClaudeRunner: AgentRunner {
    public let platform: Platform = .claude
    public let runnerID = "claude.code"
    public let sessionSupport: SessionSupport = .stableID
    public let binaryName = "claude"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    /// 实测过的语义（别照文档猜）：
    ///
    ///   `--session-id <uuid>`  第一次**创建**。再用同一个会报
    ///                          「Session ID … is already in use」直接失败。
    ///   `--resume <uuid>`      恢复，上一轮的上下文还在。
    ///
    /// 所以首轮和后续用的是**两个不同的参数**，不能只记一个 id 就完事。
    public func command(
        prompt: String, cwd: String, session: GraphSession.Mode
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        var extra: [String] = []
        if let m = RunnerConfigStore.load().model(for: platform) { extra += ["--model", m] }
        switch session {
        case .fresh, .projectResume: break
        case .create(let id): extra += ["--session-id", id]
        case .resume(let id): extra += ["--resume", id]
        }
        return (
            binaryPath ?? "claude",
            [
                "-p", prompt,
                "--add-dir", cwd,
                // 无人值守必须跳过交互确认，爆炸半径靠 worktree 隔离 +
                // 只推 agent/* 分支 + 推送前扫密钥来收敛（见 SECURITY.md）。
                "--dangerously-skip-permissions",
            ] + extra,
            // 不改 CLAUDE_CONFIG_DIR。
            //
            // 一开始设了独立目录想隔离调度器的用量，结果 agent 直接报
            // "Not logged in" —— 凭据存在 Keychain 里且按配置目录隔离，
            // 换个目录就等于全新未登录状态。
            // 而且这一步本来就是多余的：调度器的用量靠 worktree 路径就能认出来
            //（见 LaneRouter），不需要靠配置目录来隔离。
            //
            // 窗口豁免：旧版 Claude CLI 碰到不认识的新模型会直接拒跑
            //（「map it in modelOverrides or update Claude Code」），
            // MacBook 上的 EAP 审查第一棒就是这么死的。这个官方开关恢复
            // 「问 API」的老行为，对认识模型的新版 CLI 无副作用。
            ["CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1"]
        )
    }
}

public struct QwenRunner: AgentRunner {
    public let platform: Platform = .qwen
    public let runnerID = "qwen.code"
    public let sessionSupport: SessionSupport = .projectLatest
    public let binaryName = "qwen"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    /// qwen 不让我们自选会话 id（`-r` 要的是它自己生成的那个），
    /// 只能用 `-c`＝「恢复**当前项目**的最近会话」。只有工作区的 affinity
    /// 记录仍指向当前任务/能力泳道时才会传入 `.projectResume`。
    public func command(
        prompt: String, cwd: String, session: GraphSession.Mode
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        var args = ["-p", prompt, "--approval-mode", "yolo"]
        switch session {
        case .projectResume, .resume: args.insert("-c", at: 0)
        case .fresh, .create: break
        }
        // 模型偏好来自账号级配置，不写死在代码里 —— 同一个 CLI 能选十几个模型，
        // 选哪个取决于买了什么档，跟代码无关。
        if let m = RunnerConfigStore.load().model(for: platform) {
            args += ["-m", m]
        }
        // --approval-mode yolo 是必需的，不是可选优化。
        //
        // 不加的话文件编辑会被审批挡住，而无头模式下没人确认，
        // 于是 agent 反复重试同一个工具调用，最后被它自己的死循环检测器中止
        //（consecutive_identical_tool_calls）—— 实测就是这么挂的。
        //
        // 这个开关在 `qwen --help` 里看不到（帮助输出是截断的），
        // 是从包里的 yargs 定义翻出来的，取值 plan/default/auto-edit/auto/yolo。
        return (binaryPath ?? "qwen", args, [:])
    }
}

public struct GeminiRunner: AgentRunner {
    public let platform: Platform = .gemini
    public let runnerID = "gemini.code"
    public let sessionSupport: SessionSupport = .projectLatest
    public let binaryName = "gemini"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    public func command(
        prompt: String, cwd: String, session: GraphSession.Mode
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        var args = ["-p", prompt, "--yolo"]
        if case .projectResume = session { args += ["--resume", "latest"] }
        // --yolo 是确认存在的开关（--approval-mode yolo 等价）。
        // 无头模式下没人点确认，不加它 agent 会卡在审批上直到超时。
        // GEMINI_CLI_TRUST_WORKSPACE：无头环境下 Gemini 拒绝在未信任目录里动手，
        // 而 worktree 每次都是新路径，永远不可能被交互式标记为信任。
        // 变量名是从包里翻出来的，报错信息里显示的是截断的。
        return (binaryPath ?? "gemini", args,
                ["GEMINI_CLI_TRUST_WORKSPACE": "true"])
    }
}

/// Kimi Code。
///
/// 它不往 PATH 里放软链，二进制在 ~/.kimi-code/bin/kimi ——
/// 一开始漏掉这个平台就是因为 `which kimi` 找不到。
///
/// `-p` 模式下不能带审批开关：`--auto` 和 `-y` 都会被拒
///（`Cannot combine --prompt with --auto/--yolo`）——
/// 说明它在无头模式下本来就自动批准，那两个开关只对交互式有意义。
/// **ZCode(智谱官方 GLM 客户端)的执行器。**
///
/// 老板 2026-08-22:「macbook 装了 zcode,以后 GLM 我主要用官方的 zcode 了」。
///
/// ## 为什么值得接
///
/// 执行器名单里**从来没有 GLM** —— 它只作为「有额度的平台」被统计,
/// 却没有任何办法派活给它。日志里那句「空窗 GLM(5 小时窗口一轮都没开,
/// 已经闲了 1 天 23 小时)」天天在喊,而额度最富余的恰恰是它。
/// 接上这个执行器是纯增产能,不占别人的份额。
///
/// ## 它不是命令行工具
///
/// ZCode 是 Electron 桌面 App(`/Applications/ZCode.app`),但包里带了一个
/// 完整的无界面 CLI:`Contents/Resources/glm/zcode.cjs`,用 node 跑。
/// 所以 `binaryName` 那套 `which` 查找对它无效 —— 覆盖 `binaryPath`,
/// 直接看那个文件在不在。**没装的机器上自然返回 nil,调度会正确地跳过**
/// (Mac mini 上就没有,MacBook 上有)。
///
/// `--prompt` 无界面执行、`--cwd` 指定工作目录、`--mode yolo` 自主干活、
/// `--resume <sess_...>` 续接会话 —— 和我们这套的需求一一对上。
public struct ZcodeRunner: AgentRunner {
    public let platform: Platform = .glm
    public let runnerID = "zcode.code"
    public let sessionSupport: SessionSupport = .reportedID
    public let binaryName = "zcode"
    public init() {}

    /// App 包里那个 CLI 脚本。装了才有,没装返回 nil。
    ///
    /// 这几个路径做成可注入,是因为「四样齐才算可用」这条规则**只能在两台机器上
    /// 各自成立一半**(mini 没装 ZCode,MacBook 装了)—— 不注入就写不出一条在两台机器上
    /// 都会红的测试,而写不出会红的测试等于没测(docs/no-faking.md 第 4 条)。
    nonisolated(unsafe) public static var pathsOverride: (script: String, cliConfig: String,
                                                          guiConfig: String, node: String?)?
    static var scriptPath: String {
        pathsOverride?.script ?? "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
    }

    /// CLI 自己的配置。**GUI 那份(`~/.zcode/v2/config.json`)它不读** ——
    /// 缺了就报 `Model config is missing`,而且**光给环境变量补不上**(实测)。
    static var cliConfigPath: String {
        pathsOverride?.cliConfig ?? (NSHomeDirectory() + "/.zcode/cli/config.json")
    }

    /// GUI 登录后写下的配置,凭据在这儿。只读、只往子进程环境里传,不落盘不打印。
    static var guiConfigPath: String {
        pathsOverride?.guiConfig ?? (NSHomeDirectory() + "/.zcode/v2/config.json")
    }

    /// 从 GUI 配置里取一个**能用**的 provider(有 baseURL 且有 apiKey)。
    /// 返回 (baseURL, apiKey)。**调用方不许把返回值写进日志或任务记录。**
    static func credentials() -> (baseURL: String, apiKey: String)? {
        guard let d = FileManager.default.contents(atPath: guiConfigPath),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let provs = obj["provider"] as? [String: Any] else { return nil }
        // 订阅套餐那几个优先(它们才带 key);顺序固定,避免每次挑到不同的 provider。
        let preferred = ["builtin:bigmodel-coding-plan", "builtin:zai-coding-plan",
                         "builtin:bigmodel-start-plan", "builtin:zai-start-plan",
                         "builtin:bigmodel", "builtin:zai"]
        let names = preferred.filter { provs[$0] != nil } + provs.keys.sorted().filter { !preferred.contains($0) }
        for name in names {
            guard let p = provs[name] as? [String: Any],
                  let o = p["options"] as? [String: Any],
                  let base = o["baseURL"] as? String, !base.isEmpty,
                  let key = o["apiKey"] as? String, !key.isEmpty else { continue }
            return (base, key)
        }
        return nil
    }

    /// node 的绝对路径。**不能靠 `/usr/bin/env node`。**
    ///
    /// 实锤(2026-08-23,老板的 MacBook):launchd/ssh 起的进程 PATH 里没有 node,
    /// `/usr/bin/env node` 直接报 `env: node: No such file or directory` ——
    /// 于是「ZCode 装了」和「ZCode 能跑」是两回事,而调度只看前者,
    /// 每次派给 GLM 的活都在这里无声地死掉。mmx 早就踩过同一个坑并改成了绝对路径,
    /// 这里当时没跟上。
    static var nodePath: String? {
        if let o = pathsOverride { return o.node }
        if let p = Proc.which("node") { return p }
        for p in ["/usr/local/bin/node", "/opt/homebrew/bin/node",
                  NSHomeDirectory() + "/.hermes/node/bin/node"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// **「装了」不等于「调得起来」。** 四样齐了才算可用:
    /// 脚本在、node 找得到、CLI 配置在、凭据读得到。少一样都返回 nil ——
    /// 假装可用的代价是每条派过来的活都白烧一次调度名额。
    public var binaryPath: String? {
        guard FileManager.default.isReadableFile(atPath: Self.scriptPath),
              Self.nodePath != nil,
              FileManager.default.isReadableFile(atPath: Self.cliConfigPath),
              Self.credentials() != nil
        else { return nil }
        return Self.scriptPath
    }

    /// 缺哪一样。给 doctor 用,让人知道该补什么(不含任何凭据内容)。
    public static func missingPieces() -> [String] {
        var out: [String] = []
        if !FileManager.default.isReadableFile(atPath: scriptPath) {
            out.append("没装 ZCode.app(\(scriptPath) 不在)")
        }
        if nodePath == nil { out.append("找不到 node(装一个,或放到 /usr/local/bin/node)") }
        if !FileManager.default.isReadableFile(atPath: cliConfigPath) {
            out.append("缺 \(cliConfigPath) —— CLI 不读 GUI 那份配置,"
                       + "里面要有 model 和 provider 的 baseURL")
        }
        if credentials() == nil { out.append("GUI 配置里没有可用凭据 —— 在 ZCode 里登录一次") }
        return out
    }

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    public func command(prompt: String, cwd: String, session: GraphSession.Mode)
        -> (launchPath: String, args: [String], env: [String: String]) {
        var args = [Self.scriptPath, "--prompt", prompt, "--cwd", cwd,
                    "--mode", "yolo", "--no-color"]
        if case .resume(let id) = session { args += ["--resume", id] }
        // 凭据走环境变量递给子进程 —— GUI 启动 CLI 时也是这么干的。
        // **只在进程内传递**:不打印、不写任务记录、不落到别的文件。
        var env: [String: String] = [:]
        if let c = Self.credentials() {
            env["ZCODE_API_KEY"] = c.apiKey
            env["ZCODE_BASE_URL"] = c.baseURL
        }
        return (Self.nodePath ?? "/usr/bin/env", args, env)
    }

    public func discoveredSessionID(from output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            let lower = line.lowercased()
            guard lower.contains("session") || lower.contains("会话") else { continue }
            guard let range = line.range(
                of: #"\bsess_[A-Za-z0-9_-]+\b"#, options: .regularExpression)
            else { continue }
            return String(line[range])
        }
        return nil
    }
}

public struct KimiRunner: AgentRunner {
    public let platform: Platform = .kimi
    public let runnerID = "kimi.code"
    public let sessionSupport: SessionSupport = .projectLatest
    public let binaryName = "kimi"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    public func command(
        prompt: String, cwd: String, session: GraphSession.Mode
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        var args = ["-p", prompt, "--add-dir", cwd]
        if case .projectResume = session { args.insert("-c", at: 0) }
        return (
            binaryPath ?? "kimi",
            args,
            [:]
        )
    }
}

/// MiniMax 的 `mmx text chat`。
///
/// 和别的执行器不同：它是**纯文本生成**，不能读写文件、不能跑命令。
/// 所以它干不了编码任务，只适合分类、总结这类纯推理的活。
/// `canEdit = false` 就是用来表达这个区别的 —— 调度器不会把编码任务派给它。
public struct MiniMaxRunner: AgentRunner {
    public let platform: Platform = .minimax
    public let runnerID = "minimax.text"
    public let binaryName = "mmx"
    public var canEdit: Bool { false }
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        (
            binaryPath ?? "mmx",
            ["text", "chat", "--message", prompt,
             "--output", "json", "--non-interactive", "--quiet"]
                + (RunnerConfigStore.load().model(for: platform).map { ["--model", $0] } ?? []),
            [:]
        )
    }
}

/// MiniMax 的媒体执行器：把任务提示词里的资产清单变成真文件。
///
/// # 为什么终于要接这条通路
///
/// MiniMax 一直只跑分诊 —— 它的编码执行器是纯文本（canEdit=false），
/// 而它真正的本事（图片/音乐/语音生成）调度器一直够不着。
/// 用户的原话：「我的 minimax 为啥一直没有调度起来？
/// 让他去生成大量的游戏图片和音乐啊」—— 额度最富余的平台闲着，
/// 正是这个工具要消灭的那种浪费。
///
/// # 任务格式（提示词里的 DSL）
///
/// 任务提示词以【媒体】开头，正文里每行一个资产：
///
///     REF  refs/hero.png                     ← 之后的 IMG 都锁这个角色
///     IMG assets/creature-stage1.png :: 深渊里的小型发光生物，青色荧光，剪影感
///     IMG assets/zone-2.png 16:9 :: 中层海域背景，体积光从上方打下
///     MUSIC assets/ambient.mp3 :: 深海环境音，缓慢，压迫感渐强
///
/// 驱动脚本逐行执行 `mmx image generate --out` / `mmx music generate
/// --instrumental --out`，全部成功才算过。产物是真文件，走正常的
/// worktree → 提交 → 审查流程 —— **进包前逐张检查角落**（AGENTS.md：
/// 模型会画出训练数据里的画师签名）这一步留给人，工具不越权。
public struct MiniMaxMediaRunner: AgentRunner {
    public let platform: Platform = .minimax
    public let runnerID = "minimax.media"
    public let binaryName = "mmx"
    public var canEdit: Bool { true }     // 它写文件（资产），这是真的编辑
    public var mediaOnly: Bool { true }
    /// mmx 的本事里就有图片/视频理解 —— 全系统唯一看得见的一个。
    public var canSeeMedia: Bool { true }
    public init() {}

    /// `【看效果】` 的文件清单是系统自己生成的，格式固定为“都在 <目录> 下”
    /// 加若干 `- 文件名`。抽成纯函数，避免视觉任务再次被媒体 DSL 当成 0 项。
    public static func visualFiles(in prompt: String) -> [String] {
        let allowed = Review.evidenceDir.standardizedFileURL.path
        var directory: String?
        var out: [String] = []
        for raw in prompt.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let a = line.range(of: "都在 "), let b = line.range(of: " 下", range: a.upperBound..<line.endIndex) {
                let candidate = URL(fileURLWithPath: String(line[a.upperBound..<b.lowerBound]))
                    .standardizedFileURL.path
                // 视觉任务会把文件发给外部模型。只允许系统自己抽取到共享
                // evidence 目录的文件，手写提示词不能借这个入口读取任意本机图片。
                directory = candidate == allowed ? candidate : nil
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            let name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            guard [".png", ".jpg", ".jpeg", ".mov", ".mp4"]
                .contains(where: lower.hasSuffix) else { continue }
            let candidate: String?
            if name.hasPrefix("/") { candidate = URL(fileURLWithPath: name).standardizedFileURL.path }
            else if let directory {
                candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                    .standardizedFileURL.path
            } else { candidate = nil }
            if let candidate,
               URL(fileURLWithPath: candidate).deletingLastPathComponent()
                .standardizedFileURL.path == allowed {
                out.append(candidate)
            }
        }
        return out
    }

    func visualReviewCommand(prompt: String, files: [String])
        -> (launchPath: String, args: [String], env: [String: String]) {
        let driver = #"""
        export PATH="${LLMQ_MMX:h}:$HOME/.hermes/node/bin:$PATH"
        run_mmx() {
          if [ -n "$LLMQ_NODE" ]; then "$LLMQ_NODE" "$LLMQ_MMX" "$@"
          else "$LLMQ_MMX" "$@"; fi
        }
        tmpd="${TMPDIR:-/tmp}/mmxeyes-$$"
        /bin/mkdir -p "$tmpd" reviews
        observations="$tmpd/observations.txt"
        : > "$observations"
        n=0
        while IFS= read -r src; do
          [ -s "$src" ] || { echo "缺少视觉证据: $src" >> "$observations"; continue; }
          case "${src:l}" in
            *.mov|*.mp4)
              frames="$tmpd/frames-$n"
              /bin/mkdir -p "$frames"
              duration="$("$LLMQ_FFPROBE" -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null)"
              secs="${duration%%.*}"
              [[ "$secs" = <-> ]] || secs=1
              (( secs < 1 )) && secs=1
              points=(0 $((secs / 2)) $((secs > 1 ? secs - 1 : 0)))
              fi=0
              for second in "${points[@]}"; do
                fi=$((fi+1))
                "$LLMQ_FFMPEG" -loglevel error -ss "$second" -i "$src" \
                  -vf "scale='min(1280,iw)':-2" -frames:v 1 "$frames/frame-$fi.jpg" || true
              done
              for image in "$frames"/*.jpg(N); do
                n=$((n+1))
                echo "\n## $src · 抽帧 $n" >> "$observations"
                run_mmx vision describe --image "$image" --prompt "$LLMQ_FRAME_PROMPT" \
                  --output text --non-interactive --quiet >> "$observations" 2>&1
              done;;
            *)
              n=$((n+1))
              echo "\n## $src" >> "$observations"
              run_mmx vision describe --image "$src" --prompt "$LLMQ_FRAME_PROMPT" \
                --output text --non-interactive --quiet >> "$observations" 2>&1;;
          esac
        done <<< "$LLMQ_VISUAL_FILES"
        [ $n -gt 0 ] || { echo "没有读到任何可看的截图/录屏"; exit 1; }
        seen="$(<"$observations")"
        ask="你是游戏视觉质量验收人。下面先给验收任务与项目质量契约，再给图片/录屏抽帧的逐帧观察。只依据真正看到的画面判断，不用文件名猜。\n\n任务与契约：\n${LLMQ_VISUAL_PROMPT[1,12000]}\n\n逐帧观察：\n${seen[1,24000]}\n\n输出 Markdown：第一行必须严格写 **结论**：达标 或 **结论**：未达标（二选一）；然后写看到了什么、违反了哪条质量契约、对应哪个画面。任一明显穿模、悬空握持、T-pose、占位资产、流程断点或画面无法证明任务目标，都只能判未达标。"
        final="$tmpd/final.md"
        run_mmx text chat --message "$ask" --output text --non-interactive --quiet > "$final"
        [ -s "$final" ] || { echo "视觉验收没有生成结论"; exit 1; }
        branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        tid="${branch##*/}"
        out="reviews/EVAL-视觉-${tid:-new}.md"
        /bin/cp "$final" "$out"
        while IFS= read -r line; do
          case "$line" in *结论*) echo "$line"; break;; esac
        done < "$out"
        echo "已逐帧查看 $n 张画面，报告：$out"
        """#
        var env = [
            "LLMQ_VISUAL_PROMPT": prompt,
            "LLMQ_FRAME_PROMPT": "只描述这张游戏画面中实际可见的内容。重点检查双手与武器接触、手腕方向、穿模/悬空、动作状态、角色材质、HUD 和明显卡顿迹象；看不到就明确说看不到，不要推测。",
            "LLMQ_VISUAL_FILES": files.joined(separator: "\n"),
            "LLMQ_FFMPEG": Proc.which("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg",
            "LLMQ_FFPROBE": Proc.which("ffprobe") ?? "/opt/homebrew/bin/ffprobe",
        ]
        if let mmx = binaryPath { env["LLMQ_MMX"] = mmx }
        if let node = Proc.which("node") { env["LLMQ_NODE"] = node }
        return ("/bin/zsh", ["-c", driver], env)
    }

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        if TaskKind.needsEyes(prompt) {
            return visualReviewCommand(prompt: prompt,
                                       files: Self.visualFiles(in: prompt))
        }
        // 驱动内联成一段 zsh：解析 DSL、逐行调 mmx、统计成败。
        // 单独装一个脚本文件的话，发布/更新就多一个会漂移的部件。
        let driver = #"""
        # 三条铁律，全是实测换来的（macOS 26 zsh）：
        # ① 解析只用 zsh 内建 —— 同一个 zsh 里 $(…|awk…) 第一次成功、
        #    之后每次 command not found。
        # ② 外部命令**不进命令替换** —— 上一版把 mmx 放进 $(…) 捕获 stderr，
        #    连它 shebang 里 `env node` 的 PATH 查找都会坏掉。
        #    错误直接重定向进临时文件，读回用 $(<file)：zsh 内建，不 exec 任何东西。
        # ③ 管道也不用 —— 截断用 zsh 的 ${var[1,300]} 切片。
        #
        # mmx 的 shebang 是 `#!/usr/bin/env node`。在 launchd 的后代进程里
        # 它连着两次死在 `env: node: No such file`，而同样的 PATH 在终端里
        # 每次都通 —— 推演三轮都对不上账。所以不再依赖 shebang：
        # Swift 侧把 node 的绝对路径解析好递进来（LLMQ_NODE），
        # 内核直接执行 node 二进制，env/PATH/zshenv 全都插不上手。
        # PATH 前置只留作 LLMQ_NODE 意外为空时的退路。
        export PATH="${LLMQ_MMX:h}:$HOME/.hermes/node/bin:$PATH"
        run_mmx() {
          if [ -n "$LLMQ_NODE" ]; then "$LLMQ_NODE" "$LLMQ_MMX" "$@"
          else "$LLMQ_MMX" "$@"; fi
        }
        echo "# PATH=$PATH"
        echo "# LLMQ_NODE=${LLMQ_NODE-} LLMQ_MMX=$LLMQ_MMX"
        ok=0; bad=0
        tmperr="${TMPDIR:-/tmp}/mmx-err-$$"
        tmpout="${TMPDIR:-/tmp}/mmx-out-$$"
        subjref=""
        video_out=""   # 视频额度一旦报「用量上限」,本轮后面的 VIDEO 全跳过,别一条条撞
        while IFS= read -r line; do
          case "$line" in
            REF\ *)
              # **角色参考图：一条 REF 管住后面所有 IMG。**
              #
              # 漫画和素材包的根本区别就在这儿：素材包每张独立，
              # 漫画要同一个角色在几十格里长得一样。纯文生图做不到 ——
              # 实测（2026-08-20）逐行带足角色词之后，发型/服装/道具
              # 能 8/8 保住，但**脸不是同一张**，读者对脸最敏感。
              #
              # mmx 本来就有 --subject-ref（type=character,image=...），
              # 只是这条 IMG 语法没把它接出来。
              #
              # `REF -` 或空 REF 清除，之后的 IMG 回到纯文生图。
              subjref="${line#REF }"
              subjref="${subjref## }"
              [ "$subjref" = "-" ] && subjref=""
              if [ -n "$subjref" ] && [ ! -s "$subjref" ]; then
                case "$subjref" in
                  http*) ;;   # URL 交给 mmx 自己取
                  *) echo "FAIL 参考图不存在: $subjref"; bad=$((bad+1)); subjref="";;
                esac
              fi
              [ -n "$subjref" ] && echo "REF  $subjref（后续 IMG 锁定同一角色）" \
                                || echo "REF  已清除，后续 IMG 走纯文生图";;
            IMG\ *)
              rest="${line#IMG }"
              spec="${rest%%::*}"; desc="${rest#*::}"
              parts=(${=spec})              # zsh 内建分词
              # **这个变量绝对不能叫 `path`。** zsh 里 `path` 是绑死
              # `PATH` 的特殊数组：`path=foo.png` 会把 PATH 直接改成
              # `foo.png`，之后所有裸命令（file、sips、awk…）全部
              # command not found —— 不报错、不退出，只是静静地全失败。
              # 上面「铁律 ①」写的「同一个 zsh 里 $(…|awk…) 第一次成功、
              # 之后每次 command not found」就是这个：第一次是在
              # 第一条 IMG 之前跑的，PATH 还在。当时只记了现象没查出根因，
              # 于是用「只用内建 + 绝对路径」绕了过去，绕了很久。
              # 2026-08-20 加 PNG 格式校验时才撞出来 —— 那段校验用了裸
              # `file`/`sips`，实测 PATH 已经是 7 个字符，校验永远走
              # 「转换失败」分支，**比不加更糟：它会谎报「校验过了但失败」**。
              dest="${parts[1]-}"; ratio="${parts[2]-}"
              [ -n "$dest" ] || { echo "FAIL 空路径: $line"; bad=$((bad+1)); continue }
              # 幂等续跑：上一轮已经生成的不重烧额度（重试保留半成品分支）。
              [ -s "$dest" ] && { echo "SKIP $dest 已存在"; ok=$((ok+1)); continue }
              /bin/mkdir -p "${dest:h}"     # :h = 目录部分，zsh 内建
              # 比例参数必须走数组展开。zsh 的 ${ratio:+--aspect-ratio "$ratio"}
              # 不做词切分，整段并成**一个**参数 —— mmx 收到
              # "--aspect-ratio 1:1"（一个词）当场打用法退出。
              # 实测：6 张带比例的图秒败、不带比例的音乐独活，就是它。
              # 比例和参考图都必须走数组展开，理由同上（整段并成一个参数会被 mmx 拒）。
              extra=()
              [ -n "$ratio" ] && extra=(--aspect-ratio "$ratio")
              [ -n "$subjref" ] && extra+=(--subject-ref "type=character,image=$subjref")
              run_mmx image generate --prompt "$desc" --out "$dest" \
                --timeout 300 "${extra[@]}" </dev/null >"$tmpout" 2>"$tmperr"
              if [ -s "$dest" ]; then
                # **后缀说是什么，里面就得真是什么。**
                #
                # 实测（2026-08-20）：mmx 会把 JPEG 数据写进 `.png` 文件。
                # 素材包买家是独立游戏开发者，他们买 PNG 就是冲着
                # **透明通道**来的 —— 拿到一个伪装成 PNG 的 JPEG，
                # 背景是白的、边缘有压缩噪点，等于这张图废了。
                # 而这件事不报错、不崩、文件也确实存在，纯靠人打开才发现。
                #
                # 转成真 PNG 只能让容器诚实，**换不回透明通道**
                #（JPEG 里本来就没有），所以必须同时喊一声让人知道。
                case "$dest" in
                  *.png)
                    case "$(/usr/bin/file -b "$dest" 2>/dev/null)" in
                      PNG*) ;;
                      *)
                        if /usr/bin/sips -s format png "$dest" --out "$dest.fix" >/dev/null 2>&1 \
                           && [ -s "$dest.fix" ]; then
                          /bin/mv "$dest.fix" "$dest"
                          echo "FIX $dest 原本不是 PNG，已转真 PNG（**无透明通道**，需要透明就得重做）"
                        else
                          /bin/rm -f "$dest.fix"
                          echo "WARN $dest 后缀 .png 但内容不是 PNG，且转换失败"
                        fi;;
                    esac;;
                esac
                echo "OK  $dest"; ok=$((ok+1))
              else
                err="$(<$tmperr) $(<$tmpout)"
                echo "FAIL $dest :: ${err[1,400]}"; bad=$((bad+1))
              fi;;
            VIDEO\ *)
              # 视频:每天只有 3 条额度,关键画面才用(老板 2026-08-20:
              # 「游戏关键的视频用 minimax 生成,质感更强」)。
              # 语法: VIDEO <相对路径> [秒数4-15] :: <画面描述>
              # 之前有 REF 生效时走图生视频(--image),让参考图动起来 ——
              # 主菜单动态背景就是拿主视觉图转的,品牌一致。
              rest="${line#VIDEO }"
              spec="${rest%%::*}"; desc="${rest#*::}"
              parts=(${=spec})
              dest="${parts[1]-}"; vsecs="${parts[2]-}"
              [ -n "$dest" ] || { echo "FAIL 空路径: $line"; bad=$((bad+1)); continue }
              [ -s "$dest" ] && { echo "SKIP $dest 已存在"; ok=$((ok+1)); continue }
              # 额度已经撞过上限:后面的视频一条都别再试。实测(2026-08-22)一条任务
              # 排了 6 条 VIDEO,第一条就「已达到 Token Plan 用量上限」,后面 5 条
              # 每条照样发请求、照样被拒,日志里六个 FAIL 看不出是同一个原因。
              [ -n "$video_out" ] && { echo "SKIP $dest 视频额度已达上限,本轮不再试(明天再派,或改 IMG)"; bad=$((bad+1)); continue }
              /bin/mkdir -p "${dest:h}"
              # 走 Hailuo 传统线,**不带 --model/--duration**。
              # 两次实测(2026-08-20/21)夹出来的现实:
              #  ① 带 --duration 不带 --model → 被拒「require MiniMax-H3」
              #  ② 带 --model MiniMax-H3 → 被拒「TokenPlan 或 Credit
              #    暂不支持 MiniMax-H3 系列模型 (2013)」—— 老板的套餐没含 H3。
              # 所以秒数参数暂时忽略(语法保留,等套餐升级即开),
              # 时长用 Hailuo 默认;参考图走传统图生视频的 --image。
              vextra=()
              [ -n "$vsecs" ] && echo "NOTE $dest 秒数 $vsecs 当前套餐不支持,用默认时长"
              [ -n "$subjref" ] && vextra+=(--image "$subjref")
              run_mmx video generate --prompt "$desc" --download "$dest" \
                "${vextra[@]}" --timeout 900 </dev/null >"$tmpout" 2>"$tmperr"
              if [ -s "$dest" ]; then
                case "$(/usr/bin/file -b "$dest" 2>/dev/null)" in
                  *"ISO Media"*|*MP4*|*mp4*) echo "OK  $dest"; ok=$((ok+1));;
                  *)
                    echo "FAIL $dest 下载到了但不是视频文件（$(/usr/bin/file -b "$dest" 2>/dev/null)）"
                    /bin/rm -f "$dest"; bad=$((bad+1));;
                esac
              else
                err="$(<"$tmperr") $(<"$tmpout")"
                echo "FAIL $dest :: ${err[1,400]}"; bad=$((bad+1))
                # MiniMax 的视频额度(每天 3 条 / 每周 21 条)打满时报「已达到 Token Plan
                # 用量上限」。记下来,本轮后面的 VIDEO 直接跳过,并在摘要里把话说明白 ——
                # 让 agent 知道是额度没了不是提示词不对,别改词重试。
                case "$err" in
                  *用量上限*|*"usage limit"*|*"quota"*|*"Quota"*|*insufficient*)
                    video_out=1
                    echo "NOTE 视频额度已达上限 —— 本轮剩余 VIDEO 全部跳过;这不是提示词问题,别改词重试,明天再派或改 IMG";;
                esac
              fi;;
            MUSIC\ *)
              rest="${line#MUSIC }"
              spec="${rest%%::*}"; desc="${rest#*::}"
              parts=(${=spec})
              dest="${parts[1]-}"
              [ -n "$dest" ] || { echo "FAIL 空路径: $line"; bad=$((bad+1)); continue }
              # 幂等续跑：上一轮已经生成的不重烧额度（重试保留半成品分支）。
              [ -s "$dest" ] && { echo "SKIP $dest 已存在"; ok=$((ok+1)); continue }
              /bin/mkdir -p "${dest:h}"
              run_mmx music generate --prompt "$desc" --instrumental \
                --out "$dest" --timeout 300 </dev/null >"$tmpout" 2>"$tmperr"
              if [ -s "$dest" ]; then
                echo "OK  $dest"; ok=$((ok+1))
              else
                err="$(<$tmperr) $(<$tmpout)"
                echo "FAIL $dest :: ${err[1,400]}"; bad=$((bad+1))
              fi;;
          esac
        done <<< "$LLMQ_MEDIA_SPEC"
        /bin/rm -f "$tmperr" "$tmpout"
        # **一条规格都没解析出来时，要说清楚为什么。**
        #
        # 原来只 echo「生成 0 个，失败 0 个」就退出 —— 人（和 agent）看到这行
        # 完全不知道是「提示词格式不对」还是「生成失败了」。
        # 实测踩过：一条用自然语言写的媒体任务（「产出：一张 1024×1024 的 PNG，
        # 放在 assets-gen/appicon.png」）一行都没匹配上，报「生成 0 个」就完事，
        # 排查时只能去读驱动源码才知道要写成 `IMAGE <路径> :: <描述>`。
        if [ "$ok" -eq 0 ] && [ "$bad" -eq 0 ]; then
          echo "提示词里一条媒体规格都没有 —— 这个执行器只认逐行的："
          echo "  REF   <参考图路径>          （之后的 IMG 锁定同一角色，REF - 清除）"
          echo "  IMG   <相对路径> [宽高比] :: <画面描述>"
          echo "  VIDEO <相对路径> :: <画面描述>（额度每天仅 3 条,关键画面才用;有 REF 时=让参考图动起来;时长走 Hailuo 默认;额度撞顶后本轮余下 VIDEO 自动跳过,别重试）"
          echo "  MUSIC <相对路径> :: <音乐描述>"
          echo "注意图片关键字是 IMG，不是 IMAGE（写错了就一行都不匹配）。"
          echo "自然语言描述它读不懂。收到的提示词开头是：${LLMQ_MEDIA_SPEC[1,120]}"
          exit 1
        fi
        echo "生成 $ok 个，失败 $bad 个"
        [ "$ok" -gt 0 ] && [ "$bad" -eq 0 ]
        """#
        return ("/bin/zsh", ["-c", driver],
                ["LLMQ_MEDIA_SPEC": prompt,
                 // mmx 也不能靠 PATH 找 —— 同一个怪癖会咬它。
                 "LLMQ_MMX": binaryPath ?? "mmx",
                 // node 在进程内解析成绝对路径（toolDirs 优先），
                 // 子进程里 shebang/env/PATH 一概不信 —— launchd 后代里
                 // 它们连着背刺两次。
                 "LLMQ_NODE": Proc.which("node") ?? ""])
    }
}

/// Codex CLI（ChatGPT 订阅）。老板钦点的游戏打磨位之一。
///
/// `exec --full-auto`：非交互 + workspace-write 沙箱自动放行 ——
/// 爆炸半径靠 worktree 隔离收敛，和其他执行器同一套约定。
/// 不用 --dangerously-bypass：它连沙箱一起关，没必要冒这个险。
public struct CodexRunner: AgentRunner {
    public let platform: Platform = .codex
    public let runnerID = "codex.code"
    public let sessionSupport: SessionSupport = .projectLatest
    public let binaryName = "codex"
    public let canEdit = true
    public init() {}

    public func command(prompt: String, cwd: String)
        -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    public func command(prompt: String, cwd: String, session: GraphSession.Mode)
        -> (launchPath: String, args: [String], env: [String: String]) {
        // 0.147 起没有 --full-auto 了（1 秒退出码 2 实测）——
        // --approve-for-me = 自动审批 + workspace-write 沙箱，同义替代。
        let args: [String]
        if case .projectResume = session {
            args = ["exec", "resume", "--last", "--approve-for-me", prompt]
        } else {
            args = ["exec", "--approve-for-me", prompt]
        }
        return (binaryPath ?? "codex", args, [:])
    }
}

public enum RunnerRegistry {
    /// 只放**本机装了独立 CLI** 的平台。
    ///
    /// MiniMax / GLM / DeepSeek / 火山 没有独立 CLI（全机器翻遍了），
    /// 它们只能靠把别的 CLI 的 BASE_URL 指过去来用 ——
    /// 那种情况下执行器仍然是 claude/qwen，只是模型和端点变了，
    /// 所以不该在这里各建一个 runner，而应该做成「同一个执行器 + 不同端点配置」。
    /// Gemini 不在列：Google 已停止支持个人版 Gemini Code Assist 的这个客户端
    ///（IneligibleTierError，要求迁移到 Antigravity）。留着只会每次调度都白试一遍。
    /// GeminiRunner 的代码保留，哪天换成 Antigravity 或企业版把它加回来即可。
    public static let all: [AgentRunner] = [
        ClaudeRunner(), QwenRunner(), KimiRunner(), CodexRunner(),
        OpenCodeRunner(), MiniMaxMediaRunner(), MiniMaxReviewRunner(),
        // 装了 ZCode 的机器才接得到 GLM 的活（binaryPath 会自己判）。
        ZcodeRunner()
    ]

    /// 能做纯推理（分类、总结）的执行器，包含改不了文件的那些。
    /// MiniMax 排第一：它的额度最富余，而分类正是"高频、单次极小"的活。
    public static let reasoning: [AgentRunner] = [
        MiniMaxRunner(), ClaudeRunner(), QwenRunner(), KimiRunner(), OpenCodeRunner()
    ]

    /// 恢复持久化 owner。先认稳定 ID；旧 ID 不认识时，只在同平台、同能力泳道
    /// 唯一命中时迁移，绝不把歧义静默猜成另一个执行器。
    public static func resolve(
        ownerRunnerID: String,
        platform: Platform,
        prompt: String,
        runners: [AgentRunner] = all
    ) -> AgentRunner? {
        if let exact = runners.first(where: { $0.runnerID == ownerRunnerID }) {
            guard exact.platform == platform,
                  TaskCapabilityLane.accepts(exact, lane: TaskCapabilityLane.classify(prompt))
            else { return nil }
            return exact
        }
        let lane = TaskCapabilityLane.classify(prompt)
        let matches = runners.filter {
            $0.platform == platform && TaskCapabilityLane.accepts($0, lane: lane)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

// MARK: - 进程

public enum Proc {
    /// 这些 CLI 装在哪。`which` 和子进程的 PATH 共用同一份清单 ——
    /// 分成两份的话，早晚会出现「找得到、跑不起来」。
    static let toolDirs = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.hermes/node/bin",
        "\(NSHomeDirectory())/.kimi-code/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// 给子进程一个能用的 PATH。
    ///
    /// ## 为什么非加不可
    ///
    /// launchd 起的进程**不继承登录 shell 的 PATH**，只有
    /// `/usr/bin:/bin:/usr/sbin:/sbin`。而这些 CLI 大多是 node 脚本，
    /// 第一行是 `#!/usr/bin/env node` —— 于是：
    ///
    ///   `which` 找得到 `~/.hermes/node/bin/mmx` 这个**文件**，
    ///   执行时却因为 PATH 里没有 node 而失败：
    ///   `env: node: No such file or directory`
    ///
    /// 「找得到但跑不起来」这个组合特别难查：手动在终端里跑一切正常，
    /// 只有 launchd 下的定时任务不行，而它的失败又被适配器吞成了空结果。
    ///
    /// 实际后果：MiniMax 的额度采集在定时任务里永远是空的，
    /// 于是报告说它「已安装，但最近 32 天没有用量」、
    /// 手机上显示「在编未上岗」，甚至列进「每月 119 元在空烧」——
    /// 而真相是这个工具一直在被用，只是采集进程跑不动它。
    /// 一条把「我读不到」说成「你没在用」的诊断，比没有诊断更糟。
    static func augmentedPATH(_ current: String?) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for d in (current?.split(separator: ":").map(String.init) ?? []) + toolDirs
        where !d.isEmpty && seen.insert(d).inserted {
            out.append(d)
        }
        for d in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where seen.insert(d).inserted {
            out.append(d)
        }
        return out.joined(separator: ":")
    }

    public static func which(_ name: String) -> String? {
        // 有些 CLI 自带安装目录、不往 PATH 里放软链（Kimi Code 就是），
        // 只靠 `which` 会漏掉可用的平台。
        for d in toolDirs {
            let c = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        let out = run("/usr/bin/which", [name], cwd: nil, env: [:], timeout: 5).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    public struct Result: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    public struct DeadlineExtension: Sendable {
        public var seconds: TimeInterval
        public var reason: String

        public init(seconds: TimeInterval, reason: String) {
            self.seconds = seconds
            self.reason = reason
        }
    }

    /// 跑一个子进程，带超时和进程组清理。
    ///
    /// 两个坑：管道不读干净会死锁（agent 输出量很大），
    /// 以及超时后只杀父进程会留下一堆孤儿子进程 —— 所以整组一起杀。
    @discardableResult
    public static func run(
        _ launchPath: String, _ args: [String],
        cwd: String?, env extraEnv: [String: String], timeout: TimeInterval,
        deadlineExtension: ((Date) -> DeadlineExtension?)? = nil
    ) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(env["PATH"])
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // stdin 必须显式给 /dev/null。
        //
        // 不给的话子进程继承调用方的 stdin，而那个 stdin 在后台/管道场景下
        // 永远不会到达 EOF，agent 就一直等输入。实测 claude -p 会打印
        // "no stdin data received in 3s" 然后带着非零退出码结束 ——
        // 表面看像认证问题，其实是它在等一个永远不来的输入。
        p.standardInput = FileHandle.nullDevice

        // 这里**没有** setpgid，子进程和调用者同一个进程组。
        //
        // 原来这个位置有一整段注释在讲「让子进程自成一个进程组」，而下面
        // 根本没有任何 setpgid —— 全文件都没有。那是个纯虚构的前提，
        // 后来超时清理照着它写了 `kill(-pid)`，于是 worker 每次超时都把
        // 自己所在的整组杀掉。**一条描述了不存在行为的注释，比没有注释更贵。**
        // 真要自成一组得走 posix_spawn + POSIX_SPAWN_SETPGROUP，
        // Foundation 的 Process 做不到。
        p.qualityOfService = .utility
        do { try p.run() } catch {
            return Result(exitCode: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }

        // 边跑边读，不然管道缓冲区满了子进程会卡死。
        let outQ = DispatchQueue(label: "proc.out")
        let errQ = DispatchQueue(label: "proc.err")
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        outQ.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        errQ.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        var deadline = Date().addingTimeInterval(timeout)
        var nextExtensionCheck = Date()
        while p.isRunning && Date() < deadline {
            let now = Date()
            if now >= nextExtensionCheck {
                nextExtensionCheck = now.addingTimeInterval(1)
                if let ext = deadlineExtension?(deadline), ext.seconds > 0 {
                    // 一次真实里程碑就是给当前会话追加一段执行租约。
                    // 不能从 `now` 重算，否则提前汇报只会被吞掉，等临近截止时
                    // 这条汇报又可能已经过了新鲜期。
                    let proposed = deadline.addingTimeInterval(ext.seconds)
                    if proposed > deadline { deadline = proposed }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning {
            timedOut = true
            // **不能 `kill(-pid)`。**
            //
            // 那句原本想「杀整个进程组，避免留下孤儿」，但有两个致命问题：
            //
            // 1. Foundation **不会**把子进程放进新的进程组，所以它继承的是
            //    调用者的组 —— `-childPid` 指向的那个组多半根本不存在，
            //    「杀掉整组」这个意图本来就落空了。
            // 2. 更要命的是 `processIdentifier` 在进程已经退出时会是 **0**，
            //    而 `kill(-0, SIGKILL)` 在 POSIX 里的含义是
            //    **杀掉调用者所在进程组的所有进程** —— worker 把自己杀了。
            //
            // 这正好解释了那串查不出原因的现象：任务跑到一半「worker 重启时
            // 它正在执行」，worker 的 launchctl 状态是 -9（被 SIGKILL），
            // 而我并没有发布。一个为了清理孤儿写的兜底，
            // 变成了每次超时就自杀一次。
            //
            // 只杀这一个子进程，而且先确认 pid 是正数。
            let pid = p.processIdentifier
            if pid > 0 { kill(pid, SIGKILL) }
            p.terminate()
        }
        p.waitUntilExit()
        // `group.wait()` 不能无限期等。
        //
        // 两个读线程等的是管道 EOF，而 EOF 要等**所有**持有写端的进程都退出。
        // 子进程如果 fork 出一个后台进程并让它继承了管道（git 的 auto-gc
        // `gc.autoDetach` 正是这么干的），子进程自己退了、EOF 也不会来 ——
        // 这一行会永久阻塞，把上面那个 timeout 参数彻底架空。
        // 超时的意义就是「无论如何都要返回」，所以这里也必须有上限：
        // 到点就关掉读端，让 read 立刻返回。
        // **无论哪条路,读端读完都要显式关掉。** 以前只在超时那条路上关,正常路上
        // 指望 Pipe 析构 —— 而 Process 持有的这对 Pipe 在常驻进程里迟迟不释放,
        // 每次调用稳定漏 2 个 fd(见上面写端那段的实锤)。
        if group.wait(timeout: .now() + 5) == .timedOut {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 2)
        } else {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }

        return Result(
            exitCode: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

// MARK: - 接力

/// 换平台时把前一个 agent 的进度交接过去。
///
/// 原先的做法是：平台 A 失败 → 删掉 worktree → 平台 B 从零开始。
/// A 已经读过的文件、已经改的代码、已经想明白的思路，全丢。
/// 一个跑了 8 分钟才超时的任务，换个平台就得再花 8 分钟重走一遍同样的路 ——
/// 这才是"浪费 token"的大头，比选错平台严重得多。
///
/// 关键设计：**不要把 diff 贴进提示词。**
/// 工作区本身就是共享状态，文件就在 B 眼前，指给它看就行。
/// 把几百行 diff 塞进提示词，既占上下文又要花钱，还不如让它自己 `git diff` 一次。
public struct Handoff: Codable, Sendable {
    public var fromPlatform: Platform
    public var reason: String
    /// 前一个 agent 动过的文件。只给路径，不给内容。
    public var touchedFiles: [String]
    /// 前一个 agent 的进度被存成了哪个提交。
    public var wipCommit: String?
    public var elapsedSeconds: Int

    // public struct 的成员逐一初始化器默认是 internal，跨模块用不了，得显式写。
    public init(
        fromPlatform: Platform, reason: String, touchedFiles: [String],
        wipCommit: String?, elapsedSeconds: Int
    ) {
        self.fromPlatform = fromPlatform
        self.reason = reason
        self.touchedFiles = touchedFiles
        self.wipCommit = wipCommit
        self.elapsedSeconds = elapsedSeconds
    }

    /// 生成给接手方的说明，追加在原任务后面。
    public func briefing() -> String {
        var s = """


        ---
        ## 接力说明（这不是新任务，是接着干）

        这个任务先前由 \(fromPlatform.displayName) 处理，中断原因：\(reason)
        它已经工作了约 \(elapsedSeconds / 60) 分钟。
        """
        if touchedFiles.isEmpty {
            s += "\n\n它还没有产生任何文件改动，你从头开始即可，但注意避开上面那个中断原因。"
        } else {
            s += """


            **它改过的文件（改动都还在当前工作区里，没有丢）：**
            \(touchedFiles.map { "- " + $0 }.joined(separator: "\n"))

            请先用 `git diff HEAD` 或直接读这几个文件，弄清楚它已经做到哪一步，
            然后**接着往下做**，不要推倒重来 —— 重做一遍等于把它花掉的额度再花一次。
            如果发现它的做法有问题，可以改，但要说明为什么。
            """
        }
        if let wipCommit {
            s += "\n\n它的中间进度已提交为 `\(wipCommit)`，可以用 `git show \(wipCommit)` 查看。"
        }
        return s
    }
}

// MARK: - git 工作区

public enum GitWorkspace {
    /// 执行 git 时一律带上这些，屏蔽仓库里可能被投毒的钩子和全局配置。见 SECURITY.md。
    static let hardening = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=",
        // **别让 git 把非 ASCII 文件名转义。**
        //
        // 默认行为下 `reviews/EVAL-合入-x.md` 会被输出成
        // `"reviews/EVAL-\345\220\210\345\205\245-x.md"` —— 带引号、
        // 八进制转义。这个字符串**不以 `.md` 结尾，以 `"` 结尾**，
        // 于是所有 `hasSuffix(".md")` 之类的判断全部失效。
        //
        // 这个坑咬过两次：第一次是 numstat 那条路（改动统计对不上），
        // 当时只在那一个调用点加了 `-c core.quotePath=false`。
        // 第二次（2026-08-19）是 Review.list 这条路 —— EVAL 报告的文件名
        // 带中文，被判成「改了人看得见的东西」，于是纯文书分支被要求
        // 走 agent 审核、永远合不进去，把整条流水线堵着。
        //
        // 放进 hardening 就没有第三次了：**任何调用点都不可能忘**。
        "-c", "core.quotePath=false",
    ]
    static let hardEnv = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    @discardableResult
    public static func git(_ args: [String], in dir: String, timeout: TimeInterval = 120) -> Proc.Result {
        Proc.run("/usr/bin/git", hardening + args, cwd: dir, env: hardEnv, timeout: timeout)
    }

    /// 这条分支在不在。
    public static func branchExists(_ branch: String, in repo: String) -> Bool {
        git(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch],
            in: repo).exitCode == 0
    }

    public static func isRepo(_ path: String) -> Bool {
        git(["rev-parse", "--git-dir"], in: path).exitCode == 0
    }

    /// 给任务开一个独立 worktree，分支名带任务 id 和平台，便于事后追溯。
    public struct Workspace {
        public var path: String
        public var branch: String
    }

    /// - Parameter graphID: 属于哪张任务图。非 nil 时**整张图共用一个
    ///   worktree 和一个分支**。
    ///
    ///   为什么不能一节点一 worktree：第二步要看得见第一步改了什么，
    ///   而这两步可能是**不同平台**干的，所以分支名里也不能带平台。
    ///
    ///   为什么这里必须小心：下面那句 `worktree remove --force` 原本是
    ///   无条件执行的（清理上次异常退出的残留）。图内第二个节点跑起来时，
    ///   那个目录里装的正是第一步的提交 —— 照原样删下去，
    ///   前一步的产出就没了，而且不会有任何报错，
    ///   表现为「第二步的 agent 说找不到第一步说的那些改动」。
    /// 一个平台在一个仓库上的固定工作区目录名。
    ///
    /// **目录固定，分支照旧一任务一条。** 这两件事以前是绑在一起的：
    /// 一任务一目录、一任务一分支，于是每个任务都要重开会话、重读仓库、
    /// 重新猜约定 —— 老板的原话是「每次重新处理任务的上下文加载和
    /// 信息丢失我觉得损耗很大」。
    ///
    /// 而复用的机制本来就有，只是被限死在一张图内部（见 graphID 那段）。
    /// 放宽到「仓库 × 平台」之后，Claude 干这个仓库永远用同一个目录、
    /// 接同一个会话，Kimi 有自己的一份，互不串味。
    ///
    /// 分支不跟着长期化：验收还是一任务一条分支，粒度不变。
    /// 目录里切分支就行 —— 会话要的是 cwd 稳定，不是分支稳定。
    static func stableKey(repo: String, platform: Platform) -> String {
        let alias = RepoRegistry.all()
            .first { NSString(string: $0.localPath).expandingTildeInPath
                        == NSString(string: repo).expandingTildeInPath }?.alias
            ?? URL(fileURLWithPath: repo).lastPathComponent
        // 目录名不能带斜杠和空格
        let safe = alias.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(safe) + "-" + platform.rawValue
    }

    public static func prepare(repo: String, taskID: String, platform: Platform,
                               graphID: String? = nil, base: String = "main") throws -> Workspace {
        // 建 worktree 不该要两分钟。缩短到 45 秒 —— 超过这个数基本就是卡住了，
        // 早点失败早点换平台，比让一个额度槽空等两分钟强。
        let timeoutUsed: TimeInterval = 45
        let key = graphID ?? stableKey(repo: repo, platform: platform)
        let branch = graphID.map { "agent/graph/\($0)" }
            ?? "agent/\(platform.rawValue)/\(taskID)"
        let root = Paths.appSupport.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(key).path

        // 图内后续节点：复用，**绝对不能删**。
        if graphID != nil, let live = existingWorkspace(taskID: key), live.branch == branch {
            // **复用之前先把主干合进来。**
            //
            // 工作区是图开跑那一刻从 HEAD 拉的；主干后来前进了它不会知道。
            // 真实翻车：Greed 的代码基线合进 main 之后，一个重试的节点仍然
            // 站在「合并前的空 main」上跑 —— agent 把活干得完全正确
            //（图标裁好、去了 alpha、也提交了），验收却报
            // 「找不到 project.yml」退出码 1。查了三轮才发现问题不在这次改动，
            // 而在它脚下那份三小时前的主干。
            //
            // 合不上（有冲突）就原样用旧基线：这一步的活可能和冲突无关，
            // 让它跑完再由人处理冲突，比在这里判死强。
            let m = git(["merge", "--no-edit", base], in: live.path, timeout: 60)
            if m.exitCode != 0 {
                _ = git(["merge", "--abort"], in: live.path)
            }
            return live
        }

        // **目录还在但要换分支：在原地切，别删了重建。**
        //
        // 这是「上下文不丢」的整个要点。删掉目录 = 会话的 cwd 没了 =
        // 下一个任务只能从零重读仓库。而 agent 的会话里装着的
        // 「这个仓库长什么样、上次踩过什么坑」正是最贵的东西。
        //
        // 切之前必须清干净：上一个任务可能留下未提交的改动或者跑挂时的
        // 半成品，checkout 会被它们挡住 —— 而那些改动如果值钱，
        // 早就该在上一个任务结束时提交了，留到现在只会污染下一个任务。
        if FileManager.default.fileExists(atPath: path),
           git(["rev-parse", "--git-dir"], in: path).exitCode == 0 {
            _ = git(["reset", "--hard"], in: path, timeout: 30)
            _ = git(["clean", "-fd"], in: path, timeout: 30)
            // 先把主干拉到脚下，再从主干开新分支 —— 否则新任务会站在
            // 上一个任务的分支上，把无关的改动一起带进来。
            _ = git(["checkout", "--detach", base], in: path, timeout: 30)
            // **分支上已有提交就绝不 `branch -f` 回 base。**
            //
            // 实锤(2026-08-22 19:53,Flint reflog):`agent/graph/1f8de767` 被
            // `branch: Reset to main`,s1–s4 的 6 个提交 / 14 个文件从分支上
            // 消失,s5 在提问里原话「分支被重置到了 main」,整张图后来只能人工
            // 丢弃重派。图任务**共用一条分支**,前面步骤的产出就在上面 ——
            // 这里的 `-f` 等于把别人干完的活抹掉。注释说「上下文丢了总比
            // 跑不起来强」,对有提交的分支是**丢产出**,不是丢上下文。
            // 规则:分支存在且领先 base ≥1 个提交 → 直接切过去复用;
            // 只有不存在/0 提交的分支才允许(重)建。
            let ahead = Int(git(["rev-list", "--count", "\(base)..\(branch)"],
                               in: path, timeout: 30).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if ahead == 0 {
                _ = git(["branch", "-f", branch, base], in: path, timeout: 30)
            }
            let co = git(["checkout", branch], in: path, timeout: 30)
            if co.exitCode == 0 {
                return Workspace(path: path, branch: branch)
            }
            // 切不过去（分支被别的 worktree 占着之类）—— 退回删了重建，
            // 慢一点但一定能用。上下文丢了总比跑不起来强。
        }

        // 残留就先清掉，避免上一次异常退出挡住这次。
        _ = git(["worktree", "remove", "--force", path], in: repo)
        try? FileManager.default.removeItem(atPath: path)

        var r = git(["worktree", "add", "-b", branch, path, "HEAD"], in: repo,
                    timeout: timeoutUsed)

        // **分支已经存在时要接着用，不能报错退出。**
        //
        // 图节点重试就会走到这里：上一次跑到一半被杀，worktree 目录没了
        // 但分支还在（里面可能还装着前面几步的提交）。
        // 这时候 `-b` 会因为重名失败 —— 而正确的动作恰恰是**接上那条分支**，
        // 不是新建一条，更不是把它删掉重来（那会丢掉前面几步）。
        if r.exitCode != 0, branchExists(branch, in: repo) {
            r = git(["worktree", "add", path, branch], in: repo, timeout: timeoutUsed)
        }

        guard r.exitCode == 0 else {
            // 把**能定位问题的东西**都带上，不只是 git 的输出。
            //
            // 实际遇到过：git 退出码非零，而 stderr 和 stdout 全是空的。
            // 只报输出的话这条错误就是「建 worktree 失败：」后面什么都没有，
            // 完全没法往下查 —— 而「进程根本没跑起来」恰恰是最需要上下文的
            // 情况：仓库在不在、是不是 git 仓库、退出码是几、分支名是不是被占了。
            // **超时是已知事实，不是猜测。**
            //
            // 原来这里写「多半是进程没起来或超时」—— 而 `r.timedOut` 就在手边。
            // 真实排查时那句猜测把人引向了环境和 PATH，
            // 而真相是 git 跑满了 120 秒被 SIGKILL（退出码 9 正是被信号杀死）。
            // 一条把已知事实说成猜测的诊断，和说谎的代价是一样的。
            var detail = r.timedOut
                ? "**超时**（跑满 \(Int(timeoutUsed)) 秒被杀，退出码 \(r.exitCode)）"
                : "退出码 \(r.exitCode)"
            let out = (r.stderr.isEmpty ? r.stdout : r.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty {
                detail += "：" + out.prefix(200)
            } else if r.timedOut {
                // 别再把「git 卡住」一律说成锁争用。
                //
                // 实测抓到过：git 100% 的采样都停在 `init_git →
                // strbuf_getcwd → open()`，连命令都还没分发，锁根本没进场；
                // 而同一条命令在交互 shell 里是 7 毫秒。这种「同一个二进制、
                // 同一个仓库，换个进程跑就永久挂起」的形状，是**路径访问被
                // 挂起**（macOS 对 ~/Documents、~/Desktop、~/Downloads 的
                // 授权闸门：拒绝会立刻返回 EPERM，而待决的同意是无限期阻塞）。
                // 先用一次带短超时的零成本探针把两者分开，再给建议。
                let probe = git(["rev-parse", "--git-dir"], in: repo, timeout: 4)
                if probe.timedOut {
                    detail += "。**连 `git rev-parse` 都卡住了**（4 秒无响应）"
                        + "—— 这个命令什么都不做、不碰任何锁，所以问题不在仓库，"
                        + "而在「这个进程访问 \(repo) 被挂起了」。"
                        + "常见原因：仓库在 ~/Documents / ~/Desktop / ~/Downloads 下，"
                        + "而跑它的是 launchd 常驻进程，没拿到这些目录的访问授权。"
                        + "两条路：把仓库挪到 ~/dev 这类不受保护的位置，"
                        + "或给 llmq 开「完全磁盘访问权限」后 "
                        + "`launchctl kickstart -k gui/$(id -u)/com.llmquotabar.worker`"
                } else {
                    detail += "。git 能正常访问这个仓库，那多半是真的有锁"
                        + "（.git/index.lock、worktrees/*/locked）或者别的 git 进程占着"
                        + " —— `git worktree prune` 和删掉残留 lock 文件能解开"
                }
            } else {
                detail += "（git 无任何输出）"
                let exists = FileManager.default.fileExists(atPath: repo)
                detail += "；仓库 \(repo) " + (exists ? "存在" : "**不存在**")
                if exists {
                    // 这里原来直接调 `isRepo(repo)`，而它走的是默认 120 秒超时。
                    // 探针自己挂住时会被当成非零退出，于是错误信息印出
                    // 「存在，但不是 git 仓库」这句假话，还白等两分钟。
                    // tasks.jsonl 里已经留下过这样一条记录。
                    // 「探测超时」和「不是仓库」必须分开说 —— 混为一谈会把人
                    // 送去修一个没坏的仓库。
                    let probe = git(["rev-parse", "--git-dir"], in: repo, timeout: 4)
                    if probe.timedOut {
                        detail += "，但探测它的时候 git 也卡住了（4 秒无响应）"
                            + "—— 不是仓库的问题，是这个进程访问该路径被挂起了"
                    } else if probe.exitCode != 0 {
                        detail += "，但不是 git 仓库"
                    }
                }
                detail += "；分支 \(branch)"
            }
            throw NSError(domain: "GitWorkspace", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "建 worktree 失败：\(detail)"
            ])
        }
        return Workspace(path: path, branch: branch)
    }

    /// 这次干活到底改了多少文件。
    ///
    /// ## 为什么不能只看 `git status`
    ///
    /// **agent 会自己提交。** 实测：Qwen 跑了 587 秒，自己 `git commit` 了
    /// 2 个文件 +137 行，还跑了 `swift build` 和 279 个测试 ——
    /// 而我们数出来是 **0 个文件**，记成「跑完了但没有产生任何改动」。
    ///
    /// 后果不只是记录难看：普通任务走 `changed == 0` 那条分支会调
    /// `cleanup`，**把 worktree 和分支一起删掉** —— agent 那 587 秒的成果
    /// 就这么静默销毁了，而任务状态还是 `done`。
    /// 翻回历史，之前几条「跑完了但没有产生任何改动」很可能都是这么没的。
    ///
    /// 所以要数两部分的并集：还没提交的，加上**已经提交但还没落地的**。
    public static func changedFileCount(in dir: String, base: String = "main") -> Int {
        var files = Set<String>()

        // 没提交的
        for line in git(["status", "--porcelain"], in: dir).stdout.split(separator: "\n")
        where !line.isEmpty {
            // porcelain 格式是「XY 路径」，路径从第 4 个字符开始。
            let s = String(line)
            files.insert(String(s.dropFirst(min(3, s.count))))
        }

        // 已经提交的。用三点：比的是「相对分叉点」，
        // 不然 base 上别人的新提交会被算成这次的改动。
        let committed = git(["diff", "--name-only", "\(base)...HEAD"], in: dir)
        if committed.exitCode == 0 {
            for line in committed.stdout.split(separator: "\n") where !line.isEmpty {
                files.insert(String(line))
            }
        }
        return files.count
    }

    /// agent 自己提交了几个 commit（相对分叉点）。
    /// 用来在结果里说清楚「它自己提交了」，而不是让人以为是我们提交的。
    public static func commitsAhead(in dir: String, base: String = "main") -> Int {
        let r = git(["rev-list", "--count", "\(base)..HEAD"], in: dir)
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 这个工作区里改动过的文件名（未提交的 + 相对 base 已提交的，去重）。
    ///
    /// 给「纯文档改动跳过构建验收」用 —— 只有数量不够，得看清是哪些文件。
    public static func changedFileNames(in dir: String, base: String = "main") -> [String] {
        var names = Set<String>()
        let st = git(["status", "--porcelain"], in: dir)
        for line in st.stdout.split(separator: "\n") {
            let f = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if !f.isEmpty { names.insert(String(f.split(separator: " -> ").last ?? "")) }
        }
        let diff = git(["diff", "--name-only", "\(base)...HEAD"], in: dir)
        for line in diff.stdout.split(separator: "\n") {
            let f = line.trimmingCharacters(in: .whitespaces)
            if !f.isEmpty { names.insert(f) }
        }
        return names.sorted()
    }

    /// 当前 HEAD 的 sha。
    ///
    /// 用来在**跑 agent 之前**记一个基准。没有它就分不清
    /// 「这一轮这个 agent 干的」和「接手时就已经在那儿的」。
    ///
    /// 实测过后果：火山方舟接手一个 Qwen 十一小时前就做完的活，
    /// 自己一行没动，记录却写成「改了 1 个文件（1 个提交是 agent 自己打的）
    /// （接手 Kimi 的进度完成）」—— 文件是 Qwen 改的、提交是 Qwen 打的、
    /// Kimi 也没留下任何东西。三句话三个错。
    /// 多 agent 接力里，这种记录会让事后追溯稳定地指向错的那个 agent。
    public static func headSHA(in dir: String) -> String? {
        let r = git(["rev-parse", "HEAD"], in: dir)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.exitCode == 0 && !s.isEmpty ? s : nil
    }

    /// 推送前扫密钥。命中就拒绝提交 —— agent 可能把凭据写进代码或日志。
    /// 这次改动碰到的**高危路径**。空数组表示没碰。
    ///
    /// ## 为什么必须按实际改动判，而不是按任务描述
    ///
    /// 派活前的风险分级（`TaskProfile.Risk`）是**猜**的 —— 它读的是任务描述。
    /// 而 agent 实际改了什么，只有跑完才知道：一句「补个文档注释」完全可能
    /// 顺手动了 Package.swift。SECURITY.md 承诺的是「改到这些路径一律转人工」，
    /// 承诺的对象是**改动**，不是描述。
    ///
    /// 这道闸门之前**根本不存在**：文档里写着，代码里没有。
    /// 提交前只扫了密钥和跑了构建验证。一个「补文档」的任务改掉 CI 配置，
    /// 会一路通过所有检查直接进分支。文档承诺一道不存在的防线，
    /// 比没有这道防线更糟 —— 它让人以为已经被保护了。
    ///
    /// 名单和 SECURITY.md 第三节第 4 条逐字对应，改一处要改两处。
    public static func riskyPathsTouched(in dir: String) -> [String] {
        let out = git(["status", "--porcelain"], in: dir).stdout
        var hits: [String] = []
        for line in out.split(separator: "\n") {
            // porcelain 格式：前两列是状态，第 4 列起是路径。
            // 重命名是 "R  old -> new"，两边都要看。
            let body = line.count > 3 ? String(line.dropFirst(3)) : ""
            for path in body.components(separatedBy: " -> ") where !path.isEmpty {
                let f = path.trimmingCharacters(in: .whitespaces)
                if isRiskyPath(f) { hits.append(f) }
            }
        }
        return Array(Set(hits)).sorted()
    }

    /// 单条路径算不算高危。
    /// 提示词里有没有点名一个高危文件。
    ///
    /// ## 为什么不能只信分诊器的风险判断
    ///
    /// 实测：「给 TaskGraph.swift 补文件头注释，同时在 build-app.sh 末尾
    /// 加一行注释」被分诊器判成**低危** —— 理由是「不涉及业务逻辑或
    /// 构建行为变更」。这个理由本身没错，但落地时的高危闸看的是
    /// **实际改到的文件**，`build-app.sh` 照样被拦下，
    /// 于是整个任务因为一行注释全盘转人工。
    ///
    /// 而提示词里已经把文件名写出来了 —— 那是确定性信息，
    /// 不该让它经过一次语义判断再丢掉。有确定信息时就别去猜。
    public static func mentionsRiskyPath(_ prompt: String) -> Bool {
        let seps = CharacterSet(charactersIn: " \t\n\r，。、；：（）()「」『』\"'`《》")
        // **只削尾部的标点，别削开头。**
        // 两头都削的话 `.github/workflows/ci.yml` 会被削成
        // `github/...`，前缀匹配 `.github/` 立刻失效 —— 而点开头的
        // 正是最该护住的那批（.github/、.gitlab-ci.yml…）。
        let trailing = CharacterSet(charactersIn: ".,;:!?")
        return prompt.components(separatedBy: seps).contains { tok in
            var t = Substring(tok)
            while let last = t.unicodeScalars.last, trailing.contains(last) {
                t = t.dropLast()
            }
            guard t.contains(".") || t.contains("/") else { return false }
            return isRiskyPath(String(t))
        }
    }

    static func isRiskyPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".pbxproj") || name == "Package.swift" { return true }
        if name.hasSuffix(".sh") { return true }
        // 目录前缀。注意要匹配「以此开头」而不是「包含」——
        // 包含的话 vendor/Tools/x 也会中，那不是我们要护的东西。
        for prefix in ["Tools/", ".github/", "Scripts/", "fastlane/"] {
            if path.hasPrefix(prefix) { return true }
        }
        // 项目文件是目录形式（Xcode），单独判一次。
        if path.contains(".xcodeproj/") { return true }
        // **钱 / 账号 / 签名类也必须拦下。**
        //
        // 实锤(2026-08-23 复审):admob-units.json、entitlements.plist、
        // 独立的 .p8/.p12/.mobileprovision、非 .github/ 下的 release.yml ——
        // 这些「改错了动老板收入或账号、且不可逆」的文件,以前 isRiskyPath
        // 一概返回 false → 既不拦、也不提交前停,agent 一路提交进分支,
        // BossGate 永远没机会看到它们。而 BossGate 的测试还断言它们归老板 ——
        // 保护看着做了、单测全绿,实际到不了生产。
        //
        // 修法:isRiskyPath 必须是 BossGate.needsBoss 的**超集** ——
        // 凡是要老板拍板的,先得被这道闸拦住。测试钉死这个包含关系。
        if BossGate.needsBoss(files: [path]) { return true }
        return false
    }

    public static func scanForSecrets(in dir: String) -> [String] {
        let r = git(["diff", "--cached", "--", "."], in: dir)
        let diff = r.stdout.isEmpty ? git(["diff"], in: dir).stdout : r.stdout
        return SecurityAudit.credentialRegexes.compactMap { re -> String? in
            let range = NSRange(diff.startIndex..<diff.endIndex, in: diff)
            guard let m = re.firstMatch(in: diff, options: [], range: range) else { return nil }
            return String(diff[Range(m.range, in: diff)!].prefix(12)) + "…"
        }
    }

    /// 把中断时的进度存成一个提交，别让它随进程一起消失。
    ///
    /// 不提交的话，工作区里只是一堆未暂存的改动 —— 接手的 agent 用 `git diff` 能看到，
    /// 但一旦它自己乱改就再也回不去了。存成提交等于给接力留了个还原点。
    public static func commitWIP(in dir: String, platform: Platform, reason: String) -> String? {
        guard changedFileCount(in: dir) > 0 else { return nil }
        _ = git(["add", "-A"], in: dir)
        let r = git([
            "-c", "user.name=llmq-agent",
            "-c", "user.email=llmq-agent@localhost",
            "commit", "-m", "wip(\(platform.rawValue)): 中断于 \(reason)",
        ], in: dir)
        guard r.exitCode == 0 else { return nil }
        let rev = git(["rev-parse", "--short", "HEAD"], in: dir)
        return rev.exitCode == 0
            ? rev.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// 工作区里被动过的文件清单。
    public static func touchedFiles(in dir: String, sinceRef: String = "HEAD") -> [String] {
        // 未提交的 + 相对基线已提交的，都要算上。
        var files = Set<String>()
        for line in git(["status", "--porcelain"], in: dir).stdout.split(separator: "\n") {
            let path = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { files.insert(path) }
        }
        let diff = git(["diff", "--name-only", sinceRef], in: dir)
        for line in diff.stdout.split(separator: "\n") where !line.isEmpty {
            files.insert(String(line))
        }
        return files.sorted()
    }

    /// 接力时复用已有工作区，不重新创建。
    public static func existingWorkspace(taskID: String) -> Workspace? {
        let path = Paths.appSupport
            .appendingPathComponent("worktrees").appendingPathComponent(taskID).path
        guard FileManager.default.fileExists(atPath: path),
              isRepo(path) else { return nil }
        let r = git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)
        guard r.exitCode == 0 else { return nil }
        return Workspace(
            path: path,
            branch: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func commit(in dir: String, message: String) -> Proc.Result {
        _ = git(["add", "-A"], in: dir)
        return git([
            "-c", "user.name=llmq-agent",
            "-c", "user.email=llmq-agent@localhost",
            "commit", "-m", message,
        ], in: dir)
    }

    /// 收掉工作区。
    ///
    /// - Parameter branch: 一并删掉的分支。失败或空跑的分支上什么都没提交，
    ///   留着只会越堆越多 —— 实测跑三次就攒了 4 个垃圾分支。
    ///   只在确认没有提交时才传，成功的分支要留给用户 review。
    /// - Parameter graphFinished: 整张图都完了吗。
    ///
    ///   **中心防线。** 图内的节点共用一个 worktree，任何一个节点跑完就清理
    ///   会把整张图的进度删掉 —— 而调用点有五处（零改动、失败、人工放行…），
    ///   在每一处都记得判断是不现实的，漏一处就是静默的数据丢失。
    ///   所以判断放在这里：分支名是 `agent/graph/*` 且没说图完了，就不动它。
    public static func cleanup(repo: String, path: String, branch: String? = nil,
                               graphFinished: Bool = false) {
        let b = branch ?? existingWorkspace(taskID: URL(fileURLWithPath: path)
            .lastPathComponent)?.branch
        if !graphFinished, let b, b.hasPrefix("agent/graph/") {
            FileHandle.standardError.write(Data(
                "保留 \(b)：图还没跑完，删了会带走前面几步的提交\n".utf8))
            return
        }
        _ = git(["worktree", "remove", "--force", path], in: repo)
        if let branch {
            _ = git(["branch", "-D", branch], in: repo)
        }
    }
}

// MARK: - 失败分类

public enum FailureKind: Sendable {
    /// 平台侧问题：没登录、凭据过期、配额被拒、CLI 环境坏了。
    /// 这类应该换个平台重试 —— 任务本身没问题。
    case platformUnavailable(String)
    /// agent 真的跑了但没干成。换平台重试意义不大，而且会重复烧额度。
    case agentFailed(String)
    case timedOut

    public var shouldTryNextPlatform: Bool {
        switch self {
        case .platformUnavailable: return true
        // 超时意味着零产出，和「跑了但没干好」不一样，换个平台是值得的。
        // 但不能无脑换 —— 三个平台各超时 20 分钟就是一小时，
        // 所以调用方还要再卡一道总时间预算。
        case .timedOut: return true
        case .agentFailed: return false
        }
    }

    public var describe: String {
        switch self {
        case .platformUnavailable(let s): return s
        case .agentFailed(let s): return s
        case .timedOut: return "超时被终止"
        }
    }
}

public enum FailureClassifier {
    /// 这些字样说明是平台/凭据问题，不是任务本身的问题。
    /// 这些字样足够特异，出现即可判定是平台/凭据问题。
    ///
    /// **注意这里没有 quota / insufficient / 额度**。它们太普通了：
    /// agent 说一句 "insufficient contrast"、或者读一段额度相关的代码，
    /// 整段输出就命中 —— 实测把火山方舟和 Kimi 各误判罚下场一次。
    /// 额度类判定统一走 `CooldownLedger.classify`，那里是「同一行内
    /// 错误信号 + 额度措辞」双条件。
    static let platformMarkers = [
        "not logged in", "oauth", "authenticate", "unauthorized", "401", "403",
        "invalid api key", "no credentials", "please run /login",
        "command not found", "econnrefused", "enotfound",
    ]

    public static func classify(exitCode: Int32, stdout: String, stderr: String,
                                timedOut: Bool) -> FailureKind? {
        if timedOut { return .timedOut }
        guard exitCode != 0 else { return nil }
        let text = (stderr + "\n" + stdout).lowercased()
        let msg = (stderr.isEmpty ? stdout : stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = String(msg.suffix(200))
        if platformMarkers.contains(where: { text.contains($0) }) {
            return .platformUnavailable(brief)
        }
        // 额度类走统一的双条件判定。放在这里而不是塞进 platformMarkers，
        // 是因为它需要区分「服务端说打满了」和「agent 随口提了句 quota」——
        // 单纯的字符串包含做不到这件事。
        if CooldownLedger.classify(text) == .quotaExhausted {
            return .platformUnavailable(brief)
        }
        return .agentFailed("退出码 \(exitCode)：" + brief)
    }
}

// MARK: - 执行日志

/// 把 agent 的完整输出落盘。
///
/// 第一版只在失败时留 200 字符尾巴，结果 Qwen 跑满 20 分钟超时、worktree 零改动，
/// 完全无法判断它到底卡在哪 —— 等于每次异常都是黑盒。
/// 无人值守的东西必须留下能复盘的痕迹。
public enum RunLog {
    public static func path(taskID: String, platform: Platform) -> URL {
        Paths.appSupport
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(taskID)-\(platform.rawValue).log")
    }

    @discardableResult
    public static func write(
        taskID: String, platform: Platform, command: String,
        result: Proc.Result, elapsed: TimeInterval
    ) -> URL? {
        let url = path(taskID: taskID, platform: platform)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        # 任务 \(taskID) · \(platform.displayName)
        # 命令: \(command)
        # 退出码: \(result.exitCode)  超时: \(result.timedOut)  耗时: \(Int(elapsed))s

        ===== stdout =====
        \(result.stdout)

        ===== stderr =====
        \(result.stderr)
        """
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }
}

// MARK: - 飞书通知

/// 走 Hermes 的 `hermes send`。
///
/// 这是整套系统里唯一用到 Hermes 的地方，也是它真正不可替代的地方：
/// 飞书凭据和长连接都在网关那边，自己再实现一遍毫无意义。
public enum Notifier {
    public static func feishu(_ text: String, subject: String? = nil) -> Bool {
        guard let hermes = Proc.which("hermes") else { return false }
        var args = ["send", "-t", "feishu", "-q"]
        if let subject { args += ["-s", subject] }
        args.append(text)
        return Proc.run(hermes, args, cwd: nil, env: [:], timeout: 30).exitCode == 0
    }
}


/// 「这台机器上没人能接，但别的机器能」—— 把这句话变成一条可执行的命令。
///
/// ## 为什么值得单独做
///
/// 高危任务在这台机器上被拦下时，诊断只能说「要么放宽某个角色的上限，
/// 要么人工处理」。诚实，但没有可执行的下一步 —— 而**答案往往就在旁边那台
/// 机器上**：Mac mini 的 Claude 是指挥不接活，MacBook 上同一个 Claude
/// 却是 maxRisk 高危的架构师，它接得了，而那份额度正闲着。
///
/// 一条说了「你可以挪到别的机器」却不说怎么挪的提示，
/// 实际效果和不说差不多。
public enum Elsewhere {

    public struct Option: Sendable {
        /// 集群里的节点名（`llmq cluster dispatch` 要的那个）。
        public var node: String
        /// 人看的机器名。
        public var machine: String
        /// 那台机器上接得了这个风险等级的平台。
        public var platforms: [Platform]
    }

    /// 哪些别的机器接得了这个风险等级的活。
    ///
    /// 判据全部按**那台机器**算：角色的 maxRisk 够、在那台没被静音、
    /// 在那台不是指挥。三者都按机器名存，所以本机算得出来，
    /// 不需要去问对端 —— 而「问对端」在对端不可达时就给不出建议了，
    /// 恰恰那种时候人最需要知道该往哪儿挪。
    /// - Parameter presentOn: 每个平台在哪些机器上**真的装了**。
    ///
    ///   这个参数不能省。`AgentRoles.all()` 是「出厂默认 + 文件覆盖」的合并结果，
    ///   它对每个平台都有一条角色 —— 包括那台机器上根本没装的。
    ///   只看角色的话会建议「去 X 机器上用 Y」，而 Y 在那台上不存在，
    ///   命令跑过去直接失败。
    ///   **一条跑不通的建议比不给建议更糟**：它让人以为路已经指好了。
    ///
    ///   写这个函数时我就在注释里承诺了「别造跑不通的命令」，然后没做 ——
    ///   是测试把它照出来的。
    public static func options(
        risk: TaskProfile.Risk,
        presences: [ClusterPresence] = ClusterPresenceStore.all(),
        me: String = Paths.machineName(),
        presentOn: [Platform: Set<String>] = Elsewhere.detectedByMachine()
    ) -> [Option] {
        let roles = AgentRoles.all()
        var out: [Option] = []
        for p in presences where p.machineName != me {
            guard let node = p.nodeName, !node.isEmpty else { continue }
            let ok = roles.values.filter { r in
                risk <= r.maxRisk
                    && !r.mutedOn.contains(p.machineName)
                    && !r.dispatcherOn.contains(p.machineName)
                    && (presentOn[r.platform]?.contains(p.machineName) ?? false)
            }.map { $0.platform }.sorted { $0.rawValue < $1.rawValue }
            if !ok.isEmpty {
                out.append(Option(node: node, machine: p.machineName, platforms: ok))
            }
        }
        return out.sorted { $0.node < $1.node }
    }

    /// 从看板算出「每个平台在哪些机器上装了」。
    public static func detectedByMachine(
        dashboard: Dashboard? = nil
    ) -> [Platform: Set<String>] {
        let d = dashboard ?? LLMQuota.dashboard()
        var out: [Platform: Set<String>] = [:]
        for r in d.reports where r.detected || r.installed {
            out[r.platform] = Set(r.machines)
        }
        return out
    }

    /// 拼一句能直接照抄的话。没有可用的机器就返回 nil ——
    /// **别造一条跑不通的命令**，那比不给建议更糟。
    public static func hint(risk: TaskProfile.Risk, taskPrompt: String,
                            repoAlias: String?,
                            presences: [ClusterPresence] = ClusterPresenceStore.all(),
                            presentOn: [Platform: Set<String>]? = nil)
        -> String? {
        let present = presentOn ?? detectedByMachine()
        guard let best = options(risk: risk, presences: presences,
                                 presentOn: present).first else { return nil }
        let who = best.platforms.map { $0.displayName }.joined(separator: "、")
        let one = taskPrompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        return "这台接不了，但 \(best.machine) 上 \(who) 接得了（那份额度正闲着）："
            + "\n    llmq cluster dispatch \(best.node) \"\(one.prefix(100))\""
            + (repoAlias.map { " --repo \($0)" } ?? "")
    }
}

/// MiniMax 的**评审**执行器：代码审查、方案评审、项目验收和测试材料分析。
///
/// `mmx text chat` 没有仓库终端权限，因此 Swift/shell 驱动负责提取完整 diff、
/// 状态和测试材料，MiniMax 负责判断。测试是否通过仍以本地命令退出码为准，
/// 不让模型用一段总结冒充执行结果；测试失败后的代码修复交回实现 Agent。
///
/// # 两种任务
///
///     【评审·方案】<项目 id>    ← 批准前评审 playbook 里的方案
///     【评审·项目】<项目 id>    ← 做完之后对照方案验收
///
/// 材料由 Swift/shell 侧收集（方案正文、STATUS.md、最近提交、产出清单），
/// MiniMax 只负责判断。报告写进 `reviews/`，走正常的提交流程。
public struct MiniMaxReviewRunner: AgentRunner {
    public let platform: Platform = .minimax
    public let runnerID = "minimax.review"
    public let binaryName = "mmx"
    /// 它写文件（评审报告），走正常的 worktree → 提交 → 审查流程。
    public var canEdit: Bool { true }
    public var mediaOnly: Bool { false }
    public var reviewOnly: Bool { true }
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        let driver = #"""
        # 三条铁律和媒体驱动一样（macOS 26 zsh 实测）：
        # ① 解析只用 zsh 内建；② 外部命令不进 $(…)；③ 不用管道。
        export PATH="${LLMQ_MMX:h}:$HOME/.hermes/node/bin:$PATH"
        run_mmx() {
          if [ -n "$LLMQ_NODE" ]; then "$LLMQ_NODE" "$LLMQ_MMX" "$@"
          else "$LLMQ_MMX" "$@"; fi
        }

        tmpd="${TMPDIR:-/tmp}/mmxreview-$$"
        /bin/mkdir -p "$tmpd"

        # 材料：仓库现状。**评审要有据可依，不能凭任务描述空想。**
        material=""
        [ -f STATUS.md ] && material="$material
        ## STATUS.md
        $(<STATUS.md)"
        [ -f README.md ] && material="$material
        ## README.md
        $(<README.md)"
        git log --oneline -20 > "$tmpd/log.txt" 2>/dev/null
        material="$material
        ## 最近 20 个提交
        $(<$tmpd/log.txt)"
        git ls-files > "$tmpd/files.txt" 2>/dev/null
        files_text="$(<$tmpd/files.txt)"
        material="$material
        ## 文件清单（前 4000 字符）
        ${files_text[1,4000]}"

        # 材料整体也要有上限：一次评审塞进去几十万字符，模型会在中间
        # 丢掉一半，评出来的东西看着完整其实是瞎编的。
        if [ ${#material} -gt 50000 ]; then
          material="${material[1,50000]}
        …（材料截断）"
        fi

        case "$LLMQ_PROMPT" in
          【测试*) kind=测试 ;;
          *合入*) kind=合入 ;;
          *方案*) kind=方案 ;;
          *) kind=项目 ;;
        esac

        # **合入审核必须看到 diff。** 别的评审看的是「项目到哪一步了」，
        # 材料是 STATUS/README/提交历史就够；合入审核判的是「这段改动能不能进
        # 主干」，不给它看改动等于让它凭任务描述空想。
        # RepoMap.swift 记着的那六份「材料不足 —— 评审正文没给我看」就是这么来的。
        if [ "$kind" = 合入 ]; then
          # 事后复查看的是已经落进 main 的 merge commit，来源分支通常已删；
          # 合入前审核才读取仍然存在的 branch。两者不能共用 branch diff。
          stamp=""
          case "$LLMQ_PROMPT" in
            *"合并 "*)
              rest="${LLMQ_PROMPT#*合并 }"
              cand="${rest[1,12]}"
              for (( i = 1; i <= ${#cand}; i++ )); do
                case "${cand[i]}" in
                  [0-9a-f]) stamp="${stamp}${cand[i]}" ;;
                  *) break ;;
                esac
              done
              ;;
          esac
          if [ ${#stamp} -ge 7 ] && git cat-file -e "$stamp^{commit}" 2>/dev/null; then
            git show --stat --format=fuller "$stamp" > "$tmpd/dstat.txt" 2>/dev/null
            git diff "$stamp^1" "$stamp" > "$tmpd/dfull.txt" 2>/dev/null
          else
          # 分支名是提示词里 agent/ 开头那一段
            rest="${LLMQ_PROMPT#*分支 }"
            br="${rest%% *}"
            br="${br%%$'\n'*}"
            git diff --stat "main...$br" > "$tmpd/dstat.txt" 2>/dev/null
            git diff "main...$br" > "$tmpd/dfull.txt" 2>/dev/null
          fi
          dfull="$(<$tmpd/dfull.txt)"
          material="## 改动概览
        $(<$tmpd/dstat.txt)

        ## 完整改动（前 40000 字符）
        ${dfull[1,40000]}"
          if [ ${#dfull} -gt 40000 ]; then
            material="$material
        …（改动过长已截断，超出部分按「看不到」处理，别猜）"
          fi
        fi

        if [ "$kind" = 合入 ]; then
          read -r -d '' ask <<PROMPT_END
        你是代码合入审核人。判断下面这段改动能不能合进主干。

        # 待审的改动
        $LLMQ_PROMPT

        # 改动内容
        $material

        请输出一份 Markdown 审核报告，只输出报告本身：

        # 合入审核：<分支名>

        **结论**：合入 / 不合入（**只能二选一，原样写这两个字，别加别的字**）

        ## 判断依据
        逐条说清楚。看到什么就说什么，看不到的写"⚠️ 改动里看不出来"。

        ## 会出事的地方
        这段改动可能在什么情况下出错？给出具体的输入或状态。
        没有就写「没看出来」。

        ## 有没有偷工
        - 有没有为了让代码跑通而删掉原本该做的事？
        - 有没有把测试改成迎合实现（而不是反过来）？
        - 有没有留下 TODO 假装做完了？
        没有就写「没有」。

        判断标准：
        - **不合入**的理由必须是**这段改动本身有问题**：会出错、偷工、
          破坏别的东西。风格不合、命名不好、"我会写得不一样"都不是理由。
        - 看不懂 ≠ 不合入。看不懂就在"判断依据"里说清哪一段看不懂，
          结论按看得懂的部分给。
        - **不要因为改动量大就倾向不合入**，也不要因为看着整齐就放行。
        PROMPT_END
        elif [ "$kind" = "测试" ]; then
          test_material="机器没有配置仓库验证命令；只能检查现有测试材料，不能声称执行通过。"
          if [ -n "$LLMQ_VERIFY_COMMAND" ]; then
            /bin/sh -c "$LLMQ_VERIFY_COMMAND" > "$tmpd/test-out.txt" 2> "$tmpd/test-err.txt"
            test_rc=$?
            test_out="$(<$tmpd/test-out.txt)
        $(<$tmpd/test-err.txt)"
            if [ ${#test_out} -gt 12000 ]; then
              test_out="${test_out[-12000,-1]}"
            fi
            test_material="验证命令：$LLMQ_VERIFY_COMMAND
        真实退出码：$test_rc
        输出末尾：
        $test_out"
          fi
          read -r -d '' ask <<PROMPT_END
        你是测试负责人。机器已经负责执行命令，退出码是唯一的通过/失败事实；
        你负责分析失败原因、覆盖缺口、脆弱测试和测试是否被改成迎合实现。

        # 测试目标
        $LLMQ_PROMPT

        # 机器执行证据
        $test_material

        # 仓库现状
        $material

        只输出 Markdown 测试报告：结论必须明确写“通过 / 未通过 / 无法执行”之一；
        然后列出执行证据、失败分析、覆盖缺口和建议补测项。不要修改功能代码，
        不要把模型判断写成“测试已运行”。
        PROMPT_END
        elif [ "$kind" = "方案" ]; then
          read -r -d '' ask <<PROMPT_END
        你是技术方案评审人。下面是一份待评审的方案和它所在仓库的现状。

        # 待评审的方案
        $LLMQ_PROMPT

        # 仓库现状
        $material

        请输出一份 Markdown 评审报告，只输出报告本身：

        # 方案评审：<方案名>

        **结论**：可以开工 / 需要改了再开工 / 不建议做（三选一，说清为什么）

        ## 这个方案要解决的问题是真问题吗
        一段话。如果不是真问题，直接说，这比什么都重要。

        ## 方案本身的漏洞
        逐条列。每条说清：漏了什么、会导致什么后果。没有就写「没有」。

        ## 验收标准够不够硬
        方案里的"怎么算合格"能不能真的判定通过/不通过？
        如果是"做得好看"这种没法判定的标准，指出来并给一个可判定的替代。

        ## 和仓库现状对不对得上
        方案假设的前提，在这个仓库里成立吗（依赖、目录、已有能力）。

        要求：只基于上面给的材料判断，不要推测材料里没有的东西。
        宁可说"材料不足以判断"，也不要编。
        PROMPT_END
        else
          read -r -d '' ask <<PROMPT_END
        你是项目验收人。下面是一个项目的当初目标和它现在的状态。

        # 当初的目标和验收标准
        $LLMQ_PROMPT

        # 项目现状
        $material

        请输出一份 Markdown 验收报告，只输出报告本身：

        # 项目验收：<项目名>

        **结论**：达标 / 部分达标 / 不达标（三选一）

        ## 逐条对照验收标准
        当初定的每一条标准，现在满足了吗？满足写"✅ 是"并给出证据
        （哪个文件、哪个提交）；没满足写"❌ 否"并说清差在哪。
        判断不了的写"⚠️ 材料不足"，别猜。

        ## 还差什么才能交付
        按"必须做"和"可以先不做"分两组。没有就写「可以交付」。

        ## 我看到的风险
        材料里透出来的隐患（比如状态文档和实际提交对不上、
        验收标准从来没被验证过）。没有就写「没有」。

        要求：只基于上面给的材料判断。**不要因为项目看起来完成度高就放行**
        —— 你的价值在于指出"看着完成了其实没有"的那部分。
        PROMPT_END
        fi

        tmpout="$tmpd/out.txt"
        run_mmx text chat --message "$ask" --output text \
          --non-interactive --quiet > "$tmpout" 2>"$tmpd/err.txt"
        rc=$?
        if [ $rc -ne 0 ]; then
          err="$(<$tmpd/err.txt)"
          echo "mmx 失败（$rc）：${err[1,300]}"
          exit 1
        fi
        report="$(<$tmpout)"
        if [ ${#report} -lt 60 ]; then
          echo "报告太短，八成没生成出来：${report[1,200]}"
          exit 1
        fi

        # 报告文件名跟着**被复查的那个合并**走，不能用 HEAD。
        #
        # HEAD 是工作区当前位置。几个复查任务跑在同一个复用工作区里，
        # HEAD 全一样，于是报告全叫同一个名字 —— 2026-08-17 实测撞了 5 份，
        # 光看文件名分不出哪份评的是哪次合并，真合进 main 还会互相覆盖。
        stamp=""
        case "$LLMQ_PROMPT" in
          *"合并 "*)
            rest="${LLMQ_PROMPT#*合并 }"
            cand="${rest[1,12]}"
            for (( i = 1; i <= ${#cand}; i++ )); do
              case "${cand[i]}" in
                [0-9a-f]) stamp="${stamp}${cand[i]}" ;;
                *) break ;;
              esac
            done
            ;;
        esac
        # 取不到就退回 HEAD（方案评审这类提示词里本来就没有合并 sha）
        if [ ${#stamp} -lt 7 ]; then
          stamp="$(git rev-parse --short HEAD 2>/dev/null || echo new)"
        fi
        # 再缀上任务 id（分支名的尾巴，天然唯一）。
        #
        # 光有合并 sha 还不够：同一次合并被两个平台各复查一遍，报告就撞名，
        # 而撞名的直接后果是 **add/add 冲突、分支永远合不进去**。
        # Maw 的 agent/minimax/6bff5fdc 就是这么躺住的 —— 它只改了一个文件，
        # 却因为 main 上已有同名报告而永久卡在待审里。
        #
        # 一份评审报告的身份是「哪次合并 × 谁评的」，两个评审人是两份报告，
        # 都该留着。
        git rev-parse --abbrev-ref HEAD > "$tmpd/branch.txt" 2>/dev/null
        br="$(<$tmpd/branch.txt)"
        tid="${br##*/}"
        /bin/mkdir -p reviews
        if [ -n "$tid" ] && [ "$tid" != "$br" ]; then
          out="reviews/EVAL-${kind}-${stamp}-${tid}.md"
        else
          out="reviews/EVAL-${kind}-${stamp}.md"
        fi
        printf '%s\n' "$report" > "$out"
        git add "$out"
        git commit -q -m "${kind}评审（MiniMax）" || true
        echo "已写 $out（${#report} 字）"
        # 结论直接回显到任务输出里 —— 人在手机上看到的是这一行。
        while IFS= read -r l; do
          case "$l" in *结论*) echo "$l"; break;; esac
        done < "$out"
        """#
        var env: [String: String] = ["LLMQ_PROMPT": prompt]
        // cwd 通常是 agent 的 worktree，不是 RepoRegistry 里登记的主仓路径。
        // 从 git common-dir 反查主仓；否则所有【测试】任务都会误报“没配置命令”。
        let common = GitWorkspace.git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let registeredRepo = common.isEmpty
            ? CollaborationStore.normalizeProject(cwd)
            : URL(fileURLWithPath: common).deletingLastPathComponent().path
        if let verify = RepoRegistry.all().first(where: {
            CollaborationStore.normalizeProject($0.localPath)
                == CollaborationStore.normalizeProject(registeredRepo)
        })?.verifyCommand, !verify.isEmpty {
            env["LLMQ_VERIFY_COMMAND"] = verify
        }
        if let mmx = binaryPath { env["LLMQ_MMX"] = mmx }
        if let node = Proc.which("node") { env["LLMQ_NODE"] = node }
        return ("/bin/zsh", ["-c", driver], env)
    }
}
