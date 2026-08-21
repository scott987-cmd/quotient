import XCTest
@testable import LLMQuotaCore

/// **没给 --repo 时用当前目录,不是默认别名。**
///
/// 实锤(2026-08-22 凌晨):`RepoRegistry.resolve(nil)` 返回默认别名,
/// 于是 `resolve(arg) ?? 当前目录` 里的兜底永远轮不到 —— 在 ~/dev/Flint
/// 里跑 `llmq work review --merge <分支>` 跑去 LLMQuotaBar 上合,
/// 报「not something we can merge」。同名分支存在于两个仓库时更危险:
/// 它会默默合错仓库。
final class RepoArgResolutionTests: XCTestCase {
    private var sandbox: URL!
    private var repoA: String!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoarg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        repoA = sandbox.appendingPathComponent("repoA").path
        try? FileManager.default.createDirectory(atPath: repoA, withIntermediateDirectories: true)
        _ = GitWorkspace.git(["init", "--initial-branch=main"], in: repoA)
    }
    override func tearDown() {
        RepoRegistry.fileOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func registry(defaultPath: String) throws {
        let f = sandbox.appendingPathComponent("repos.json")
        let entry: [String: Any] = ["alias": "other", "path": defaultPath,
                                    "isDefault": true, "pathByMachine": [:]]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: f)
        RepoRegistry.fileOverride = f
    }

    func testCwdWinsWhenNoArgGiven() throws {
        try registry(defaultPath: "/somewhere/else")
        XCTAssertEqual(RepoRegistry.resolveForCommand(nil, cwd: repoA), repoA,
                       "站在哪个仓库里就操作哪个 —— 否则命令会在你没看的仓库上动手")
    }

    /// 当前目录不是 git 仓库时才退回默认别名。
    func testFallsBackToDefaultOutsideAnyRepo() throws {
        try registry(defaultPath: "/somewhere/else")
        XCTAssertEqual(RepoRegistry.resolveForCommand(nil, cwd: sandbox.path),
                       "/somewhere/else")
    }

    /// 显式 --repo 永远优先。
    func testExplicitArgWins() throws {
        try registry(defaultPath: "/somewhere/else")
        XCTAssertEqual(RepoRegistry.resolveForCommand("other", cwd: repoA), "/somewhere/else")
    }
}
