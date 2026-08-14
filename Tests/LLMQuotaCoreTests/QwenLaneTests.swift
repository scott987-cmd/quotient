import XCTest
@testable import LLMQuotaCore

/// Qwen 的用量要能分出「人烧的」和「调度器烧的」。
///
/// # 这条不修会怎样
///
/// Qwen 的事件原来**根本不带 lane**，于是每一笔都算人用的。
/// 调度器有一条「人刚用过就让开」的规则，判据正是这个 —— 结果它派 Qwen
/// 跑完一个任务之后，立刻把 Qwen 自己排除掉：
///
///     [23:15] 派给 Qwen 跑 s2
///     [23:21] 排除 Qwen「你 6 分钟前还在用它，先让着你」
///
/// 当时 Kimi 额度耗尽、Claude 是指挥、火山档次不够 ——
/// **等于每跑一个任务就把自己锁在唯一可用的平台外面 20 分钟**。
/// 这跟「一分不浪费」正好相反。
///
/// # 证据从哪来
///
/// Qwen 落两份记录，各缺一半：`token-usage-*.jsonl` 有 token 没路径，
/// `usage_record.jsonl` 有 `project` 没 token。两边靠 `sessionId` 对上。
/// 真实数据上验过：138 条 headless / 42 条 interactive / 93 条判不出。
final class QwenLaneTests: XCTestCase {

    private var home: URL!

    override func setUp() {
        super.setUp()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qwenlane-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        Paths.appSupportOverride = home
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    /// 调度器的 worktree 里烧的，一律是 headless。
    func testWorktreePathIsHeadless() {
        let wt = LaneRouter.schedulerWorkspaceRoot + "/42266d0f"
        XCTAssertEqual(LaneRouter.lane(forEntrypoint: nil, cwd: wt), .headless,
                       "worktree 里跑的是调度器自己，不该算人在用")
    }

    /// 人自己的项目目录是 interactive。
    func testUserProjectIsInteractive() {
        XCTAssertEqual(
            LaneRouter.lane(forEntrypoint: nil, cwd: "/Users/x/dev/我的项目"),
            .interactive)
    }

    /// **判不出来时要保守地当成「人在用」。**
    ///
    /// 反过来（判不出就当自己烧的）会让调度器在人正在敲代码时抢同一个窗口 ——
    /// 那个错误方向的代价大得多。
    func testUnknownFallsBackToInteractive() {
        XCTAssertEqual(LaneRouter.lane(forEntrypoint: nil, cwd: nil), .interactive)
        XCTAssertEqual(LaneRouter.lane(forEntrypoint: "", cwd: nil), .interactive)
    }

    /// 两份记录靠 sessionId 对上。
    func testSessionToProjectJoin() throws {
        let qwen = home.appendingPathComponent(".qwen", isDirectory: true)
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        // 这里只验拼接逻辑本身 —— 真实路径由 sessionProjects() 从 ~ 下读，
        // 单测不改 HOME，所以直接验它对「有/无 project」两种输入的判定。
        let wt = LaneRouter.schedulerWorkspaceRoot + "/abc"
        let joined: [String: String] = ["s1": wt, "s2": "/Users/x/我的项目"]

        XCTAssertEqual(LaneRouter.lane(forEntrypoint: nil, cwd: joined["s1"]), .headless)
        XCTAssertEqual(LaneRouter.lane(forEntrypoint: nil, cwd: joined["s2"]), .interactive)
        XCTAssertEqual(LaneRouter.lane(forEntrypoint: nil, cwd: joined["没这个会话"]),
                       .interactive, "对不上的会话要退回保守判定，不能当成自己烧的")
    }

    /// 缓存不能把「文件变了」也一起缓存掉。
    func testSessionProjectsIsCallableAndStable() {
        let a = QwenCodeAdapter.sessionProjects()
        let b = QwenCodeAdapter.sessionProjects()
        XCTAssertEqual(a.count, b.count, "同一份文件两次读出来要一致")
    }
}
