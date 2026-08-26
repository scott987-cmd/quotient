import Foundation

/// 统一的系统上下文构建入口（Context Pack）。
///
/// 阶段 1 之前，派发提示词是各模块自行追加的：RepoMap（3 万字符上限）、
/// ProductBrief、任务图 briefing、协作账（最近 18 条）、固定条款各有各的
/// 局部上限，没有一个总预算，也没有统一的优先级 —— 理论注入上界能超过
/// 8 万字符。现在全部收口到这里：
///
/// - 任务正文和用户明确提供的材料（最新答复）不截断、不计预算；
/// - 系统自动注入部分共享一个硬预算（默认 24,000 字符）；
/// - 装配顺序按优先级：P0 固定契约/产品硬约束 → P1 决定·否决·未解决问题
///   → P2 依赖交接 → P3 图内位置与最新进展 → P4 仓库地图；
/// - 预算不够时先整段丢弃 P4，再 P3；任何事实不允许静默消失 ——
///   要么全文在场、要么折叠为引用、要么带着原因记进 manifest；
/// - P0/P1 的关键语义装不下时：能读文件的 Runner 改为路径引用；
///   文本型 Runner 在派发前拒绝（`insufficientContextCapability`），
///   不生成「材料不足」的报告。
///
/// 每次构建都产出 manifest（含每段字符数、纳入/折叠/丢弃的事实 ID），
/// 由 `ContextTelemetry` 追加记录。派发路径只允许调这一个入口，
/// 不允许任何模块再往 prompt 尾部自行追加无预算内容。
public enum ContextPackBuilder {

    /// 系统自动注入的总上限。24,000 是可解释的第一版安全线，
    /// 不宣称等于固定 token 数。
    public static let defaultBudget = 24_000

    public enum Section: String, CaseIterable, Sendable {
        case contracts       // 固定执行/进度/提问/协作契约
        case product         // 产品硬约束与当前验收条款
        case facts           // 决定、否决、未解决问题（协作账投影）
        case dependencies    // 依赖、交接、产物和 commit
        case graphPosition   // 图内位置与最新 checkpoint
        case repoMap         // 仓库地图

        /// 分段的默认预算（设计 6.3）。它们是分配参考，不是硬隔离：
        /// 高优先级内容装不下时允许占用共享池，代价由低优先级段落承担。
        var ceiling: Int {
            switch self {
            case .contracts: return 2_000
            case .product: return 5_000
            case .facts: return 4_000
            case .dependencies: return 4_000
            case .graphPosition: return 3_000
            case .repoMap: return 6_000
            }
        }
    }

    public struct Request: Sendable {
        public var task: WorkTask
        /// 当前全量任务快照（投影输入）。调用方读一次传进来，
        /// builder 不自己碰 TaskStore，保证可测、可重放。
        public var allTasks: [WorkTask]
        /// 协作事件。nil = 读 CollaborationStore.all()。
        public var events: [CollaborationEvent]?
        public var runnerID: String
        public var platform: Platform
        /// 能不能打开本地文件。能读的拿路径引用，不能读的才需要内联正文。
        public var canReadFiles: Bool
        public var workspacePath: String
        public var handoff: Handoff?
        /// 用户对上一轮提问的最新答复 —— 用户提供的材料，不截断不计预算。
        public var resumedAnswer: AskAnswer?
        public var resumedAsk: Ask?
        public var mayAsk: Bool
        public var askFile: String?
        public var tier: TaskProfile.Tier?
        public var sessionAction: String?
        public var budget: Int

        public init(task: WorkTask, allTasks: [WorkTask],
                    events: [CollaborationEvent]? = nil,
                    runnerID: String, platform: Platform,
                    canReadFiles: Bool, workspacePath: String,
                    handoff: Handoff?, resumedAnswer: AskAnswer?,
                    resumedAsk: Ask?, mayAsk: Bool, askFile: String?,
                    tier: TaskProfile.Tier?, sessionAction: String?,
                    budget: Int = ContextPackBuilder.defaultBudget) {
            self.task = task
            self.allTasks = allTasks
            self.events = events
            self.runnerID = runnerID
            self.platform = platform
            self.canReadFiles = canReadFiles
            self.workspacePath = workspacePath
            self.handoff = handoff
            self.resumedAnswer = resumedAnswer
            self.resumedAsk = resumedAsk
            self.mayAsk = mayAsk
            self.askFile = askFile
            self.tier = tier
            self.sessionAction = sessionAction
            self.budget = budget
        }
    }

