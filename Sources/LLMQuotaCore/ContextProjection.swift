import Foundation

/// Context Graph 第一阶段的关系投影：只读、确定性、随时可重建。
///
/// 它**不是真相源**：任务状态在 `TaskStore`，协作事实在 `CollaborationStore`，
/// 代码和产物在 Git。这里只把「它们之间怎么关联」按字段确定性索引出来，
/// 同一批输入重建必然得到同一份结果；不落盘、不进 iCloud、不引入第二套
/// 状态机。坏行由各 Store 自己「跳过但计数」，一个坏事件拖不垮全图。
///
/// 项目隔离在这里一次做死：构造时先按项目过滤，之后的所有查询都只见本项目的
/// 事实 —— 下游不再需要各自记得过滤。
public struct ContextProjection: Sendable {

    public struct Finding: Sendable, Equatable {
        public var id: String
        public var summary: String
        /// 可见性元数据：nil = 项目广播；否则只发给这个 Runner。
        var recipient: String?
        var sender: String

        public init(id: String, summary: String) {
            self.id = id
            self.summary = summary
            self.recipient = nil
            self.sender = ""
        }

        init(event: CollaborationEvent) {
            self.id = event.id
            self.summary = event.summary
            self.recipient = event.recipientRunnerID
            self.sender = event.senderRunnerID
        }

        /// 与 CollaborationStore.context 同一套语义：
        /// 广播、发给我的、我自己发的才可见。
        func isVisible(to runnerID: String?) -> Bool {
            guard let runnerID else { return true }
            return recipient == nil || recipient == runnerID || sender == runnerID
        }
    }

    /// 视觉 Review 与原实现任务之间的 Review/Finding/Evidence 关系。
    ///
    /// 事故回放：视觉票（origin == "visual-quality-review"）否决后，原实现
    /// 任务靠 `visualRemediationReviewID` 找回「哪张票打回了我」。投影把三类
    /// 事实收拢到一起：
    /// - Review：票的文字结论（报告正文），不含任何图片内容；
    /// - Finding：协作账里挂在这张票下的结构化发现；
    /// - Evidence：证据文件的**路径引用**，绝不内嵌图像数据。
    ///
    /// 只采信看得见画面的执行器确认过的票（MiniMax 视觉通道）。这样像 Ox
    /// 这种只收文本的 Runner 拿到的是「画面已被谁看过、看到了什么、材料在哪」，
    /// 而不是被诱导自己去 Read(image) 然后整轮 400。
    public struct VisualFact: Sendable, Equatable {
        public var reviewTaskID: String
        public var sourceTaskID: String
        public var reviewedPlatform: Platform?
        public var observation: String
        public var evidencePaths: [String]
        public var findings: [Finding]
    }

    public let project: String
    public private(set) var tasks: [WorkTask]
    public private(set) var events: [CollaborationEvent]
    public private(set) var tasksByID: [String: WorkTask]
    public private(set) var resolvedEventIDs: Set<String>
    private var eventsByTaskID: [String: [CollaborationEvent]]
    private var visualFactsBySourceTaskID: [String: [VisualFact]]

