import XCTest
@testable import LLMQuotaCore

final class VisualQualityRemediationTests: XCTestCase {
    func testVisualRemediationCannotCompleteFromHistoricalBranchOutputAlone() {
        var task = WorkTask(id: "grip", prompt: "继续整改握枪", repo: "/flint")
        task.visualRemediationReviewID = "rejected-grip"

        XCTAssertNotNil(VisualQualityGate.completionBlockReason(
            task: task, attemptChangedFiles: 0, attemptNewCommits: 0),
            "视觉整改本轮零增量时，不能拿分支历史成果冒充本轮完成")
        XCTAssertNil(VisualQualityGate.completionBlockReason(
            task: task, attemptChangedFiles: 1, attemptNewCommits: 0))
        XCTAssertNil(VisualQualityGate.completionBlockReason(
            task: task, attemptChangedFiles: 0, attemptNewCommits: 1),
            "自动收尾提交后的新 commit 也必须算本轮增量，不能误报失败")

        task.visualRemediationReviewID = nil
        XCTAssertNil(VisualQualityGate.completionBlockReason(
            task: task, attemptChangedFiles: 0, attemptNewCommits: 0),
            "普通核验任务仍可诚实确认已有成果，不能扩大成全局零改动禁令")
    }

    func testFailedVisualReviewRetriesAreCappedPerCommit() {
        let branch = "agent/minimax/grip"
        let head = "c43c026"
        var attempts = (1...3).map { index in
            var task = visual(id: "failed-\(index)", branch: branch, head: head,
                              verdict: "未达标", endedAt: Date())
            task.state = .failed
            task.outputs = []
            return task
        }
        XCTAssertTrue(VisualQualityGate.exhausted(
            branch: branch, head: head, tasks: attempts))

        attempts.removeLast()
        XCTAssertFalse(VisualQualityGate.exhausted(
            branch: branch, head: head, tasks: attempts),
            "第一次失败后仍应允许两次正常重试")
        XCTAssertFalse(VisualQualityGate.exhausted(
            branch: branch, head: "new-head", tasks: attempts),
            "实现产生新提交后必须重新允许视觉验收")
    }

    func testPromptKeepsOnlyLatestVisualRemediation() {
        let prompt = "原始任务\n\n【视觉整改：old】\n旧问题"
            + "\n\n【视觉整改：new】\n新问题"
        let compact = VisualQualityGate.compactRemediationPrompt(prompt)
        XCTAssertTrue(compact.contains("原始任务"))
        XCTAssertFalse(compact.contains("old"))
        XCTAssertFalse(compact.contains("旧问题"))
        XCTAssertTrue(compact.contains("【视觉整改：new】"))
        XCTAssertTrue(compact.contains("新问题"))
    }

    func testLatestVerdictWinsInsteadOfFirstArrayEntry() {
        let branch = "agent/kimi/sample"
        let head = "abc123"
        var old = visual(id: "old", branch: branch, head: head,
                         verdict: "未达标", endedAt: Date(timeIntervalSince1970: 10))
        var fresh = visual(id: "fresh", branch: branch, head: head,
                           verdict: "达标", endedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: head, tasks: [old, fresh]), .approved)
        XCTAssertTrue(VisualQualityGate.hasApproved(branch: branch, tasks: [old, fresh]))

