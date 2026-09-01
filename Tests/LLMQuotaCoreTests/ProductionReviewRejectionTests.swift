import XCTest
@testable import LLMQuotaCore

final class ProductionReviewRejectionTests: XCTestCase {
    func testHumanRejectionKeepsGoldenSampleOwnerBranchAndContext() {
        let started = Date(timeIntervalSince1970: 100)
        let retried = Date(timeIntervalSince1970: 200)
        var task = WorkTask(id: "74726e09", prompt: "继续修 Flint 握枪",
                            repo: "/tmp/Flint")
        task.state = .done
        task.branch = "agent/minimax/74726e09"
        task.platform = .minimax
        task.preferredPlatform = .minimax
        task.ownerPlatform = .minimax
        task.ownerRunnerID = "minimax.code"
        task.ownerAssignedAt = started
        task.startedAt = started
        task.endedAt = started
        task.runnerPID = 42
        task.outputs = ["旧输出"]
        task.triedPlatforms = [.minimax]
        task.discardedAt = started
        task.discardReason = "两个手的握枪姿势都不对"
        task.production = .init(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-yan-v1", requiresExperienceApproval: true)

        let result = Review.requeuedAfterHumanRejection(
            task, reason: "两个手的握枪姿势都不对",
            head: "171c60eef117a11bb6674ff06ade3251bb114a49", now: retried)

        XCTAssertEqual(result.state, .queued)
        XCTAssertEqual(result.branch, task.branch)
        XCTAssertEqual(result.ownerRunnerID, "minimax.code")
        XCTAssertEqual(result.ownerPlatform, .minimax)
        XCTAssertEqual(result.ownerAssignedAt, started)
        XCTAssertEqual(result.preferredPlatform, .minimax)
        XCTAssertEqual(result.createdAt, retried)
        XCTAssertNil(result.startedAt)
        XCTAssertNil(result.endedAt)
        XCTAssertNil(result.runnerPID)
        XCTAssertNil(result.discardedAt)
        XCTAssertNil(result.discardReason)
        XCTAssertNil(result.pendingAsk)
        XCTAssertNil(result.answeredAsk)
        XCTAssertTrue(result.outputs.isEmpty)
        XCTAssertTrue(result.triedPlatforms.isEmpty)
        XCTAssertTrue(result.prompt.contains("【你的效果反馈：171c60ee】"))
        XCTAssertTrue(result.prompt.contains("两个手的握枪姿势都不对"))
        XCTAssertTrue(result.prompt.contains("【本轮整改授权：171c60ee】"))
        XCTAssertTrue(result.prompt.contains("不得修改、绕过或放宽质量门槛"))
        XCTAssertTrue(result.note?.contains("已保留分支") == true)
    }

    func testRepeatedSameHeadRejectionDoesNotDuplicatePromptFeedback() {
        var task = WorkTask(id: "sample", prompt: "原始任务", repo: "/tmp/Flint")
        task.production = .init(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-v1", requiresExperienceApproval: true)
        let once = Review.requeuedAfterHumanRejection(
            task, reason: "手势不对", head: "abcdef0123456789")
        let twice = Review.requeuedAfterHumanRejection(
            once, reason: "手势不对", head: "abcdef0123456789")

        XCTAssertEqual(
            twice.prompt.components(separatedBy: "【你的效果反馈：abcdef01】").count,
            2)
        XCTAssertEqual(
            twice.prompt.components(separatedBy: "【本轮整改授权：abcdef01】").count,
            2)
        XCTAssertEqual(twice.state, .blocked,
                       "连续两轮效果拒绝必须暂停，不能被新提交无限重开")
        XCTAssertNotNil(twice.pausedAt)
    }

    func testFailedRemediationCanRecoverLatestHumanFeedbackWithoutHistoryBloat() {
        let prompt = """
        原始任务

        【你的效果反馈：171c60ee】
        两个手的握枪姿势都不对

        【本轮整改授权：171c60ee】
        旧授权
        """
        XCTAssertEqual(Review.latestHumanFeedback(in: prompt),
                       "两个手的握枪姿势都不对")

        var failed = WorkTask(id: "74726e09", prompt: prompt, repo: "/tmp/Flint")
        failed.state = .failed
        failed.branch = "agent/minimax/74726e09"
        failed.ownerPlatform = .minimax
        failed.note = "视觉整改本轮没有产生新改动"
        let retried = Review.requeuedAfterHumanRejection(
            failed, reason: try! XCTUnwrap(Review.latestHumanFeedback(in: prompt)),
            head: "6d77ba3aa362dba8d90577c5095633e2ee3a6ed7")
        XCTAssertEqual(retried.state, .queued)
        XCTAssertTrue(retried.prompt.contains("【你的效果反馈：6d77ba3a】"))
        XCTAssertTrue(retried.prompt.contains("【本轮整改授权：6d77ba3a】"))
        XCTAssertEqual(Review.latestHumanFeedback(in: retried.prompt),
                       "两个手的握枪姿势都不对")
    }

    func testExperienceReviewUsesRemediationSemanticsAndIgnoresOldBranchDecision() {
        var task = WorkTask(id: "74726e09", prompt: "继续整改", repo: "/tmp/Flint")
        task.state = .done
        task.branch = "agent/minimax/74726e09"
        task.production = .init(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-v1", requiresExperienceApproval: true)

        XCTAssertTrue(Review.isExperienceRemediation(
            branch: "agent/minimax/74726e09", tasks: [task]))
        XCTAssertEqual(Review.rejectionLabel(
            branch: "agent/minimax/74726e09", tasks: [task]), "退回整改")
        XCTAssertFalse(Review.shouldHideAfterDecision(
            repo: "/tmp/Flint", branch: "agent/minimax/74726e09", tasks: [task],
            done: ["/tmp/Flint|agent/minimax/74726e09|discard"]))

        var ordinary = task
        ordinary.production = nil
        XCTAssertFalse(Review.isExperienceRemediation(
            branch: "agent/minimax/74726e09", tasks: [ordinary]))
        XCTAssertEqual(Review.rejectionLabel(
            branch: "agent/minimax/74726e09", tasks: [ordinary]), "丢弃")
        XCTAssertTrue(Review.shouldHideAfterDecision(
            repo: "/tmp/Flint", branch: "agent/minimax/74726e09", tasks: [ordinary],
            done: ["/tmp/Flint|agent/minimax/74726e09|discard"]))
    }

    func testEachVerdictClickGetsARevisionScopedIdempotencyKey() {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let old = Review.Verdict(repo: "/tmp/Flint", branch: "agent/minimax/74726e09",
                                 action: "discard", reason: "手势不对", decidedAt: t0)
        let newer = Review.Verdict(repo: old.repo, branch: old.branch,
                                   action: old.action, reason: "还是不对", decidedAt: t1)
        XCTAssertNotEqual(Review.verdictDoneKey(old), Review.verdictDoneKey(newer))
    }
}
