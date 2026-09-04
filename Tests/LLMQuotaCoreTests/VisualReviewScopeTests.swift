import XCTest
@testable import LLMQuotaCore

final class VisualReviewScopeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("visual-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root.appendingPathComponent("state")
    }
    override func tearDownWithError() throws {
        RepoRegistry.fileOverride = nil
        Paths.appSupportOverride = nil
        try FileManager.default.removeItem(at: root)
    }

    func testMilestoneCreatesObservationNotAcceptanceOrArchitectTicket() throws {
        let item = Milestone.Item(repo: root.path, repoName: "Flint",
            branch: "agent/kimi/source", mergeSHA: "abc123", subject: "角色母版四机位",
            landedAt: Date(), evidenceFiles: ["front.jpg", "turntable.m4v"],
            taskID: "source", isCheckpoint: true)
        let id = try XCTUnwrap(Milestone.dispatchVisualCheck(item, repoPath: root.path))
        let task = try XCTUnwrap(TaskStore.all().first { $0.id == id })
        XCTAssertTrue(task.prompt.contains("【阶段观察 v1】"))
        XCTAssertTrue(task.prompt.contains("abc123"))
        XCTAssertFalse(task.prompt.contains(ArchitectReview.contractMarker))
        XCTAssertEqual(MiniMaxMediaRunner.visualFiles(in: task.prompt).count, 2,
                       "转码后的 m4v 阶段录屏不能丢")
    }

    func testMilestoneCannotVoteOrEscalateEvenIfModelEmitsFinalVerdict() {
        var task = WorkTask(id: "stage",
            prompt: VisualQualityGate.marker(branch: "agent/kimi/source", head: "abc123")
                + "\n" + ArchitectReview.contractMarker, repo: root.path)
        task.origin = "milestone-eyes"
        task.state = .done
        task.outputs = ["**结论**：达标"]
        XCTAssertNil(VisualQualityGate.verdict(task))
        XCTAssertEqual(VisualQualityGate.status(branch: "agent/kimi/source", head: "abc123",
                                              tasks: [task]), .missing)
        task.outputs = ["**结论**：不达标，需要改"]
        XCTAssertFalse(ArchitectReview.isNegative(task))
        XCTAssertTrue(ArchitectReview.reconcile([task]).isEmpty)
        XCTAssertTrue(VisualQualityGate.reconcileRemediation([task]).isEmpty)
        task.state = .blocked
        task.note = "旧阶段票等待"
        XCTAssertEqual(VisualQualityGate.status(branch: "agent/kimi/source", head: "abc123",
                                              tasks: [task]), .missing)
        XCTAssertNil(VisualQualityGate.blockedReason(branch: "agent/kimi/source", head: "abc123",
                                                   tasks: [task]))
        task.state = .failed
        XCTAssertFalse(VisualQualityGate.exhausted(branch: "agent/kimi/source", head: "abc123",
                                                  tasks: [task, task, task]))
    }

    func testObservationDriverKeepsTaskTailAndDoesNotHardcodeGameplayRubric() {
        let prompt = String(repeating: "旧项目背景。", count: 3_000)
            + "\n【看效果】阶段模型\n【阶段观察 v1】\n本次只检查母版比例与材质。"
        let command = MiniMaxMediaRunner().command(prompt: prompt, cwd: root.path)
        XCTAssertEqual(command.env["LLMQ_VISUAL_PROMPT"], prompt)
        XCTAssertFalse(command.args[1].contains("LLMQ_VISUAL_PROMPT[1,12000]"))
        XCTAssertFalse(command.args[1].contains("任一明显穿模、悬空握持、T-pose"))
        XCTAssertTrue(command.env["LLMQ_REVIEW_RULES"]?.contains("阶段观察") == true)
        XCTAssertTrue(command.env["LLMQ_FRAME_PROMPT"]?.contains("静态图不能证明") == true)
        XCTAssertFalse(command.env["LLMQ_FRAME_PROMPT"]?.contains("重点检查双手与武器接触") == true)
    }

    func testCheckpointCardDoesNotClaimTaskIsStillRunning() {
        Milestone.save([Milestone.Item(repo: root.path, repoName: "Flint", branch: "b",
            mergeSHA: "abc", subject: "样板", landedAt: Date(), evidenceFiles: ["front.jpg"],
            taskID: "finished", isCheckpoint: true)])
        let card = ViewFeed.reviewPage().sections.flatMap { $0.cards ?? [] }.first
        XCTAssertFalse(card?.body?.contains("任务仍在运行") == true)
        XCTAssertTrue(card?.body?.contains("未合入") == true)
    }

    func testTypedOriginWinsOverReferencedStageMarkerAndIgnoresContextFileLists() {
        let runner: any AgentRunner = MiniMaxMediaRunner()
        var task = WorkTask(id: "final", prompt: """
        【看效果】正式验收
        文件（都在 \(Review.evidenceDir.path) 下）：
          - current.png
        引用旧阶段报告：
        【阶段观察 v1】
        """, repo: root.path)
        task.origin = "visual-quality-review"
        let context = task.prompt + "\n文件（都在 \(Review.evidenceDir.path) 下）：\n - stale.png"
        let final = runner.command(task: task, prompt: context, cwd: root.path, session: .fresh)
        XCTAssertEqual(final.env["LLMQ_REVIEW_SCOPE"], "acceptance")
        XCTAssertEqual(final.env["LLMQ_VISUAL_FILES"], Review.evidenceDir.appendingPathComponent("current.png").path)
        task.origin = "milestone-eyes"
        let stage = runner.command(task: task, prompt: context, cwd: root.path, session: .fresh)
        XCTAssertEqual(stage.env["LLMQ_REVIEW_SCOPE"], "observation")
        task.origin = nil
        task.prompt = "【看效果】看一遍这次产出的录屏/截图,替老板先过一道眼。"
        XCTAssertEqual(VisualReviewScope.resolve(task: task), .observation,
                       "旧阶段票即使没有新标记也不能跑成整局终验")
    }

    func testBothContextBuildersRetainQualityButScopeItToObservation() throws {
        try "禁止造假；冻结目录不可改。".write(to: root.appendingPathComponent("AGENTS.md"),
            atomically: true, encoding: .utf8)
        try "终验要求：HUD、持枪、连续60秒录屏。".write(to: root.appendingPathComponent("QUALITY.md"),
            atomically: true, encoding: .utf8)
        RepoRegistry.fileOverride = root.appendingPathComponent("repos.json")
        try JSONSerialization.data(withJSONObject: [["alias": "flint", "path": root.path,
            "qualityContract": "QUALITY.md"]]).write(to: RepoRegistry.fileOverride!)
        var task = WorkTask(id: "stage", prompt: "【看效果】母版参考图", repo: root.path)
        task.origin = "milestone-eyes"
        let pack = ContextPackBuilder.build(.init(task: task, allTasks: [task], events: [],
            runnerID: "minimax.media", platform: .minimax, canReadFiles: false,
            workspacePath: root.path, handoff: nil, resumedAnswer: nil, resumedAsk: nil,
            mayAsk: false, askFile: nil, tier: nil, sessionAction: nil))
        XCTAssertFalse(pack.refused)
        let legacy = LegacyContextPromptBuilder.build(task: task, allTasks: [task],
            runnerID: "minimax.media", workspacePath: root.path, handoff: nil,
            resumedAnswer: nil, resumedAsk: nil, mayAsk: false, askFile: nil)
        for text in [pack.text, legacy] {
            XCTAssertTrue(text.contains("终验要求：HUD、持枪、连续60秒录屏。"))
            XCTAssertTrue(text.contains("禁止造假；冻结目录不可改。"))
            XCTAssertTrue(text.contains("本次阶段观察的背景"))
            XCTAssertFalse(text.contains("不满足时必须明确写“未达标”"))
        }
        XCTAssertTrue(ProductBrief.fullBriefing(repo: root.path).contains("验收标准，不是参考建议"),
                      "正式验收和实现任务的契约不能被这次改动全局降级")
    }

    /// 用可控 CLI 替身跑真实驱动，不把字符串检查冒充执行路径测试。
    private func runDriver(mode: String, files: [String]? = nil,
                           scope: VisualReviewScope = .observation) throws -> Proc.Result {
        let stub = root.appendingPathComponent("mmx-stub")
        try #"""
        #!/bin/zsh
        if [ "$1" = vision ]; then
          [ "$TEST_MODE" != vision-fail ] || { echo 'upstream failure' >&2; exit 42; }
          [ "$TEST_MODE" != empty ] || exit 0
          echo '实际看见：母版参考姿势与表面材质。静态图不能证明游戏流程。'
        else
          print -r -- "$*" > "$TEST_CAPTURE"
          if [ "$TEST_MODE" = stage-title ]; then
            printf '\n# 阶段观察\r\n'
          elif [ "$TEST_MODE" = wrong-verdict ] || [ "$LLMQ_REVIEW_SCOPE" = acceptance ]; then
            echo '**结论**：未达标'
          else
            echo '**阶段观察**：发现可见问题'
          fi
          echo '对应画面：front.png；未验证动画和完整流程。'
        fi
        """#.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let picture = root.appendingPathComponent("front.png")
        try Data([1]).write(to: picture) // CLI 协议替身，不冒充真实图片/视觉验证。
        let prompt = String(repeating: "背景", count: 7_000) + "\nCURRENT-TASK-TAIL"
        let command = MiniMaxMediaRunner().visualReviewCommand(prompt: prompt,
            files: files ?? [picture.path], scope: scope)
        var env = command.env
        env["LLMQ_MMX"] = stub.path
        env["LLMQ_NODE"] = ""
        env["TEST_MODE"] = mode
        env["TEST_CAPTURE"] = root.appendingPathComponent("captured.txt").path
        env["TMPDIR"] = root.path
        return Proc.run(command.launchPath, command.args, cwd: root.path, env: env, timeout: 10)
    }

    func testActualDriverDeliversTailAndProducesObservationOnly() throws {
        let result = try runDriver(mode: "success")
        XCTAssertEqual(result.exitCode, 0, result.stderr + result.stdout)
        let sent = try String(contentsOf: root.appendingPathComponent("captured.txt"), encoding: .utf8)
        XCTAssertTrue(sent.contains("CURRENT-TASK-TAIL"))
        let report = try String(contentsOf: root.appendingPathComponent("reviews/EVAL-视觉-new.md"), encoding: .utf8)
        XCTAssertTrue(report.hasPrefix("**阶段观察**："))
    }

    func testActualDriverDoesNotTurnFailedOrEmptyVisionIntoVerdict() throws {
        for mode in ["vision-fail", "empty"] {
            let result = try runDriver(mode: mode)
            XCTAssertNotEqual(result.exitCode, 0, mode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("captured.txt").path),
                           "读图失败不能再花一次总结额度生成结论")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("reviews/EVAL-视觉-new.md").path))
        }
    }

    func testActualDriverRejectsWrongScopeVerdictAndMissingEvidence() throws {
        XCTAssertNotEqual(try runDriver(mode: "wrong-verdict").exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("reviews/EVAL-视觉-new.md").path))
        XCTAssertNotEqual(try runDriver(mode: "success", files: [root.appendingPathComponent("missing.png").path]).exitCode, 0)
    }

    func testActualAcceptanceDriverStillReturnsStrictQualityVerdict() throws {
        let result = try runDriver(mode: "success", scope: .acceptance)
        XCTAssertEqual(result.exitCode, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("**结论**：未达标"))
    }

    func testActualDriverAcceptsObservedMarkdownStageTitleWithoutInventingVerdict() throws {
        // M2 真实报告以 “# 阶段观察” 开头，没有正式验收票；排版不是用途错误。
        let result = try runDriver(mode: "stage-title")
        XCTAssertEqual(result.exitCode, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("阶段观察"))
        XCTAssertFalse(result.stdout.contains("**结论**"))
        XCTAssertTrue(VisualReviewScope.observation.acceptsReportHeading("\n# 阶段观察\r\n正文"))
        XCTAssertFalse(VisualReviewScope.observation.acceptsReportHeading("**结论**：达标"))
        XCTAssertFalse(VisualReviewScope.acceptance.acceptsReportHeading("# 阶段观察"))
        XCTAssertFalse(VisualReviewScope.observation.acceptsReportHeading(" \n\t\n"))
    }
}
