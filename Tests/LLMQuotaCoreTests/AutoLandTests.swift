import XCTest
@testable import LLMQuotaCore

/// 自动落地（Review.autoLand）的边界。
///
/// 它解决的问题：auto 模式「自动干活」却不「自动交付」——
/// agent 干完的产出全部堆在待审名单里等人敲 `work review`。
/// 但**放宽的只能是「谁来按回车」**，五个安全条件一条都不能松：
/// 任务 done / 非高危 / 干净合入 / 不与其他待审分支重叠 / 不碰敏感路径。
/// 这个文件逐条验它们真的在拦。
final class AutoLandTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoland-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox

        repo = sandbox.appendingPathComponent("repo").path
        try? FileManager.default.createDirectory(
            atPath: repo, withIntermediateDirectories: true)
        git(["init", "--initial-branch=main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        write("README.md", "hello")
        git(["add", "."]); git(["commit", "-m", "init"])
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    @discardableResult
    private func git(_ args: [String]) -> Proc.Result {
        GitWorkspace.git(args, in: repo)
    }

    private func write(_ name: String, _ content: String) {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.data(using: .utf8)!.write(to: url)
    }

    /// 建一条 agent 产出分支：改一个文件、提交、切回 main。
    /// 命名遵守真实约定 `agent/<平台>/<任务id>` —— taskID 从第三段解析。
    private func makeBranch(_ taskID: String, file: String = "Feature.swift") {
        git(["checkout", "-b", "agent/qwen/\(taskID)"])
        write(file, "// \(taskID)\n")
        git(["add", "."]); git(["commit", "-m", "\(taskID) 产出"])
        git(["checkout", "main"])
    }

    private func doneTask(_ id: String, risk: TaskProfile.Risk = .normal,
                          state: WorkTask.State = .done) -> WorkTask {
        var t = WorkTask(id: id, prompt: "加个功能", repo: repo)
        t.state = state
        t.profile = TaskProfile(
            tier: .standard, risk: risk, estimatedMinutes: 5,
            isSelfContained: true, rationale: "测试")
        return t
    }

    /// 主场景：done、安全、无冲突 → 自动合入 main，分支删掉。
    func testSafeDoneBranchLands() {
        makeBranch("t1")
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t1")])
        XCTAssertEqual(out.count, 1, "\(out)")
        XCTAssertTrue(out.first?.landed == true, out.first?.note ?? "没有任何结果")
        let log = git(["log", "--oneline", "main"]).stdout
        XCTAssertTrue(log.contains("t1 产出"), "合并后 main 里必须有产出提交：\(log)")
        XCTAssertFalse(GitWorkspace.git(["branch", "--list", "agent/qwen/t1"], in: repo)
            .stdout.contains("agent/qwen/t1"), "落地后分支该清掉")
    }

    /// 高危产出不自动合 —— 高危本来就该人看。
    func testSensitiveTaskIsLeftForHumans() {
        makeBranch("t2")
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t2", risk: .sensitive)])
        XCTAssertTrue(out.isEmpty, "\(out)")
        XCTAssertTrue(GitWorkspace.git(["branch", "--list", "agent/qwen/t2"], in: repo)
            .stdout.contains("agent/qwen/t2"), "高危分支必须原样留着")
    }

    /// 任务不是 done（failed/running）→ 产出不合。
    func testUnfinishedTaskDoesNotLand() {
        makeBranch("t3")
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t3", state: .failed)])
        XCTAssertTrue(out.isEmpty, "failed 任务的产出不该被自动合入：\(out)")
    }

    /// 改动碰了敏感路径（CI、构建脚本那批）→ 留给人。
    func testRiskyPathStaysManual() {
        makeBranch("t4", file: ".github/workflows/ci.yml")
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t4")])
        XCTAssertTrue(out.isEmpty, "碰 .github/ 的产出必须人工审：\(out)")
    }

    /// 两条待审分支改同一个文件 → 都不自动合（顺序该人定）。
    func testOverlappingBranchesStayManual() {
        makeBranch("t5", file: "Shared.swift")
        makeBranch("t6", file: "Shared.swift")
        let out = Review.autoLand(repo: repo,
                                  tasks: [doneTask("t5"), doneTask("t6")])
        XCTAssertTrue(out.isEmpty, "重叠分支单看都能干净合入，但合完第一个第二个就冲突：\(out)")
    }

    /// 进过否决名单（上次验收失败）的分支不再自动重试。
    func testVetoedBranchIsSkipped() {
        makeBranch("t7")
        Review.setAutoLandVeto(branch: "agent/qwen/t7", note: "上次验收失败")
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t7")])
        XCTAssertTrue(out.isEmpty, "否决过的分支每轮重验会白烧全量构建：\(out)")
    }

    /// 一轮限流：两条独立可合分支，maxPerCall=1 只吃一条。
    func testOnePerRound() {
        makeBranch("t8", file: "A.swift")
        makeBranch("t9", file: "B.swift")
        let out = Review.autoLand(repo: repo,
                                  tasks: [doneTask("t8"), doneTask("t9")],
                                  maxPerCall: 1)
        XCTAssertEqual(out.count, 1, "每轮最多合一个，验收贵：\(out)")
        XCTAssertTrue(out.first?.landed == true)
    }

    /// 主仓库有未提交改动 → 整轮跳过，且**不记否决**。
    /// 环境脏是人的状态，不是分支的错；否决记上就再也不自动重试了。
    func testDirtyRepoSkipsRoundWithoutVeto() {
        makeBranch("t10")
        write("WIP.swift", "// 人改到一半\n")   // 未提交
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t10")])
        XCTAssertTrue(out.isEmpty, "脏仓库这一轮什么都不该做：\(out)")
        XCTAssertNil(Review.autoLandVeto()["agent/qwen/t10"],
                     "环境问题不能给分支记否决")
        // 收拾干净后同一条分支要能正常落地。
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: repo).appendingPathComponent("WIP.swift"))
        let retry = Review.autoLand(repo: repo, tasks: [doneTask("t10")])
        XCTAssertTrue(retry.first?.landed == true, "\(retry)")
    }

    /// 开关默认是关的 —— 授权必须显式给。
    func testSwitchDefaultsToOff() {
        XCTAssertFalse(Review.autoLandEnabled())
        Review.setAutoLand(enabled: true)
        XCTAssertTrue(Review.autoLandEnabled())
        Review.setAutoLand(enabled: false)
        XCTAssertFalse(Review.autoLandEnabled())
    }
}

