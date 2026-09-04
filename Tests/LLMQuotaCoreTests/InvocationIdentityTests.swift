import XCTest
@testable import LLMQuotaCore

final class InvocationIdentityTests: XCTestCase {
    func testRoutedConsumerIsolatesMachineRetryBudgetAndTerminalReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = Paths.appSupportOverride
        Paths.appSupportOverride = root
        defer { Paths.appSupportOverride = saved; try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(MobileAction.scoped("review:merge:/tmp/repo|branch|head", machineID: "a"))
        let invocation = try decode("{\"id\":\"\(id)\",\"invocationID\":\"click\",\"at\":\"2026-09-03T00:00:00Z\"}")
        var executions = 0
        XCTAssertNil(MobileAction.process(invocation, machineID: "b") { executions += 1; return true })
        XCTAssertEqual(executions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mobile-actions").path))
        for i in 1...3 {
            let result = MobileAction.process(invocation, machineID: "a") { executions += 1; return false }
            XCTAssertEqual(result?.attempts, i)
            XCTAssertEqual(result?.state, i == 3 ? "failed" : "retrying")
        }
        XCTAssertEqual(MobileAction.process(invocation, machineID: "a") { executions += 1; return true }?.state, "failed")
        XCTAssertEqual(executions, 3, "耗尽后的重复消费不能再执行，也不能改成成功")
        let retry = try decode("{\"id\":\"\(id)\",\"invocationID\":\"retry\",\"at\":\"2026-09-03T00:00:00Z\"}")
        XCTAssertEqual(MobileAction.process(retry, machineID: "a") { executions += 1; return true }?.state, "succeeded")
        XCTAssertEqual(MobileAction.process(retry, machineID: "a") { executions += 1; return false }?.state, "succeeded")
        XCTAssertEqual(executions, 4)
        let name = MobileAction.receiptName(actionID: id, invocationID: "retry")
        let receipt = try XCTUnwrap(SafeDecode.json(at: Paths.sharedRoot.appendingPathComponent("action-receipts/" + name), as: MobileAction.Receipt.self))
        XCTAssertEqual(receipt.machineID, "a")
        XCTAssertEqual(receipt.actionID, id)
        XCTAssertEqual(receipt.invocationID, "retry")
        let raw = try decode(#"{"id":"review:merge:/tmp/repo|branch","at":"2026-09-03T00:00:00Z"}"#)
        XCTAssertNil(MobileAction.process(raw, machineID: "a") { executions += 1; return true })
        XCTAssertEqual(executions, 4)
    }

    func testRoutesRejectContradictionsAndReviewDecisionsArePerMachine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = Paths.appSupportOverride, machine = Paths.machineIDOverride
        Paths.appSupportOverride = root
        defer { Paths.appSupportOverride = saved; Paths.machineIDOverride = machine; try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(MobileAction.scoped("task:approve:same", machineID: "a"))
        XCTAssertEqual(MobileAction.scoped(id, machineID: "a"), id)
        XCTAssertNil(MobileAction.scoped(id, machineID: "b"))
        for bad in ["machine::x", "machine:" + MobileAction.digest("a") + ":", "machine:" + MobileAction.digest("a") + ":" + id] {
            XCTAssertNil(MobileAction.route(bad))
        }
        Paths.machineIDOverride = "a"
        Review.markDecided(repo: "/tmp/repo", branch: "same")
        XCTAssertFalse(Review.decidedBranches().isEmpty)
        Paths.machineIDOverride = "b"
        XCTAssertTrue(Review.decidedBranches().isEmpty)
    }

    func testPublishedActionsProtectLegacyConsumers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = Paths.appSupportOverride
        Paths.appSupportOverride = root
        defer { Paths.appSupportOverride = saved; try? FileManager.default.removeItem(at: root) }
        let page = ViewFeed.Page(page: "review", sections: [.init(kind: "cards", cards: [
            .init(id: "same", title: "same", actions: [.init(id: "review:merge:/tmp/repo|same", label: "合入")])
        ], actions: [.init(id: "task:approve:same", label: "放行")])])
        XCTAssertTrue(ViewFeed.publish(page))
        let name = NotificationDetail.sourcePage("review", machineID: Paths.machineID())
        let scope = String(name.dropFirst("review-".count))
        for key in ["review", name] {
            let section = try XCTUnwrap(ViewFeed.published(page: key)?.sections.first)
            XCTAssertEqual(section.cards?.first?.actions.first?.id,
                           "machine:" + scope + ":review:merge:/tmp/repo|same")
            XCTAssertEqual(section.actions?.first?.id, "machine:" + scope + ":task:approve:same")
        }
    }

    private func decode(_ json: String) throws -> ViewFeed.Invocation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ViewFeed.Invocation.self, from: Data(json.utf8))
    }

    func testNewInvocationIDSeparatesTwoClicksInSameSecond() throws {
        let first = try decode(#"{"id":"retry","invocationID":"click-1","at":"2026-08-23T12:00:00Z"}"#)
        let second = try decode(#"{"id":"retry","invocationID":"click-2","at":"2026-08-23T12:00:00Z"}"#)
        XCTAssertNotEqual(first.key, second.key)
    }

    func testLegacyInvocationKeepsOldIdentity() throws {
        let old = try decode(#"{"id":"retry","at":"2026-08-23T12:00:00Z"}"#)
        XCTAssertNil(old.invocationID)
        XCTAssertEqual(old.key, "retry@2026-08-23T12:00:00Z")
    }

    func testPendingInvocationsIgnoreMetadataAndEmptyActions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("invocations-\(UUID().uuidString)")
        let saved = Paths.appSupportOverride
        Paths.appSupportOverride = root
        defer {
            Paths.appSupportOverride = saved
            try? FileManager.default.removeItem(at: root)
        }
        let actions = root.appendingPathComponent("shared/actions")
        try FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true)
        try #"{"bad@now":3}"#.write(
            to: actions.appendingPathComponent(".failures.json"),
            atomically: true, encoding: .utf8)
        try #"{}"#.write(to: actions.appendingPathComponent("empty.json"),
                          atomically: true, encoding: .utf8)
        try #"{"id":"task:approve:t1","at":"2026-08-23T12:00:00Z"}"#.write(
            to: actions.appendingPathComponent("valid.json"),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(ViewFeed.pendingInvocations().map(\.id), ["task:approve:t1"])
    }
}
