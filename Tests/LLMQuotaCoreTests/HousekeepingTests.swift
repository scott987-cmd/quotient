import XCTest
@testable import LLMQuotaCore

/// 验收残留扫除 —— 36 个 llmq-verify-* 目录 7GB 把磁盘吃到 99% 的那次。
final class HousekeepingTests: XCTestCase {
    func testQueuedVisualTaskKeepsItsEvidenceWhileTerminalOrphanIsSwept() throws {
        let saved = Paths.appSupportOverride
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-evidence-\(UUID().uuidString)")
        Paths.appSupportOverride = support
        defer {
            Paths.appSupportOverride = saved
            try? FileManager.default.removeItem(at: support)
        }

        let dir = Review.evidenceDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let protected = dir.appendingPathComponent("flint-grip.m4v")
        let orphan = dir.appendingPathComponent("old-orphan.jpg")
        try Data("video".utf8).write(to: protected)
        try Data("image".utf8).write(to: orphan)
        let old = Date().addingTimeInterval(-3600)
        for file in [protected, orphan] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: file.path)
        }

        var task = WorkTask(id: "eyes", prompt: """
        【看效果】Flint 持枪姿势验收
        文件（都在 \(dir.path) 下）：
          - flint-grip.m4v
        """, repo: "/flint")
        task.state = .queued

        XCTAssertEqual(Housekeeping.sweepOrphanEvidence(
            directory: dir, digests: [], tasks: [task], now: Date()), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path),
                      "排队中的视觉任务还要消费这个证据，不能当孤儿删除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

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
