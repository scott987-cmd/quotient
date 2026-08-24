import XCTest
@testable import LLMQuotaCore

/// 基线新鲜度：main 上没有的东西，不代表它不存在。
///
/// 这条是回放真实数据倒逼出来的：先做了 `PremiseCheck`（核任务自己写出来的
/// 前置事实），拿历史回放发现 17 个「基线错了 / 过时」的丢弃里只有 1 个带
/// 显式前置段落 —— 那个机制当初只能挡 1/17。剩下 16 个是**隐含**假设
/// 「今天的成果在 main 上」，只有这条能挡。
///
/// 老板的丢弃理由（完整版）：
/// > 基线错了：从 main 开工，而 main 上没有任何今天的游戏改动
/// >（…**28 个提交全在 agent/volcark/9932ef49 上未合**）。
/// > 首条提交已写「现状基线：无猎物系统」，照这个做等于重造一遍。
final class BaselineFreshnessTests: XCTestCase {

    private var repo: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-\(UUID().uuidString.prefix(8))")
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

    private func doneTask(_ id: String) -> WorkTask {
        var t = WorkTask(id: id, prompt: "干活", repo: repo)
        t.state = .done
        t.platform = .kimi
        return t
    }

    /// 干净的仓库：可以派。
    func testCleanRepoIsFresh() {
        XCTAssertEqual(BaselineFreshness.check(repo: repo, tasks: []), .fresh)
    }

    /// **有实质性成果没合 → 不派。** 这是 volcark/9932ef49 那一幕。
    func testSubstantialUnmergedWorkMakesBaselineStale() {
        git(["checkout", "-q", "-b", "agent/kimi/aaa11111"])
        for i in 0..<4 { write("Src/F\(i).swift", "class F\(i) {}\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "野生物系统"])
        git(["checkout", "-q", "main"])

        let r = BaselineFreshness.check(repo: repo, tasks: [doneTask("aaa11111")])
        guard case .stale(let branches, let files) = r else {
            return XCTFail("该判成基线不新鲜，判成了 \(r)")
        }
        XCTAssertEqual(branches, ["agent/kimi/aaa11111"])
        XCTAssertEqual(files, 4)
    }

    /// 一个文件的分支不算「实质性成果」。
    ///
    /// main 少一份评审报告，不影响任何人对代码现状的判断。
    /// 算进来的话，每次评审都会把整个仓库的派活冻住一轮。
    func testTinyBranchDoesNotBlockDispatch() {
        git(["checkout", "-q", "-b", "agent/minimax/bbb22222"])
        write("reviews/EVAL-项目-abc.md", "报告\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "评审报告"])
        git(["checkout", "-q", "main"])

        XCTAssertEqual(
            BaselineFreshness.check(repo: repo, tasks: [doneTask("bbb22222")]),
            .fresh, "一份评审报告不该把整个仓库的派活冻住")
    }

    /// **合不进去的分支不能挡新活 —— 否则整个仓库冻死。**
    ///
    /// 真冲突、被评审否决、记录已丢的分支可能**永远**进不来。
    /// 拿它们当「马上要落地的成果」去等，就是无限期停工。
    /// 这类分支各有各的处置路径（StaleBranch 刷新、MergeReview 出结论），
    /// 不该在这里再堵一次。
    func testConflictingBranchDoesNotFreezeTheRepoForever() {
        git(["checkout", "-q", "-b", "agent/kimi/ccc33333"])
        for i in 0..<4 { write("Shared\(i).swift", "branch\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "分支改动"])
        git(["checkout", "-q", "main"])
        // main 改同样的文件 → 真冲突
        for i in 0..<4 { write("Shared\(i).swift", "main\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "main 也改了"])

        XCTAssertEqual(
            BaselineFreshness.check(repo: repo, tasks: [doneTask("ccc33333")]),
            .fresh,
            "合不进去的分支不能无限期挡住新活 —— 那是把仓库冻死，不是保护它")
    }

    /// 视觉验收已经判退的分支不是“马上要落地的成果”。整改任务必须能开工，
    /// 否则分支等整改、整改等分支落地，整个仓库形成死锁。
    func testVisualQualityRejectedBranchDoesNotBlockRemediation() {
        let branch = "agent/kimi/ddd44444"
        git(["checkout", "-q", "-b", branch])
        for i in 0..<4 { write("Render/F\(i).swift", "class F\(i) {}\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "待视觉验收成果"])
        let head = GitWorkspace.git(["rev-parse", "--short", "HEAD"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        git(["checkout", "-q", "main"])

        var visual = WorkTask(
            id: "visual", prompt: VisualQualityGate.marker(branch: branch, head: head),
            repo: repo)
        visual.state = .done
        visual.outputs = ["**结论**：未达标\n存在穿模和悬空"]

        XCTAssertEqual(
            BaselineFreshness.check(repo: repo, tasks: [doneTask("ddd44444"), visual]),
            .fresh,
            "视觉验收判退后必须允许整改任务启动，不能继续把仓库当成基线待合")
    }

    /// 说明必须写出「为什么不能先干」。
    ///
    /// 只说「基线不新鲜」，以后改这段代码的人会以为这是个可以放宽的
    /// 保守限制，顺手删掉 —— 而它挡住的是最贵的一种浪费。
    func testDescriptionExplainsTheRealCost() {
        let d = BaselineFreshness.describe(
            .stale(branches: ["agent/volcark/9932ef49"], files: 28))
        XCTAssertTrue(d.contains("重造一遍"),
                      "得说清后果是「把已经做好的东西重造一遍」")
        XCTAssertTrue(d.contains("agent/volcark/9932ef49"), "得说出在等哪条")
        XCTAssertTrue(d.contains("28"), "得说出差多少")
    }
}
