import XCTest
@testable import LLMQuotaCore

final class TaskPauseTests: XCTestCase {
    func testPausePreservesContextAndLeavesDispatchQueue() {
        var task = WorkTask(id: "flint", prompt: "继续黄金样板", repo: "/tmp/Flint")
        task.state = .running
        task.branch = "agent/minimax/flint"
        task.ownerPlatform = .minimax
        task.ownerRunnerID = "minimax.code"
        task.runnerPID = 123
        task.outputs = ["checkpoint"]
        task.handoff = Handoff(fromPlatform: .kimi, reason: "额度交接",
                               touchedFiles: ["a.swift"], wipCommit: "abc", elapsedSeconds: 1)

        let paused = TaskPause.pause(
            task, reason: "同一质量问题不再重复修改",
            now: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(paused.state, .blocked)
        XCTAssertEqual(paused.branch, task.branch)
        XCTAssertEqual(paused.ownerRunnerID, task.ownerRunnerID)
        XCTAssertEqual(paused.handoff?.wipCommit, "abc")
        XCTAssertEqual(paused.outputs, ["checkpoint"])
        XCTAssertNil(paused.runnerPID)
        XCTAssertEqual(paused.pauseReason, "同一质量问题不再重复修改")
        XCTAssertNil(TaskGraph.nextReady([paused]), "暂停任务不能被后台循环领取")
        let brief = TaskBoard.build(from: [paused], machineName: "Mac").tasks.first
        XCTAssertEqual(brief?.progressPhase, "已暂停 · 等待架构决策")
        XCTAssertTrue(brief?.progressSummary?.contains("已暂停") == true)
    }

    func testTwoQualityRejectionsPauseUntilExplicitResume() {
        var task = WorkTask(id: "sample", prompt: "做黄金样板", repo: "/tmp/Flint")
        XCTAssertFalse(TaskPause.registerQualityRejection(&task, reason: "第一轮"))
        XCTAssertEqual(task.qualityRejectionCount, 1)
        XCTAssertTrue(TaskPause.registerQualityRejection(
            &task, reason: "第二轮", now: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(task.state, .blocked)
        XCTAssertNotNil(task.pausedAt)
        XCTAssertNotNil(task.architectureReviewRequestedAt)

        let resumed = TaskPause.resume(task, now: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pausedAt)
        XCTAssertEqual(resumed.qualityRejectionCount, 0)
        XCTAssertEqual(TaskGraph.nextReady([resumed])?.id, resumed.id)
    }

    func testArchitectureReviewPauseRequiresExplicitUserOverride() {
        var task = WorkTask(id: "sample", prompt: "继续黄金样板", repo: "/tmp/Flint")
        task = TaskPause.requestArchitectureReview(
            task, reason: "架构结论要求保持暂停", now: Date(timeIntervalSince1970: 20))
        task.qualityRejectionCount = 2
        let requestedAt = task.architectureReviewRequestedAt

        XCTAssertFalse(TaskPause.canResume(task))
        XCTAssertTrue(TaskPause.canResume(task, userOverride: true))

        let resumed = TaskPause.resume(
            task, reason: "用户明确继续", preserveQualityHistory: true)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertEqual(resumed.architectureReviewRequestedAt, requestedAt,
                       "强制恢复是覆盖决定，不得抹掉曾触发架构重审的审计历史")
        XCTAssertEqual(resumed.qualityRejectionCount, 2,
                       "强制恢复不得把两轮质量失败伪装成从未发生")
        XCTAssertEqual(resumed.note, "用户明确继续")
    }
}
