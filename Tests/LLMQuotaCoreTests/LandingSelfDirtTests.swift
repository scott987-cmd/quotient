import XCTest
@testable import LLMQuotaCore

/// 落地自己留下的脏(STATUS.md 提交没成)不能把落地堵死。
/// 实锤 2026-08-23 14:59 Flint:一行进度没提交上,整仓两小时没落地,续活还重复派了主线第 3 块。
final class LandingSelfDirtTests: XCTestCase {
    private func git(_ args: [String], _ dir: String) -> Proc.Result { GitWorkspace.git(args, in: dir) }

    private func makeRepo() throws -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfdirt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let p = d.path
        _ = git(["init", "-q", "-b", "main"], p)
        _ = git(["config", "user.email", "t@t"], p); _ = git(["config", "user.name", "t"], p)
        try "# s\n".write(toFile: p + "/STATUS.md", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: p + "/foo.txt", atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], p); _ = git(["commit", "-q", "-m", "init"], p)
        return p
    }

    func test_只有STATUS脏_自动补提交_不挡落地() throws {
        let p = try makeRepo()
        try "# s\nnew line\n".write(toFile: p + "/STATUS.md", atomically: true, encoding: .utf8)
        _ = git(["add", "--", "STATUS.md"], p)   // 像上次提交失败后那样:暂存着
        XCTAssertNil(Review.dirtBlockingLanding(repo: p), "自己留的脏要自己收,不该挡落地")
        XCTAssertTrue(git(["log", "-1", "--format=%s"], p).stdout.contains("补记"))
        XCTAssertEqual(git(["status", "--porcelain"], p).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func test_别的文件脏_照旧让开_且不动STATUS() throws {
        let p = try makeRepo()
        try "y\n".write(toFile: p + "/foo.txt", atomically: true, encoding: .utf8)
        try "# s\nnew\n".write(toFile: p + "/STATUS.md", atomically: true, encoding: .utf8)
        XCTAssertNotNil(Review.dirtBlockingLanding(repo: p), "人在改 foo.txt,落地该让开")
        XCTAssertEqual(git(["log", "-1", "--format=%s"], p).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "init",
                       "人在工作时不替人提交任何东西")
    }

    func test_干净仓库_nil() throws {
        let p = try makeRepo()
        XCTAssertNil(Review.dirtBlockingLanding(repo: p))
    }

    func test_提交撞锁失败_还原STATUS_不留脏() throws {
        let p = try makeRepo()
        try "# s\nnew\n".write(toFile: p + "/STATUS.md", atomically: true, encoding: .utf8)
        // 模拟另一个 git 进程占着 index.lock
        FileManager.default.createFile(atPath: p + "/.git/index.lock", contents: Data())
        let ok = ProgressLog.commitStatus(repo: p, message: "进度：记录 x")
        XCTAssertFalse(ok)
        // 锁还占着时至少把工作区内容还原成 HEAD 版本(不碰 index 的路径)
        XCTAssertEqual(try String(contentsOfFile: p + "/STATUS.md", encoding: .utf8), "# s\n")
        // 锁一放,下一轮落地前的判定把残留收干净,不挡落地
        try? FileManager.default.removeItem(atPath: p + "/.git/index.lock")
        XCTAssertNil(Review.dirtBlockingLanding(repo: p))
        XCTAssertEqual(git(["status", "--porcelain"], p).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
