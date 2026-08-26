import XCTest
@testable import LLMQuotaCore

final class WorkRunTargetTests: XCTestCase {
    private func task(_ id: String) -> WorkTask {
        WorkTask(id: id, prompt: "任务 \(id)", repo: "/tmp/repo")
    }

    func testExplicitIDIgnoresOptions() {
        XCTAssertEqual(
            WorkRunTarget.explicitID(arguments: ["74726e09", "--dry-run"]),
            "74726e09")
        XCTAssertNil(WorkRunTarget.explicitID(arguments: ["--dry-run"]))
    }

    func testExplicitRunCannotFallThroughToAnotherReadyTask() {
        let target = task("74726e09")
        let unrelated = task("274147a0")

        XCTAssertEqual(
            WorkRunTarget.select(
                ready: [target, unrelated], explicitID: "74726e09").map(\.id),
            ["74726e09"])
    }

    func testUnavailableExplicitTargetDoesNotSelectQueueFallback() {
        let unrelated = task("274147a0")

        XCTAssertTrue(
            WorkRunTarget.select(
                ready: [unrelated], explicitID: "74726e09").isEmpty,
            "点名任务不可运行时必须退出，不能偷跑队列里的其他任务")
    }

    func testUnscopedWorkerStillReceivesWholeReadyQueue() {
        let tasks = [task("a"), task("b")]
        XCTAssertEqual(
            WorkRunTarget.select(ready: tasks, explicitID: nil).map(\.id),
            ["a", "b"])
    }
}
