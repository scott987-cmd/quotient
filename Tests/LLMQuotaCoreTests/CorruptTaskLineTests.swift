import XCTest
@testable import LLMQuotaCore

/// 解不出来的任务行必须被数出来。
///
/// `TaskStore.skippedLines` 的注释一直写着「上一次 all() 里有几行没解出来」，
/// 而那个 `continue` 光秃秃的、从来不给它加一 —— **它永远是 0**。
/// 也就是说损坏的任务记录静默消失，没有任何地方会提。
///
/// 后果不是理论上的：`tasks.jsonl` 是 append-only，而写它的进程
/// 在这一天里被杀过很多次（单次超时、发布重启、机器崩了十小时）。
/// 写到一半被杀就留下半行。那条任务从此不存在，而它的下游节点会
/// 永远等一个不会到来的上游 —— 从外面看是「图卡住了」，查不出原因。
///
/// **一个声明了却永远不动的计数器，比没有这个计数器更糟**：
/// 它让人以为「查过了，没有损坏」。
final class CorruptTaskLineTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tasks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Paths.appSupportOverride = dir
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func writeLines(_ text: String) {
        try? text.write(to: TaskStore.file, atomically: true, encoding: .utf8)
    }

    private func goodLine(_ id: String) throws -> String {
        let t = WorkTask(id: id, prompt: "p", repo: "/tmp")
        return String(decoding: try SnapshotCoding.encoder().encode(t), as: UTF8.self)
    }

    func testHalfWrittenLineIsCounted() throws {
        writeLines(try goodLine("ok1") + "\n" + #"{"id":"broken","prompt":"写到一半就被"# + "\n")
        let tasks = TaskStore.all()
        XCTAssertEqual(tasks.count, 1, "好的那条要留下")
        XCTAssertEqual(TaskStore.skippedLines, 1,
                       "损坏的那行必须被数出来 —— 静默丢掉会让下游永远等一个不存在的上游")
    }

    /// 文件末尾天然有一个空行，**不能算成损坏** ——
    /// 否则每次 doctor 都报一条假警报，真警报就被淹没了。
    func testTrailingNewlineIsNotCorruption() throws {
        writeLines(try goodLine("ok1") + "\n" + (try goodLine("ok2")) + "\n")
        XCTAssertEqual(TaskStore.all().count, 2)
        XCTAssertEqual(TaskStore.skippedLines, 0, "末尾换行是正常的，不是损坏")
    }

    func testCounterResetsBetweenReads() throws {
        writeLines(try goodLine("ok") + "\n{ 坏\n")
        _ = TaskStore.all()
        XCTAssertEqual(TaskStore.skippedLines, 1)

        writeLines(try goodLine("ok") + "\n")
        _ = TaskStore.all()
        XCTAssertEqual(TaskStore.skippedLines, 0,
                       "修好之后必须归零，否则人删了坏行还看到警报，会以为没删掉")
    }

    func testMultipleCorruptLinesAllCounted() throws {
        writeLines([try goodLine("a"), "{ 坏1", try goodLine("b"), "坏2", ""].joined(separator: "\n"))
        XCTAssertEqual(TaskStore.all().count, 2)
        XCTAssertEqual(TaskStore.skippedLines, 2)
    }

    /// 全是空白的行也不算损坏。
    func testWhitespaceOnlyLineIsNotCorruption() throws {
        writeLines(try goodLine("a") + "\n   \n")
        XCTAssertEqual(TaskStore.skippedLines, 0)
    }
}
