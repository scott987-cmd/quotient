import XCTest
@testable import LLMQuotaCore

final class CollaborationTests: XCTestCase {
    func testInternalArtifactProjectionFitsProtocolWithoutChangingOrder() {
        let files = (0..<52).map { "file-\($0).swift" }
        let projected = CollaborationEvent.boundedArtifacts(files)
        XCTAssertEqual(projected.count, CollaborationEvent.maxArtifacts)
        XCTAssertEqual(projected.first, "file-0.swift")
        XCTAssertEqual(projected.last, "file-49.swift")
    }

    func testBriefingTruncatesHistoricalOutputInsteadOfReplayingLogs() throws {
        try publish(summary: String(repeating: "x", count: 2_000))
        let briefing = CollaborationStore.briefing(
            project: "/tmp/project-a", taskID: "task-a", runnerID: "kimi.code")
        XCTAssertLessThan(briefing.count, 1_000)
        XCTAssertTrue(briefing.contains(String(repeating: "x", count: 400)))
        XCTAssertFalse(briefing.contains(String(repeating: "x", count: 401)))
    }

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collaboration-" + UUID().uuidString)
        CollaborationStore.directoryOverride = scratch
    }

    override func tearDown() {
        CollaborationStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    @discardableResult
    private func publish(id: String = UUID().uuidString, project: String = "/tmp/project-a",
                         task: String? = "task-a", sender: String = "kimi.code",
                         to: String? = nil, kind: CollaborationEvent.Kind = .finding,
                         summary: String = "发现一个可复查的问题",
                         replyTo: String? = nil, machine: String = "machine-A",
                         at: Date = Date()) throws -> CollaborationEvent {
        try CollaborationStore.publish(CollaborationEvent(
            id: id, project: project, taskID: task,
            senderRunnerID: sender, senderMachineID: machine,
            recipientRunnerID: to, kind: kind, summary: summary,
            replyTo: replyTo, createdAt: at))
    }

    func testPerMachineAppendOnlyJournalsMergeWithoutOverwrite() throws {
        try publish(id: "a", summary: "A 的结论", machine: "machine-A")
        try publish(id: "b", sender: "claude.code", summary: "B 的结论",
                    machine: "machine-B")

        XCTAssertEqual(Set(CollaborationStore.all().map(\.id)), ["a", "b"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("machine-A.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("machine-B.jsonl").path))
    }

    func testDuplicateIDAcrossMachinesDeterministicallyKeepsEarliestFact() throws {
        let start = Date()
        let first = CollaborationEvent(
            id: "same", project: "/tmp/project-a", senderRunnerID: "kimi.code",
            senderMachineID: "machine-B", kind: .finding, summary: "最早的事实",
            createdAt: start)
        let later = CollaborationEvent(
            id: "same", project: "/tmp/project-a", senderRunnerID: "claude.code",
            senderMachineID: "machine-A", kind: .finding, summary: "较晚的重试",
            createdAt: start.addingTimeInterval(1))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for (machine, event) in [("machine-B", first), ("machine-A", later)] {
            var data = try SnapshotCoding.encoder().encode(event)
            data.append(UInt8(ascii: "\n"))
            try data.write(to: scratch.appendingPathComponent(machine + ".jsonl"))
        }
        XCTAssertEqual(CollaborationStore.all().map(\.summary), ["最早的事实"])
    }

    func testPublishAndAcknowledgeAreIdempotent() throws {
        let event = CollaborationEvent(
            id: "stable-id", project: "/tmp/project-a", taskID: "task-a",
            senderRunnerID: "kimi.code", senderMachineID: "machine-A",
            kind: .decision, summary: "统一采用方案 A")
        _ = try CollaborationStore.publish(event)
        _ = try CollaborationStore.publish(event)
        _ = try CollaborationStore.acknowledge(
            eventID: event.id, project: event.project, taskID: event.taskID,
            senderRunnerID: "claude.code")
        _ = try CollaborationStore.acknowledge(
            eventID: event.id, project: event.project, taskID: event.taskID,
            senderRunnerID: "claude.code")

        XCTAssertEqual(CollaborationStore.all().filter { $0.id == event.id }.count, 1)
        XCTAssertEqual(CollaborationStore.all().filter {
            $0.kind == .ack && $0.replyTo == event.id
        }.count, 1)
        XCTAssertTrue(CollaborationStore.unresolved(project: event.project).isEmpty)
    }

    func testContextDoesNotLeakOtherProjectTaskOrRecipient() throws {
        try publish(id: "broadcast", task: nil, summary: "项目广播")
        try publish(id: "mine", to: "kimi.code", summary: "给 Kimi")
        try publish(id: "other-runner", sender: "claude.code", to: "claude.code",
                    summary: "给 Claude")
        try publish(id: "other-task", task: "task-b", summary: "另一个任务")
        try publish(id: "other-project", project: "/tmp/project-b", summary: "另一个项目")
        try publish(id: "started", kind: .started, summary: "只是开工轨迹")

        let ids = Set(CollaborationStore.context(
            project: "/tmp/project-a", taskID: "task-a", runnerID: "kimi.code").map(\.id))
        XCTAssertEqual(ids, ["broadcast", "mine"])
    }

    func testAnswerClosesQuestionAndBriefingMarksOnlyPending() throws {
        try publish(id: "q1", kind: .question, summary: "接口返回值怎么定？")
        XCTAssertTrue(CollaborationStore.briefing(
            project: "/tmp/project-a", taskID: "task-a",
            runnerID: "kimi.code").contains("[待回应]"))

        try publish(id: "answer", sender: "claude.code", kind: .answer,
                    summary: "沿用兼容字段", replyTo: "q1")
        XCTAssertTrue(CollaborationStore.unresolved(project: "/tmp/project-a").isEmpty)
        XCTAssertFalse(CollaborationStore.briefing(
            project: "/tmp/project-a", taskID: "task-a",
            runnerID: "kimi.code").contains("[待回应]"))
    }

    func testLaterTaskResultClosesHandoff() throws {
        let start = Date()
        try publish(id: "handoff", kind: .handoff, summary: "前一棒超时", at: start)
        try publish(id: "result", sender: "claude.code", kind: .result,
                    summary: "接手后已完成", at: start.addingTimeInterval(1))
        XCTAssertTrue(CollaborationStore.unresolved(project: "/tmp/project-a").isEmpty)
    }

    func testMalformedLineDoesNotLoseValidEventsAndOldSchemaDecodes() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = #"{"project":"/tmp/project-a","senderRunnerID":"old","senderMachineID":"machine-A","kind":"checkpoint","summary":"old"}"#
        try (Data("not-json\n".utf8) + Data(old.utf8) + Data("\n".utf8))
            .write(to: scratch.appendingPathComponent("machine-A.jsonl"))

        let events = CollaborationStore.all()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].schemaVersion, 1)
        XCTAssertEqual(events[0].artifacts, [])
    }

    func testMCPListsToolsAndPublishesUsingSameStore() throws {
        let list = try XCTUnwrap(CollaborationMCP.response(for: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        ]))
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), [
            "collaboration_get_context", "collaboration_publish", "collaboration_ack"
        ])

        let response = try XCTUnwrap(CollaborationMCP.response(for: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "collaboration_publish", "arguments": [
                "id": "via-mcp", "project": "/tmp/project-a",
                "senderRunnerID": "kimi.code", "kind": "checkpoint",
                "summary": "已完成第一阶段"
            ]]
        ]))
        let result = response["result"] as? [String: Any]
        XCTAssertNil(result?["isError"])
        XCTAssertEqual(CollaborationStore.all().map(\.id), ["via-mcp"])
    }

    func testDynamicMobilePageAndMenuExposeCollaboration() throws {
        try publish(id: "pending", kind: .finding, summary: "需要另一位 Agent 复核")
        let page = ViewFeed.collaborationPage()
        XCTAssertEqual(page.page, "collaboration")
        XCTAssertTrue(page.sections.flatMap { $0.cards ?? [] }
            .contains { $0.id == "pending" && $0.title.contains("待回应") })
        let entry = ViewFeed.menu().entries.first { $0.page == "collaboration" }
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.badge, "Agent 待回应不是人的未读消息，不能制造幽灵角标")
    }

    func testEventSizeIsBounded() throws {
        XCTAssertThrowsError(try publish(summary: String(repeating: "x", count: 2_001)))
        XCTAssertTrue(CollaborationStore.all().isEmpty)
    }
}
