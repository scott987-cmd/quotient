import XCTest
@testable import LLMQuotaCore

/// 同一个平台在同一个仓库上，**必须复用同一个工作区目录**。
///
/// ## 这条为什么值钱
///
/// 老板的原话：「每次重新处理任务的上下文加载和信息丢失我觉得损耗很大」。
///
/// 根因是一任务一目录、跑完就删：目录没了，agent 的会话就接不上
///（`--resume` 恢复出来的 cwd 已经不存在），于是每个任务都要
/// 重开会话、重读仓库、重新猜约定。而会话里装着的
/// 「这仓库长什么样、上次为什么那么改、哪个坑踩过」是重读读不回来的。
///
/// 复用的机制本来就有，只是被限死在一张图内部。放宽到「仓库 × 平台」
/// 之后：目录稳定 → 会话能接上 → 上下文跨任务活着。
///
/// 顺带治了磁盘：一任务一个全量检出，15 个工作区吃掉 1.9G，
/// 直接把机器撑到 ENOSPC（连编译都跑不动）。改完之后工作区数量的上界
/// 是「仓库数 × 平台数」，不再随任务数无限涨。
///
/// **分支不跟着长期化**：验收还是一任务一条分支，粒度不变 ——
/// 会话要的是 cwd 稳定，不是分支稳定。
final class WorkspaceReuseTests: XCTestCase {

    /// 同仓库同平台 → 同一个目录名；换平台或换仓库 → 不同目录。
    func testStableKeyIsPerRepoAndPlatform() {
        let a = GitWorkspace.stableKey(repo: "/dev/greed", platform: .claude)
        let b = GitWorkspace.stableKey(repo: "/dev/greed", platform: .claude)
        XCTAssertEqual(a, b, "同一个仓库同一个平台必须落在同一个目录，否则会话接不上")

        let other = GitWorkspace.stableKey(repo: "/dev/greed", platform: .kimi)
        XCTAssertNotEqual(a, other, "两个平台共用一个目录会互相踩")

        let otherRepo = GitWorkspace.stableKey(repo: "/dev/maw", platform: .claude)
        XCTAssertNotEqual(a, otherRepo, "两个仓库共用一个目录，agent 会把 A 的约定用到 B 上")
    }

    /// 目录名不能带斜杠空格之类 —— 它要当文件名用。
    func testStableKeyIsFilesystemSafe() {
        let k = GitWorkspace.stableKey(repo: "/some/path with space/My Repo",
                                       platform: .codex)
        XCTAssertFalse(k.contains("/"), "带斜杠会被当成子目录")
        XCTAssertFalse(k.contains(" "), "带空格会在各种脚本里翻车")
        XCTAssertFalse(k.isEmpty)
    }

    /// 真跑一遍：同一个仓库连开两个任务，目录相同、分支不同。
    ///
    /// 这是这次改动的**全部意义**，所以要用真 git 仓库验，不能只测键。
    func testTwoTasksShareDirectoryButGetOwnBranches() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory
            .appendingPathComponent("wsreuse-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: repo) }
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)

        func git(_ args: [String]) { _ = GitWorkspace.git(args, in: repo.path) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        try "hello\n".write(to: repo.appendingPathComponent("README.md"),
                            atomically: true, encoding: .utf8)
        git(["add", "-A"])
        git(["commit", "-q", "-m", "init"])

        let w1 = try GitWorkspace.prepare(repo: repo.path, taskID: "task-one",
                                          platform: .claude)
        // 第一个任务留下一个提交，模拟真实情况
        try "one\n".write(to: URL(fileURLWithPath: w1.path)
            .appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        _ = GitWorkspace.git(["add", "-A"], in: w1.path)
        _ = GitWorkspace.git(["commit", "-q", "-m", "one"], in: w1.path)

        let w2 = try GitWorkspace.prepare(repo: repo.path, taskID: "task-two",
                                          platform: .claude)

        XCTAssertEqual(w1.path, w2.path,
                       "两个任务必须落在同一个目录 —— 换目录就等于会话作废")
        XCTAssertNotEqual(w1.branch, w2.branch,
                          "分支还是一任务一条，验收粒度不能变")

        // 第二个任务必须站在干净的主干上，不能把上一个任务的改动带进来
        let leftover = FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: w2.path).appendingPathComponent("one.txt").path)
        XCTAssertFalse(leftover,
                       "第二个任务脚下带着上一个任务的改动，产出会被算成它干的")

        // 上一个任务的提交没丢 —— 只是不在脚下
        let has = GitWorkspace.git(["rev-parse", "--verify", w1.branch], in: repo.path)
        XCTAssertEqual(has.exitCode, 0, "复用目录不能把上一条分支弄没")

        // 收尾，别把测试用的 worktree 留在真实的 app support 目录里
        _ = GitWorkspace.git(["worktree", "remove", "--force", w2.path], in: repo.path)
    }
}