    // MARK: - 入口

    public static func build(_ request: Request) -> ContextPack {
        let body = VisualQualityGate.compactRemediationPrompt(request.task.prompt)
        let projection = ContextProjection(
            project: request.task.repo, tasks: request.allTasks,
            events: request.events ?? CollaborationStore.all())

        var assembler = Assembler(budget: request.budget)
        // 用户明确提供的材料：不截断、不计预算。
        var userMaterial = ""
        if let answer = request.resumedAnswer, let ask = request.resumedAsk {
            userMaterial += answer.briefing(for: ask)
        }

        let contracts = renderContracts(request: request)
        let product = ProductBrief.fullBriefing(repo: request.workspacePath,
                                                registeredRepo: request.task.repo)
        let facts = factItems(projection: projection, request: request)

        // P0 固定契约：没有它 agent 不知道怎么交证据、怎么汇报进度、怎么留
        // 结构化事实 —— 装不下说明预算本身错了，对所有 Runner 拒绝。
        if contracts.content.count > assembler.remaining {
            return refusal(request: request,
                           detail: "固定执行契约无法纳入系统注入预算")
        }
        assembler.append(section: .contracts, content: contracts.content,
                         includedIDs: contracts.factIDs)

        // P0 产品硬约束：高优先级可借共享池 —— 全文放得下就完整放入，
        // 不做任何截断；全文装不下时按 Runner 能力分流：能读文件的折叠为
        // AGENTS.md/QUALITY 路径引用；文本型 Runner 或连引用都放不下时
        // 一律派发前拒绝。缺着硬约束派发等于让它瞎干，丢 P0 继续更不行。
        if !product.isEmpty {
            if product.count <= assembler.remaining {
                assembler.append(section: .product, content: product,
                                 includedIDs: ["agents"])
            } else if request.canReadFiles {
                let qualityName = RepoExecutionPolicy.repo(for: request.task.repo)?
                    .qualityContract?.trimmingCharacters(in: .whitespacesAndNewlines)
                var files = [ProductBrief.fileName]
                if let qualityName, !qualityName.isEmpty, !qualityName.hasPrefix("/") {
                    files.append(qualityName)
                }
                let reference = "\n\n---\n## 这个产品是什么、什么不能动（预算内折叠为引用）\n\n"
                    + "完整约束在仓库的 " + files.joined(separator: " 和 ")
                    + " 里，动手之前先自己读一遍；改动和铁律冲突时在产出里明说。\n---\n"
                guard reference.count <= assembler.remaining else {
                    return refusal(request: request,
                                   detail: "产品硬约束连路径引用都无法纳入系统注入预算")
                }
                assembler.append(section: .product, content: reference,
                                 referencedIDs: ["agents"])
            } else {
                return refusal(request: request,
                               detail: "产品硬约束无法纳入系统注入预算，"
                                   + "而该 Runner 读不了本地文件")
            }
        }

        // P1 决定/否决/未解决问题：逐条装配。装不下的先折叠为引用；
        // 连引用都放不下、或语义无法折叠（未解决问题全文 / 文本型 Runner 的
        // 视觉观察全文）时，派发前拒绝而不是静默截掉语义。
        do { try appendFacts(facts, to: &assembler) }
        catch {
            return refusal(request: request, detail: error.localizedDescription)
        }

        appendDependencies(projection: projection, request: request, to: &assembler)
        appendGraphPosition(projection: projection, request: request, to: &assembler)
        appendRepoMap(request: request, to: &assembler)

        let manifest = assembler.manifest(taskID: request.task.id,
                                          runnerID: request.runnerID,
                                          sessionAction: request.sessionAction)
        return ContextPack(text: body + userMaterial + assembler.rendered,
                           manifest: manifest, refusedReason: nil)
    }

