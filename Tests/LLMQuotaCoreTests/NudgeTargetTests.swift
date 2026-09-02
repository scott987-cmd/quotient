import XCTest
@testable import LLMQuotaCore

/// **别推一件他点进去做不了的事。**
///
/// 老板 2026-08-22 两次报同一件事:「收到消息说让我评审,进去之后就没有了」
/// 「老是有一个消息让我审批,手机点进去就没有了」。
/// 每次的具体原因都不同(成果页没做、拦截没按钮、搁浅根本没有页面),
/// 形状却是同一个。逐个修是打地鼠 —— 这道闸拦的是整类:
/// 推送之前先看它指向的那一页有没有东西。
final class NudgeTargetTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmp() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func publish(_ page: String, cards: Int) {
        _ = ViewFeed.publish(ViewFeed.Page(
            page: page,
            sections: [ViewFeed.Section(
                kind: "cards", title: "t",
                cards: (0..<cards).map {
                    ViewFeed.Card(id: "c\($0)", title: "卡", body: "b")
                })],
            now: Date()))
    }

    func testSuppressedWhenPageIsEmpty() {
        publish("review", cards: 0)
        XCTAssertFalse(Nudge.hasSomethingToShow(key: "review-1"),
                       "页面空的时候推「1 份产出等你验收」,人点进去只会看到一片空白")
    }

    func testSentWhenPageHasCards() {
        publish("review", cards: 2)
        XCTAssertTrue(Nudge.hasSomethingToShow(key: "review-2"))
    }

    func testMilestoneNotificationTargetsReviewPage() {
        publish("review", cards: 1)
        XCTAssertEqual(Nudge.targetPage(for: "milestone-1-deadbeef"), "review")
        XCTAssertTrue(Nudge.hasSomethingToShow(key: "milestone-1-deadbeef"))
    }

    func testMilestoneWaitsUntilCardAndEvidenceReachMobileRoot() throws {
        let local = tmp()
        let mobile = tmp()
        let image = "checkpoint.jpg"
        let card = ViewFeed.Card(id: "repo|deadbeef", title: "阶段成果",
                                 images: [image])
        let page = ViewFeed.Page(page: "review", sections: [
            ViewFeed.Section(kind: "cards", cards: [card])
        ])
        XCTAssertTrue(ViewFeed.publish(page, root: local))
        XCTAssertFalse(Nudge.mobileContentReady(
            key: "milestone-1-deadbeef", localRoot: local, mobileRoot: mobile))

        XCTAssertTrue(ViewFeed.publish(page, root: mobile))
        XCTAssertFalse(Nudge.mobileContentReady(
            key: "milestone-1-deadbeef", localRoot: local, mobileRoot: mobile),
            "页面先到、证据没到时也不能提前推送")

        let evidence = mobile.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: evidence.appendingPathComponent(image))
        XCTAssertTrue(Nudge.mobileContentReady(
            key: "milestone-1-deadbeef", localRoot: local, mobileRoot: mobile))
    }

    func testMilestoneReadinessIgnoresUnrelatedOldCardWithMissingEvidence() throws {
        let local = tmp()
        let mobile = tmp()
        let current = ViewFeed.Card(id: "repo|deadbeef", title: "本次成果",
                                    images: ["current.jpg"])
        let old = ViewFeed.Card(id: "repo|old", title: "旧成果",
                                images: ["already-cleaned.jpg"])
        let page = ViewFeed.Page(page: "review", sections: [
            ViewFeed.Section(kind: "cards", cards: [current, old])
        ])
        XCTAssertTrue(ViewFeed.publish(page, root: local))
        XCTAssertTrue(ViewFeed.publish(page, root: mobile))
        let evidence = mobile.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: evidence.appendingPathComponent("current.jpg"))

        XCTAssertTrue(Nudge.mobileContentReady(
            key: "milestone-2-deadbeef", localRoot: local, mobileRoot: mobile),
            "旧卡片的证据已清理时，不能拦住本次成果通知")
    }

    /// 没有对应页面的推送(比如搁浅)一律拦下 —— 那正是他第二次报的那条。
    func testUnpublishedPageIsSuppressed() {
        XCTAssertFalse(Nudge.hasSomethingToShow(key: "blocked-1"))
    }

    /// 不指向任何一页的提醒照旧放行(额度类落在原生看板上),
    /// 否则这道闸会把有用的提醒一起掐掉。
    func testNonPageNudgesStillGoOut() {
        XCTAssertTrue(Nudge.hasSomethingToShow(key: "wasting-claude-5h"))
        XCTAssertTrue(Nudge.hasSomethingToShow(key: "trouble-3"))
    }
}
