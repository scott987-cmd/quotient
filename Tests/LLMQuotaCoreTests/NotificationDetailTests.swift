import XCTest
@testable import LLMQuotaCore

final class NotificationDetailTests: XCTestCase {
    private var roots: [URL] = []
    private func tmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url); return url
    }
    override func setUpWithError() throws {
        Paths.appSupportOverride = try tmp()
        AskStore.rootOverride = try tmp()
    }
    override func tearDown() {
        Paths.appSupportOverride = nil; AskStore.rootOverride = nil
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    private func record(machine: String = "m2", detail: String = "M2 完整证据") -> NotificationDetail.Record {
        let page = ViewFeed.Page(page: "review", sections: [.init(kind: "cards", cards: [
            .init(id: "same-task", title: "待复核", detail: detail, images: ["evidence.jpg"],
                  actions: [.init(id: "dangerous-old-approval", label: "合入")])
        ], actions: [.init(id: "also-dangerous", label: "放行")])])
        return NotificationDetail.make(key: "milestone-1-sha", kind: .needsYou,
                                       body: "成果就绪", machineID: machine, page: page, now: Date())
    }
    func testMachineAndContentArePartOfStableIdentity() {
        XCTAssertEqual(record().id, record().id)
        XCTAssertNotEqual(record().id, record(machine: "mini").id)
        XCTAssertNotEqual(record().id, record(detail: "新的真实证据").id)
        XCTAssertNotEqual(record().sourcePage, record(machine: "mini").sourcePage)
    }
    func testArchivePreservesDetailsButCannotReplayActions() {
        let saved = record()
        XCTAssertEqual(saved.content?.sections.first?.cards?.first?.detail, "M2 完整证据")
        XCTAssertEqual(saved.content?.sections.first?.cards?.first?.images, ["evidence.jpg"])
        XCTAssertTrue(saved.content?.sections.first?.cards?.first?.actions.isEmpty == true)
        XCTAssertTrue(saved.content?.sections.first?.actions?.isEmpty == true)
    }
    func testPublicationReadinessAndOtherMachineOverwrite() throws {
        let local = try tmp(), mobile = try tmp(), saved = record()
        XCTAssertFalse(NotificationDetail.ready(saved, mobileRoot: mobile))
        XCTAssertTrue(NotificationDetail.publish(saved, localRoot: local, mobileRoot: mobile))
        XCTAssertFalse(NotificationDetail.ready(saved, mobileRoot: mobile), "媒体没到不能声称已就绪")
        let evidence = mobile.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: evidence.appendingPathComponent("evidence.jpg"))
        XCTAssertTrue(Nudge.mobileContentReady(key: "milestone-1-sha", mobileRoot: mobile, notification: saved))
        _ = ViewFeed.publish(.init(page: "review", sections: []), root: mobile)
        XCTAssertTrue(NotificationDetail.ready(saved, mobileRoot: mobile), "其他机器的空页不能抹掉通知详情")
        let first = try Data(contentsOf: mobile.appendingPathComponent("notification-details/\(saved.id).json"))
        var retry = saved; retry.createdAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(NotificationDetail.publish(retry, localRoot: local, mobileRoot: mobile))
        XCTAssertEqual(first, try Data(contentsOf: mobile.appendingPathComponent("notification-details/\(saved.id).json")))
    }
    func testBlockedSnapshotDestinationCannotBeSilentlyDropped() throws {
        XCTAssertEqual(Nudge.targetPage(for: "progress-stalled-task"), "roadmap")
        XCTAssertEqual(Nudge.targetPage(for: "question-1-ask"), "now")
        let r = record()
        let payload = try XCTUnwrap(Push.notificationPayload(.needsYou, body: r.body, page: "review",
                                                            notificationID: r.id, sourcePage: r.sourcePage))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["notificationID"] as? String, r.id)
        XCTAssertEqual(json["sourcePage"] as? String, r.sourcePage)
        XCTAssertEqual(json["page"] as? String, "review", "旧手机仍保留旧版入口")
    }
    func testPublicationFailureDoesNotClaimReadyAndLegacyDecodeWorks() throws {
        let local = try tmp(), mobile = try tmp()
        try Data("not-a-directory".utf8).write(to: mobile.appendingPathComponent("notification-details"))
        XCTAssertFalse(NotificationDetail.publish(record(), localRoot: local, mobileRoot: mobile))
        let decoded = try JSONDecoder().decode(NotificationDetail.Record.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.content)
        XCTAssertEqual(decoded.title, "提醒详情")
    }
    func testActionPagePublishesAndClearsOwnerScopedLiveView() throws {
        let root = try tmp()
        let name = NotificationDetail.sourcePage("review", machineID: Paths.machineID())
        XCTAssertNotEqual(name, "review")
        XCTAssertTrue(ViewFeed.publish(.init(page: "review", sections: [.init(kind: "cards", cards: [
            .init(id: "mine", title: "本机当前成果")
        ])]), root: root))
        XCTAssertEqual(ViewFeed.published(page: name, root: root)?.sections.first?.cards?.first?.title, "本机当前成果")
        XCTAssertTrue(ViewFeed.publish(.init(page: "review", sections: []), root: root))
        XCTAssertTrue(ViewFeed.published(page: name, root: root)?.sections.isEmpty == true)
    }

    func testCaptureUsesExactTaskAndPublishedLiveQuestion() throws {
        var task = WorkTask(id: "notification-task", prompt: "通知详情专项", repo: "/tmp/Flint")
        task.state = .blocked; task.note = "等待真实输入"
        task.ownerRunnerID = "kimi.code"; task.branch = "agent/kimi/notification-task"
        let ask = Ask(id: "live-ask", taskID: task.id, machineID: Paths.machineID(), round: 1,
                      platform: .kimi, taskPrompt: task.prompt, repoName: "Flint",
                      questions: [.init(text: "需要保留原来的验收标准吗？")])
        task.pendingAsk = ask
        try TaskStore.append(task)
        let stalled = try XCTUnwrap(NotificationDetail.capture(
            key: "progress-stalled-" + task.id, kind: .trouble, body: "进展停滞"))
        let card = try XCTUnwrap(stalled.content?.sections.first?.cards?.first)
        XCTAssertEqual(card.taskID, task.id)
        XCTAssertTrue(card.detail?.contains(task.branch!) == true)
        XCTAssertEqual(stalled.sourcePage, "roadmap")
        XCTAssertNil(NotificationDetail.capture(key: "progress-stalled-missing", kind: .trouble, body: "失效提醒"))
        XCTAssertNil(NotificationDetail.capture(key: "question-1-live-ask", kind: .needsYou, body: "有问题"))
        try AskStore.publish(ask)
        let question = try XCTUnwrap(NotificationDetail.capture(
            key: "question-1-live-ask", kind: .needsYou, body: "有问题"))
        XCTAssertEqual(question.content?.sections.first?.cards?.first?.detail, ask.questions[0].text)
        XCTAssertEqual(question.sourcePage, "now")
    }

    func testSnapshotKeepsOldTextWithoutBlockingOnUnrelatedOldMedia() throws {
        let local = try tmp(), mobile = try tmp()
        let page = ViewFeed.Page(page: "review", sections: [.init(kind: "cards", cards: [
            .init(id: "repo|current", title: "本次成果", images: ["current.jpg"]),
            .init(id: "repo|old", title: "历史成果", detail: "仍保留全文", images: ["cleaned.jpg"])
        ])])
        XCTAssertTrue(ViewFeed.publish(page, root: local))
        let saved = try XCTUnwrap(NotificationDetail.capture(
            key: "milestone-2-current", kind: .needsYou, body: "有成果", root: local))
        XCTAssertEqual(saved.content?.sections.first?.cards?.count, 2)
        XCTAssertEqual(saved.requiredImages, ["current.jpg"])
        XCTAssertTrue(NotificationDetail.publish(saved, localRoot: local, mobileRoot: mobile))
        XCTAssertFalse(NotificationDetail.ready(saved, mobileRoot: mobile))
        let dir = mobile.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: dir.appendingPathComponent("current.jpg"))
        XCTAssertTrue(NotificationDetail.ready(saved, mobileRoot: mobile))
        XCTAssertNil(NotificationDetail.capture(
            key: "milestone-2-missing", kind: .needsYou, body: "还没有本次成果", root: local))
    }
}
