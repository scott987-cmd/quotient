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
}
