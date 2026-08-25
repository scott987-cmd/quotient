import XCTest
@testable import LLMQuotaCore

/// 任务状态不许倒流。
///
/// 2026-08-25 现场（任务 6a4a3d11）：被 kill 的旧 worker 带着 3 分半前的快照，
/// 在新 worker 写完 `running` 之后才落盘，读取端「后写覆盖先写」把新状态抹掉，
/// 于是 opencode 实际跑了 64 分钟、看板却说「排队」。
final class TaskRevisionTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("taskrev-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Paths.appSupportOverride = dir
        TaskStore.resetWrittenRevForTests()
        TaskStore.staleRejections = []
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func make(_ id: String) -> WorkTask {
        WorkTask(id: id, prompt: "p", repo: "/tmp/r")
    }

    func test_写盘后_rev单调递增() throws {
        var t = make("a")
        try TaskStore.append(t)
        XCTAssertEqual(TaskStore.all().first?.rev, 0, "第一条从 0 开始")
        t = TaskStore.all().first!
        t.state = .running
        try TaskStore.append(t)
        XCTAssertEqual(TaskStore.all().first?.rev, 1)
    }

    /// 核心场景：旧快照后写，必须被拒。
    func test_旧快照后写_被拒且状态不倒流() throws {
        let t = make("b")
        try TaskStore.append(t)
        let stale = TaskStore.all().first!        // 旧 worker 手里这份

        // 新 worker 读到同一份，改成 running 写进去
        var fresh = TaskStore.all().first!
        fresh.state = .running
        fresh.runnerPID = 21981
        try TaskStore.append(fresh)
        XCTAssertEqual(TaskStore.all().first?.state, .running)

        // 旧 worker 是**另一个进程**：清掉「我写过什么」来如实模拟这一点。
        // （这不是为了让测试变绿而放水 —— 现场那两个 PID 20686/21981
        //   本来就是两个进程；同进程内的旧快照由状态机护栏负责，不归这一层。）
        TaskStore.resetWrittenRevForTests()

        // 旧 worker 临终把 failed 写下来 —— 必须写不进去
        var dying = stale
        dying.state = .failed
        dying.runnerPID = 20686
        XCTAssertThrowsError(try TaskStore.append(dying)) { error in
            XCTAssertTrue(error is StaleWrite, "要给出明确的过期写入错误，不能静默丢")
        }
        XCTAssertEqual(TaskStore.all().first?.state, .running, "状态不许倒流")
        XCTAssertEqual(TaskStore.all().first?.runnerPID, 21981, "PID 也不许被幽灵覆盖")
        XCTAssertEqual(TaskStore.staleRejections.count, 1, "被拒这件事必须留痕，不能没声音")
    }

    func test_同进程的两个独立快照_旧的也必须被拒() throws {
        try TaskStore.append(make("same-process"))
        var fresh = TaskStore.all().first!
        var stale = TaskStore.all().first!

        fresh.state = .running
        fresh.runnerPID = 42
        try TaskStore.append(fresh)

        stale.state = .failed
        XCTAssertThrowsError(try TaskStore.append(stale)) { error in
            XCTAssertTrue(error is StaleWrite)
        }
        XCTAssertEqual(TaskStore.all().first?.state, .running)
        XCTAssertEqual(TaskStore.all().first?.runnerPID, 42)
    }

    func test_读取按最高rev折叠_不让后写的低版本获胜() throws {
        var newest = make("reader")
        newest.rev = 7
        newest.state = .running
        newest.runnerPID = 77
        var stale = newest
        stale.rev = 3
        stale.state = .queued
        stale.runnerPID = nil

        let encoder = SnapshotCoding.encoder()
        let data = try [newest, stale].reduce(into: Data()) { out, task in
            out.append(try encoder.encode(task))
            out.append(UInt8(ascii: "\n"))
        }
        try data.write(to: dir.appendingPathComponent("tasks.jsonl"))

        let loaded = try XCTUnwrap(TaskStore.all().first)
        XCTAssertEqual(loaded.rev, 7)
        XCTAssertEqual(loaded.state, .running)
        XCTAssertEqual(loaded.runnerPID, 77)
    }

    /// 同一进程一轮里对同一个 task 变量连写多次是正常操作，不能被误判成过期。
    func test_同一进程连写_不被误判() throws {
        var t = make("c")
        try TaskStore.append(t)              // rev 0
        t.state = .running
        try TaskStore.append(t)              // 手上的 t.rev 仍是 0，但这是我自己
        t.state = .done
        try TaskStore.append(t)
        XCTAssertEqual(TaskStore.all().first?.state, .done)
        XCTAssertTrue(TaskStore.staleRejections.isEmpty, "自己的连写不该被拒")
    }

    /// 老记录没有 rev 字段，读出来是 0，不能因此拒掉第一次正常更新。
    func test_旧JSON没有rev_仍可正常更新() throws {
        let line = #"{"id":"d","prompt":"p","repo":"/tmp/r","state":"queued","createdAt":"2026-08-01T00:00:00Z","triedPlatforms":[],"askRounds":0,"outputs":[],"dependsOn":[]}"#
        let f = dir.appendingPathComponent("tasks.jsonl")
        try (line + "\n").data(using: .utf8)!.write(to: f)
        var t = TaskStore.all().first!
        XCTAssertEqual(t.rev, 0)
        t.state = .running
        XCTAssertNoThrow(try TaskStore.append(t))
        XCTAssertEqual(TaskStore.all().first?.state, .running)
    }
}
