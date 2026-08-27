import XCTest
@testable import LLMQuotaCore

final class CodingMediaGuardTests: XCTestCase {
    func testBlocksRelativeAndAbsoluteImageReads() {
        XCTAssertTrue(CodingMediaGuard.disallowedReadTools.contains("Read(**/*.png)"))
        XCTAssertTrue(CodingMediaGuard.disallowedReadTools.contains("Read(//**/*.png)"))
        XCTAssertTrue(CodingMediaGuard.disallowedReadTools.contains("Read(**/*.m4v)"))
        XCTAssertTrue(CodingMediaGuard.systemPrompt.contains("独立多模态验收文字"))
    }

    func testSensitiveImageErrorPoisonsCodingSession() {
        let output = "API Error: 500 input new_sensitive, messages[114]'s "
            + "content[0] image is sensitive, please check your input (1026)"
        XCTAssertTrue(CodingMediaGuard.poisonedSession(output))
    }

    func testOrdinaryCodeFailureDoesNotPoisonSession() {
        XCTAssertFalse(CodingMediaGuard.poisonedSession(
            "build failed: missing symbol in ImageRenderer"))
    }
}