    private static func refusal(request: Request, detail: String) -> ContextPack {
        var manifest = ContextPackManifest(
            taskID: request.task.id, runnerID: request.runnerID,
            totalCharacters: 0, charactersBySection: [:],
            includedFactIDs: [], referencedFactIDs: [], droppedFacts: [],
            fullRepoMapUsed: false, sessionAction: request.sessionAction)
        manifest.refusedReason = "insufficientContextCapability: " + detail
        return ContextPack(text: "", manifest: manifest,
                           refusedReason: manifest.refusedReason)
    }

    // MARK: - 装配器

    struct Assembler {
        let budget: Int
        var remaining: Int
        private(set) var parts: [String] = []
        private(set) var charsBySection: [String: Int] = [:]
        private(set) var includedFactIDs: [String] = []
        private(set) var referencedFactIDs: [String] = []
        private(set) var droppedFacts: [ContextPackManifest.DroppedFact] = []
        private(set) var fullRepoMapUsed = false

        init(budget: Int) {
            self.budget = budget
            self.remaining = budget
        }

        mutating func append(section: Section, content: String,
                             includedIDs: [String] = [],
                             referencedIDs: [String] = []) {
            guard !content.isEmpty else { return }
            parts.append(content)
            remaining -= content.count
            charsBySection[section.rawValue, default: 0] += content.count
            includedFactIDs.append(contentsOf: includedIDs)
            referencedFactIDs.append(contentsOf: referencedIDs)
        }

        mutating func drop(id: String, reason: String) {
            droppedFacts.append(.init(id: id, reason: reason))
        }

        mutating func markFullRepoMapUsed() { fullRepoMapUsed = true }

        var rendered: String { parts.joined() }

        func manifest(taskID: String, runnerID: String,
                      sessionAction: String?) -> ContextPackManifest {
            ContextPackManifest(
                taskID: taskID, runnerID: runnerID,
                totalCharacters: charsBySection.values.reduce(0, +),
                charactersBySection: charsBySection,
                includedFactIDs: includedFactIDs,
                referencedFactIDs: referencedFactIDs,
                droppedFacts: droppedFacts,
                fullRepoMapUsed: fullRepoMapUsed,
                sessionAction: sessionAction)
        }
    }

    // MARK: - 各段内容

    struct Contracts {
        var content: String
        var factIDs: [String]
    }

    private static func renderContracts(request: Request) -> Contracts {
        let evidence = EvidenceGate.inlineClause(repoPath: request.task.repo,
                                                 prompt: request.task.prompt)
        var content = evidence
            + WorkProgressContract.clause()
            + CollaborationStore.conventionClause(
                project: request.task.repo, taskID: request.task.id,
                graphID: request.task.graphID, runnerID: request.runnerID)
        var ids = ["contract:progress", "contract:collaboration"]
        if !evidence.isEmpty { ids.insert("contract:evidence", at: 0) }
        if request.mayAsk, let askFile = request.askFile, !askFile.isEmpty {
            content += AskContract.clause(askFile: askFile)
            ids.append("contract:ask")
        }
        return Contracts(content: content, factIDs: ids)
    }

    // MARK: P1 事实（决定 · 否决 · 未解决问题）

    struct FactItem {
        var id: String
        var line: String
        /// true = 这条承载的是不能折叠的关键语义；放不下时宁可拒派。
        var essential: Bool
        /// 折叠形式。给能读文件 / 有 MCP 工具的 Runner 兜底用。
        var referenceLine: String?
    }

