import XCTest
@testable import LLMQuotaCore

final class ReviewFeedReadinessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-feed-readiness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root
        RepoRegistry.fileOverride = root.appendingPathComponent("repos.json")
        try Data("[]".utf8).write(to: RepoRegistry.fileOverride!)
    }

    override func tearDownWithError() throws {
        RepoRegistry.fileOverride = nil
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture() throws -> [Review.Digest] {
        let reviews: [[String: Any]] = [
            ["sourceMachineID": "machine-a", "repo": "/tmp/game", "repoName": "game", "branch": "agent/codex/ready",
             "head": String(repeating: "1", count: 40), "platform": "codex", "subject": "可确认成果",
             "files": ["Game.swift"], "insertions": 2, "deletions": 1, "mergesCleanly": true,
             "overlapsWith": [], "evidence": ["ready.png"], "evidenceFiles": ["ready.png"]],
            ["sourceMachineID": "machine-a", "repo": "/tmp/game", "repoName": "game", "branch": "agent/kimi/progress",
             "head": String(repeating: "2", count: 40), "platform": "kimi", "subject": "仍在检查的成果",
             "files": ["Game.swift"], "insertions": 4, "deletions": 0, "mergesCleanly": true,
             "overlapsWith": [], "evidence": ["progress.png"], "evidenceFiles": ["progress.png"],
             "landingBlockReason": "视觉验收尚未完成"]
        ]
        let data = try JSONSerialization.data(withJSONObject: reviews)
        return try SnapshotCoding.decoder().decode([Review.Digest].self, from: data)
    }

    func testNowPageSeparatesConfirmationFromRetainedProgress() throws {
        let sections = ViewFeed.nowReviewSections(try fixture())
        let awaiting = try XCTUnwrap(sections.first { $0.title == "等你验收" })
        XCTAssertEqual(awaiting.cards?.map(\.title), ["可确认成果"])
        XCTAssertEqual(awaiting.note, "1 份产出跑完了在等你")
        let progress = try XCTUnwrap(sections.first { $0.title == "保留成果" })
        XCTAssertEqual(progress.cards?.map(\.title), ["仍在检查的成果"])
        XCTAssertTrue(progress.note?.contains("无需你现在确认") == true)
        XCTAssertFalse(progress.cards?.first?.actions.contains { $0.id.contains("review:merge:") } == true)
    }

    func testReviewPageLabelsBlockedCardAsProgressInsteadOfHumanTodo() throws {
        let card = ViewFeed.reviewCard(try fixture()[1])
        XCTAssertTrue(card.body?.contains("保留成果，无需你确认") == true)
        XCTAssertFalse(card.actions.contains { $0.id.contains("review:merge:") })
        XCTAssertFalse(card.actions.contains { $0.id.contains("review:discard:") })
    }

    func testNudgeCountsOnlyReviewsThatCanActuallyBeConfirmed() throws {
        try FileManager.default.createDirectory(at: Paths.sharedRoot, withIntermediateDirectories: true)
        try SnapshotCoding.encoder().encode(fixture())
            .write(to: Paths.sharedRoot.appendingPathComponent("reviews.json"), options: .atomic)
        let reviewNudges = Nudge.pending(tasks: [], publishedAsks: [])
            .filter { $0.key.hasPrefix("review-") }
        XCTAssertEqual(reviewNudges.map(\.key), ["review-1"])
        XCTAssertTrue(reviewNudges.first?.body.contains("可确认成果") == true)
    }
}
