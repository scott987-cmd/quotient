import XCTest
@testable import LLMQuotaCore

/// 验收残留扫除 —— 36 个 llmq-verify-* 目录 7GB 把磁盘吃到 99% 的那次。
final class HousekeepingTests: XCTestCase {
    func testSweepsOnlyStaleVerifyDirs() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("llmq-verify-old1")
        let young = base.appendingPathComponent("llmq-verify-young")
        let other = base.appendingPathComponent("somebody-else")
        for d in [old, young, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 3600)], ofItemAtPath: old.path)
        let n = Housekeeping.sweepVerifyLeftovers(tempDir: base.path + "/")
        XCTAssertEqual(n, 1, "只扫过期的那一个")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "三小时前的残留该删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.path), "刚建的可能正在验收,不能动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "不是我们的目录,碰都不碰")
    }
    func testFreeDiskIsReadable() {
        XCTAssertNotNil(Housekeeping.freeDiskBytes(), "读不到余量就没法守门")
    }
}