        // 变异钉：只交换新旧结论，必须跟着最新票变，不能退回“见过批准就算过”。
        old.outputs = ["**结论**：达标"]
        fresh.outputs = ["**结论**：未达标"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: head, tasks: [old, fresh]), .rejected)
        XCTAssertFalse(VisualQualityGate.hasApproved(branch: branch, tasks: [old, fresh]))
    }

    func testBlockedReviewPreventsDuplicateDispatch() {
        let branch = "agent/kimi/sample"
        let head = "abc123"
        var waiting = visual(id: "waiting", branch: branch, head: head,
                             verdict: "", endedAt: Date(timeIntervalSince1970: 20))
        waiting.state = .blocked
        waiting.outputs = []
        waiting.note = "MiniMax 视觉读取额度不足"

        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: head, tasks: [waiting]), .pending,
            "等待用户回答的视觉票仍是进行中，不能每轮重复派一张新票")
        XCTAssertEqual(VisualQualityGate.blockedReason(
            branch: branch, head: head, tasks: [waiting]),
            "MiniMax 视觉读取额度不足")
    }

    func testRejectedReviewReopensExactOwnerTaskOnlyOnce() throws {
        let branch = "agent/kimi/source"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var source = WorkTask(
            id: "source", prompt: "继续做黄金样板", repo: fixture.repo.path)
        source.state = .done
        source.branch = branch
        source.landedAt = Date(timeIntervalSince1970: 15)
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        source.preferredPlatform = .kimi
        source.triedPlatforms = [.kimi]
        source.production = ProductionContext(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-v1", requiresExperienceApproval: true)

        var review = visual(id: "eyes", branch: branch, head: fixture.head,
                            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        review.repo = fixture.repo.path
        review.outputs.append("左手悬空，第三人称角色没有武器")

        let reopened = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review], now: Date(timeIntervalSince1970: 30)).only)
        XCTAssertEqual(reopened.id, source.id, "不得另造一条从零加载上下文的新任务")
        XCTAssertEqual(reopened.state, .queued)
        XCTAssertEqual(reopened.ownerPlatform, .kimi)
        XCTAssertEqual(reopened.ownerRunnerID, "kimi.code")
        XCTAssertEqual(reopened.visualRemediationReviewID, review.id)
        XCTAssertNil(reopened.landedAt)
        XCTAssertTrue(reopened.triedPlatforms.isEmpty,
                      "上一轮成功使用过 Kimi 不能反过来把 Kimi 排除掉")
        XCTAssertTrue(reopened.prompt.contains("左手悬空"))

        XCTAssertTrue(VisualQualityGate.reconcileRemediation([reopened, review]).isEmpty,
                      "同一张否决票每轮对账只能重开一次")

        let throughGraph = try XCTUnwrap(TaskGraph.reconcile([source, review])
            .first(where: { $0.id == source.id }))
        XCTAssertEqual(throughGraph.state, .queued,
                       "worker 每轮实际调用的是 TaskGraph.reconcile，闭环不能只停在孤立 helper")
        XCTAssertEqual(throughGraph.ownerRunnerID, "kimi.code")

        var falselyCompleted = reopened
        falselyCompleted.state = .done
        falselyCompleted.note = "派活前核实：分支 \(branch) 已合入 main，产出早已落地"
        let recovered = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [falselyCompleted, review]).only)
        XCTAssertEqual(recovered.state, .queued,
                       "旧分支已合入是上一轮事实，不能把本轮视觉整改判成早已完成")
        XCTAssertEqual(recovered.prompt, reopened.prompt,
                       "恢复假完成不能把同一份视觉报告重复追加进提示词")
    }

    func testVisualRemediationBlocksInvalidPersistedOwnerInsteadOfMisrouting() throws {
        let branch = "agent/kimi/invalid-owner"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var source = WorkTask(
            id: "invalid-owner", prompt: "继续实现角色控制功能", repo: fixture.repo.path)
        source.state = .done
        source.branch = branch
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "minimax.media"
        var review = visual(
            id: "eyes-invalid", branch: branch, head: fixture.head,
            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        review.repo = fixture.repo.path

        let blocked = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review], now: Date(timeIntervalSince1970: 30)).only)
        XCTAssertEqual(blocked.state, .blocked)
        XCTAssertEqual(blocked.waitReason, .ownerUnavailable)
        XCTAssertEqual(blocked.ownerRunnerID, "minimax.media")
        XCTAssertTrue(blocked.note?.contains("等待显式交接") == true)
    }

    func testSecondVisualRejectionPausesInsteadOfStartingThirdImplementationRound() throws {
        let branch = "agent/minimax/sample"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var source = WorkTask(
            id: "sample", prompt: "继续黄金样板", repo: fixture.repo.path)
        source.state = .done
        source.branch = branch
        source.ownerPlatform = .minimax
        source.ownerRunnerID = "minimax.code"
        source.qualityRejectionCount = 1
        var second = visual(id: "second", branch: branch, head: fixture.head,
                            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        second.repo = fixture.repo.path

        let paused = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, second], now: Date(timeIntervalSince1970: 30)).only)
        XCTAssertEqual(paused.state, .blocked)
        XCTAssertEqual(paused.ownerRunnerID, "minimax.code")
        XCTAssertEqual(paused.branch, branch)
        XCTAssertNotNil(paused.pausedAt)
        XCTAssertNil(TaskGraph.nextReady([paused]))
    }

    func testZeroIncrementFailureRetriesOnceWithArchitectCorrection() throws {
        let branch = "agent/minimax/source"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var source = WorkTask(
            id: "source", prompt: "继续做黄金样板", repo: fixture.repo.path)
        source.state = .failed
        source.branch = branch
        source.ownerPlatform = .minimax
        source.ownerRunnerID = "minimax.code"
        source.preferredPlatform = .minimax
        source.visualRemediationReviewID = "eyes"
        source.note = "视觉整改本轮没有产生新改动，不能用分支历史成果判定完成"

        var review = visual(id: "eyes", branch: branch, head: fixture.head,
                            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        review.repo = fixture.repo.path
        review.prompt += "\n" + ArchitectReview.contractMarker
        var architect = WorkTask(id: "aeyes", prompt: "复核", repo: fixture.repo.path)
        architect.origin = "architect-review:eyes"
        architect.state = .done
        architect.outputs = [
            "HP 绿条已经实现；使用现有 Blender 生成链修手部，并补拍低血红条。",
            "**结论**：维持拒绝"
        ]

        let retried = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review, architect], now: Date(timeIntervalSince1970: 30)).only)
        XCTAssertEqual(retried.id, source.id)
        XCTAssertEqual(retried.state, .queued)
        XCTAssertEqual(retried.ownerRunnerID, "minimax.code")
        XCTAssertTrue(retried.prompt.contains("HP 绿条已经实现"))
        XCTAssertTrue(retried.prompt.contains("Blender"))

        var failedAgain = retried
        failedAgain.state = .failed
        failedAgain.note = source.note
        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [failedAgain, review, architect]).isEmpty,
            "同一份架构纠偏只能恢复一次，避免拒绝型 Agent 无限烧额度")
    }

    func testRejectedOlderHeadCannotReopenAdvancedImplementationBranch() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory
            .appendingPathComponent("visual-stale-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: repo) }
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) -> Proc.Result {
            GitWorkspace.git(args, in: repo.path)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.email", "test@example.com"])
        _ = git(["config", "user.name", "Test"])
        try "old\n".write(to: repo.appendingPathComponent("result.txt"),
                          atomically: true, encoding: .utf8)
        _ = git(["add", "-A"]); _ = git(["commit", "-q", "-m", "old"])
        let oldHead = git(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = "agent/minimax/source"
        _ = git(["checkout", "-q", "-b", branch])
        try "new\n".write(to: repo.appendingPathComponent("result.txt"),
                          atomically: true, encoding: .utf8)
        _ = git(["add", "-A"]); _ = git(["commit", "-q", "-m", "new"])

        var source = WorkTask(id: "source", prompt: "继续整改", repo: repo.path)
        source.state = .done
        source.branch = branch
        source.ownerPlatform = .minimax
        source.ownerRunnerID = "minimax.code"
        var staleReview = WorkTask(
            id: "stale-review",
            prompt: "【看效果】分支 \(branch) 提交 \(oldHead) 的视觉质量是否达到项目契约。",
            repo: repo.path)
        staleReview.origin = "visual-quality-review"
        staleReview.state = .done
        staleReview.outputs = ["**结论**：未达标"]

        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [source, staleReview]).isEmpty,
            "分支已有更新提交时，旧提交的否决票不能再次打回实现任务")

        let currentHead = git(["rev-parse", branch]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var currentReview = staleReview
        currentReview.id = "current-review"
        currentReview.prompt = "【看效果】分支 \(branch) 提交 \(currentHead) 的视觉质量是否达到项目契约。"
        XCTAssertEqual(VisualQualityGate.reconcileRemediation(
            [source, currentReview]).count, 1,
            "当前分支头自己的否决票仍必须正常打回，不能把质量闸整体关闭")
    }

    func testOlderRejectedSampleIsIgnoredWhenNewerContinuationExists() {
        let branch = "agent/kimi/old"
        var old = WorkTask(id: "old", prompt: "第一轮", repo: "/flint")
        old.state = .done
        old.branch = branch
        old.createdAt = Date(timeIntervalSince1970: 1)
        old.production = ProductionContext(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-v1", requiresExperienceApproval: true)
        let rejected = visual(id: "eyes-old", branch: branch, head: "aaa",
                              verdict: "未达标", endedAt: Date(timeIntervalSince1970: 10))
        var continuation = WorkTask(id: "new", prompt: "第二轮整改", repo: "/flint")
        continuation.createdAt = Date(timeIntervalSince1970: 20)
        continuation.production = old.production

        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [old, rejected, continuation]).isEmpty,
            "部署闭环机制不能把已经被后续续作接住的历史否决重新翻出来")
    }

    func testHistoricalRejectionCannotOverwriteActiveOrNewerRemediation() {
        let branch = "agent/openrouter/grip"
        let old = visual(id: "old-review", branch: branch, head: "aaa",
                         verdict: "未达标", endedAt: Date(timeIntervalSince1970: 10))
        let fresh = visual(id: "fresh-review", branch: branch, head: "bbb",
                           verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        var source = WorkTask(id: "grip", prompt: "继续整改握枪", repo: "/flint")
        source.branch = branch
        source.ownerPlatform = .openrouter
        source.ownerRunnerID = "opencode.openrouter.code"
        source.visualRemediationReviewID = fresh.id

        source.state = .running
        source.runnerPID = 123
        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [source, old, fresh]).isEmpty,
            "历史否决不能把真实运行中的任务覆盖回排队")

        source.state = .done
        source.runnerPID = nil
        source.note = "完成本轮整改"
        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [source, old, fresh]).isEmpty,
            "已经处理较新否决后，旧票不能在收工时再次倒灌")
    }

    func testPlatformQuotaFailureSurvivesHistoricalVisualReconciliation() throws {
        let branch = "agent/qwen/74726e09"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var source = WorkTask(
            id: "74726e09", prompt: "继续 Flint 黄金样板", repo: fixture.repo.path)
        source.state = .failed
        source.branch = branch
        source.ownerPlatform = .qwen
        source.ownerRunnerID = "qwen.code"
        source.terminalFailureKind = .quotaExhausted
        source.note = "Qwen：周额度用尽；reset at 09-04 13:14 UTC"
        var historical = visual(
            id: "old-rejection", branch: branch, head: fixture.head,
            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        historical.repo = fixture.repo.path

        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [source, historical]).isEmpty)
        XCTAssertFalse(TaskGraph.reconcile([source, historical]).contains {
            $0.id == source.id && $0.state == .queued
        }, "完整 TaskGraph 对账不得把真实额度失败改写成视觉整改排队")
    }

    func testUnreadableGitStateFailsClosedInsteadOfReopening() {
        let branch = "agent/qwen/source"
        var source = WorkTask(id: "source", prompt: "继续整改", repo: "/不存在的仓库")
        source.state = .done
        source.branch = branch
        let review = visual(
            id: "unverifiable", branch: branch, head: "abc123",
            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        var matchingReview = review
        matchingReview.repo = source.repo

        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [source, matchingReview]).isEmpty,
            "Git 无法确认票据对应当前分支时必须保守等待，不能按未前进处理")
    }

    private func visual(id: String, branch: String, head: String,
                        verdict: String, endedAt: Date) -> WorkTask {
        var task = WorkTask(
            id: id,
            prompt: "【看效果】分支 \(branch) 提交 \(head) 的视觉质量是否达到项目契约。",
            repo: "/flint")
        task.origin = "visual-quality-review"
        task.state = .done
        task.createdAt = endedAt.addingTimeInterval(-1)
        task.endedAt = endedAt
        task.outputs = ["**结论**：\(verdict)"]
        return task
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