    private static func factItems(projection: ContextProjection,
                                  request: Request) -> [FactItem] {
        var items: [FactItem] = []

        // 未解决的问题最先 —— 它们在等人处理，比一切历史结论都急。
        // 只有问题的语义长在那行文字里、折叠不得；决定/交接虽然也在等回应，
        // 但它们可以折叠成 ID 引用（collaboration_get_context 能按 ID 展开），
        // 全部当成不可折叠会让几十条旧裁决挤死共享池。
        for event in projection.unresolvedEvents(recipientRunnerID: request.runnerID) {
            let essential = event.kind == .question
            items.append(FactItem(
                id: event.id,
                line: "- [\(event.id)] \(event.kind.rawValue) · \(event.senderRunnerID)"
                    + (event.recipientRunnerID.map { " → \($0)" } ?? "")
                    + " [待回应]：" + String(event.summary.prefix(240)),
                essential: essential,
                referenceLine: essential ? nil
                    : "- [\(event.id)]（预算内折叠为引用；可用 collaboration_get_context 按 ID 展开）"))
        }

        // 视觉否决：Review/Finding/Evidence 经 visualRemediationReviewID 关联。
        // 对不能看图的 Runner 只注入已确认的文字观察和证据**引用**，
        // 绝不发图片内容，也绝不出现「去打开它」的指令 —— 那会复现 Ox 的
        // 400 invalid_request 整轮失败。挂在票下的 finding 同样按收件人
        // 可见性过滤，发给别人的私有发现不进这个包。
        for fact in projection.visualFacts(sourceTaskID: request.task.id,
                                           recipientRunnerID: request.runnerID) {
            var lines = ["- 视觉否决 [visual:\(fact.reviewTaskID)]"
                + "（独立多模态验收已判未达标；下面是它的文字结论 —— 勿打开图像或录屏文件）"]
            lines.append("  观察：" + fact.observation)
            if !fact.evidencePaths.isEmpty {
                lines.append("  证据引用：" + fact.evidencePaths.prefix(8)
                    .joined(separator: "、") + "（仅路径引用，不要 Read）")
            }
            for finding in fact.findings.prefix(6) {
                lines.append("  关联发现：- [\(finding.id)] "
                    + String(finding.summary.prefix(200)))
            }
            let reference: String? = request.canReadFiles
                ? "- 视觉否决 [visual:\(fact.reviewTaskID)]：文字观察已折叠为引用"
                    + "（完整结论在本任务正文的整改段和报告里）；证据引用："
                    + fact.evidencePaths.prefix(8).joined(separator: "、")
                    + "（勿打开图像）"
                : nil
            items.append(FactItem(id: "visual:\(fact.reviewTaskID)",
                                  line: lines.joined(separator: "\n"),
                                  essential: true, referenceLine: reference))
        }

        // 其余相关事实：同任务 > 同图 > 项目广播（scopedFacts 已按此排序，
        // 时间只是同级内的条件），排除上面已经带上的。
        let listed = Set(items.map(\.id))
        for event in projection.scopedFacts(taskID: request.task.id,
                                            graphID: request.task.graphID,
                                            recipientRunnerID: request.runnerID)
        where !listed.contains(event.id) {
            let line = "- [\(event.id)] \(event.kind.rawValue) · \(event.senderRunnerID)："
                + String(event.summary.prefix(240))
            let ref = event.kind.needsResponse
                ? "- [\(event.id)]（预算内折叠为引用；可用 collaboration_get_context 按 ID 展开）"
                : "- [\(event.id)]（预算内折叠为引用）"
            items.append(FactItem(id: event.id, line: line,
                                  essential: false, referenceLine: ref))
        }
        return items
    }

