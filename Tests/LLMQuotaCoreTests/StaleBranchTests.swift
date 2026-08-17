import XCTest
@testable import LLMQuotaCore

/// 分支腐烂检测与刷新派活。
///
/// 背景见 `StaleBranch` 的文档注释。这里守的是**边界**：
/// 哪些分支该刷、哪些绝对不能碰。刷错一条的代价是实打实的 ——
/// 解冲突是重活，一次跑掉的额度够干几件真事。
final class StaleBranchTests: XCTestCase {

    private var repo: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repo = dir.path
        func git(_ a: [String]) { _ = GitWorkspace.git(a, in: repo) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        write("base.txt", "0\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "init"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: repo)
        super.tearDown()
    }

    private func write(_ name: String, _ text: String) {
        let u = URL(fileURLWithPath: repo).appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    /// 造一条会和 main 冲突的分支：两边都改同一个文件的同一行。
    @discardableResult
    private func makeConflicting(_ id: String, files: Int) -> String {
        let branch = "agent/kimi/\(id)"
        func git(_ a: [String]) { _ = GitWorkspace.git(a, in: repo) }
        git(["checkout", "-q", "-b", branch, "main"])
        for i in 0..<files {
            write("shared\(i).swift", "branch-\(id)\n")
        }
        git(["add", "-A"]); git(["commit", "-q", "-m", "分支 \(id) 的改动"])
        // main 往前走，改同样的文件 → 真冲突
        git(["checkout", "-q", "main"])
        for i in 0..<files {
            write("shared\(i).swift", "main-moved\n")
        }
        git(["add", "-A"]); git(["commit", "-q", "-m", "main 前进"])
        return branch
    }

    private func task(_ id: String, state: WorkTask.State = .done,
                      platform: Platform? = .kimi) -> WorkTask {
        var t = WorkTask(id: id, prompt: "干点什么", repo: repo)
        t.state = state
        t.platform = platform
        return t
    }

    /// 主路径：过期、够大、任务 done → 该刷，且记得住是谁做的。
    func testStaleBranchIsPickedUpWithItsOriginalPlatform() {
        makeConflicting("aaa11111", files: 4)
        let cs = StaleBranch.candidates(repo: repo, tasks: [task("aaa11111")])
        XCTAssertEqual(cs.count, 1, "过期又够大的分支该被挑出来：\(cs)")
        XCTAssertEqual(cs.first?.platform, .kimi,
                       "得记住当初是谁做的 —— 刷新要派回给它，它还留着会话")
        XCTAssertGreaterThan(cs.first?.commitsBehind ?? 0, 0)
    }

    /// **还在跑的不碰。** 分支下面正有 agent 在动，去搅它等于两个人抢一支笔。
    func testRunningTaskIsNeverRefreshed() {
        makeConflicting("bbb22222", files: 4)
        let cs = StaleBranch.candidates(repo: repo,
                                        tasks: [task("bbb22222", state: .running)])
        XCTAssertTrue(cs.isEmpty, "跑着的任务不能派刷新：\(cs)")
    }

    /// **失败的不刷。** 失败产出本来就该人看，
    /// 刷新只会把一堆垃圾洗干净再端上来，看着像能合了。
    func testFailedTaskIsNeverRefreshed() {
        makeConflicting("ccc33333", files: 4)
        let cs = StaleBranch.candidates(repo: repo,
                                        tasks: [task("ccc33333", state: .failed)])
        XCTAssertTrue(cs.isEmpty, "failed 的产出不该自动刷新：\(cs)")
    }

    /// **太小的不刷。** 一个只改一两个文件的分支（比如一份评审报告），
    /// 重做比解冲突便宜 —— 解冲突要读两边改动加中间几十个提交，
    /// 重做只要读当前 main。
    func testTinyBranchIsNotWorthRefreshing() {
        makeConflicting("ddd44444", files: 1)
        let cs = StaleBranch.candidates(repo: repo, tasks: [task("ddd44444")])
        XCTAssertTrue(cs.isEmpty, "一个文件的分支重做更便宜，别派解冲突：\(cs)")
    }

    /// **能干净合入的不刷。** 它没病，刷它就是白烧一次额度。
    func testCleanlyMergingBranchIsNotRefreshed() {
        let branch = "agent/kimi/eee55555"
        func git(_ a: [String]) { _ = GitWorkspace.git(a, in: repo) }
        git(["checkout", "-q", "-b", branch, "main"])
        for i in 0..<4 { write("only-mine\(i).swift", "x\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "不冲突的改动"])
        git(["checkout", "-q", "main"])

        let cs = StaleBranch.candidates(repo: repo, tasks: [task("eee55555")])
        XCTAssertTrue(cs.isEmpty, "合得进去的分支没病，别刷：\(cs)")
    }

    /// 刷新指令必须写死「不许改变原意图」。
    ///
    /// 这不是措辞洁癖 —— agent 拿到「解决冲突」很容易顺手把冲突处两边都删掉，
    /// 或者按自己的想法重写。合是合上了，但这条分支想做的事没了，
    /// 而外面看起来是「刷新成功」。这种失败是**静默**的，最贵。
    func testRefreshPromptForbidsChangingIntent() {
        let c = StaleBranch.Candidate(
            branch: "agent/kimi/f6", repo: repo, platform: .kimi,
            commitsBehind: 39, files: 16, subject: "修换档叠影")
        let p = StaleBranch.refreshPrompt(c)
        XCTAssertTrue(p.contains("不许改变"), "得挡住「顺手重写一遍」")
        XCTAssertTrue(p.contains("不许为了「合得上」把本分支的改动删掉"),
                      "得挡住「删干净就不冲突了」这条最省事的歪路")
        XCTAssertTrue(p.contains("agent/kimi/f6"), "提示词里要带分支名 —— 查重靠它")
        XCTAssertTrue(p.contains("39"), "要告诉它落后多少，它才知道该多小心")
    }
}
