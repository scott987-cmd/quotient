import XCTest
@testable import LLMQuotaCore

/// Context Pack 第一阶段的验收测试。
///
/// 六个必测场景对应设计文档 14.1 和本次事故回放：
/// 项目隔离、视觉事实关联（Review/Finding/Evidence 经
/// visualRemediationReviewID 连接）、P0/P1 保留、超预算先删 P4/P3、
/// Ox（不能看图）能力渲染、原任务正文不丢失。
final class ContextPackTests: XCTestCase {
    func test火山上下文预算为模型输出预留窗口() {
        XCTAssertEqual(ContextPackBuilder.budget(for: .volcark), 8_000)
        XCTAssertEqual(ContextPackBuilder.budget(for: .openrouter),
                       ContextPackBuilder.defaultBudget)
    }

    private var scratch: URL!
    private var appSupport: URL!
    private var repoA: URL!
    private var repoB: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctxpack-" + UUID().uuidString)
        CollaborationStore.directoryOverride = scratch
        // 隔离真实用户配置：EvidenceGate/ProductBrief 都会查仓库登记表，
        // 不隔离的话测试结果取决于这台机器登记了什么。
        RepoRegistry.fileOverride = scratch.appendingPathComponent("repos.json")
        try? Data("[]".utf8).write(to: RepoRegistry.fileOverride!, options: .atomic)
        appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctxpack-support-" + UUID().uuidString)
        Paths.appSupportOverride = appSupport
        ContextTelemetry.fileOverride = appSupport
            .appendingPathComponent("context-packs.jsonl")
        repoA = makeRepo("repo-a", agents: "# 产品 A\n\n铁律：不许删除导出按钮。\n验证：swift test。\n")
        repoB = makeRepo("repo-b", agents: "# 产品 B\n")
    }

    override func tearDown() {
        CollaborationStore.directoryOverride = nil
        RepoRegistry.fileOverride = nil
        Paths.appSupportOverride = nil
        ContextTelemetry.fileOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: appSupport)
        try? FileManager.default.removeItem(at: repoA)
        try? FileManager.default.removeItem(at: repoB)
        super.tearDown()
    }

    // MARK: - 工具

    @discardableResult
    private func makeRepo(_ name: String, agents: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name + "-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? agents.write(to: dir.appendingPathComponent("AGENTS.md"),
                          atomically: true, encoding: .utf8)
        return dir
    }

    /// 往仓库塞一批带符号的源码文件，把 RepoMap 撑大到指定规模。
    private func stuffRepo(_ repo: URL, files: Int) {
        for i in 0..<files {
            let body = """
            import Foundation
            struct Gen\(i) { func run\(i)() -> Int { return \(i) } }
            struct Gen\(i)Helper { func assist\(i)() -> Int { return \(i) } }
            """
            try? body.write(to: repo.appendingPathComponent("Gen\(i).swift"),
                            atomically: true, encoding: .utf8)
        }
    }

    private func task(_ id: String, prompt: String, repo: URL) -> WorkTask {
        WorkTask(id: id, prompt: prompt, repo: repo.path)
    }

    /// 一张被 MiniMax 否决的视觉票 + 它的报告文件。
    /// 报告正文以 marker 开头，便于断言「文字观察」确实进了包。
    private func visualReview(id: String, repo: URL, observation: String) -> WorkTask {
        let evidenceDir = repo.appendingPathComponent("docs/evidence")
        try? FileManager.default.createDirectory(at: evidenceDir,
                                                 withIntermediateDirectories: true)
        let report = evidenceDir.appendingPathComponent("visual-\(id).md")
        try? observation.write(to: report, atomically: true, encoding: .utf8)
        var review = task(id, prompt: """
            【看效果】分支 agent/x/src 提交 abc123 的视觉质量是否达到项目契约。

            成果：握枪动作
            文件（都在 \(Review.evidenceDir.standardizedFileURL.path) 下）：
              - f\(id).png

            必须真的逐帧看图/录屏，并逐条对照任务目标和注入的 QUALITY.md。
            **结论**：未达标
            """, repo: repo)
        review.origin = "visual-quality-review"
        review.platform = .minimax
        review.state = .done
        // verdict 判据读的是 outputs/note 里的「结论」行，不是提示词。
        review.outputs = ["**结论**：未达标", "报告：docs/evidence/visual-\(id).md"]
        review.endedAt = Date()
        return review
    }

    private func publishEvent(id: String, project: URL, taskID: String?,
                              sender: String, to: String? = nil,
                              kind: CollaborationEvent.Kind = .decision,
                              summary: String) throws {
        _ = try CollaborationStore.publish(CollaborationEvent(
            id: id, project: project.path, taskID: taskID,
            senderRunnerID: sender, recipientRunnerID: to,
            kind: kind, summary: summary))
    }

    private func build(task t: WorkTask, all: [WorkTask],
                       runnerID: String, platform: Platform,
                       canReadFiles: Bool, budget: Int? = nil,
                       events: [CollaborationEvent]? = nil) -> ContextPack {
        ContextPackBuilder.build(.init(
            task: t, allTasks: all, events: events ?? CollaborationStore.all(),
            runnerID: runnerID, platform: platform,
            canReadFiles: canReadFiles, workspacePath: t.repo,
            handoff: nil, resumedAnswer: nil, resumedAsk: nil,
            mayAsk: false, askFile: nil, tier: .standard,
            sessionAction: "fresh", budget: budget ?? ContextPackBuilder.defaultBudget))
    }

    // MARK: - 1. 项目隔离

    func testPriorityContractsRenderAheadOfLargeTaskBodyWithoutDuplication() {
        let marker = "TASK-BODY-START"
        let source = task("large", prompt: marker
            + String(repeating: "超长任务正文", count: 8_000), repo: repoA)
        let pack = build(task: source, all: [source], runnerID: "kimi.code",
                         platform: .kimi, canReadFiles: true)

        let contract = try! XCTUnwrap(pack.text.range(of: "【协作约定】"))
        let body = try! XCTUnwrap(pack.text.range(of: marker))
        XCTAssertLessThan(contract.lowerBound, body.lowerBound,
            "P0 契约必须先于不计预算的任务正文，避免尾部截断让 Agent 丢失工具")
        XCTAssertEqual(pack.text.components(separatedBy: "## 长任务进度与续期").count - 1,
                       1, "进度契约不能重复注入并浪费上下文")
    }

    func testAskContractIsInjectedExactlyOnce() {
        let source = task("ask-once", prompt: "需要时向用户提问", repo: repoA)
        let marker = "/tmp/llmq-ask-once.json"
        let pack = ContextPackBuilder.build(.init(
            task: source, allTasks: [source], events: [],
            runnerID: "kimi.code", platform: .kimi,
            canReadFiles: true, workspacePath: source.repo,
            handoff: nil, resumedAnswer: nil, resumedAsk: nil,
            mayAsk: true, askFile: marker, tier: .standard,
            sessionAction: "fresh"))

        XCTAssertEqual(pack.text.components(separatedBy: marker).count - 1, 1,
                       "同一份提问契约不能重复注入并浪费上下文")
        XCTAssertEqual(pack.manifest.includedFactIDs.filter { $0 == "contract:ask" }.count, 1)
    }

    func testFactsFromOtherProjectsNeverEnterThePack() throws {
        try publishEvent(id: "foreign-decision", project: repoB, taskID: "t1",
                         sender: "kimi.code", summary: "B项目专属决定不得串线")
        try publishEvent(id: "foreign-question", project: repoB, taskID: "t1",
                         sender: "kimi.code", to: "claude.code",
                         kind: .question, summary: "B项目专属问题不得串线")

        let source = task("t1", prompt: "修 A 产品的导出按钮", repo: repoA)
        let pack = build(task: source, all: [source], runnerID: "claude.code",
                         platform: .claude, canReadFiles: true)

        XCTAssertFalse(pack.text.contains("B项目专属"), "另一个项目的事实泄漏进了提示词")
        XCTAssertFalse(pack.manifest.includedFactIDs.contains("foreign-decision"))
        XCTAssertTrue(pack.manifest.includedFactIDs.isEmpty
            || pack.manifest.includedFactIDs.allSatisfy { !$0.hasPrefix("foreign") })
    }

    // MARK: - 2. 视觉事实关联（Review/Finding/Evidence）

    func testVisualRejectionLinksObservationFindingsAndEvidenceToSourceTask() throws {
        let marker = "OBS-握手偏移15px-左手IK抖动"
        let review = visualReview(id: "rev1", repo: repoA,
                                  observation: marker + "；连续三帧手指穿透扳机。")
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "rev1"
        try publishEvent(id: "f1", project: repoA, taskID: "rev1",
                         sender: "minimax.review", kind: .finding,
                         summary: "左手 IK 在第 3 帧抖动")

        let pack = build(task: source, all: [source, review],
                         runnerID: "opencode.openrouter.code",
                         platform: .openrouter, canReadFiles: true)

        XCTAssertTrue(pack.text.contains(marker),
            "MiniMax 已确认的文字观察必须进入不能看图的 Ox 的上下文")
        XCTAssertTrue(pack.text.contains("左手 IK 在第 3 帧抖动"),
            "挂在视觉票下的结构化发现必须跟着票一起关联进来")
        XCTAssertTrue(pack.manifest.includedFactIDs.contains("visual:rev1"),
            "Review 关系必须以事实 ID 记入 manifest")
        XCTAssertTrue(pack.manifest.includedFactIDs.contains("f1"))
        XCTAssertTrue(pack.text.contains("证据引用"), "证据只允许以路径引用形式出现")
    }

    // MARK: - 3+4. 预算压力：P0/P1 保留，P4/P3 先删

    /// 重压场景：一张 12000 字的视觉否决（P1，必须保全文）+ 一个未解决的
    /// 广播问题（P1）+ 几十条常规决定把共享池吃光。地图（P4）和图内位置
    /// （P3）必须整体让位，且任何事实都不允许静默消失。
    private func pressuredFacts(decisions: Int) throws -> (WorkTask, [WorkTask]) {
        let review = visualReview(id: "revbig", repo: repoA, observation: String(
            repeating: "画面证实角色手臂穿透枪身，第 N 帧偏移超阈值。", count: 380))
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "revbig"
        source.graphID = "g1"
        var downstream = task("t2", prompt: "依据上一步调整开火节奏", repo: repoA)
        downstream.graphID = "g1"
        downstream.dependsOn = ["t1"]
        downstream.state = .done
        downstream.outputs = ["fire-rate.md"]
        let all: [WorkTask] = [source, downstream, review]
        try publishEvent(id: "q-hold", project: repoA, taskID: nil,
                         sender: "human", kind: .question,
                         summary: "QHOLD-导出按钮这轮到底保不保留")
        let verdict = String(repeating: "保持程序化灰盒路线与共享材质参数表，禁止更换渲染管线。", count: 7)
        for i in 0..<decisions {
            try publishEvent(id: String(format: "d%02d", i), project: repoA,
                             taskID: "t1", sender: "codex.architect",
                             summary: "裁决\(i)：" + verdict)
        }
        return (source, all)
    }

    func testEssentialFactsSurviveWhenBudgetIsExhausted() throws {
        let (source, all) = try pressuredFacts(decisions: 40)
        let pack = build(task: source, all: all, runnerID: "minimax.text",
                         platform: .minimax, canReadFiles: false)

        XCTAssertLessThanOrEqual(pack.manifest.totalCharacters,
                                 ContextPackBuilder.defaultBudget,
                                 "系统注入总量突破了硬预算")
        XCTAssertTrue(pack.text.contains("QHOLD-导出按钮这轮到底保不保留"),
            "未解决问题是 P1，预算再紧也不能丢")
        XCTAssertTrue(pack.manifest.includedFactIDs.contains("visual:revbig"),
            "P1 视觉否决不能丢")
        XCTAssertTrue(pack.text.contains("画面证实角色手臂穿透枪身"),
            "文字观察的语义必须在包里")
        // 无静默丢失：每条常规决定要么全文在场、要么折叠为引用、要么显式记录丢弃。
        for i in 0..<40 {
            let id = String(format: "d%02d", i)
            let accounted = pack.manifest.includedFactIDs.contains(id)
                || pack.manifest.referencedFactIDs.contains(id)
                || pack.manifest.droppedFacts.contains { $0.id == id }
            XCTAssertTrue(accounted, "决定 \(id) 从包里静默消失了")
        }
    }

    func testOverBudgetDropsRepoMapFirstThenGraphPosition() throws {
        stuffRepo(repoA, files: 500)   // RepoMap ≈ 2.3 万字符，任何重压档位都装不下
        let (source, all) = try pressuredFacts(decisions: 10)

        let pack = build(task: source, all: all, runnerID: "minimax.text",
                         platform: .minimax, canReadFiles: false)

        XCTAssertLessThanOrEqual(pack.manifest.totalCharacters,
                                 ContextPackBuilder.defaultBudget)
        // P4 最先让位：重压下地图整段丢弃并记录原因。
        XCTAssertEqual(pack.manifest.droppedFacts.first?.id, "repomap",
            "最先被删的必须是 P4 仓库地图，实际：\(pack.manifest.droppedFacts)")
        // 压力较轻时 P3 图内位置应该还活着 —— 只有 P4 让位。
        XCTAssertFalse(pack.manifest.droppedFacts.contains { $0.id == "graph:g1" },
            "这个压力档位只该删 P4，不该连 P3 一起删")
        XCTAssertGreaterThan(pack.manifest.charactersBySection["graphPosition"] ?? 0, 0)
        XCTAssertTrue(pack.manifest.fullRepoMapUsed == false)
    }

    func testHeavierPressureDropsBothP4AndP3() throws {
        stuffRepo(repoA, files: 500)
        // 决策供给量（约 2.7 万字符）远超 P0 之后的共享池：
        // 无论逐条宽度如何浮动，facts 装配结束时剩余空间必然不足一个段落，
        // P3 图内位置必须跟着 P4 一起让位。
        let (source, all) = try pressuredFacts(decisions: 120)

        let pack = build(task: source, all: all, runnerID: "minimax.text",
                         platform: .minimax, canReadFiles: false)

        XCTAssertTrue(pack.manifest.droppedFacts.contains { $0.id == "repomap" })
        XCTAssertTrue(pack.manifest.droppedFacts.contains { $0.id == "graph:g1" },
            "P4 让完位之后该轮到 P3；实际丢弃清单：\(pack.manifest.droppedFacts)")
    }

    // MARK: - 5. Ox 能力渲染

    func testOxGetsTextualVisualFactsWithoutAnyImageInducement() throws {
        let marker = "OXOBS-准星抖动幅度超阈值"
        let review = visualReview(id: "revox", repo: repoA,
                                  observation: marker + "；录屏第 4 秒可见弹孔偏离靶心。")
        var source = task("t1", prompt: "修复射击散布", repo: repoA)
        source.visualRemediationReviewID = "revox"

        let pack = build(task: source, all: [source, review],
                         runnerID: "opencode.openrouter.code",
                         platform: .openrouter, canReadFiles: true)

        XCTAssertTrue(pack.text.contains(marker))
        XCTAssertTrue(pack.text.contains("勿打开图像"),
            "给 Ox 的视觉块必须自带禁读图像的边界说明")
        XCTAssertFalse(pack.text.contains("逐帧看图"),
            "把评审员的看图指令转嫁给不能看图的 Ox 会复现 400 事故")
        // 所有媒体路径只能出现在「证据引用」语境里，不得出现在祈使句中。
        for line in pack.text.components(separatedBy: .newlines)
        where line.contains(".png") || line.contains(".mp4") {
            XCTAssertTrue(line.contains("证据引用") || line.contains("勿打开图像"),
                "这一行在诱导不能看图的 Runner 打开媒体文件：\(line)")
        }
    }

    // MARK: - 6. 原任务不丢失

    func testOriginalTaskBodySurvivesVerbatimAfterPriorityContext() {
        let prompt = """
            给设置页补一个导出按钮。
            【视觉整改：rev-old｜保持原 owner 和原会话】
            独立多模态验收判定按钮间距未达标。
            【视觉整改：rev-new｜保持原 owner 和原会话】
            独立多模态验收判定图标颜色未达标。
            """
        let source = task("t1", prompt: prompt, repo: repoA)
        let pack = build(task: source, all: [source],
                         runnerID: "opencode.openrouter.code",
                         platform: .openrouter, canReadFiles: true)

        let expectedBody = VisualQualityGate.compactRemediationPrompt(prompt)
        let contract = try! XCTUnwrap(pack.text.range(of: "【协作约定】"))
        let body = try! XCTUnwrap(pack.text.range(of: expectedBody))
        XCTAssertLessThan(contract.lowerBound, body.lowerBound,
            "P0 协作契约必须先交付，随后仍要完整保留压缩后的任务正文")
        XCTAssertTrue(pack.text.contains("给设置页补一个导出按钮。"))
        XCTAssertTrue(pack.text.contains("rev-new"), "最新的视觉票必须保留")
        XCTAssertFalse(pack.text.contains("rev-old"), "旧票已被新票取代，不得重复携带")
    }

    // MARK: - 文本型 Runner 材料不足时的派发前拒绝

    func testTextRunnerIsRefusedWhenEssentialMaterialCannotFit() throws {
        let review = visualReview(id: "revhuge", repo: repoA, observation: String(
            repeating: "画面证实角色手臂穿透枪身。", count: 700))
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "revhuge"

        let denied = build(task: source, all: [source, review],
                           runnerID: "minimax.text", platform: .minimax,
                           canReadFiles: false, budget: 3_000)
        XCTAssertNotNil(denied.refusedReason,
            "文本型 Runner 装不下关键材料时必须在派发前拒绝")
        XCTAssertTrue(denied.refusedReason?.hasPrefix("insufficientContextCapability") == true)

        let allowed = build(task: source, all: [source, review],
                            runnerID: "claude.code", platform: .claude,
                            canReadFiles: true, budget: 3_000)
        XCTAssertNil(allowed.refusedReason,
            "能读文件的 Runner 改为路径引用即可，不应拒绝")
        XCTAssertLessThanOrEqual(allowed.manifest.totalCharacters, 3_000)
        XCTAssertTrue(allowed.manifest.referencedFactIDs.contains("visual:revhuge"),
            "文件型 Runner 的观察应折叠为引用而不是全文内联")
    }

    // MARK: - 投影的可重建性与排序

    func testProjectionIsDeterministicAndUnresolvedOutranksNewerNoise() throws {
        let review = visualReview(id: "rev1", repo: repoA, observation: "观察甲")
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "rev1"

        let events = [
            CollaborationEvent(id: "noise", project: repoA.path, taskID: nil,
                               senderRunnerID: "kimi.code", kind: .checkpoint,
                               summary: "无关的新检查点", createdAt: Date()),
            CollaborationEvent(id: "q-late", project: repoA.path, taskID: "t1",
                               senderRunnerID: "kimi.code", recipientRunnerID: "claude.code",
                               kind: .question, summary: "定向问题",
                               createdAt: Date().addingTimeInterval(-3600)),
        ]
        let first = ContextProjection(project: repoA.path, tasks: [source, review],
                                      events: events)
        let second = ContextProjection(project: repoA.path, tasks: [source, review],
                                       events: events)

        XCTAssertEqual(first.visualFacts(sourceTaskID: "t1"),
                       second.visualFacts(sourceTaskID: "t1"),
            "同样的输入重建必须得到同一份投影")
        XCTAssertEqual(first.unresolvedEvents(recipientRunnerID: "claude.code").map(\.id),
                       ["q-late"])
        // 时间只是最后的排序条件：一小时前的定向问题必须排在更新的无关检查点前面。
        let ranked = first.scopedFacts(taskID: "t1", graphID: nil,
                                       recipientRunnerID: "claude.code")
        XCTAssertEqual(ranked.first?.id, "q-late")
        // 收件人过滤：发给 Claude 的私有事实不能出现在别人的投影里。
        let oxView = first.scopedFacts(taskID: "t1", graphID: nil,
                                       recipientRunnerID: "opencode.openrouter.code")
        XCTAssertFalse(oxView.contains { $0.id == "q-late" },
            "scopedFacts 必须按收件人可见性过滤")
        XCTAssertEqual(first.visualFacts(sourceTaskID: "t1").first?.observation, "观察甲")
    }

    // MARK: - 架构复核修复（2026-08-26 三项）

    /// 修复 1：明确发给别的 Runner 的私有事实不得进入 Ox 的包。
    func testPrivateFactsAddressedToOtherRunnersNeverEnterThePack() throws {
        try publishEvent(id: "priv-q", project: repoA, taskID: "t1",
                         sender: "kimi.code", to: "claude.code",
                         kind: .question, summary: "PRIV-只发给Claude的私有事实")
        try publishEvent(id: "priv-f", project: repoA, taskID: "t1",
                         sender: "kimi.code", to: "claude.code",
                         kind: .finding, summary: "PRIV-只给Claude的发现")
        let source = task("t1", prompt: "修 A 产品的导出按钮", repo: repoA)

        let ox = build(task: source, all: [source],
                       runnerID: "opencode.openrouter.code",
                       platform: .openrouter, canReadFiles: true)
        XCTAssertFalse(ox.text.contains("PRIV-"),
            "发给别人的私有事实泄漏进了 Ox 的提示词")
        XCTAssertFalse(ox.manifest.includedFactIDs.contains("priv-q"))
        XCTAssertFalse(ox.manifest.includedFactIDs.contains("priv-f"))

        // 发送者本人仍然看得见自己的线程（与 CollaborationStore.context 同语义）。
        let kimi = build(task: source, all: [source], runnerID: "kimi.code",
                         platform: .kimi, canReadFiles: true)
        XCTAssertTrue(kimi.text.contains("PRIV-"), "发送者自己的事实被误藏了")
    }

    /// 修复 1：已解决的 question/handoff 不应重新占核心事实预算。
    func testResolvedQuestionsAndHandoffsDoNotReenterCoreBudget() throws {
        try publishEvent(id: "q-done", project: repoA, taskID: "t1",
                         sender: "kimi.code", to: "opencode.openrouter.code",
                         kind: .question, summary: "DONEQ-已经回答过的问题")
        _ = try CollaborationStore.publish(CollaborationEvent(
            id: "a-done", project: repoA.path, taskID: "t1",
            senderRunnerID: "human", recipientRunnerID: "opencode.openrouter.code",
            kind: .answer, summary: "已答复，按方案 A 走",
            replyTo: "q-done"))
        var source = task("t1", prompt: "继续干活", repo: repoA)
        source.handoff = Handoff(fromPlatform: .qwen, reason: "超时",
                                 touchedFiles: [], wipCommit: nil, elapsedSeconds: 60)

        let pack = build(task: source, all: [source],
                         runnerID: "opencode.openrouter.code",
                         platform: .openrouter, canReadFiles: true)
        XCTAssertFalse(pack.text.contains("DONEQ-"),
            "已被回答关闭的问题不应再进包占预算")
    }

    // MARK: - 修复 2：产品硬约束的预算行为

    private func giveRepoBigAgents(_ repo: URL, characters: Int) {
        let sentence = "铁律：不许删除导出按钮，不许绕过验收闸门。"
        let body = "# 产品 A\n\n"
            + String(repeating: sentence, count: max(1, characters / sentence.count))
        try? body.write(to: repo.appendingPathComponent("AGENTS.md"),
                        atomically: true, encoding: .utf8)
    }

    /// 装不下时：能读文件的 Runner 折叠为 AGENTS.md/QUALITY 路径引用，
    /// 不硬塞半截硬约束。
    func testProductConstraintsFoldToPathReferenceForFileReaders() throws {
        giveRepoBigAgents(repoA, characters: 2_000)
        let source = task("t1", prompt: "修 A 产品", repo: repoA)
        let pack = build(task: source, all: [source], runnerID: "claude.code",
                         platform: .claude, canReadFiles: true, budget: 1_500)

        XCTAssertNil(pack.refusedReason)
        XCTAssertFalse(pack.text.contains("不许删除导出按钮"),
            "装不下时应折叠为引用，而不是截断硬塞半截约束")
        XCTAssertTrue(pack.text.contains("AGENTS.md"), "折叠必须指路到文件")
        XCTAssertLessThanOrEqual(pack.manifest.totalCharacters, 1_500)
    }

    /// 装不下时：文本型 Runner 读不了文件，缺硬约束还派发等于瞎干 —— 拒绝。
    func testTextRunnerIsRefusedWhenProductConstraintsCannotFit() throws {
        giveRepoBigAgents(repoA, characters: 2_000)
        let source = task("t1", prompt: "修 A 产品", repo: repoA)
        let pack = build(task: source, all: [source], runnerID: "minimax.text",
                         platform: .minimax, canReadFiles: false, budget: 1_500)

        XCTAssertNotNil(pack.refusedReason,
            "文本型 Runner 缺产品硬约束必须在派发前拒绝")
        XCTAssertTrue(pack.refusedReason?.hasPrefix("insufficientContextCapability") == true)
    }

    /// 预算不变量扫描：任何档位下 totalCharacters 都不得超过 budget；
    /// 装不下就走折叠或拒绝（P0 全文 / 引用 / 拒绝三选一，不再有截断态）。
    func testTotalCharactersNeverExceedBudgetAcrossTightSweep() throws {
        giveRepoBigAgents(repoA, characters: 8_000)   // P0 全文，超旧 ceiling
        stuffRepo(repoA, files: 30)
        let review = visualReview(id: "revs", repo: repoA, observation: "观察甲乙丙丁")
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "revs"

        for budget in [650, 700, 750, 800, 900, 1_000, 1_300, 1_600, 2_000, 5_000, 24_000] {
            for (runner, files) in [("claude.code", true), ("minimax.text", false)] {
                let pack = build(task: source, all: [source, review],
                                 runnerID: runner, platform: .claude,
                                 canReadFiles: files, budget: budget)
                if pack.refused {
                    continue   // 拒绝路径不产出正文，是合法出口
                }
                XCTAssertLessThanOrEqual(
                    pack.manifest.totalCharacters, budget,
                    "budget=\(budget) runner=\(runner) 时注入量突破硬预算："
                        + "\(pack.manifest.totalCharacters)")
            }
        }
    }

    // MARK: - 修复 3：canReadFiles 是显式能力

    func testRunnerFileReadingCapabilityIsExplicitNotBorrowedFromCanEdit() {
        // 纯文本进出的执行器读不了本地文件 —— 不能拿 canEdit 冒充。
        XCTAssertFalse(MiniMaxReviewRunner().canReadFiles)
        XCTAssertFalse(MiniMaxRunner().canReadFiles)
        XCTAssertFalse(MiniMaxMediaRunner().canReadFiles)
        // 编码执行器默认能读文件。
        XCTAssertTrue(MiniMaxCodeRunner().canReadFiles)
        XCTAssertTrue(ClaudeRunner().canReadFiles)
        XCTAssertTrue(QwenRunner().canReadFiles)
        XCTAssertTrue(KimiRunner().canReadFiles)
        XCTAssertTrue(OpenCodeRunner(platform: .openrouter).canReadFiles)
    }

    // MARK: - 第二轮架构复核（2026-08-26 五项）

    /// 修复 1a：P0 高优先级可借共享池 —— 全文能放进 remaining 时，
    /// 即使超过 product ceiling=5000 也必须完整放入，不能截断。
    func testProductFullTextRidesSharedPoolEvenBeyondCeiling() throws {
        giveRepoBigAgents(repoA, characters: 8_000)
        let source = task("t1", prompt: "修 A 产品", repo: repoA)

        // 重写一份带尾部标志的大 AGENTS.md（约 1 万字符，超过 ceiling）。
        let sentence = "铁律：不许删除导出按钮，不许绕过验收闸门。"
        let body = "# 产品 A\n\n" + String(repeating: sentence, count: 440)
            + "\n尾部铁律：TAIL-EXPORT-⌘E 不许移除。\n"
        try body.write(to: repoA.appendingPathComponent("AGENTS.md"),
                       atomically: true, encoding: .utf8)

        let pack = build(task: source, all: [source], runnerID: "minimax.text",
                         platform: .minimax, canReadFiles: false,
                         budget: ContextPackBuilder.defaultBudget)
        XCTAssertNil(pack.refusedReason)
        XCTAssertGreaterThan(pack.manifest.charactersBySection["product"] ?? 0, 5_000,
            "全文能放进共享池时不得按 ceiling 截断")
        XCTAssertTrue(pack.text.contains("TAIL-EXPORT-⌘E"),
            "文本 Runner 也必须拿到完整 P0 尾部铁律")
        XCTAssertLessThanOrEqual(pack.manifest.totalCharacters,
                                 ContextPackBuilder.defaultBudget)
    }

    /// 修复 1b：可读文件 Runner 连路径引用都放不下时必须拒绝，不能丢 P0 继续。
    func testFileReaderRefusedWhenEvenProductReferenceCannotFit() throws {
        // 先用小产品测出固定契约段的真实长度。
        let probe = task("t0", prompt: "探针", repo: repoA)
        let baseline = build(task: probe, all: [probe], runnerID: "claude.code",
                             platform: .claude, canReadFiles: true, budget: 24_000)
        let contracts = baseline.manifest.charactersBySection["contracts"] ?? 623

        giveRepoBigAgents(repoA, characters: 2_000)
        let source = task("t1", prompt: "修 A 产品", repo: repoA)
        let pack = build(task: source, all: [source], runnerID: "claude.code",
                         platform: .claude, canReadFiles: true,
                         budget: contracts + 50)

        XCTAssertNotNil(pack.refusedReason,
            "连引用都放不下时必须拒绝派发，而不是静默丢弃 P0 硬约束")
        XCTAssertTrue(pack.refusedReason?.hasPrefix("insufficientContextCapability") == true)
    }

    /// 修复 2：builder 必须拿未截断的产品全文 —— ProductBrief 的
    /// per-file 8000 预截断会先把尾部铁律吃掉，让 builder 把缺语义的
    /// 文本当完整。旧 API 保持截断兼容。
    func testBuilderReceivesUntruncatedProductBriefTailIncluded() throws {
        let sentence = "铁律：不许删除导出按钮，不许绕过验收闸门。"
        let body = "# 产品 A\n\n" + String(repeating: sentence, count: 500)
            + "\n尾部铁律：TAIL-LAW-777 快捷键 ⌘E 不许移除。\n"
        try body.write(to: repoA.appendingPathComponent("AGENTS.md"),
                       atomically: true, encoding: .utf8)
        let source = task("t1", prompt: "修 A 产品", repo: repoA)

        // 旧 API 仍然截断（兼容行为不变）。
        let legacy = ProductBrief.text(repo: repoA.path) ?? ""
        XCTAssertLessThanOrEqual(legacy.count, ProductBrief.maxCharacters + 100)

        // builder 走未截断通道：文本 Runner 在默认预算下拿到含尾部的全文。
        let pack = build(task: source, all: [source], runnerID: "minimax.text",
                         platform: .minimax, canReadFiles: false)
        XCTAssertNil(pack.refusedReason)
        XCTAssertTrue(pack.text.contains("TAIL-LAW-777"),
            "8000 字以后的尾部铁律对文本 Runner 丢失了 —— "
                + "builder 拿到的是被预截断的 P0")
    }

    /// 修复 3：证据路径解析必须吃真实 dispatch 形状
    /// （「都在 <evidenceDir> 下」+ 相对文件名），只允许 evidence 目录，
    /// 其他目录一律为空。
    func testEvidencePathsParseRealDispatchShapeAndRejectOtherDirectories() {
        let dir = Review.evidenceDir.standardizedFileURL.path
        let realPrompt = """
            【看效果】分支 agent/x/s 提交 abc 的视觉质量是否达到项目契约。

            成果：开火节奏
            文件（都在 \(dir) 下）：
              - idle.png
              - fire.mov

            必须真的逐帧看图/录屏。
            """
        XCTAssertEqual(ContextProjection.evidencePaths(in: realPrompt),
                       [dir + "/idle.png", dir + "/fire.mov"],
            "真实票形状解析不出完整绝对路径，视觉事实的证据引用就是空的")

        let foreign = """
            文件（都在 /tmp/other-dir 下）：
              - sneak.png
            """
        XCTAssertTrue(ContextProjection.evidencePaths(in: foreign).isEmpty,
            "非 evidence 目录的文件不得借这个入口进入上下文")

        XCTAssertTrue(ContextProjection.evidencePaths(in: "- notes.md").isEmpty,
            "非媒体后缀不算视觉证据")
    }

    /// 修复 4：挂在视觉票下的 finding 同样受收件人隔离约束；
    /// 发给别人的私有发现不进 pack。
    func testPrivateVisualFindingsStayHiddenFromOtherRunners() throws {
        let review = visualReview(id: "revp", repo: repoA, observation: "观察甲乙丙")
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "revp"
        try publishEvent(id: "priv-vf", project: repoA, taskID: "revp",
                         sender: "kimi.code", to: "claude.code",
                         kind: .finding, summary: "PRIVVF-只给Claude的画面发现")
        try publishEvent(id: "pub-vf", project: repoA, taskID: "revp",
                         sender: "minimax.review", kind: .finding,
                         summary: "PUBVF-广播的画面发现")

        let ox = build(task: source, all: [source, review],
                       runnerID: "opencode.openrouter.code",
                       platform: .openrouter, canReadFiles: true)
        XCTAssertFalse(ox.text.contains("PRIVVF-"),
            "发给 Claude 的私有视觉发现泄漏进了 Ox 的包")
        XCTAssertTrue(ox.text.contains("PUBVF-"), "广播的视觉发现应当可见")

        let claude = build(task: source, all: [source, review],
                           runnerID: "claude.code", platform: .claude,
                           canReadFiles: true)
        XCTAssertTrue(claude.text.contains("PRIVVF-"), "收件人本人必须看得见")
    }

    /// 修复 5：拒绝的 manifest 也要能进台账 —— 否则 context miss /
    /// 拒绝率没法统计（main.swift 每次 build 恰好 record 一次，
    /// 拒绝分支在 record 之后）。
    func testRefusedManifestIsRecordableForTelemetry() {
        let review = visualReview(id: "revr", repo: repoA, observation: String(
            repeating: "画面证实手臂穿透枪身。", count: 700))
        var source = task("t1", prompt: "修复握枪动作", repo: repoA)
        source.visualRemediationReviewID = "revr"

        let denied = build(task: source, all: [source, review],
                           runnerID: "minimax.text", platform: .minimax,
                           canReadFiles: false, budget: 3_000)
        XCTAssertNotNil(denied.refusedReason)

        ContextTelemetry.record(denied.manifest)
        let recorded = ContextTelemetry.all().first { $0.taskID == "t1" }
        XCTAssertNotNil(recorded, "拒绝 manifest 没有进台账")
        XCTAssertFalse(recorded?.refusedReason?.isEmpty ?? true,
            "台账里的记录必须带着拒绝原因")
    }
    // MARK: - 直接依赖产物是 P1（设计 6.2）

    /// 重压下直接依赖的产物不能当 P2 丢掉 —— 下一棒拿不到它就会重复工作。
    func testDirectDependencySurvivesBudgetPressureNeverDropped() throws {
        let review = visualReview(id: "revd", repo: repoA, observation: "画面观察短句")
        var upstream = task("t-up", prompt: "上游产出开火节奏表", repo: repoA)
        upstream.graphID = "g-dep"
        upstream.state = .done
        upstream.outputs = ["DEPMARK-fire-rate.md", "spread-table.md"]
        upstream.branch = "agent/graph/g-dep"
        var source = task("t1", prompt: "依据上一步调整开火节奏", repo: repoA)
        source.visualRemediationReviewID = "revd"
        source.dependsOn = ["t-up"]
        try publishEvent(id: "noise-q", project: repoA, taskID: nil,
                         sender: "human", kind: .question, summary: "QHOLD-占位问题")
        for i in 0..<40 {
            try publishEvent(id: String(format: "dd%02d", i), project: repoA,
                             taskID: "t1", sender: "codex.architect",
                             summary: "裁决\(i)：" + String(repeating: "保持灰盒路线。", count: 8))
        }

        // 文本 Runner（不能折叠成它读不了的引用）：要么全文在场，要么拒派，
        // 绝不允许静默丢弃。
        let denied = build(task: source, all: [source, upstream, review],
                           runnerID: "minimax.text", platform: .minimax,
                           canReadFiles: false, budget: 12_000)
        if !denied.refused {
            XCTAssertTrue(denied.manifest.includedFactIDs.contains("dep:t-up"),
                "直接依赖产物是 P1，不能被降级丢弃")
            XCTAssertTrue(denied.text.contains("DEPMARK-fire-rate.md"),
                "依赖的产出文件名必须在包里")
            XCTAssertFalse(denied.manifest.droppedFacts.contains { $0.id == "dep:t-up" })
        } else {
            XCTAssertTrue(denied.refusedReason?.hasPrefix("insufficientContextCapability") == true)
        }

        // 重压档：40 条常规决定挤压共享池。dep 作为 P1 必须先于它们落座，
        // 绝不允许进丢弃清单。
        let pressured = build(task: source, all: [source, upstream, review],
                              runnerID: "minimax.text", platform: .minimax,
                              canReadFiles: false, budget: 5_500)
        let accounted = pressured.manifest.includedFactIDs.contains("dep:t-up")
            || pressured.manifest.referencedFactIDs.contains("dep:t-up")
        XCTAssertTrue(accounted || pressured.refused,
            "重压下直接依赖只能全文在场、合法引用或整体拒派，不能消失")
        XCTAssertFalse(pressured.manifest.droppedFacts.contains { $0.id == "dep:t-up" },
            "P1 依赖产物不允许进入丢弃清单")
        XCTAssertLessThanOrEqual(pressured.manifest.totalCharacters, 5_500)
    }

    /// 文本 Runner 读不了引用：依赖语义装不下时必须派发前拒绝。
    func testTextRunnerRefusedWhenDependencySemanticsCannotFit() throws {
        let probe = task("probe", prompt: "探针", repo: repoA)

        var upstream = task("t-up", prompt: "上游步骤的标题比较长一点", repo: repoA)
        upstream.state = .done
        upstream.outputs = ["fire-rate.md"]
        var source = task("t1", prompt: "接着干", repo: repoA)
        source.dependsOn = ["t-up"]

        // 探针测出固定段（契约+产品约束）的真实长度，再留一个
        // 「装得下引用、装不下全文」也容不下的极小尾巴。
        let probeBase = build(task: probe, all: [probe], runnerID: "minimax.text",
                              platform: .minimax, canReadFiles: false)
            .manifest.charactersBySection
        let fixed = (probeBase["contracts"] ?? 0) + (probeBase["product"] ?? 0)
        let denied = build(task: source, all: [source, upstream],
                           runnerID: "minimax.text", platform: .minimax,
                           canReadFiles: false, budget: fixed + 60)
        XCTAssertNotNil(denied.refusedReason,
            "文本 Runner 不能拿着读不了的引用开工，缺依赖语义就该拒")
        XCTAssertTrue(denied.refusedReason?.hasPrefix("insufficientContextCapability") == true)
    }

    /// 文件型 Runner 的依赖事实必须带折叠引用形式（全文装不下时的
    /// 合法出口）；文本 Runner 没有引用形式 —— 只能全文或拒派。
    func testDependencyFactCarriesFoldFormOnlyForFileReaders() {
        var upstream = task("t-up", prompt: "上游步骤的标题比较长一点", repo: repoA)
        upstream.state = .done
        upstream.outputs = ["fire-rate.md"]
        var source = task("t1", prompt: "接着干", repo: repoA)
        source.dependsOn = ["t-up"]

        let projection = ContextProjection(project: repoA.path,
                                           tasks: [source, upstream], events: [])
        let forReader: (String, Bool) -> ContextPackBuilder.FactItem? = { runner, files in
            ContextPackBuilder.factItems(
                projection: projection,
                request: ContextPackBuilder.Request(
                    task: source, allTasks: [source, upstream], events: [],
                    runnerID: runner, platform: .claude,
                    canReadFiles: files, workspacePath: self.repoA.path,
                    handoff: nil, resumedAnswer: nil, resumedAsk: nil,
                    mayAsk: false, askFile: nil, tier: .standard,
                    sessionAction: "fresh"))
            .first { $0.id == "dep:t-up" }
        }
        let fileReader = forReader("claude.code", true)
        XCTAssertEqual(fileReader?.essential, true, "依赖产物必须是 P1 essential")
        XCTAssertTrue(fileReader?.referenceLine?.contains("[dep:t-up]") == true,
            "文件型 Runner 的折叠引用要带得上 dep 标识")
        let textOnly = forReader("minimax.text", false)
        XCTAssertNil(textOnly?.referenceLine,
            "文本 Runner 不能被塞一个它读不了的引用当出口")
        XCTAssertTrue(textOnly?.line.contains("fire-rate.md") == true)
    }

    /// 一条异常/恶意的超长 output 不能制造巨型提示词行。
    func testGiantOutputNameIsClampedPerItem() {
        var upstream = task("t-up", prompt: "上游", repo: repoA)
        upstream.state = .done
        upstream.outputs = [String(repeating: "X", count: 50_000)]
        var source = task("t1", prompt: "接着干", repo: repoA)
        source.dependsOn = ["t-up"]

        let pack = build(task: source, all: [source, upstream],
                         runnerID: "claude.code", platform: .claude,
                         canReadFiles: true)
        XCTAssertNil(pack.refusedReason)
        XCTAssertFalse(pack.text.contains(String(repeating: "X", count: 5_000)),
            "单个输出名必须按项钳长，不能整段灌进提示词")
        XCTAssertLessThanOrEqual(pack.manifest.totalCharacters,
                                 ContextPackBuilder.defaultBudget)
    }
}
