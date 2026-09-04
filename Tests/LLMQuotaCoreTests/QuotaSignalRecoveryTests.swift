import XCTest
@testable import LLMQuotaCore

final class QuotaSignalRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func attempt(
        id: String, platform: Platform = .qwen, outcome: WorkAttempt.Outcome,
        endedAt: Date, reason: String? = nil
    ) -> WorkAttempt {
        WorkAttempt(
            attemptID: id, taskID: "task", runnerID: platform.rawValue + ".code",
            platform: platform, startedAt: endedAt.addingTimeInterval(-60),
            endedAt: endedAt, outcome: outcome,
            failureKind: outcome == .failed ? "platformUnavailable" : nil,
            timedOut: false, handoffReason: reason)
    }

    func testQuotaFailureSurvivesThroughAttemptLedger() throws {
        let reset = now.addingTimeInterval(3 * 86400)
        let resetText = ISO8601DateFormatter().string(from: reset)
        let failed = attempt(
            id: "quota", outcome: .failed, endedAt: now.addingTimeInterval(-600),
            reason: "insufficient_quota: 429 token-plan quota exhausted; reset at \(resetText)")

        let hit = try XCTUnwrap(QuotaSignal.hitsFromAttempts([failed], now: now).first)
        XCTAssertEqual(hit.platform, .qwen)
        XCTAssertEqual(hit.resetsAt?.timeIntervalSince1970 ?? 0,
                       reset.timeIntervalSince1970, accuracy: 1)
    }

    func testLaterSuccessPreventsOldQuotaFailureFromBeingReplayed() {
        let failure = attempt(
            id: "old", outcome: .failed, endedAt: now.addingTimeInterval(-600),
            reason: "429 quota exhausted")
        let success = attempt(
            id: "new", outcome: .done, endedAt: now.addingTimeInterval(-60))

        XCTAssertTrue(QuotaSignal.hitsFromAttempts([failure, success], now: now).isEmpty)
    }

    func testExpiredAttemptSignalDoesNotRefreezePlatform() {
        let failed = attempt(
            id: "expired", outcome: .failed, endedAt: now.addingTimeInterval(-7 * 3600),
            reason: "429 quota exhausted")

        XCTAssertTrue(QuotaSignal.hitsFromAttempts([failed], now: now).isEmpty)
    }

    func testQuotaFailedTaskRecoversOnlyAfterRecordedDeadline() throws {
        var task = WorkTask(id: "flint", prompt: "继续原任务", repo: "/tmp/Flint")
        task.state = .failed
        task.ownerPlatform = .qwen
        task.ownerRunnerID = "qwen.code"
        task.branch = "agent/qwen/flint"
        task.terminalFailureKind = .quotaExhausted
        task.retryNotBefore = now.addingTimeInterval(60)
        task.qualityRejectionCount = 2

        XCTAssertTrue(TaskGraph.reconcile([task], now: now).isEmpty,
                      "冷却未到期不得把失败态伪装成排队")

        let recovered = try XCTUnwrap(TaskGraph.reconcile(
            [task], now: now.addingTimeInterval(61)).first)
        XCTAssertEqual(recovered.state, .queued)
        XCTAssertEqual(recovered.ownerRunnerID, "qwen.code")
        XCTAssertEqual(recovered.branch, "agent/qwen/flint")
        XCTAssertEqual(recovered.qualityRejectionCount, 2)
        XCTAssertNil(recovered.terminalFailureKind)
        XCTAssertNil(recovered.retryNotBefore)
    }

    func testTemporaryEnvironmentFailureRecoversAfterBackoff() throws {
        var task = WorkTask(id: "flint-env", prompt: "继续原任务", repo: "/tmp/Flint")
        task.state = .failed
        task.ownerPlatform = .volcark
        task.ownerRunnerID = "opencode.volcark.code"
        task.branch = "agent/volcark/flint-env"
        task.terminalFailureKind = .environmentBroken
        task.retryNotBefore = now.addingTimeInterval(120)

        XCTAssertTrue(TaskGraph.reconcile([task], now: now).isEmpty)
        let recovered = try XCTUnwrap(TaskGraph.reconcile(
            [task], now: now.addingTimeInterval(121)).first)
        XCTAssertEqual(recovered.state, .queued)
        XCTAssertEqual(recovered.ownerRunnerID, "opencode.volcark.code")
        XCTAssertEqual(recovered.branch, "agent/volcark/flint-env")
        XCTAssertNil(recovered.terminalFailureKind)
        XCTAssertNil(recovered.retryNotBefore)
    }
}
