import XCTest
@testable import LLMQuotaCore

final class WorkAttemptSessionTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempt-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        WorkAttemptStore.fileOverride = scratch.appendingPathComponent("attempts.jsonl")
    }

    override func tearDown() {
        WorkAttemptStore.fileOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func attempt(
        id: String, outcome: WorkAttempt.Outcome, startedAt: Date
    ) -> WorkAttempt {
        WorkAttempt(
            attemptID: id, taskID: "flint", runnerID: "minimax.code",
            platform: .minimax, startedAt: startedAt,
            endedAt: outcome == .running ? nil : startedAt.addingTimeInterval(10),
            outcome: outcome, timedOut: false,
            sessionSupport: .stableID, sessionAction: .create)
    }

    func testLaterSuccessSupersedesOlderSessionFailure() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var failed = attempt(id: "old", outcome: .failed, startedAt: start)
        failed.failureKind = "sessionInvalid"
        failed.handoffReason = "No conversation found with session ID"
        try WorkAttemptStore.append(failed)
        try WorkAttemptStore.append(attempt(
            id: "new", outcome: .done, startedAt: start.addingTimeInterval(20)))

        XCTAssertEqual(
            WorkAttemptStore.latestTerminal(
                taskID: "flint", runnerID: "minimax.code")?.outcome,
            .done,
            "后来成功的新会话必须压过旧会话失败，不能把有效会话误删")
    }

    func testRunningEventDoesNotHideLatestTerminalAttempt() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        try WorkAttemptStore.append(attempt(id: "done", outcome: .done, startedAt: start))
        try WorkAttemptStore.append(attempt(
            id: "current", outcome: .running, startedAt: start.addingTimeInterval(20)))

        XCTAssertEqual(
            WorkAttemptStore.latestTerminal(
                taskID: "flint", runnerID: "minimax.code")?.attemptID,
            "done")
    }

    func testLatestSnapshotsDoesNotShowTerminalAttemptAsStillRunning() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let id = "same-attempt"
        try WorkAttemptStore.append(attempt(id: id, outcome: .running, startedAt: start))
        try WorkAttemptStore.append(attempt(id: id, outcome: .failed, startedAt: start))
        try WorkAttemptStore.append(attempt(
            id: "active", outcome: .running, startedAt: start.addingTimeInterval(20)))

        let snapshots = WorkAttemptStore.latestSnapshots()
        XCTAssertEqual(snapshots.map(\.attemptID), [id, "active"])
        XCTAssertEqual(snapshots.map(\.outcome), [.failed, .running])
    }
}
