import XCTest
@testable import LLMQuotaCore

final class PostLandRepairTests: XCTestCase {
    func testConcreteReviewFindingCreatesSameOwnerRepairExactlyOnce() throws {
        var source = WorkTask(id: "source1", prompt: "实现战斗逻辑", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source1"
        source.platform = .kimi
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"

        var review = WorkTask(
            id: "review1",
            prompt: """
            【审查】复查刚合入 main 的合并 abc1234（来源分支 agent/kimi/source1）。
            \(PostLandRepair.contractMarker)
            产出：把结论写进 reviews/REVIEW-abc1234.md
            """,
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done

        let report = """
        # 审查
        ### 1. GameScene.swift:113 — 玩家子弹打不中 bot（高）
        """
        let made = PostLandRepair.reconcile([source, review]) { _ in report }
        XCTAssertEqual(made.count, 1)
        let repair = try XCTUnwrap(made.first)
        XCTAssertEqual(repair.id, "rreview1",
                       "两台 worker 同时对账时不能生成两个逻辑整改任务")
        XCTAssertEqual(repair.origin, "post-land-repair:review1")
        XCTAssertEqual(repair.ownerPlatform, Platform.kimi)
        XCTAssertEqual(repair.ownerRunnerID, "kimi.code")
        XCTAssertTrue(repair.prompt.contains("GameScene.swift:113"))

        XCTAssertTrue(PostLandRepair.reconcile(
            [source, review, repair], reportText: { _ in report }).isEmpty,
            "同一份审查报告只能创建一条整改")
    }

    func testPassingReviewCreatesNoRepair() {
        var review = WorkTask(id: "review2", prompt: "【审查】审查通过",
                              repo: "/flint")
        review.prompt += "\n" + PostLandRepair.contractMarker
        review.origin = "post-land-review"
        review.state = .done
        XCTAssertTrue(PostLandRepair.reconcile([review]) { _ in
            "# 审查\n审查通过：没有发现逻辑问题。"
        }.isEmpty)
    }

    func testHistoricalReviewsAreNotBackfilledIntoAQueueFlood() {
        var old = WorkTask(id: "oldreview", prompt: "【审查】旧格式报告", repo: "/flint")
        old.origin = "post-land-review"
        old.state = .done
        XCTAssertTrue(PostLandRepair.reconcile([old]) { _ in
            "### 1. Old.swift:10 — 历史问题（低）"
        }.isEmpty, "启用机制时不能把所有历史报告一次性翻成新任务")
    }

    func testTaskGraphReadsRealReportAndQueuesRepair() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-land-\(UUID().uuidString)")
        let reviews = repo.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "### 1. Store.swift:42 — 并发写会丢记录（中）\n".write(
            to: reviews.appendingPathComponent("REVIEW-deadbee.md"),
            atomically: true, encoding: .utf8)

        var source = WorkTask(id: "source3", prompt: "实现存储", repo: repo.path)
        source.state = .done
        source.branch = "agent/codex/source3"
        source.ownerPlatform = .codex
        source.ownerRunnerID = "codex"
        var review = WorkTask(
            id: "review3",
            prompt: "【审查】（来源分支 agent/codex/source3）。"
                + PostLandRepair.contractMarker + " 写入 reviews/REVIEW-deadbee.md",
            repo: repo.path)
        review.origin = "post-land-review"
        review.state = .done

        let repair = try XCTUnwrap(TaskGraph.reconcile([source, review]).first {
            $0.origin == "post-land-repair:review3"
        })
        XCTAssertEqual(repair.state, .queued)
        XCTAssertEqual(repair.ownerRunnerID, "codex")
    }
}
