import XCTest
@testable import LLMQuotaCore

/// Context Pack 第一阶段的验收测试。
///
/// 六个必测场景对应设计文档 14.1 和本次事故回放：
/// 项目隔离、视觉事实关联（Review/Finding/Evidence 经
/// visualRemediationReviewID 连接）、P0/P1 保留、超预算先删 P4/P3、
/// Ox（不能看图）能力渲染、原任务正文不丢失。
final class ContextPackTests: XCTestCase {
    private var scratch: URL!
    private var appSupport: URL!
    private var repoA: URL!
    private var repoB: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctxpack-" + UUID().uuidString)
        CollaborationStore.directoryOverride = scratch
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
            文件（都在证据目录下）：
              - \(evidenceDir.path)/f\(id).png

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
        var all: [WorkTask] = [source, downstream, review]
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

    func testOriginalTaskBodyAlwaysLeadsThePackVerbatim() {
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
        XCTAssertTrue(pack.text.hasPrefix(expectedBody),
            "任务正文（压缩整改票之后）必须是提示词的第一段")
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
        let ranked = first.scopedFacts(taskID: "t1", graphID: nil)
        XCTAssertEqual(ranked.first?.id, "q-late")
        XCTAssertEqual(first.visualFacts(sourceTaskID: "t1").first?.observation, "观察甲")
    }
}
