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
    static var file: URL { Paths.appSupport.appendingPathComponent("tasks.jsonl") }

    /// 上一次 all() 里有几行没解出来。非 0 说明任务记录有损坏。
    public private(set) static var skippedLines = 0

    public static func all() -> [WorkTask] {
        skippedLines = 0
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = SnapshotCoding.decoder()
        var latest: [String: WorkTask] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let t = try? dec.decode(WorkTask.self, from: Data(line)) else { continue }
            latest[t.id] = t   // 后写的覆盖先写的
        }
        return latest.values.sorted { $0.createdAt < $1.createdAt }
    }

    public static func append(_ task: WorkTask) throws {
        try Paths.ensureDirectories()
        var data = try SnapshotCoding.encoder().encode(task)
        data.append(UInt8(ascii: "\n"))
        if FileManager.default.fileExists(atPath: file.path) {
            let fh = try FileHandle(forWritingTo: file)
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
            try fh.close()
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
}

// MARK: - 调度

/// 挑一个平台来跑这个任务。
///
/// 当前的目标函数很朴素，因为现在只值得朴素：真实上限大多还没确认，
/// 复杂的评分在没有 limit 的情况下会退化成常数。所以先做对两件事 ——
/// **排除跑不了的**，**在能跑的里面挑最闲的**。
public struct WorkScheduler: Sendable {
    /// 给人类留出的额度比例。调度器不能把额度吃光让你自己没得用。
    ///
    /// 这条不是可选项：实测确认 `claude -p` 仍然计入订阅额度
    /// （Anthropic 那个独立信用池在 2026-06-15 被暂停了），
    /// 也就是说调度器和你抢的是同一份配额。
    public var humanReserve: Double = 0.25

    /// 人停手多久之后才允许调度插进来。
    ///
    /// 短了会在人思考的间隙插进来（改一行代码想两分钟很正常），
    /// 长了则整个工作日都不敢派活。20 分钟是「他大概真的走开了」。
    public var humanIdleGrace: TimeInterval = 20 * 60

    public init(humanReserve: Double = 0.25, humanIdleGrace: TimeInterval = 20 * 60) {
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

        for runner in runners {
            let p = runner.platform

            // 接力时别转回已经失败过的平台 —— 它刚在同一个任务上栽过。
            if let task, task.triedPlatforms.contains(p) {
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

            // 任何一条额度已用尽或即将超额，就整个平台排除。
            if let bad = report.statuses.first(where: {
                $0.health == .exhausted || $0.health == .atRisk
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
            if let last = report.lastHumanActivityHere,
               now.timeIntervalSince(last) < humanIdleGrace {
                rejected.append(Rejection(
                    platform: p,
                    reason: "你 \(Int(now.timeIntervalSince(last) / 60)) 分钟前还在用它，先让着你"))
                continue
            }

            // 配了上限的额度里，剩余最少的那条决定这个平台还能不能接活。
            let configured = report.statuses.compactMap { s -> (QuotaStatus, Double)? in
                guard let f = s.usedFraction else { return nil }
                return (s, f)
            }
            if let tightest = configured.max(by: { $0.1 < $1.1 }) {
                let headroom = 1 - tightest.1
                guard headroom > humanReserve else {
                    rejected.append(Rejection(
                        platform: p,
                        reason: "\(tightest.0.label)已用 \(Format.percent(tightest.1))"
                            + "，剩余不足给人类预留的 \(Format.percent(humanReserve))"))
                    continue
                }
                candidates.append((Pick(
                    platform: p, runner: runner,
                    reason: "\(tightest.0.label)已用 \(Format.percent(tightest.1))"
                        + "，剩 \(Format.percent(headroom))，是当前最闲的"
                ), headroom + overkillPenalty(platform: p, task: task, history: history)
                    + rolePreferenceBonus(platform: p, task: task)
                    + stickinessBonus(platform: p, task: task, history: history)))
            } else {
                // 一条上限都没配。不能因此排除它 —— 那是默认状态，
                // 排除的话调度器一个平台都挑不出来。给个中性分，排在有数据的后面。
                candidates.append((Pick(
                    platform: p, runner: runner,
                    reason: "未配额度上限，按中性优先级参与调度"
                ), 0.5 + overkillPenalty(platform: p, task: task, history: history)
                    + stickinessBonus(platform: p, task: task, history: history)))
            }
        }

        let ordered = candidates.sorted { $0.1 > $1.1 }.map(\.0)
        return Decision(candidates: ordered, rejected: rejected,
                        dispatcher: dispatcherPlatform)
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

public protocol AgentRunner: Sendable {
    var platform: Platform { get }
    var binaryName: String { get }
    /// 能不能改文件、跑命令。
    ///
    /// 纯文本生成型的 CLI（比如 mmx text chat）只能进出文本，
    /// 派编码任务给它必然产出零改动。这个标志让调度器提前排除它，
    /// 而不是白跑一轮才发现。
    var canEdit: Bool { get }
    /// 无头执行。cwd 是独立 worktree，不是用户的工作区。
    func command(prompt: String, cwd: String) -> (launchPath: String, args: [String], env: [String: String])
}

public extension AgentRunner {
    /// 绝大多数执行器都是能改文件的编码 agent。
    var canEdit: Bool { true }
    var binaryPath: String? { Proc.which(binaryName) }
    var isAvailable: Bool { binaryPath != nil }
}

public struct ClaudeRunner: AgentRunner {
    public let platform: Platform = .claude
    public let binaryName = "claude"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        var extra: [String] = []
        if let m = RunnerConfigStore.load().model(for: platform) { extra += ["--model", m] }
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
            [:]
        )
    }
}

public struct QwenRunner: AgentRunner {
    public let platform: Platform = .qwen
    public let binaryName = "qwen"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        var args = ["-p", prompt, "--approval-mode", "yolo"]
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
    public let binaryName = "gemini"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        // --yolo 是确认存在的开关（--approval-mode yolo 等价）。
        // 无头模式下没人点确认，不加它 agent 会卡在审批上直到超时。
        // GEMINI_CLI_TRUST_WORKSPACE：无头环境下 Gemini 拒绝在未信任目录里动手，
        // 而 worktree 每次都是新路径，永远不可能被交互式标记为信任。
        // 变量名是从包里翻出来的，报错信息里显示的是截断的。
        (binaryPath ?? "gemini", ["-p", prompt, "--yolo"],
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
public struct KimiRunner: AgentRunner {
    public let platform: Platform = .kimi
    public let binaryName = "kimi"
    public init() {}

    public func command(
        prompt: String, cwd: String
    ) -> (launchPath: String, args: [String], env: [String: String]) {
        (
            binaryPath ?? "kimi",
            ["-p", prompt, "--add-dir", cwd],
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
        ClaudeRunner(), QwenRunner(), KimiRunner(), OpenCodeRunner()
    ]

    /// 能做纯推理（分类、总结）的执行器，包含改不了文件的那些。
    /// MiniMax 排第一：它的额度最富余，而分类正是"高频、单次极小"的活。
    public static let reasoning: [AgentRunner] = [
        MiniMaxRunner(), ClaudeRunner(), QwenRunner(), KimiRunner(), OpenCodeRunner()
    ]
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

    /// 跑一个子进程，带超时和进程组清理。
    ///
    /// 两个坑：管道不读干净会死锁（agent 输出量很大），
    /// 以及超时后只杀父进程会留下一堆孤儿子进程 —— 所以整组一起杀。
    @discardableResult
    public static func run(
        _ launchPath: String, _ args: [String],
        cwd: String?, env extraEnv: [String: String], timeout: TimeInterval
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
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning {
            timedOut = true
            // 杀整个进程组，避免留下孤儿。
            kill(-p.processIdentifier, SIGKILL)
            p.terminate()
        }
        p.waitUntilExit()
        group.wait()

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
    public static func prepare(repo: String, taskID: String, platform: Platform,
                               graphID: String? = nil) throws -> Workspace {
        let key = graphID ?? taskID
        let branch = graphID.map { "agent/graph/\($0)" }
            ?? "agent/\(platform.rawValue)/\(taskID)"
        let root = Paths.appSupport.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(key).path

        // 图内后续节点：复用，**绝对不能删**。
        if graphID != nil, let live = existingWorkspace(taskID: key), live.branch == branch {
            return live
        }

        // 残留就先清掉，避免上一次异常退出挡住这次。
        _ = git(["worktree", "remove", "--force", path], in: repo)
        try? FileManager.default.removeItem(atPath: path)

        let r = git(["worktree", "add", "-b", branch, path, "HEAD"], in: repo)
        guard r.exitCode == 0 else {
            // 把**能定位问题的东西**都带上，不只是 git 的输出。
            //
            // 实际遇到过：git 退出码非零，而 stderr 和 stdout 全是空的。
            // 只报输出的话这条错误就是「建 worktree 失败：」后面什么都没有，
            // 完全没法往下查 —— 而「进程根本没跑起来」恰恰是最需要上下文的
            // 情况：仓库在不在、是不是 git 仓库、退出码是几、分支名是不是被占了。
            var detail = "退出码 \(r.exitCode)"
            let out = (r.stderr.isEmpty ? r.stdout : r.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty {
                detail += "：" + out.prefix(200)
            } else {
                detail += "（git 无任何输出，多半是进程没起来或超时）"
                let exists = FileManager.default.fileExists(atPath: repo)
                detail += "；仓库 \(repo) " + (exists ? "存在" : "**不存在**")
                if exists && !isRepo(repo) { detail += "，但不是 git 仓库" }
                detail += "；分支 \(branch)"
            }
            throw NSError(domain: "GitWorkspace", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "建 worktree 失败：\(detail)"
            ])
        }
        return Workspace(path: path, branch: branch)
    }

    public static func changedFileCount(in dir: String) -> Int {
        let r = git(["status", "--porcelain"], in: dir)
        return r.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
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
    static let platformMarkers = [
        "not logged in", "oauth", "authenticate", "unauthorized", "401", "403",
        "invalid api key", "no credentials", "please run /login", "quota", "rate limit",
        "429", "insufficient", "command not found", "econnrefused", "enotfound",
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
