import XCTest
@testable import LLMQuotaCore

/// 工作区还有人在里面，就不许切分支交给别人。
///
/// 2026-08-25 现场：worker 被发版重启，它的 agent 子进程成了孤儿，
/// 在 worktrees/flint-openrouter 里又跑了 88 分钟；新 worker 把同一个目录
/// 切到另一条任务的分支，两个 agent 同时往一个工作区里写。
/// 仓库租约挡不住 —— 租约看任务状态，而孤儿对应的任务根本没有 running 记录。
final class WorkspaceBusyTests: XCTestCase {
    private var saved: ((String) -> [Int32])!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        saved = GitWorkspace.occupantsProbe
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-busy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch,
                                                  withIntermediateDirectories: true)
        Paths.appSupportOverride = scratch.appendingPathComponent("support")
    }

    override func tearDown() {
        GitWorkspace.occupantsProbe = saved
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func test_有人占着时_错误里要点名进程() {
        let e = GitWorkspace.WorkspaceBusy(path: "/tmp/wt/flint-openrouter", pids: [22566])
        XCTAssertTrue(e.description.contains("22566"), "必须说清是谁占着，否则没法处置")
        XCTAssertTrue(e.description.contains("flint-openrouter"))
    }

    func test_探针可注入_并且排除自己() {
        GitWorkspace.occupantsProbe = { _ in [22566, getpid()] }
        let found = GitWorkspace.occupantsProbe("/tmp/wt").filter { $0 != getpid() }
        XCTAssertEqual(found, [22566], "自己这个进程不算占用")
    }

    func test_没人占着时_探针返回空() {
        GitWorkspace.occupantsProbe = { _ in [] }
        XCTAssertTrue(GitWorkspace.occupantsProbe("/tmp/wt").isEmpty)
    }

    func test_切换复用工作区前_真实经过占用闸() throws {
        let repo = scratch.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo,
                                                withIntermediateDirectories: true)
        func git(_ args: [String]) { _ = GitWorkspace.git(args, in: repo.path) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        try "base\n".write(to: repo.appendingPathComponent("README.md"),
                            atomically: true, encoding: .utf8)
        git(["add", "-A"])
        git(["commit", "-q", "-m", "base"])

        GitWorkspace.occupantsProbe = { _ in [] }
        let first = try GitWorkspace.prepare(
            repo: repo.path, taskID: "one", platform: .openrouter)
        GitWorkspace.occupantsProbe = { path in
            path == first.path ? [22566] : []
        }

        XCTAssertThrowsError(try GitWorkspace.prepare(
            repo: repo.path, taskID: "two", platform: .openrouter)) { error in
            guard let busy = error as? GitWorkspace.WorkspaceBusy else {
                return XCTFail("应由 WorkspaceBusy 阻止切分支，实际：\(error)")
            }
            XCTAssertEqual(busy.pids, [22566])
        }
        let branch = GitWorkspace.git(
            ["rev-parse", "--abbrev-ref", "HEAD"], in: first.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, first.branch, "拦截发生后不能已经切到第二条任务")
    }
}
