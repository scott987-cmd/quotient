import XCTest
@testable import LLMQuotaCore

final class TaskStoreCheckpointTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("task-checkpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root
        TaskStore.resetWrittenRevForTests()
    }

    override func tearDownWithError() throws {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testColdProcessLoadsCheckpointAndOnlyParsesAppendedTail() throws {
        var ledger = Data()
        for index in 0..<400 {
            var task = WorkTask(id: "t-\(index)", prompt: String(repeating: "x", count: 512),
                                repo: "/tmp/repo")
            task.rev = index
            ledger.append(try SnapshotCoding.encoder().encode(task))
            ledger.append(UInt8(ascii: "\n"))
        }
        try ledger.write(to: TaskStore.file)

        XCTAssertEqual(TaskStore.all().count, 400)
        XCTAssertGreaterThan(TaskStore.bytesParsedLastLoad, 200_000)

        // 模拟另一个短命进程：内存索引消失，但磁盘 checkpoint 保留。
        TaskStore.resetWrittenRevForTests()
        var appended = WorkTask(id: "tail", prompt: "new", repo: "/tmp/repo")
        appended.rev = 1
        var tail = try SnapshotCoding.encoder().encode(appended)
        tail.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: TaskStore.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()

        let loaded = TaskStore.all()
        XCTAssertEqual(loaded.count, 401)
        XCTAssertEqual(loaded.first(where: { $0.id == "tail" })?.rev, 1)
        XCTAssertLessThanOrEqual(TaskStore.bytesParsedLastLoad, Int64(tail.count + 16),
                                 "冷启动只能解析 checkpoint 之后的新尾部")
    }

    func testAppendRemovesKilledProcessPartialTailBeforeWritingNextRecord() throws {
        var first = WorkTask(id: "first", prompt: "first", repo: "/tmp/repo")
        first.rev = 1
        var ledger = try SnapshotCoding.encoder().encode(first)
        ledger.append(UInt8(ascii: "\n"))
        ledger.append(Data(#"{"id":"half""#.utf8))
        try ledger.write(to: TaskStore.file)
        TaskStore.resetWrittenRevForTests()

        _ = try TaskStore.create(
            WorkTask(id: "second", prompt: "second", repo: "/tmp/repo"),
            actor: "test", reason: "append after crash")

        XCTAssertEqual(Set(TaskStore.all().map(\.id)), ["first", "second"])
        XCTAssertEqual(TaskStore.skippedLines, 0,
                       "尾部半行必须在下一次持锁写入前清理，不能污染后续记录")
    }

    func testAppendPreservesCompleteRecordThatOnlyMissedNewline() throws {
        var first = WorkTask(id: "first", prompt: "first", repo: "/tmp/repo")
        first.rev = 1
        try SnapshotCoding.encoder().encode(first).write(to: TaskStore.file)
        TaskStore.resetWrittenRevForTests()

        _ = try TaskStore.create(
            WorkTask(id: "second", prompt: "second", repo: "/tmp/repo"),
            actor: "test", reason: "append after missing newline")

        XCTAssertEqual(Set(TaskStore.all().map(\.id)), ["first", "second"])
        XCTAssertEqual(TaskStore.skippedLines, 0)
    }
}