/// 落地即排审查：每次合并自动生成【审查】任务；审查/媒体产出落地不再生成。
extension AutoLandTests {
    func testLandingEnqueuesReviewTask() {
        makeBranch("t20")
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t20")])
        XCTAssertTrue(out.first?.landed == true, "\(out)")
        let reviews = TaskStore.all().filter { $0.prompt.hasPrefix("【审查】") }
        XCTAssertEqual(reviews.count, 1, "落地一单必须排一条审查")
        XCTAssertEqual(reviews.first?.profile?.risk, .safe, "审查是 safe 档的活")
        XCTAssertEqual(reviews.first?.preferredPlatform, .volcark,
                       "审查点名给审查员（opencode/火山）")
    }

    /// 审查产出自己落地时不再生成审查 —— 否则审查→落地→审查无限循环。
    func testReviewLandingDoesNotRecurse() {
        makeBranch("t21", file: "reviews/REVIEW-abc.md")
        var t = doneTask("t21")
        t.prompt = "【审查】复查合并 abc……"
        try? TaskStore.append(t)
        let out = Review.autoLand(repo: repo, tasks: [t])
        XCTAssertTrue(out.first?.landed == true, "\(out)")
        let reviews = TaskStore.all().filter {
            $0.prompt.hasPrefix("【审查】") && $0.id != "t21"
        }
        XCTAssertTrue(reviews.isEmpty, "审查落地不能再生审查：\(reviews.map(\.id))")
    }
}

/// 登记为「必须人工终审」的仓库（游戏）整个绕过自动落地。
extension AutoLandTests {
    func testManualReviewRepoNeverAutoLands() {
        makeBranch("t30")
        var entry = RepoAlias(alias: "game", path: repo)
        entry.manualReview = true
        try? RepoRegistry.save([entry])
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t30")])
        XCTAssertTrue(out.isEmpty, "游戏仓库构建通过≠可合入，必须终审：\(out)")
        XCTAssertTrue(GitWorkspace.git(["branch", "--list", "agent/qwen/t30"], in: repo)
            .stdout.contains("t30"), "分支必须原样留给终审")
    }
}
