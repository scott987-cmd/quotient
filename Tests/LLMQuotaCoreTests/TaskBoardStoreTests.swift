import XCTest
@testable import LLMQuotaCore

/// 「手机上只看得到最后一台采集的机器的活」那个 bug 的防线。
///
/// 病根：任务是塞在 `dashboard.json` 里发的，而那个文件在 iCloud 上
/// **只有一份、每台机器都往里写**。每条任务身上确实带着 machineName，
/// 但整份内容永远是最后写的那台的 —— 两台机器同时干活时，
/// 手机上的列表会随着谁最后采集而整批切换。
///
/// 这里守的是四件会真的咬人的事：
/// 1. 真的按机器分成了文件，文件名就是 `Paths.machineID()`。
/// 2. `dashboard.tasks` 一个字都没少 —— 老版本手机只认它，删了就是白屏。
/// 3. 清理**不会删读不动的**。iCloud 没响应 ≠ 那台机器没了。
/// 4. 缺字段的板子还能解出来，而且缺 `generatedAt` 的不会被当成刚采的。
final class TaskBoardStoreTests: XCTestCase {

    private var root: URL!
    private var appSupport: URL!

    override func setUp() {
        super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("taskboards-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("taskboards", isDirectory: true)
        appSupport = base.appendingPathComponent("app-support", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TaskBoardStore.dirOverride = root
        Paths.appSupportOverride = appSupport
        Watchdog.resetForTesting()
    }

    override func tearDown() {
        TaskBoardStore.dirOverride = nil
        Paths.appSupportOverride = nil
        // 权限被改过的用例：不改回来的话连目录都删不掉。
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) {
            for u in entries {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: u.path)
            }
        }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func brief(_ id: String, _ state: WorkTask.State = .running,
                       machine: String = "Mac mini") -> TaskBrief {
        TaskBrief(id: id, title: "活 \(id)", state: state, machineName: machine)
    }

    private func board(
        _ machineID: String, name: String = "Mac mini",
        generatedAt: Date? = nil, tasks: [TaskBrief] = []
    ) -> MachineTaskBoard {
        MachineTaskBoard(machineID: machineID, machineName: name,
                         generatedAt: generatedAt ?? now, tasks: tasks)
    }

    private func fileURL(_ machineID: String) -> URL {
        root.appendingPathComponent("\(machineID).json")
    }

    private func setModified(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - 1. 真的按机器分成了文件

    func testPublishWritesOneFilePerMachine() throws {
        XCTAssertTrue(TaskBoardStore.publish(
            board("AAA", name: "Mac mini", tasks: [brief("t1"), brief("t2")])))
        XCTAssertTrue(TaskBoardStore.publish(
            board("BBB", name: "MacBook", tasks: [brief("t3", machine: "MacBook")])))

        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(files, ["AAA.json", "BBB.json"], """
            两台机器必须落成两个文件。合在一份里就是原来那个 bug ——
            后写的那台把先写的整个盖掉，手机上只看得见一台的活。
            """)

        let listing = TaskBoardStore.loadAll()
        XCTAssertEqual(listing.boards.map(\.machineID).sorted(), ["AAA", "BBB"])
        XCTAssertEqual(listing.boards.flatMap { $0.tasks.map(\.id) }.sorted(),
                       ["t1", "t2", "t3"], "合并之后两台的任务都要在")
        XCTAssertTrue(listing.isComplete)
    }

    /// **一台机器只写自己那个文件。** 和 `snapshots/` 同一条规矩 ——
    /// 谁都不写别人的，所以根本不存在合并冲突。
    func testPublishNeverTouchesAnotherMachinesFile() throws {
        TaskBoardStore.publish(board("AAA", tasks: [brief("keep")]))
        let before = try Data(contentsOf: fileURL("AAA"))

        TaskBoardStore.publish(board("BBB", name: "MacBook", tasks: [brief("other")]))

        XCTAssertEqual(try Data(contentsOf: fileURL("AAA")), before,
                       "B 机器发布把 A 的文件改了 —— 那就还是在互相覆盖")
    }

    // MARK: - 2. machineID 取自 Paths.machineID()

    /// 文件名必须是 `Paths.machineID()`，和 `snapshots/<machineID>.json` 同一个。
    /// 手机要靠它把任务板和快照里的那台机器对上号，取错了就永远对不上。
    func testDefaultMachineIDComesFromPaths() throws {
        let dash = Dashboard(generatedAt: now, machines: [], reports: [],
                             tasks: [brief("t1")], tasksTruncated: false)
        XCTAssertTrue(TaskBoardStore.publish(dash))

        let expected = Paths.machineID()
        XCTAssertFalse(expected.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        XCTAssertEqual(files, ["\(expected).json"], """
            文件名不是 Paths.machineID() —— 快照用的是它，任务板用别的，
            手机上两边就对不上号了
            """)
        XCTAssertEqual(TaskBoardStore.loadAll().boards.first?.machineID, expected)
    }

    /// 发布出去的内容就是 `Dashboard` 里那一份，不重新算一遍。
    /// 重算就有机会不一致，而老手机读 `dashboard.tasks`、新手机读任务板，
    /// 两边说的必须是同一件事。
    func testPublishedBoardMirrorsTheDashboardExactly() throws {
        let dash = Dashboard(generatedAt: now, machines: [], reports: [],
                             tasks: [brief("a"), brief("b")], tasksTruncated: true)
        TaskBoardStore.publish(dash, machineID: "AAA", machineName: "Mac mini")

        let got = TaskBoardStore.loadAll().boards.first
        XCTAssertEqual(got?.tasks.map(\.id), dash.tasks.map(\.id))
        XCTAssertEqual(got?.generatedAt, dash.generatedAt)
        XCTAssertTrue(got?.tasksTruncated ?? false,
                      "截断标记丢了，手机上的条数就变成一句没人会核对的假话")
    }

    // MARK: - 3. 老 dashboard.tasks 还在

    /// **别删 `dashboard.tasks`。** 老版本手机只认它，
    /// 一删它们不是「少了任务列表」，是一条任务都看不到。
    func testDashboardStillCarriesTasksForOldPhones() throws {
        let engine = QuotaEngine(config: PlansConfig.template())
        var t = WorkTask(id: "r1", prompt: "干活", repo: "/tmp/repo")
        t.state = .running
        t.startedAt = now.addingTimeInterval(-60)
        let dash = engine.buildDashboard(snapshots: [], now: now, tasks: [t],
                                         machineName: "Mac mini", repoAliases: [])

        XCTAssertEqual(dash.tasks.map(\.id), ["r1"])
        let json = String(decoding: try SnapshotCoding.encoder().encode(dash), as: UTF8.self)
        XCTAssertTrue(json.contains("\"tasks\""), """
            dashboard.json 里没有 tasks 键了 —— 老版本手机只认这个键，
            新的 taskboards/ 它们根本不会去读
            """)
        XCTAssertTrue(json.contains("\"tasksTruncated\""))
    }

    /// 采集那一段必须**两个都发**。手工枚举发布点这件事，这个项目漏过一次，
    /// 所以在源码层面钉一下：删掉任何一边都会红。
    func testCollectPublishesBothTheDashboardAndTheTaskboard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LLMQuotaCore/Store.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("Inbox.publishDashboard(dash)"),
                      "dashboard.json 的 tasks 是老手机唯一的来源，不能停发")
        XCTAssertTrue(src.contains("TaskBoardStore.publish(dash)"),
                      "按机器分的任务板没发出去，手机上还是只看得到一台")
        XCTAssertTrue(src.contains("TaskBoardStore.prune("),
                      "清理只能在 Mac 侧做，手机只读 —— 这里不做就没人做了")
    }

    // MARK: - 4. 清理

    func testPruneRemovesBoardsNobodyHasTouchedForAWeek() throws {
        let old = now.addingTimeInterval(-8 * 86400)
        TaskBoardStore.publish(board("OLD", generatedAt: old))
        TaskBoardStore.publish(board("NEW", generatedAt: now.addingTimeInterval(-600)))
        setModified(fileURL("OLD"), old)
        setModified(fileURL("NEW"), now.addingTimeInterval(-600))

        let r = TaskBoardStore.prune(now: now)
        XCTAssertEqual(r.removed, ["OLD.json"])
        XCTAssertEqual(TaskBoardStore.loadAll().boards.map(\.machineID), ["NEW"])
    }

    /// **读不动的一律留着。**
    ///
    /// iCloud 没响应不等于那台机器没了，而删除是不可逆的。
    /// 这个项目已经在「把读不到当成没有」上栽过三次，其中一次
    /// （新机器 mirror 失败被当成「iCloud 上没有」）把整份配置覆盖掉了。
    func testPruneKeepsBoardsItCannotRead() throws {
        let old = now.addingTimeInterval(-30 * 86400)
        TaskBoardStore.publish(board("UNREADABLE", generatedAt: old))
        let url = fileURL("UNREADABLE")
        setModified(url, old)
        // 内容和 mtime 都写着「30 天前」—— 单看年龄它百分之百够格被删。
        // 唯一拦住它的只能是「这一份我读不出来」。
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: url.path)
        // 前提自检：真的读不了。读得了的话下面那条断言就是白过的。
        XCTAssertNil(try? Data(contentsOf: url), "文件还读得动，这条用例没测到东西")

        let r = TaskBoardStore.prune(now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), """
            读不动的板子被删了 —— iCloud 没响应不等于那台机器没了，
            而这一步不可逆
            """)
        XCTAssertEqual(r.removed, [])
        XCTAssertEqual(r.skipped, ["UNREADABLE.json"],
                       "没删也得报出来，否则「留着」和「没这个文件」又分不清了")
    }

    /// 内容里没有 `generatedAt`（老版本写的）时，不能靠解码兜底的
    /// `distantPast` 就把文件删了 —— 文件 mtime 才是它真实的年龄。
    func testPruneFallsBackToFileTimeWhenGeneratedAtIsMissing() throws {
        let url = fileURL("NOSTAMP")
        try Data(#"{"machineName":"Mac mini","tasks":[]}"#.utf8).write(to: url)
        setModified(url, now.addingTimeInterval(-600))

        let r = TaskBoardStore.prune(now: now)
        XCTAssertEqual(r.removed, [], """
            缺 generatedAt 的板子被当成「非常旧」删掉了 ——
            它可能是十分钟前刚写的，文件 mtime 就摆在那儿
            """)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 目录整个读不动的那一轮，什么都不许删。
    func testPruneDoesNothingWhenTheDirectoryIsGone() {
        TaskBoardStore.dirOverride = root.appendingPathComponent("nope", isDirectory: true)
        let r = TaskBoardStore.prune(now: now)
        XCTAssertEqual(r.removed, [])
        XCTAssertEqual(r.skipped, [])
    }

    func testLastActivityTakesTheNewerSignal() {
        let old = now.addingTimeInterval(-9 * 86400)
        XCTAssertEqual(TaskBoardStore.lastActivity(generatedAt: old, mtime: now), now)
        XCTAssertEqual(TaskBoardStore.lastActivity(generatedAt: now, mtime: old), now)
        XCTAssertEqual(TaskBoardStore.lastActivity(generatedAt: .distantPast, mtime: now), now,
                       "distantPast 是解码兜底出来的，不是真实时间，不该参与比较")
        XCTAssertNil(TaskBoardStore.lastActivity(generatedAt: nil, mtime: nil),
                     "一个时间信号都没有时必须返回 nil —— 让调用方留着，别猜")
    }

    // MARK: - 读不到 ≠ 没有

    func testLoadAllSeparatesUnreadableFromAbsent() throws {
        TaskBoardStore.publish(board("GOOD", tasks: [brief("t1")]))
        // 同步到一半的半截文件。
        try Data("{ not json".utf8).write(to: fileURL("HALF"))

        let listing = TaskBoardStore.loadAll()
        XCTAssertEqual(listing.boards.map(\.machineID), ["GOOD"])
        XCTAssertEqual(listing.unreadable, ["HALF.json"])
        XCTAssertFalse(listing.isComplete, """
            有读不出来的却说清单是完整的 —— 界面会照着说「一共 1 台」，
            而实际上有一台不知道
            """)
    }

    func testMissingDirectoryIsNotTheSameAsEmptyDirectory() {
        let empty = TaskBoardStore.loadAll()
        XCTAssertTrue(empty.boards.isEmpty)
        XCTAssertFalse(empty.directoryMissing, "目录在、只是没文件")

        TaskBoardStore.dirOverride = root.appendingPathComponent("nope", isDirectory: true)
        let gone = TaskBoardStore.loadAll()
        XCTAssertTrue(gone.directoryMissing, """
            目录不存在和目录是空的必须分得开：前者是「还没人发过」，
            后者是「发过的都被清掉了」
            """)
    }

    // MARK: - 缺字段照样解得出来

    /// 合成解码器缺一个键就抛 `keyNotFound`，整份任务板解不出来 ——
    /// 手机上那台机器就变成「一条任务都没有」，而它明明在干活。
    func testDecodesWithEveryOptionalKeyMissing() throws {
        let b = try SnapshotCoding.decoder()
            .decode(MachineTaskBoard.self, from: Data("{}".utf8))
        XCTAssertEqual(b.machineID, "")
        XCTAssertEqual(b.tasks, [])
        XCTAssertFalse(b.tasksTruncated)
        XCTAssertEqual(b.generatedAt, .distantPast, """
            缺 generatedAt 兜底成「现在」的话，一份不知道什么时候采的板子
            会被当成刚采的，里面那些早就死了的 running 就成了实时状态
            """)
    }

    /// 缺 `machineID` 时用文件名补上 —— 文件名就是 machineID。
    /// 手机按 `(machineID, task.id)` 去重，machineID 空掉会让两台机器
    /// 的同 id 任务互相盖掉。
    func testMachineIDFallsBackToTheFileName() throws {
        try Data(#"{"machineName":"老机器","tasks":[]}"#.utf8)
            .write(to: fileURL("C15DF1AA"))
        let listing = TaskBoardStore.loadAll()
        XCTAssertEqual(listing.boards.map(\.machineID), ["C15DF1AA"])
    }

    /// 板子多久没更新，是手机判断「这是 N 分钟前的状态」的唯一依据。
    /// 口径写在一个地方，别让两边各写一个数。
    func testStaleThresholdIsTwoCollectionRounds() {
        XCTAssertEqual(TaskBoardStore.staleAfter, 30 * 60)
        XCTAssertEqual(TaskBoardStore.discardAfter, 7 * 86400)
        XCTAssertGreaterThan(TaskBoardStore.discardAfter, TaskBoardStore.staleAfter, """
            「不能当实时看」和「这台机器已经不在了」是两回事 ——
            清理阈值要是掉到显示阈值下面，一台机器睡一晚上任务板就没了
            """)
    }
}
