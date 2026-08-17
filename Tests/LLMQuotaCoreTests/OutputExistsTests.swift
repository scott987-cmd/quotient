import XCTest
@testable import LLMQuotaCore

/// 产出已存在：这一步要造的东西已经在了。
///
/// 老板的问题：「为啥已经在了任务却还要重复执行？问题原因在哪里？」
///
/// 实况：Greed 两条图的五个步骤冻着等上游，而它们要做的事（BGM 接玩法阶段、
/// SettingsView、根视图设置入口、两个持久化开关）**全都已经在 main 上了**，
/// 连 UserDefaults 的 key 名都和任务描述一字不差。
///
/// 根因三层，见 `OutputExists` 的文档注释。这个文件守的是判据边界 ——
/// 尤其是**验收类任务绝不能跳**，那条判错等于永远不验收。
final class OutputExistsTests: XCTestCase {

    private var repo: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outex-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repo = dir.path
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@t"]); git(["config", "user.name", "t"])
        write("README.md", "hi\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "init"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: repo)
        super.tearDown()
    }

    private func git(_ a: [String]) { _ = GitWorkspace.git(a, in: repo) }
    private func write(_ n: String, _ s: String) {
        let u = URL(fileURLWithPath: repo).appendingPathComponent(n)
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }

    /// 声明的产出已经在 → 跳过。这就是那五个步骤的处境。
    func testDeclaredOutputAlreadyPresentIsSkipped() {
        write("Sources/Greed/Shell/SettingsView.swift", "struct SettingsView {}\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "已经有了"])

        let p = "新增 SettingsView 设置页。产出：`Sources/Greed/Shell/SettingsView.swift`"
        let r = OutputExists.check(prompt: p, repo: repo)
        guard case .alreadyDone(let paths) = r else {
            return XCTFail("该判成已完成，判成了 \(r)")
        }
        XCTAssertEqual(paths, ["Sources/Greed/Shell/SettingsView.swift"])
    }

    /// **验收类任务绝不能跳。**
    ///
    /// 「模拟器实跑验收」「端到端取证出报告」的前提就是东西都已经在了 ——
    /// 它要干的事是跑起来看对不对。按「产出已存在」跳掉它们，
    /// 等于永远不验收，而那恰恰是唯一能证明这些改动真的能用的环节。
    func testAcceptanceTasksAreNeverSkipped() {
        write("Sources/Greed/Shell/SettingsView.swift", "x\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "有了"])

        let prompts = [
            "模拟器实跑验收：实听无声 + 重开保持。产出：`Sources/Greed/Shell/SettingsView.swift`",
            "端到端验收：杀进程续档 + 暂停退出 + 音频代码取证，出报告",
            "【评审·合入】分支 agent/a/x 能不能合",
            "【证据】把分支跑起来截图",
            "【刷新】把 main 合进分支",
        ]
        for p in prompts {
            XCTAssertEqual(OutputExists.check(prompt: p, repo: repo), .shouldRun,
                           "验收/审查类不能跳：\(p.prefix(20))")
        }
    }

    /// **产出只到了一半就照旧跑。**
    ///
    /// 半成品状态下跳过等于把活扔在半路 —— 外面看起来「已完成」，
    /// 实际少一半，而且没人会再回来做。
    func testPartialOutputStillRuns() {
        write("A.swift", "x\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "只有一个"])
        let p = "新建 `A.swift` 和 新建 `B.swift`"
        XCTAssertEqual(OutputExists.check(prompt: p, repo: repo), .shouldRun,
                       "少一个就得跑，不能扔在半路")
    }

    /// 没声明产出的任务不判 —— 大量任务是改现有代码，没有「新建」。
    func testNoDeclaredOutputMeansRun() {
        XCTAssertEqual(
            OutputExists.check(prompt: "把翻牌改成两段式", repo: repo), .shouldRun)
        XCTAssertTrue(OutputExists.declaredOutputs(in: "改一下手感").isEmpty)
    }

    /// 摘产出路径认几种真实写法。
    func testDeclaredOutputForms() {
        let cases = [
            "产出：`Maw/BackgroundNode.swift`",
            "本步新建 `Maw/BackgroundNode.swift`",
            "新增 `Maw/BackgroundNode.swift`",
            "创建 `Maw/BackgroundNode.swift`",
        ]
        for c in cases {
            XCTAssertEqual(OutputExists.declaredOutputs(in: c),
                           ["Maw/BackgroundNode.swift"], "认不出：\(c)")
        }
    }

    /// 符号名不是路径 —— 「新增 `didMove(to:)`」不该拿去当文件核。
    func testSymbolsAreNotOutputPaths() {
        XCTAssertTrue(
            OutputExists.declaredOutputs(in: "新增 `didMove(to:)` 的实现").isEmpty)
    }

    /// 说明要写出「可能是谁做的」—— 人看到跳过时得知道去哪儿找那个产出。
    func testDescriptionExplainsWhereItCameFrom() {
        let d = OutputExists.describe(.alreadyDone(paths: ["A.swift"]))
        XCTAssertTrue(d.contains("人工") && d.contains("上游"),
                      "要列出可能的来源，否则人会以为是误判：\(d)")
    }
}
