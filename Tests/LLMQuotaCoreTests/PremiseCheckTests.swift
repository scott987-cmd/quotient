import XCTest
@testable import LLMQuotaCore

/// 派活前核前提。
///
/// 对应的真实浪费（老板手写的丢弃理由，70 个未派任务）：
/// 13 个「基线错了：从 main 开工，而 main 上没有任何今天的改动」
/// + 3 个「过时：前提不在了」。
///
/// 这个文件的核心是**「等」和「废」不能判反**，两个方向的代价不对称：
/// - 该等的判成废 → 丢掉好任务，而它只是**派早了**；
/// - 该废的判成等 → 永远等一个不会到来的前提，队列里多一个僵尸。
final class PremiseCheckTests: XCTestCase {

    private var repo: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("premise-\(UUID().uuidString.prefix(8))")
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

    // MARK: 摘路径

    /// 只认前置段落里的路径。
    ///
    /// **不切段的后果**：提示词经常写「本步要新建 `Foo.swift`」——
    /// 那个文件本来就不该存在，拿它去核会把每个新建任务都判成前提不成立，
    /// 于是整个队列被自动作废清空。
    func testOnlyPremiseSectionPathsAreChecked() {
        let p = """
        仓库 Maw（SpriteKit）。本步新增一个自包含的背景节点类。

        前置事实（已完成，直接用）：
        - `Maw/Resources/Backgrounds/zone-shallow.png` 已进包

        产出：新建 `Maw/BackgroundNode.swift`
        """
        let got = PremiseCheck.premisePaths(in: p)
        XCTAssertEqual(got, ["Maw/Resources/Backgrounds/zone-shallow.png"],
                       "要新建的文件不该被当成前提，否则新建类任务全会被作废")
    }

    /// 符号名不是路径。
    ///
    /// 实测提示词里大量出现「已有 `didMove(to:)`」。拿它当文件核，
    /// 每次都判不存在 —— 又是一条把好任务全废掉的路。
    func testSymbolsAreNotTreatedAsPaths() {
        let p = "前置事实：`Maw/GameScene.swift`：已有 `didMove(to:)` 和 `setupBackground()`"
        XCTAssertEqual(PremiseCheck.premisePaths(in: p), ["Maw/GameScene.swift"])
    }

    /// 没写前置的任务不核 —— 宁可不核，不能瞎核。
    func testNoPremiseSectionMeansNoCheck() {
        XCTAssertTrue(PremiseCheck.premisePaths(in: "随便改点什么").isEmpty)
        XCTAssertEqual(PremiseCheck.check(prompt: "随便改点什么", repo: repo), .ok)
    }

    // MARK: 等 vs 废 —— 这一组是本模块的核心

    /// 前提在 main 上就有 → 直接放行。
    func testPresentOnMainIsOK() {
        write("Maw/Tuning.swift", "x\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "add tuning"])
        let p = "前置事实：`Maw/Tuning.swift` 是唯一可调数值去处"
        XCTAssertEqual(PremiseCheck.check(prompt: p, repo: repo), .ok)
    }

    /// **在未合的 agent 分支上有 → 该等，不该废。**
    ///
    /// 这就是那 13 个「基线错了」的真相：它们不是坏任务，是**派早了**。
    /// 判成废就等于把上游 agent 刚做好、还没合的成果当成不存在。
    func testPresentOnlyOnUnmergedBranchMeansWait() {
        git(["checkout", "-q", "-b", "agent/kimi/abc123"])
        write("Maw/PlayerNode.swift", "class PlayerNode {}\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "新增玩家节点"])
        git(["checkout", "-q", "main"])

        let p = "前置事实（已完成，直接用）：`Maw/PlayerNode.swift` 已写好"
        let r = PremiseCheck.check(prompt: p, repo: repo)
        guard case .notYet(let missing, let branches) = r else {
            return XCTFail("该判成「等」，判成了 \(r)")
        }
        XCTAssertEqual(missing, ["Maw/PlayerNode.swift"])
        XCTAssertEqual(branches, ["agent/kimi/abc123"],
                       "要说出在哪条分支上 —— 人才知道在等什么")
    }

    /// **到处都找不到 → 该废。**
    ///
    /// 对应那三个「build-app.sh 已大改，这条任务的前提不在了」。
    /// 判成等的话，队列里就多一个永远不会就绪的僵尸。
    func testMissingEverywhereMeansGone() {
        let p = "前置事实：`Maw/NeverExisted.swift` 已经写好了"
        let r = PremiseCheck.check(prompt: p, repo: repo)
        guard case .gone(let missing) = r else {
            return XCTFail("该判成「废」，判成了 \(r)")
        }
        XCTAssertEqual(missing, ["Maw/NeverExisted.swift"])
    }

    /// 目录形式的前提也要能核。
    func testDirectoryPremise() {
        write("Maw/Resources/Creatures/creature-s1.png", "x\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "assets"])
        let p = "前置事实：`Maw/Resources/Creatures/` 下已有素材"
        XCTAssertEqual(PremiseCheck.check(prompt: p, repo: repo), .ok)
    }

    /// 说明文字要能让人一眼看懂在等什么 / 为什么废。
    func testDescriptionsAreActionable() {
        let wait = PremiseCheck.describe(
            .notYet(missing: ["A.swift"], onBranches: ["agent/kimi/x"]))
        XCTAssertTrue(wait.contains("agent/kimi/x"), "要说出在等哪条分支")
        XCTAssertTrue(wait.contains("等它落地"))

        let gone = PremiseCheck.describe(.gone(missing: ["B.swift"]))
        XCTAssertTrue(gone.contains("都找不到"), "要说清是「到处都没有」而不是「还没到」")
    }
}