    private static func appendFacts(_ rawItems: [FactItem],
                                    to assembler: inout Assembler) throws {
        guard !rawItems.isEmpty else { return }
        // 关键语义（未解决问题、视觉否决）先占位，常规事实填剩余 ——
        // 否则几十条旧裁决会排在否决前面，把它挤出预算。
        let items = rawItems.filter { $0.essential } + rawItems.filter { !$0.essential }
        let header = "\n\n【决定 · 否决 · 未解决问题（协作账投影；先处理待回应项，回复引用事件 ID）】\n"
        var body: [String] = []
        var consumed = header.count
        var included: [String] = []
        var referenced: [String] = []

        for item in items {
            let cost = item.line.count + 1
            if consumed + cost <= assembler.remaining {
                body.append(item.line)
                consumed += cost
                included.append(item.id)
                continue
            }
            // 全文放不下：优先折叠为引用。
            if let ref = item.referenceLine, consumed + ref.count + 1 <= assembler.remaining {
                body.append(ref)
                consumed += ref.count + 1
                referenced.append(item.id)
                continue
            }
            if item.essential {
                // 关键语义不能折叠也不能丢：文本型 Runner 派发前拒绝。
                throw NSError(domain: "ContextPackBuilder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "关键事实 \(item.id) 无法纳入系统注入预算"])
            }
            // 常规事实连引用都放不下：显式记录丢弃，绝不静默消失。
            assembler.drop(id: item.id, reason: "总预算不足（P1 常规项最后让位）")
        }
        guard !body.isEmpty else {
            for id in included { assembler.drop(id: id, reason: "总预算不足") }
            return
        }
        assembler.append(section: .facts,
                         content: header + body.joined(separator: "\n"),
                         includedIDs: included, referencedIDs: referenced)
    }

    // MARK: P2 依赖与交接

    private static func appendDependencies(projection: ContextProjection,
                                           request: Request,
                                           to assembler: inout Assembler) {
        var lines: [String] = []
        var ids: [String] = []
        if let handoff = request.handoff {
            lines.append(handoff.briefing().trimmingCharacters(in: .whitespacesAndNewlines))
            ids.append("handoff")
        }
        for upstream in projection.directDependencies(of: request.task) {
            var line = "- [dep:\(upstream.id)] "
                + (upstream.stepTitle ?? String(upstream.prompt.prefix(40)))
            if !upstream.outputs.isEmpty {
                line += "，产出：" + upstream.outputs.prefix(10).joined(separator: "、")
            }
            if let branch = upstream.branch { line += "，分支 \(branch)" }
            lines.append(line)
            ids.append("dep:\(upstream.id)")
        }
        guard !lines.isEmpty else { return }
        let header = "\n\n【依赖与交接（改动都在工作区里，别推倒重来）】\n"
        let full = header + lines.joined(separator: "\n")
        if full.count <= assembler.remaining {
            assembler.append(section: .dependencies, content: full, includedIDs: ids)
            return
        }
        // 超限时改为引用（设计 6.2）：只保留「有什么」，细节让 agent 自查。
        let compact = "\n\n【依赖与交接（预算内折叠为引用，细节用 git diff 自查）】\n"
            + ids.map { "- [\($0)]" }.joined(separator: "\n")
        if compact.count <= assembler.remaining {
            assembler.append(section: .dependencies, content: compact,
                             referencedIDs: ids)
        } else {
            for id in ids { assembler.drop(id: id, reason: "总预算不足（P2 让位）") }
        }
    }

    // MARK: P3 图内位置与 checkpoint

    private static func appendGraphPosition(projection: ContextProjection,
                                            request: Request,
                                            to assembler: inout Assembler) {
        var content = ""
        var ids: [String] = []
        if let brief = TaskGraph.briefing(for: request.task, in: projection.tasks) {
            content += "\n\n" + brief
            ids.append("graph:\(request.task.graphID ?? "?")")
        }
        if let progress = WorkProgressStore.load(taskID: request.task.id) {
            var line = "\n\n【最新进展】阶段 \(progress.phase)：\(progress.summary)"
            if let next = progress.nextStep { line += "；下一步：\(next)" }
            if !progress.evidence.isEmpty {
                line += "；证据：" + progress.evidence.prefix(5).joined(separator: "、")
            }
            content += line
            ids.append("checkpoint:\(request.task.id)")
        }
        guard !content.isEmpty else { return }
        // 整段放得下才放；放不下整体让位并记录原因。半张前情比没有前情更骗人。
        if content.count <= assembler.remaining {
            assembler.append(section: .graphPosition, content: content, includedIDs: ids)
        } else {
            for id in ids { assembler.drop(id: id, reason: "总预算不足（P3 次先让位）") }
        }
    }

    // MARK: P4 仓库地图

    private static func appendRepoMap(request: Request, to assembler: inout Assembler) {
        // 沿用既有规则：接力任务的交接说明里已经有文件清单；
        // trivial 任务的描述里点名了文件行号 —— 地图一个字都用不上。
        if request.handoff != nil || request.tier == .trivial { return }
        let map = RepoMap.briefing(repo: request.workspacePath)
        guard !map.isEmpty else { return }
        if map.count <= assembler.remaining {
            assembler.append(section: .repoMap, content: map, includedIDs: ["repomap"])
            assembler.markFullRepoMapUsed()
        } else {
            assembler.drop(id: "repomap",
                           reason: "总预算不足（P4 最先让位；agent 可自己 ls/读文件认路）")
        }
    }
}

/// 一次派发的完整上下文包：提示词正文 + manifest + 派发前拒绝标记。
public struct ContextPack: Sendable {
    /// 完整提示词 = 原任务正文 + 用户答复 + 系统注入段落。refused 时为空。
    public var text: String
    public var manifest: ContextPackManifest
    /// 非 nil 表示这个 Runner 在派发前被拒绝；调用方应换下一个候选，
    /// 而不是照常派发让它产出一轮「材料不足」的报告。
    public var refusedReason: String?
    public var refused: Bool { refusedReason != nil }
}

/// 每次派发一条轻量记录：只存 ID 和计数，不存重复正文（设计 9.1）。
public struct ContextPackManifest: Codable, Sendable {
    public struct DroppedFact: Codable, Sendable, Equatable {
        public var id: String
        public var reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    public var packVersion: Int
    public var taskID: String
    public var runnerID: String
    public var totalCharacters: Int
    public var charactersBySection: [String: Int]
    public var includedFactIDs: [String]
    public var referencedFactIDs: [String]
    public var droppedFacts: [DroppedFact]
    public var fullRepoMapUsed: Bool
    public var sessionAction: String?
    public var refusedReason: String?
    /// 灰度模式（shadow/active）。旧记录没有这个字段，解码降级为 nil。
    public var rolloutMode: String?
    /// 实际派发那一份提示词里的**系统注入**字符数。
    ///
    /// 影子模式派发的是旧拼装：这里记 legacy 总长 − 任务正文 − 用户答复
    /// （handoff/地图/产品约束/条款/图位置/协作账/提问契约都算系统注入），
    /// 否则新旧 P50/P95 和节省率没法比 —— 这是设计阶段 0 的核心对照数据。
    /// active 非拒绝 = totalCharacters（派发的就是新包）；active 拒绝 =
    /// nil（什么都没派发，别拿候选包充数）。旧记录缺字段降级为 nil。
    public var dispatchedSystemCharacters: Int?
    public var createdAt: Date