    public init(project: String, tasks allTasks: [WorkTask],
                events allEvents: [CollaborationEvent]) {
        let normalized = CollaborationStore.normalizeProject(project)
        self.project = normalized
        self.tasks = allTasks
            .filter { CollaborationStore.normalizeProject($0.repo) == normalized }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        self.events = allEvents
            .filter { $0.project == normalized && $0.kind != .started }
        self.tasksByID = Dictionary(self.tasks.map { ($0.id, $0) },
                                    uniquingKeysWith: { a, _ in a })
        var byTask: [String: [CollaborationEvent]] = [:]
        for event in self.events { byTask[event.taskID ?? "", default: []].append(event) }
        self.eventsByTaskID = byTask
        self.resolvedEventIDs = CollaborationStore.resolvedIDs(in: self.events)

        let reviewsByID = Dictionary(
            self.tasks.filter { $0.origin == "visual-quality-review" }
                .map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
        var visuals: [String: [VisualFact]] = [:]
        for source in self.tasks {
            guard let rid = source.visualRemediationReviewID,
                  let review = reviewsByID[rid],
                  VisualQualityGate.verdict(review) == .rejected,
                  review.platform?.canSeeMediaSemantics == true else { continue }
            let findings = self.events
                .filter { ($0.taskID == rid || $0.replyTo == rid) && $0.kind == .finding }
                .map { Finding(event: $0) }
            visuals[source.id, default: []].append(VisualFact(
                reviewTaskID: rid, sourceTaskID: source.id,
                reviewedPlatform: review.platform,
                observation: VisualQualityGate.rejectionDetail(review),
                evidencePaths: Self.evidencePaths(in: review.prompt),
                findings: findings))
        }
        self.visualFactsBySourceTaskID = visuals
    }

    /// 挂在视觉票下的结构化发现。`recipientRunnerID` 传入当前 Runner：
    /// 广播、发给我的、我发的才带进 pack —— 发给别人的私有发现不泄漏
    /// （与 scopedFacts 同一套可见性语义）。nil = 不过滤（投影层直调用）。
    ///
    /// 视觉票本身没有收件人概念 —— 它就是打回这条实现任务的票，
    /// 对实现 owner 天然可见；需要隔离的是挂在票下的协作 finding。
    public func visualFacts(sourceTaskID: String,
                            recipientRunnerID: String? = nil) -> [VisualFact] {
        let facts = visualFactsBySourceTaskID[sourceTaskID] ?? []
        guard recipientRunnerID != nil else { return facts }
        return facts.map { fact in
            var copy = fact
            copy.findings = fact.findings.filter { $0.isVisible(to: recipientRunnerID) }
            return copy
        }
    }

    /// 还需要这个 Runner 处理的问题/交接/否决：定向给它的和项目广播都算。
    /// 已被 answer/ack/result 关闭的不在内。
    public func unresolvedEvents(recipientRunnerID: String) -> [CollaborationEvent] {
        events.filter {
            $0.kind.needsResponse && !resolvedEventIDs.contains($0.id)
                && ($0.recipientRunnerID == nil || $0.recipientRunnerID == recipientRunnerID)
        }
    }

    /// 与当前任务相关的其余事实。排序规则是设计 6.2 的硬要求：
    /// **同任务 > 同图 > 项目广播，时间只是同级内的最后条件** ——
    /// 一条一小时前的定向问题比一条刚刚发生的无关检查点更重要。
    ///
    /// 可见性与 `CollaborationStore.context` 是同一套语义：
    /// 项目广播、明确发给当前 Runner 的、以及当前 Runner 自己发出的才可见 ——
    /// 发给别人的私有事实进别人的包，不进这里的。
    ///
    /// 已被 answer/ack 关闭的 question/handoff 不再返回（它们的使命结束了，
    /// 重新携带只会白占核心预算）；decision/finding 保留「最新有效」语义。
    public func scopedFacts(taskID: String?, graphID: String?,
                            recipientRunnerID: String,
                            limit: Int = 40) -> [CollaborationEvent] {
        func rank(_ e: CollaborationEvent) -> Int {
            if taskID != nil && e.taskID == taskID { return 0 }
            if let graphID, e.graphID == graphID { return 1 }
            if e.taskID == nil && e.graphID == nil { return 2 }
            return 3
        }
        func visible(_ e: CollaborationEvent) -> Bool {
            e.recipientRunnerID == nil || e.recipientRunnerID == recipientRunnerID
                || e.senderRunnerID == recipientRunnerID
        }
        return events
            .filter { $0.kind != .started && $0.kind != .ack && $0.kind != .answer }
            .filter { event in
                guard resolvedEventIDs.contains(event.id),
                      event.kind == .question || event.kind == .handoff else { return true }
                return false
            }
            .filter { visible($0) }
            .filter { rank($0) < 3 }
            .sorted {
                let ra = rank($0), rb = rank($1)
                if ra != rb { return ra < rb }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
            .prefix(max(0, min(limit, 100))).map { $0 }
    }

    /// 直接依赖任务的记录 —— 它们的产出和分支是跨 CLI 协作唯一能传递的东西。
    public func directDependencies(of task: WorkTask) -> [WorkTask] {
        task.dependsOn.compactMap { tasksByID[$0] }
    }

    /// 从视觉票提示词里抽证据文件路径，直接复用 `MiniMaxMediaRunner.visualFiles`
    /// 的安全解析 —— 真实票的形状是「都在 <Review.evidenceDir> 下」加相对
    /// 文件名（VisualQualityGate.dispatch 生成的），只允许系统 evidence 目录，
    /// 手写提示词不能借这个入口读取任意本机图片；返回完整绝对路径。
    /// 这里只存路径引用：不能看图的 Runner 需要知道「材料在哪」，
    /// 不需要也不该拿到「去打开它」的指令。
    static func evidencePaths(in prompt: String) -> [String] {
        MiniMaxMediaRunner.visualFiles(in: prompt)
    }
}

extension Platform {
    /// 这个平台能不能亲自看图/看录屏。目前只有 MiniMax 的视觉通道算数；
    /// 放在 Platform 上而不是逐个 Runner 上，是因为视觉票记录的是平台，
    /// 不是具体 Runner ID。
    var canSeeMediaSemantics: Bool { self == .minimax }
}
