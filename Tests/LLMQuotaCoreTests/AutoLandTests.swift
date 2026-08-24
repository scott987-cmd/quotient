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

    /// 两条待审分支改同一个文件 → **排队合，一轮放行一条**，不是都不合。
    ///
    /// 这条原来断言 `out.isEmpty`，理由写的是「顺序该人定」。但没有任何环节
    /// 会去问人，实际后果是一条都不合：2026-08-17 盘点 Maw，三条实质分支
    /// 两两都动了 GameScene/PlayerNode/Tuning，互相卡住躺了两天，
    /// 否决名单还是空的 —— 它们根本没被**尝试**过。
    ///
    /// 现在放行最老的那条。第二条下一轮对着新 main 重新判定：
    /// 要么还能干净合入，要么 mergesCleanly 变 false，那才是真冲突、才给人。
    /// 一轮只合一条这个保护还在（见 testOnePerRound），
    /// 所以不会出现「一口气把一组重叠全合了」。
    func testOverlappingBranchesLandOneAtATime() {
        makeBranch("t5", file: "Shared.swift")
        makeBranch("t6", file: "Shared.swift")
        let out = Review.autoLand(repo: repo,
                                  tasks: [doneTask("t5"), doneTask("t6")])
        XCTAssertEqual(out.count, 1,
                       "一组重叠里必须恰好合一条 —— 0 条是死锁，2 条是抢着合：\(out)")
        XCTAssertTrue(out.first?.landed == true, "放行的那条该真的合进去了：\(out)")
    }

    /// 进过否决名单（上次验收失败）的分支，**同一版**不再自动重试。
    func testVetoedBranchIsSkipped() {
        makeBranch("t7")
        let head = git(["rev-parse", "--short", "agent/qwen/t7"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Review.setAutoLandVeto(branch: "agent/qwen/t7",
                               note: "上次验收失败", head: head)
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t7")])
        XCTAssertTrue(out.isEmpty, "否决过的提交每轮重验会白烧全量构建：\(out)")
    }

    /// **被否 → 改好 → 要能重新验收。** 这是否决绑提交的全部意义。
    ///
    /// 审核结论那层（VerdictScopeTests）当天已经改成绑提交，但这层否决
    /// 还绑分支名的话，同一条闭环走到落地这步照样被按名字扣住 ——
    /// **两层只修一层等于没修**。这条测试钉的就是整条闭环的下半截。
    func testVetoExpiresAfterNewCommitAndBranchLands() {
        makeBranch("t7b")
        let oldHead = git(["rev-parse", "--short", "agent/qwen/t7b"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Review.setAutoLandVeto(branch: "agent/qwen/t7b",
                               note: "验收失败：测试红了", head: oldHead)
        // 修复提交 —— 回应否决的那种
        git(["checkout", "agent/qwen/t7b"])
        write("Feature.swift", "// t7b 修好了\n")
        git(["add", "."]); git(["commit", "-m", "t7b 修复"])
        git(["checkout", "main"])
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t7b")])
        XCTAssertEqual(out.count, 1,
                       "否决是给旧提交的；新提交要能重进验收，"
                       + "否则唯一出路是人工清否决名单：\(out)")
        XCTAssertTrue(out.first?.landed == true, out.first?.note ?? "")
    }

    /// 老格式否决（没记提交）保持粘性 —— 升级本身不放行任何东西。
    func testLegacyVetoWithoutHeadStaysSticky() {
        makeBranch("t7c")
        Review.setAutoLandVeto(branch: "agent/qwen/t7c",
                               note: "老格式否决", head: "")
        git(["checkout", "agent/qwen/t7c"])
        write("Feature.swift", "// 又提交了\n")
        git(["add", "."]); git(["commit", "-m", "t7c 新提交"])
        git(["checkout", "main"])
        let out = Review.autoLand(repo: repo, tasks: [doneTask("t7c")])
        XCTAssertTrue(out.isEmpty,
                      "head 未知的否决不知道该对哪一版过期 —— 只能留给人：\(out)")
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

    func testQualityContractDispatchesVisualGateBeforeLanding() {
        git(["checkout", "-b", "agent/qwen/t31"])
        write("Feature.swift", "// visible behavior\n")
        write("docs/evidence/t31-playtest.mov", "fake-video-bytes")
        git(["add", "."]); git(["commit", "-m", "t31 视觉改动与证据"])
        git(["checkout", "main"])

        var entry = RepoAlias(alias: "game", path: repo)
        entry.qualityContract = "QUALITY.md"
        try? RepoRegistry.save([entry])
        let task = doneTask("t31")
        let out = Review.autoLand(repo: repo, tasks: [task])

        XCTAssertTrue(out.isEmpty, "没经过多模态逐帧验收前不能自动落地：\(out)")
        XCTAssertTrue(GitWorkspace.git(
            ["branch", "--list", "agent/qwen/t31"], in: repo).stdout.contains("t31"))
        let visual = TaskStore.all().first { $0.origin == "visual-quality-review" }
        XCTAssertNotNil(visual, "质量契约必须真的派出视觉验收，不能只留一句提示词；"
            + "诊断=\(Review.whyNotLanding(repo: repo, tasks: [task]).map(\.reason)) "
            + "任务=\(TaskStore.all().map { ($0.origin ?? "nil") + ":" + $0.prompt.prefix(20) })")
        XCTAssertEqual(visual?.preferredPlatform, .minimax)
        XCTAssertTrue(visual?.prompt.contains("agent/qwen/t31") == true)
    }
}