    public init(taskID: String, runnerID: String, totalCharacters: Int,
                charactersBySection: [String: Int], includedFactIDs: [String],
                referencedFactIDs: [String], droppedFacts: [DroppedFact],
                fullRepoMapUsed: Bool, sessionAction: String?,
                createdAt: Date = Date()) {
        self.packVersion = 1
        self.taskID = taskID
        self.runnerID = runnerID
        self.totalCharacters = totalCharacters
        self.charactersBySection = charactersBySection
        self.includedFactIDs = includedFactIDs
        self.referencedFactIDs = referencedFactIDs
        self.droppedFacts = droppedFacts
        self.fullRepoMapUsed = fullRepoMapUsed
        self.sessionAction = sessionAction
        self.refusedReason = nil
        self.rolloutMode = nil
        self.dispatchedSystemCharacters = nil
        self.createdAt = createdAt
    }

    /// 共享数据会被不同版本的两台机器读取，缺字段必须安全降级。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packVersion = try c.decodeIfPresent(Int.self, forKey: .packVersion) ?? 1
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        runnerID = try c.decodeIfPresent(String.self, forKey: .runnerID) ?? ""
        totalCharacters = try c.decodeIfPresent(Int.self, forKey: .totalCharacters) ?? 0
        charactersBySection = try c.decodeIfPresent([String: Int].self,
                                                    forKey: .charactersBySection) ?? [:]
        includedFactIDs = try c.decodeIfPresent([String].self,
                                                forKey: .includedFactIDs) ?? []
        referencedFactIDs = try c.decodeIfPresent([String].self,
                                                  forKey: .referencedFactIDs) ?? []
        droppedFacts = try c.decodeIfPresent([DroppedFact].self,
                                             forKey: .droppedFacts) ?? []
        fullRepoMapUsed = try c.decodeIfPresent(Bool.self,
                                                forKey: .fullRepoMapUsed) ?? false
        sessionAction = try c.decodeIfPresent(String.self, forKey: .sessionAction)
        refusedReason = try c.decodeIfPresent(String.self, forKey: .refusedReason)
        rolloutMode = try c.decodeIfPresent(String.self, forKey: .rolloutMode)
        dispatchedSystemCharacters = try c.decodeIfPresent(
            Int.self, forKey: .dispatchedSystemCharacters)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}
