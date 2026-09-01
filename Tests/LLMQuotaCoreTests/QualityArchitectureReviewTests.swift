import XCTest
@testable import LLMQuotaCore

final class QualityArchitectureReviewTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-architecture-\(UUID().uuidString)")
        let repoURL = sandbox.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        repo = repoURL.path
        _ = GitWorkspace.git(["init", "-q", "-b", "main"], in: repo)
        try? "base\n".write(to: repoURL.appendingPathComponent("README.md"),
                             atomically: true, encoding: .utf8)
        _ = GitWorkspace.git(["add", "-A"], in: repo)
        _ = GitWorkspace.git(["-c", "user.email=t@t", "-c", "user.name=t",
                              "commit", "-qm", "base"], in: repo)
        _ = GitWorkspace.git(["branch", "agent/minimax/74726e09"], in: repo)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func pausedTask() -> WorkTask {
        var task = WorkTask(id: "74726e09", prompt: "继续 Flint 握枪姿势整改", repo: repo)
        task.branch = "agent/minimax/74726e09"
        task.platform = .minimax
        task.preferredPlatform = .minimax
        task.ownerPlatform = .minimax
        task.ownerRunnerID = "minimax.code"
        return TaskPause.requestArchitectureReview(
            task, reason: "连续视觉整改不收敛", now: Date(timeIntervalSince1970: 100))
    }

    func testPausedQualityTaskCreatesVisibleCodexArchitectureWorkWithoutChangingOwner() throws {
        let original = pausedTask()
        let updates = QualityArchitectureReview.reconcile(
            [original], now: Date(timeIntervalSince1970: 110))
        let review = try XCTUnwrap(updates.first { $0.id != original.id })
        let waiting = try XCTUnwrap(updates.first { $0.id == original.id })

        XCTAssertEqual(review.preferredPlatform, .codex)
        XCTAssertTrue(TaskKind.isArchitectReview(review.prompt))
        XCTAssertTrue(review.prompt.contains("## 骨骼与握枪约束"))
        XCTAssertEqual(waiting.state, .blocked)
        XCTAssertEqual(waiting.ownerRunnerID, "minimax.code")
        XCTAssertEqual(waiting.branch, original.branch)
        XCTAssertTrue(waiting.note?.contains(review.id) == true)

        let brief = try XCTUnwrap(TaskBoard.build(
            from: [waiting, review], machineName: "Mac mini").tasks.first {
                $0.id == original.id
            })
        XCTAssertEqual(brief.progressPhase, "架构重审进行中")
        XCTAssertTrue(brief.progressNextStep?.contains("原 MiniMax 任务") == true)
    }

    func testPausedQualityTaskNextStepNamesCurrentOwnerInsteadOfLegacyMiniMax() throws {
        var waiting = pausedTask()
        waiting.platform = .qwen
        waiting.preferredPlatform = .qwen
        waiting.ownerPlatform = .qwen
        waiting.ownerRunnerID = "qwen.code"
        waiting.branch = "agent/qwen/74726e09"

        let brief = try XCTUnwrap(TaskBoard.build(
            from: [waiting], machineName: "Mac mini").tasks.first)
        XCTAssertTrue(brief.progressNextStep?.contains("原 Qwen 任务") == true)
        XCTAssertFalse(brief.progressNextStep?.contains("MiniMax") == true)
    }

    func testCompleteArchitecturePlanReturnsWorkToOriginalOwnerAndSession() throws {
        let original = pausedTask()
        let created = QualityArchitectureReview.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.id != original.id })
        review.state = .done
        review.outputs = [completeReport(conclusion: "允许恢复")]

        let resumed = try XCTUnwrap(QualityArchitectureReview.reconcile(
            [waiting, review], now: Date(timeIntervalSince1970: 200)).first {
                $0.id == original.id
            })
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pausedAt)
        XCTAssertNil(resumed.architectureReviewRequestedAt)
        XCTAssertEqual(resumed.ownerRunnerID, "minimax.code")
        XCTAssertEqual(resumed.preferredPlatform, .minimax)
        XCTAssertEqual(resumed.branch, original.branch)
        XCTAssertTrue(resumed.prompt.contains("【架构重审方案：\(review.id)】"))
        XCTAssertTrue(resumed.prompt.contains("停止条件"))
    }

    func testExistingArchitecturePlanResumesWithoutReprobingOriginalBranch() throws {
        var waiting = pausedTask()
        let request = try XCTUnwrap(waiting.architectureReviewRequestedAt)
        let origin = QualityArchitectureReview.originPrefix + waiting.id + ":"
            + String(Int(request.timeIntervalSince1970))
        waiting.branch = "branch-that-is-no-longer-locally-visible"

        var review = WorkTask(id: "existing-review", prompt: "架构重审", repo: repo)
        review.origin = origin
        review.state = .done
        review.outputs = [completeReport(conclusion: "允许恢复")]

        let resumed = try XCTUnwrap(QualityArchitectureReview.reconcile(
            [waiting, review], now: Date(timeIntervalSince1970: 200)).first {
                $0.id == waiting.id
            })
        XCTAssertEqual(resumed.state, .queued,
                       "已有评审结论只需对账状态，不应再次依赖 Git 分支探测")
        XCTAssertNil(resumed.pausedAt)
        XCTAssertTrue(resumed.prompt.contains("【架构重审方案：existing-review】"))
    }

    func testIncompleteArchitectureReportRetriesAtMostTwiceAndNeverResumesImplementation() throws {
        let original = pausedTask()
        let created = QualityArchitectureReview.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.id != original.id })
        review.state = .done
        review.outputs = ["**结论**：允许恢复"]

        var updates = QualityArchitectureReview.reconcile([waiting, review])
        review = try XCTUnwrap(updates.first { $0.id == review.id })
        XCTAssertEqual(review.state, .queued)
        XCTAssertEqual(review.interruptedCount, 1)
        XCTAssertFalse(updates.contains { $0.id == original.id && $0.state == .queued })

        review.state = .done
        updates = QualityArchitectureReview.reconcile([waiting, review])
        review = try XCTUnwrap(updates.first { $0.id == review.id })
        XCTAssertEqual(review.interruptedCount, 2)

        review.state = .done
        updates = QualityArchitectureReview.reconcile([waiting, review])
        XCTAssertFalse(updates.contains { $0.id == review.id })
        XCTAssertFalse(updates.contains { $0.id == original.id && $0.state == .queued })
    }

    func testExhaustedCodexReviewGetsOneSameTicketRecoveryAfterNormalRetryLimit() throws {
        let original = pausedTask()
        let created = QualityArchitectureReview.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.id != original.id })
        review.state = .failed
        review.platform = .codex
        review.triedPlatforms = [.codex]
        review.interruptedCount = 2
        review.note = "Codex：退出码 1：You've hit your weekly limit · resets 7am (Asia/Shanghai)"

        var updates = QualityArchitectureReview.reconcile([waiting, review])
        review = try XCTUnwrap(updates.first { $0.id == review.id })
        XCTAssertEqual(review.state, .queued)
        XCTAssertEqual(review.interruptedCount, 3)
        XCTAssertTrue(review.triedPlatforms.isEmpty)
        XCTAssertTrue(review.note?.contains("独立候选") == true)

        review.state = .failed
        updates = QualityArchitectureReview.reconcile([waiting, review])
        XCTAssertFalse(updates.contains { $0.id == review.id },
                       "迁移恢复也失败后必须停住，不能无限烧额度")
    }

    func testExplicitRemainPausedConclusionDoesNotRestartImplementation() throws {
        let original = pausedTask()
        let created = QualityArchitectureReview.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.id != original.id })
        review.state = .done
        review.outputs = [completeReport(
            conclusion: "保持暂停", blockingType: "用户决策")]

        let held = try XCTUnwrap(QualityArchitectureReview.reconcile(
            [waiting, review]).first { $0.id == original.id })
        XCTAssertEqual(held.state, .blocked)
        XCTAssertNotNil(held.pausedAt)
        XCTAssertEqual(held.ownerRunnerID, "minimax.code")
        XCTAssertTrue(held.note?.contains("结论为保持暂停") == true)
    }

    func testActionablePlanCannotKeepImplementationPausedBehindItsOwnVisualGate() throws {
        let original = pausedTask()
        let created = QualityArchitectureReview.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.id != original.id })
        review.state = .done
        review.outputs = [completeReport(conclusion: "保持暂停")]

        let resumed = try XCTUnwrap(QualityArchitectureReview.reconcile(
            [waiting, review]).first { $0.id == original.id })
        XCTAssertEqual(resumed.state, .queued,
                       "样板尚未过门是下一步工作，不是冻结这项工作的外部阻塞")
        XCTAssertNil(resumed.pausedAt)
        XCTAssertTrue(resumed.note?.contains("可执行方案") == true)
    }

    private func completeReport(conclusion: String, blockingType: String? = nil) -> String {
        """
        ## 目标与差距
        差距
        ## 资产管线
        管线
        ## 骨骼与握枪约束
        约束
        ## 渲染与取证
        证据
        ## 量化验收门槛
        门槛
        ## 实施顺序
        顺序
        ## 停止条件
        条件
        \(blockingType.map { "**阻塞类型**：\($0)" } ?? "")
        **结论**：\(conclusion)
        """
    }
}
