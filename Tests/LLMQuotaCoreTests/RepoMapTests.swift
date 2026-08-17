import XCTest
@testable import LLMQuotaCore

/// 仓库地图必须在**工作区路径**下也能扫出东西。
///
/// 真实事故（2026-08-17）：地图上线当天，`llmq map greed` 打印得漂漂亮亮，
/// 而真派活时注入的是空字符串 —— 一个字都没进提示词。
///
/// 原因是噪音过滤器拿**绝对路径**的组件去匹配 `worktrees`，
/// 而 agent 的工作区本身就住在 `…/LLMQuotaBar/worktrees/<任务号>/`：
/// 里面每一个文件都带着这个组件，于是被自己的过滤器一个不剩地杀光。
///
/// 手测用的是主仓库路径，派活用的是工作区路径 —— 测的和跑的不是同一条路，
/// 所以「跑通了但没生效」。这个测试就是把两条路都钉住：
/// 工作区下必须扫得出，主仓库下必须扫不到工作区里的东西。
final class RepoMapTests: XCTestCase {

    /// 造一个假仓库：根目录下有源码，另有一个 worktrees 子目录装「别人的副本」。
    private func makeRepo(at root: URL, marker: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources"),
                               withIntermediateDirectories: true)
        try "struct \(marker) {}\n"
            .write(to: root.appendingPathComponent("Sources/Main.swift"),
                   atomically: true, encoding: .utf8)
    }

    func testScansUnderAPathThatItselfContainsWorktrees() throws {
        let fm = FileManager.default
        // 关键：根目录路径里**就带着** worktrees 这一段，模拟真实的 agent 工作区
        let base = fm.temporaryDirectory
            .appendingPathComponent("repomap-\(UUID().uuidString)")
        let worktree = base.appendingPathComponent("worktrees/abc123")
        defer { try? fm.removeItem(at: base) }
        try makeRepo(at: worktree, marker: "InsideWorktree")

        let map = RepoMap.build(repo: worktree.path)
        XCTAssertFalse(map.isEmpty,
                       "工作区路径下扫不出东西 —— 派活时注入的会是空字符串")
        XCTAssertTrue(map.contains("InsideWorktree"),
                      "扫到了文件但没抓到符号名")
    }

    func testMainRepoStillExcludesItsOwnWorktrees() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("repomap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try makeRepo(at: root, marker: "RealSource")
        // 仓库里躺着一个 agent 工作区，里面是同一份代码的旧副本
        try makeRepo(at: root.appendingPathComponent("worktrees/old"),
                     marker: "StaleCopy")

        let map = RepoMap.build(repo: root.path)
        XCTAssertTrue(map.contains("RealSource"), "主仓库的源码丢了")
        XCTAssertFalse(map.contains("StaleCopy"),
                       "把 agent 工作区里的过期副本也列进地图了")
    }

    /// 声明名提取：修饰词吃干净，`class func` 不能被当成类声明。
    func testDeclaredName() {
        XCTAssertEqual(RepoMap.declaredName("public struct Foo: Codable {"), "Foo")
        XCTAssertEqual(RepoMap.declaredName("    static func bar(x: Int) {"), "bar")
        XCTAssertEqual(RepoMap.declaredName("public final class Baz {"), "Baz")
        // `class func` 是方法，名字该取 func 后面那个，不是 "func"
        XCTAssertEqual(RepoMap.declaredName("class func shared() -> Self {"), "shared")
        XCTAssertNil(RepoMap.declaredName("let x = 1"))
        XCTAssertNil(RepoMap.declaredName("// struct NotReal {"))
    }
}
