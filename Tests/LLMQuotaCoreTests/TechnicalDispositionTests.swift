import XCTest
@testable import LLMQuotaCore

final class TechnicalDispositionTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("technical-disposition-\(UUID().uuidString)")
        let repoURL = sandbox.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        repo = repoURL.path
        _ = GitWorkspace.git(["init", "-q", "-b", "main"], in: repo)
        try? "base\n".write(to: repoURL.appendingPathComponent("README.md"),
                             atomically: true, encoding: .utf8)
        _ = GitWorkspace.git(["add", "-A"], in: repo)
        _ = GitWorkspace.git(["-c", "user.email=t@t", "-c", "user.name=t",
                              "commit", "-qm", "base"], in: repo)
        Paths.appSupportOverride = sandbox.appendingPathComponent("support")
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func blockedTask() throws -> WorkTask {
        let branch = "agent/minimax/74726e09"
        _ = GitWorkspace.git(["checkout", "-qb", branch], in: repo)
        try "change\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("feature.swift"),
            atomically: true, encoding: .utf8)
        _ = GitWorkspace.git(["add", "-A"], in: repo)
        _ = GitWorkspace.git(["-c", "user.email=t@t", "-c", "user.name=t",
                              "commit", "-qm", "implementation"], in: repo)
        _ = GitWorkspace.git(["checkout", "-q", "main"], in: repo)

        var task = WorkTask(id: "74726e09", prompt: "继续 Flint 人物整改", repo: repo)
        task.state = .blocked
        task.branch = branch
        task.platform = .minimax
        task.ownerPlatform = .minimax
        task.ownerRunnerID = "minimax.code"
        task.note = "碰到高危路径（Flint.xcodeproj/project.pbxproj），等 Claude 处置"
        return task
    }

    func testBlockedTechnicalChangeCreatesOneCodexDispositionWithoutChangingOwner() throws {
        let original = try blockedTask()
        let first = TechnicalDisposition.reconcile([original])
        let review = try XCTUnwrap(first.first {
            $0.origin?.hasPrefix(TechnicalDisposition.originPrefix + original.id + ":") == true
        })
        let waiting = try XCTUnwrap(first.first { $0.id == original.id })

        XCTAssertEqual(review.preferredPlatform, .codex)
        XCTAssertTrue(TaskKind.isTechnicalDisposition(review.prompt))
        XCTAssertTrue(review.prompt.contains(original.branch!))
        XCTAssertEqual(waiting.ownerRunnerID, "minimax.code")
        XCTAssertTrue(waiting.note?.contains("已排给架构师") == true)

        let second = TechnicalDisposition.reconcile([waiting, review])
        XCTAssertFalse(second.contains { $0.origin == review.origin },
                       "同一个技术阻塞不能每轮再造一条架构任务")
        let refreshed = try XCTUnwrap(second.first { $0.id == original.id })
        XCTAssertTrue(TechnicalDisposition.reconcile([refreshed, review]).isEmpty,
                      "状态文字稳定后不能每 30 秒重复写 tasks.jsonl")
    }

    func testArchitectDecisionAutomaticallySettlesOriginalAndKeepsImplementationOwner() throws {
        let original = try blockedTask()
        let created = TechnicalDisposition.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.origin != nil })
        review.state = .done
        review.outputs = ["检查完成", "**结论**：放行"]

        let approved = try XCTUnwrap(
            TechnicalDisposition.reconcile([waiting, review]).first { $0.id == original.id })
        XCTAssertEqual(approved.state, .done)
        XCTAssertEqual(approved.ownerRunnerID, "minimax.code")
        XCTAssertTrue(approved.note?.contains(review.id) == true)
        XCTAssertTrue(approved.note?.contains("等待评审与合入") == true,
                      "技术放行只结束高危处置，不能冒充已经落地")
        XCTAssertNil(approved.terminalFailureKind)

        var rejectedReview = review
        rejectedReview.outputs = ["**结论**：拒绝"]
        let rejected = try XCTUnwrap(
            TechnicalDisposition.reconcile([waiting, rejectedReview]).first {
                $0.id == original.id
            })
        XCTAssertEqual(rejected.state, .queued)
        XCTAssertEqual(rejected.ownerRunnerID, "minimax.code")
        XCTAssertNotNil(rejected.branch, "拒绝后保留隔离分支，原 Owner 才能基于现有成果修正")
        XCTAssertTrue(rejected.prompt.contains("架构师技术处置反馈"))
        XCTAssertTrue(rejected.prompt.contains("拒绝"))
        XCTAssertTrue(rejected.note?.contains("同一任务续作") == true)
    }

    func testNewSnapshotGetsNewDispositionInsteadOfReusingOldRejection() throws {
        let original = try blockedTask()
        let created = TechnicalDisposition.reconcile([original])
        var waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var firstReview = try XCTUnwrap(created.first { $0.origin != nil })
        firstReview.state = .done
        firstReview.outputs = ["**结论**：拒绝"]

        waiting = try XCTUnwrap(
            TechnicalDisposition.reconcile([waiting, firstReview]).first {
                $0.id == original.id
            })
        _ = GitWorkspace.git(["checkout", "-q", waiting.branch!], in: repo)
        try "corrected\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("feature.swift"),
            atomically: true, encoding: .utf8)
        _ = GitWorkspace.git(["add", "-A"], in: repo)
        _ = GitWorkspace.git(["-c", "user.email=t@t", "-c", "user.name=t",
                              "commit", "-qm", "correct rejection"], in: repo)
        _ = GitWorkspace.git(["checkout", "-q", "main"], in: repo)
        waiting.state = .blocked
        waiting.note = "又碰到高危路径，等 Claude 处置"

        let next = TechnicalDisposition.reconcile([waiting, firstReview])
        let secondReview = try XCTUnwrap(next.first {
            $0.origin?.hasPrefix(TechnicalDisposition.originPrefix + original.id + ":") == true
                && $0.id != firstReview.id
        })
        XCTAssertNotEqual(secondReview.origin, firstReview.origin)
        XCTAssertTrue(secondReview.prompt.contains("correct rejection") == false,
                      "提示只绑定新快照，不复制旧任务的无界历史")
    }

    func testFailedDispositionRetriesSameTicketAtMostTwice() throws {
        let original = try blockedTask()
        let created = TechnicalDisposition.reconcile([original])
        let waiting = try XCTUnwrap(created.first { $0.id == original.id })
        var review = try XCTUnwrap(created.first { $0.origin != nil })
        review.state = .failed
        review.note = "Claude quota exhausted"

        let first = TechnicalDisposition.reconcile([waiting, review])
        review = try XCTUnwrap(first.first { $0.id == review.id })
        XCTAssertEqual(review.state, .queued)
        XCTAssertEqual(review.interruptedCount, 1)
        XCTAssertEqual(review.preferredPlatform, .codex)

        review.state = .failed
        let second = TechnicalDisposition.reconcile([waiting, review])
        review = try XCTUnwrap(second.first { $0.id == review.id })
        XCTAssertEqual(review.interruptedCount, 2)

        review.state = .failed
        XCTAssertFalse(TechnicalDisposition.reconcile([waiting, review]).contains {
            $0.id == review.id
        }, "同一张坏票不能无限重跑浪费架构师 token")
    }

    func testCheckpointSurvivesWorktreeRemovalAndCanBeApproved() throws {
        let branch = "agent/minimax/checkpoint"
        let ws = sandbox.appendingPathComponent("ws").path
        _ = GitWorkspace.git(["worktree", "add", "-q", "-b", branch, ws, "main"], in: repo)
        try "generated\n".write(
            to: URL(fileURLWithPath: ws).appendingPathComponent("project.pbxproj"),
            atomically: true, encoding: .utf8)

        let checkpoint = TechnicalDisposition.checkpoint(
            repo: repo, workspace: ws, platform: .minimax, prompt: "生成工程")
        guard case .success(let sha) = checkpoint else {
            return XCTFail("高危改动没有形成可恢复快照：\(checkpoint)")
        }
        XCTAssertFalse(sha.isEmpty)
        _ = GitWorkspace.git(["worktree", "remove", "--force", ws], in: repo)

        var task = WorkTask(id: "checkpoint", prompt: "生成工程", repo: repo)
        task.state = .blocked
        task.branch = branch
        let outcome = Approval.settle(task: task, approve: true)
        XCTAssertEqual(outcome.task.state, .done, outcome.note)
        XCTAssertTrue(GitWorkspace.branchExists(branch, in: repo))
    }

    func testPhoneProjectionShowsBlockInsteadOfStaleProgress() throws {
        var task = try blockedTask()
        task.endedAt = Date(timeIntervalSince1970: 2_000_000 - 1_500)
        let stale = WorkProgress(
            taskID: task.id, sequence: 3, phase: "持续实现",
            summary: "检测到旧提交", evidence: [], evidenceFingerprint: "old",
            requestedMinutes: 20,
            updatedAt: Date(timeIntervalSince1970: 2_000_000 - 1_500))
        let board = TaskBoard.build(
            from: [task], machineName: "Mac mini",
            progressByTaskID: [task.id: stale],
            now: Date(timeIntervalSince1970: 2_000_000))
        let brief = try XCTUnwrap(board.tasks.first)
        XCTAssertEqual(brief.progressPhase, "等待架构师技术处置")
        XCTAssertEqual(brief.progressSummary, task.note)
        XCTAssertFalse(brief.progressSummary?.contains("旧提交") == true)
        XCTAssertTrue(brief.progressNextStep?.contains("实现 Owner") == true)
    }

    func testTechnicalDispositionIntakePrefersCodexAndDoesNotAddNegativeReviewContract() throws {
        let outcome = try TaskIntake.enqueue(
            prompt: "【技术处置】检查隔离分支", repo: repo,
            classify: false, split: false, force: true)
        guard case .single(let task) = outcome else {
            return XCTFail("技术处置必须保持单任务")
        }
        XCTAssertEqual(task.preferredPlatform, .codex)
        XCTAssertTrue(TaskKind.isReview(task.prompt))
        XCTAssertFalse(task.prompt.contains(ArchitectReview.contractMarker))
    }
}
