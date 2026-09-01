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
        XCTAssertNil(t.terminalFailureKind,
                     "新增失败原因字段必须向后兼容，旧任务记录不能解码消失")
        t.state = .running
        XCTAssertNoThrow(try TaskStore.append(t))
        XCTAssertEqual(TaskStore.all().first?.state, .running)
    }

    func test_结构化失败原因和重试期限会持久化() throws {
        var t = make("quota-persistence")
        t.state = .failed
        t.terminalFailureKind = .quotaExhausted
        t.retryNotBefore = Date(timeIntervalSince1970: 1_800_000_000)

        try TaskStore.append(t)

        let loaded = try XCTUnwrap(TaskStore.all().first)
        XCTAssertEqual(loaded.terminalFailureKind, .quotaExhausted)
        XCTAssertEqual(try XCTUnwrap(loaded.retryNotBefore).timeIntervalSince1970,
                       1_800_000_000, accuracy: 0.001)
    }

    func test_短写会继续直到整条记录写完() throws {
        let payload = Data("abcdefgh".utf8)
        var received: [UInt8] = []
        var calls = 0

        try TaskStore.writeCompletely(payload) { base, count in
            calls += 1
            let n = min(3, count)
            received.append(contentsOf: UnsafeRawBufferPointer(start: base, count: n))
            return n
        }

        XCTAssertEqual(Data(received), payload)
        XCTAssertEqual(calls, 3, "8 字节按 3/3/2 短写，必须调用三次")
    }

    func test_写入零进展必须明确失败() {
        XCTAssertThrowsError(try TaskStore.writeCompletely(Data("x".utf8)) { _, _ in 0 })
    }

    func test_追加写到一半失败会回滚坏尾巴() throws {
        let ledger = dir.appendingPathComponent("rollback.jsonl")
        let original = Data("old-record\n".utf8)
        try original.write(to: ledger)
        let fd = open(ledger.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var calls = 0
        XCTAssertThrowsError(
            try TaskStore.appendCompletely(Data("new-record\n".utf8), to: fd) { base, count in
                calls += 1
                if calls == 1 { return write(fd, base, min(3, count)) }
                return 0
            }
        )

        XCTAssertEqual(try Data(contentsOf: ledger), original,
                       "失败的半条记录必须从账本里完整撤销")
    }

    func test_mutate并发修改同一任务不丢更新() throws {
        try TaskStore.append(make("mutate-concurrent"))
        let count = 100
        let group = DispatchGroup()
        let errorLock = NSLock()
        var errors: [Error] = []

        for _ in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try TaskStore.transition(
                        id: "mutate-concurrent", actor: "test", reason: "并发计数"
                    ) {
                        $0.qualityRejectionCount += 1
                    }
                } catch {
                    errorLock.lock(); errors.append(error); errorLock.unlock()
                }
            }
        }
        group.wait()

        XCTAssertTrue(errors.isEmpty, "每次转换都必须成功或显式报错：\(errors)")
        let loaded = try XCTUnwrap(TaskStore.all().first)
        XCTAssertEqual(loaded.qualityRejectionCount, count)
        XCTAssertEqual(loaded.rev, count, "初始 rev 0，100 次转换后必须是 rev 100")
    }

    func test_mutate找不到任务会明确失败() {
        XCTAssertThrowsError(try TaskStore.mutate(id: "missing") { $0.state = .done }) {
            XCTAssertTrue($0 is MissingTask)
        }
    }

    func test_并发领取同一任务只有一个赢家() throws {
        try TaskStore.append(make("claim-once"))
        let group = DispatchGroup()
        let resultLock = NSLock()
        var winners = 0
        var rejected = 0

        for pid in 100..<120 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try TaskStore.claimForExecution(
                        id: "claim-once", runnerPID: Int32(pid))
                    resultLock.lock(); winners += 1; resultLock.unlock()
                } catch is InvalidTaskTransition {
                    resultLock.lock(); rejected += 1; resultLock.unlock()
                } catch {
                    XCTFail("出现非预期写入错误：\(error)")
                }
            }
        }
        group.wait()

        XCTAssertEqual(winners, 1)
        XCTAssertEqual(rejected, 19)
        XCTAssertEqual(TaskStore.all().first?.state, .running)
        XCTAssertNotNil(TaskStore.all().first?.runnerPID)
    }

    func test_派发租约把任务限速凭据和快照原子绑定() throws {
        _ = try TaskStore.create(make("dispatch"), actor: "test", reason: "创建")
        let head = try XCTUnwrap(TaskStore.all().first)
        let leased = try TaskStore.claimForDispatch(
            id: head.id, expectedRevision: head.rev, coordinatorPID: 42,
            snapshotID: "snapshot-1", quotaReservationID: "quota-1",
            leaseID: "lease-1", at: Date(),
            leaseSeconds: 60)

        XCTAssertEqual(leased.state, .queued)
        XCTAssertEqual(leased.dispatchLeaseID, "lease-1")
        XCTAssertEqual(leased.dispatchLeaseOwnerPID, 42)
        XCTAssertEqual(leased.quotaReservationID, "quota-1")
        XCTAssertEqual(leased.dispatchSnapshotID, "snapshot-1")
        XCTAssertTrue(TaskStore.readyQueue().isEmpty,
                      "未到期租约必须从下一轮候选集消失")
    }

    func test_两个协调器同时领取同一任务只有一个获得派发租约() throws {
        _ = try TaskStore.create(make("dispatch-race"), actor: "test", reason: "创建")
        let head = try XCTUnwrap(TaskStore.all().first)
        let lock = NSLock()
        var winners: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            let lease = "lease-\(index)"
            if (try? TaskStore.claimForDispatch(
                id: head.id, expectedRevision: head.rev,
                coordinatorPID: Int32(index + 1), snapshotID: "snapshot-\(index)",
                quotaReservationID: "quota-\(index)", leaseID: lease,
                leaseSeconds: 60)) != nil {
                lock.lock(); winners.append(lease); lock.unlock()
            }
        }

        XCTAssertEqual(winners.count, 1)
        let saved = try XCTUnwrap(TaskStore.all().first)
        XCTAssertEqual(saved.dispatchLeaseID, winners.first)
        XCTAssertEqual(saved.rev, head.rev + 1)
    }

    func test_只有持租约子进程能把任务转为运行() throws {
        _ = try TaskStore.create(make("lease-owner"), actor: "test", reason: "创建")
        let head = try XCTUnwrap(TaskStore.all().first)
        _ = try TaskStore.claimForDispatch(
            id: head.id, expectedRevision: head.rev, coordinatorPID: 42,
            snapshotID: "snapshot", quotaReservationID: "quota",
            leaseID: "right", leaseSeconds: 60)

        XCTAssertThrowsError(try TaskStore.claimForExecution(
            id: head.id, runnerPID: 7, dispatchLeaseID: "wrong")) {
            XCTAssertTrue($0 is InvalidTaskTransition)
        }
        let running = try TaskStore.claimForExecution(
            id: head.id, runnerPID: 8, dispatchLeaseID: "right")
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.runnerPID, 8)
    }

    func test_启动失败释放租约后任务重新可见() throws {
        _ = try TaskStore.create(make("release"), actor: "test", reason: "创建")
        let head = try XCTUnwrap(TaskStore.all().first)
        _ = try TaskStore.claimForDispatch(
            id: head.id, expectedRevision: head.rev, coordinatorPID: 42,
            snapshotID: "snapshot", quotaReservationID: "quota",
            leaseID: "lease", leaseSeconds: 60)
        _ = try TaskStore.releaseDispatchLease(
            id: head.id, leaseID: "lease", reason: "模拟启动失败")

        let released = try XCTUnwrap(TaskStore.all().first)
        XCTAssertNil(released.dispatchLeaseID)
        XCTAssertNil(released.quotaReservationID)
        XCTAssertEqual(TaskStore.readyQueue().map(\.id), ["release"])
    }

    func test_create拒绝覆盖同ID任务() throws {
        _ = try TaskStore.create(make("create-once"), actor: "test", reason: "首次创建")

        XCTAssertThrowsError(
            try TaskStore.create(make("create-once"), actor: "test", reason: "重复创建")
        ) { error in
            XCTAssertTrue(error is DuplicateTask)
        }
        XCTAssertEqual(TaskStore.all().filter { $0.id == "create-once" }.count, 1)
    }

    func test_transition记录审计信息并规范等待原因() throws {
        _ = try TaskStore.create(make("audit"), actor: "intake", reason: "创建任务")
        let saved = try TaskStore.transition(
            id: "audit", actor: "scheduler", reason: "等待用户确认",
            configVersion: "cfg-7"
        ) {
            $0.state = .blocked
        }

        XCTAssertEqual(saved.waitReason, .humanApproval)
        XCTAssertEqual(saved.transitionActor, "scheduler")
        XCTAssertEqual(saved.transitionReason, "等待用户确认")
        XCTAssertEqual(saved.transitionPreviousState, .queued)
        XCTAssertEqual(saved.transitionConfigVersion, "cfg-7")
        XCTAssertNotNil(saved.transitionedAt)
    }

    func test_transition完整快照冲突必须可见且不覆盖() throws {
        _ = try TaskStore.create(make("cas"), actor: "test", reason: "创建")
        var stale = try XCTUnwrap(TaskStore.all().first)
        _ = try TaskStore.transition(id: "cas", actor: "newer", reason: "先推进") {
            $0.state = .running
            $0.runnerPID = 88
        }
        stale.state = .failed

        XCTAssertThrowsError(
            try TaskStore.transition(stale, actor: "stale", reason: "迟到结果")
        ) { error in
            XCTAssertTrue(error is StaleWrite)
        }
        XCTAssertEqual(TaskStore.all().first?.state, .running)
        XCTAssertEqual(TaskStore.all().first?.runnerPID, 88)
        XCTAssertEqual(TaskStore.staleRejections.count, 1)
        XCTAssertEqual(TaskStore.staleRejections.first?.id, "cas")
        XCTAssertEqual(TaskStore.staleRejections.first?.mine, stale.rev)
    }

    func test_旧blocked记录会补出结构化等待原因() throws {
        let line = #"{"id":"legacy-wait","prompt":"p","repo":"/tmp/r","state":"blocked","createdAt":"2026-08-01T00:00:00Z","pausedAt":"2026-08-01T00:01:00Z"}"#
        try (line + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("tasks.jsonl"))

        XCTAssertEqual(TaskStore.all().first?.waitReason, .paused)
    }

    func test_旧blocked记录缺少线索时仍显示需要人工处置() throws {
        let line = #"{"id":"legacy-generic-block","prompt":"p","repo":"/tmp/r","state":"blocked","createdAt":"2026-08-01T00:00:00Z"}"#
        try (line + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("tasks.jsonl"))

        XCTAssertEqual(TaskStore.all().first?.waitReason, .humanApproval)
    }

    func test_任务图对账通过控制内核持久化() throws {
        var upstream = make("upstream")
        upstream.state = .failed
        var downstream = make("downstream")
        downstream.dependsOn = [upstream.id]
        _ = try TaskStore.create(upstream, actor: "test", reason: "创建上游")
        _ = try TaskStore.create(downstream, actor: "test", reason: "创建下游")

        let saved = try TaskGraph.persistReconciliation(
            actor: "test-reconciler", reason: "传播上游失败")
        let blocked = try XCTUnwrap(saved.first { $0.id == downstream.id })
        XCTAssertEqual(blocked.state, .blocked)
        XCTAssertEqual(blocked.waitReason, .dependency)
        XCTAssertEqual(blocked.transitionActor, "test-reconciler")
    }

    func test_生产代码不能绕过控制内核直接写TaskStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scannedFiles = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFiles += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["TaskStore.append(", "TaskStore.mutate("]
                where source.contains(forbidden) {
                violations.append(url.lastPathComponent + " 包含 " + forbidden)
            }
        }
        XCTAssertGreaterThan(scannedFiles, 10, "源码扫描异常，不能把空扫描当通过")
        XCTAssertTrue(violations.isEmpty, "业务代码必须使用 create/transition：\(violations)")
    }
}
