import XCTest
@testable import LLMQuotaCore

final class ReviewArtifactCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ReviewArtifactCache.resetForTesting()
    }

    func testCompletedTaskArtifactIsLoadedOncePerRevision() {
        var task = WorkTask(id: "review", prompt: "", repo: "/tmp/repo")
        task.branch = "agent/minimax/review"
        task.state = .done
        var loads = 0
        let loader = { () -> String? in loads += 1; return "report" }

        XCTAssertEqual(ReviewArtifactCache.load(task: task, path: "reviews/a.md", loader: loader), "report")
        XCTAssertEqual(ReviewArtifactCache.load(task: task, path: "reviews/a.md", loader: loader), "report")
        XCTAssertEqual(loads, 1)

        task.rev += 1
        XCTAssertEqual(ReviewArtifactCache.load(task: task, path: "reviews/a.md", loader: loader), "report")
        XCTAssertEqual(loads, 2, "a new task revision must not reuse stale report text")
    }

    func testMissingArtifactIsRetried() {
        var task = WorkTask(id: "review", prompt: "", repo: "/tmp/repo")
        task.branch = "agent/minimax/review"
        task.state = .done
        var loads = 0
        let loader = { () -> String? in loads += 1; return nil }

        XCTAssertNil(ReviewArtifactCache.load(task: task, path: "reviews/a.md", loader: loader))
        XCTAssertNil(ReviewArtifactCache.load(task: task, path: "reviews/a.md", loader: loader))
        XCTAssertEqual(loads, 2, "a report that appears later must remain discoverable")
    }
}
