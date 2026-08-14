import XCTest
@testable import LLMQuotaCore

/// 接力时「这一轮谁干的」必须和「分支上一共有什么」分开算。
///
/// 真实事故：任务 `e048033c` 被三个 agent 接力跑。Qwen 早上做完并提交，
/// 机器崩了十小时，恢复后 Kimi 和火山方舟先后接手。火山方舟自己一行没动
/// （worktree 干净、没有新提交），记录却写着：
///
///     改了 1 个文件，验证通过，已提交到 agent/qwen/e048033c
///     （1 个提交是 agent 自己打的）（接手 Kimi 的进度完成）
///
/// 三句话三个错：文件是 Qwen 改的、提交是 Qwen 打的、Kimi 也没留下东西。
/// 原因是所有计数都相对 `main` 算，那是**累计量**，接力时包含前人的成果。
final class AttributionTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "attr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        _ = GitWorkspace.git(["init", "-q", "-b", "main"], in: dir)
        _ = GitWorkspace.git(["config", "user.email", "t@t"], in: dir)
        _ = GitWorkspace.git(["config", "user.name", "t"], in: dir)
        write("base.txt", "base")
        _ = GitWorkspace.git(["add", "-A"], in: dir)
        _ = GitWorkspace.git(["commit", "-qm", "base"], in: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func write(_ name: String, _ body: String) {
        try? body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func commit(_ msg: String) {
        _ = GitWorkspace.git(["add", "-A"], in: dir)
        _ = GitWorkspace.git(["commit", "-qm", msg], in: dir)
    }

    /// 第二棒什么都没干时，**相对它开工时的 HEAD** 必须算出 0。
    func testSecondAgentThatDidNothingCountsZero() throws {
        _ = GitWorkspace.git(["checkout", "-qb", "agent/x"], in: dir)
        write("a.swift", "第一棒写的")
        commit("agent1")

        // 第二棒接手时的基准。
        let headBefore = try XCTUnwrap(GitWorkspace.headSHA(in: dir))
        // ……然后它什么都没做。

        XCTAssertEqual(GitWorkspace.changedFileCount(in: dir, base: headBefore), 0,
                       "第二棒没动任何东西，属于它的改动必须是 0")
        XCTAssertEqual(GitWorkspace.commitsAhead(in: dir, base: headBefore), 0)

        // 而累计量是 1 —— 旧代码报的就是这个数，于是记到了第二棒头上。
        XCTAssertEqual(GitWorkspace.changedFileCount(in: dir, base: "main"), 1,
                       "分支相对 main 确实有 1 个文件，但那是第一棒的")
    }

    /// 第二棒真干了活时，两个数都要对得上。
    func testSecondAgentContributionIsCountedSeparately() throws {
        _ = GitWorkspace.git(["checkout", "-qb", "agent/y"], in: dir)
        write("a.swift", "第一棒")
        commit("agent1")
        let headBefore = try XCTUnwrap(GitWorkspace.headSHA(in: dir))

        write("b.swift", "第二棒")
        commit("agent2")

        XCTAssertEqual(GitWorkspace.changedFileCount(in: dir, base: headBefore), 1,
                       "第二棒自己加了 b.swift，就是 1")
        XCTAssertEqual(GitWorkspace.commitsAhead(in: dir, base: headBefore), 1)
        XCTAssertEqual(GitWorkspace.changedFileCount(in: dir, base: "main"), 2,
                       "累计是 2（a + b）—— 这个数本身没错，错在拿它当「谁干的」")
    }

    /// 没提交但改了工作区，也算这一棒干的。
    func testUncommittedWorkCountsForThisAgent() throws {
        _ = GitWorkspace.git(["checkout", "-qb", "agent/z"], in: dir)
        write("a.swift", "第一棒")
        commit("agent1")
        let headBefore = try XCTUnwrap(GitWorkspace.headSHA(in: dir))

        write("c.swift", "第二棒还没提交")

        XCTAssertEqual(GitWorkspace.changedFileCount(in: dir, base: headBefore), 1)
        XCTAssertEqual(GitWorkspace.commitsAhead(in: dir, base: headBefore), 0,
                       "没提交，所以提交数是 0 —— 但改动是它的")
    }

    func testHeadSHAIsStableAndRealistic() throws {
        let sha = try XCTUnwrap(GitWorkspace.headSHA(in: dir))
        XCTAssertEqual(sha.count, 40, "要完整 sha，短 sha 在大仓库里会撞")
        XCTAssertEqual(sha, GitWorkspace.headSHA(in: dir))
        XCTAssertNil(GitWorkspace.headSHA(in: NSTemporaryDirectory() + "no-such-\(UUID())"),
                     "不是仓库就该返回 nil，不能给一个假 sha")
    }
}
