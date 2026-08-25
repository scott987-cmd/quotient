import XCTest
@testable import LLMQuotaCore

final class InvocationIdentityTests: XCTestCase {
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
