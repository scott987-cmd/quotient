import XCTest
@testable import LLMQuotaCore

/// **一个任务在一个 agent 内闭环；每个 agent 都知道自己在给什么产品干活。**
///
/// 老板（2026-08-20）的两条原话：
/// -「尽量让一个任务在一个 agent 内完成工作，agent 之间尽量少的信息传递」
/// -「项目的设计和产品文档如何避免后期频繁的改变，或者让不同的 agent
///   不知道自己在干啥」
///
/// 两条其实是同一个病：agent 之间每一次交接都是一条有损的文本通道，
/// 而产品意图不注入的话，每个 agent 都要临场重新猜一遍。
final class OneAgentOneTaskTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("oaot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        RepoRegistry.fileOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: 产品事实注入（AGENTS.md）

    func testBriefingCarriesTheProductFacts() throws {
        try "# 产品事实\n对外名字是 Longlong,绝不能叫 Dragon Tales。"
            .write(to: tmp.appendingPathComponent("AGENTS.md"),
                   atomically: true, encoding: .utf8)
        let b = ProductBrief.briefing(repo: tmp.path)
        XCTAssertTrue(b.contains("绝不能叫 Dragon Tales"), "铁律要原样进提示词")
        XCTAssertTrue(b.contains("不是任务"),
                      "必须声明这是约束不是任务 —— RepoMap 试过：不声明的话，"
                      + "agent 会把背景材料当成要执行的清单")
        XCTAssertTrue(b.contains("在产出里明说冲突"),
                      "任务和铁律打架时要出声，不能不吭声地二选一")
    }

    /// 没有 AGENTS.md 的仓库一个字都不注入 —— 别造一段空框架浪费上下文。
    func testNoFactsFileMeansNoBriefing() {
        XCTAssertEqual(ProductBrief.briefing(repo: tmp.path), "")
    }

    /// 写飞的文档要截断并提醒 —— 产品事实该是一页纸，
    /// 不能让它吃掉任务本身的上下文。
    func testOversizedFactsAreTruncated() throws {
        try String(repeating: "废话 ", count: 5_000)
            .write(to: tmp.appendingPathComponent("AGENTS.md"),
                   atomically: true, encoding: .utf8)
        let t = ProductBrief.text(repo: tmp.path)!
        XCTAssertLessThan(t.count, ProductBrief.maxCharacters + 200)
        XCTAssertTrue(t.contains("截断"), "截断要明说，别让人以为读到的是全文")
    }

    func testConfiguredQualityContractIsInjectedAsAcceptanceStandard() throws {
        try "# 质量契约\n持枪时双手必须真实接触武器，不能穿模。"
            .write(to: tmp.appendingPathComponent("QUALITY.md"),
                   atomically: true, encoding: .utf8)
        let f = tmp.appendingPathComponent("repos.json")
        let entry: [String: Any] = [
            "alias": "flint", "path": tmp.path,
            "pathByMachine": [Paths.machineName(): tmp.path],
            "qualityContract": "QUALITY.md",
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: f)
        RepoRegistry.fileOverride = f

        let b = ProductBrief.briefing(repo: tmp.path, registeredRepo: tmp.path)
        XCTAssertTrue(b.contains("双手必须真实接触武器"))
        XCTAssertTrue(b.contains("验收标准，不是参考建议"))
        XCTAssertTrue(b.contains("构建通过只证明代码能跑"))
    }

    func testQualityContractFallsBackToRegisteredRepoBeforeStableWorktreeHasIt() throws {
        let worktree = tmp.appendingPathComponent("stable-worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "# 首轮质量契约\n必须交实机录屏。"
            .write(to: tmp.appendingPathComponent("QUALITY.md"),
                   atomically: true, encoding: .utf8)
        let f = tmp.appendingPathComponent("repos.json")
        let entry: [String: Any] = [
            "alias": "flint", "path": tmp.path,
            "pathByMachine": [Paths.machineName(): tmp.path],
            "qualityContract": "QUALITY.md",
        ]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: f)
        RepoRegistry.fileOverride = f

        let b = ProductBrief.briefing(repo: worktree.path, registeredRepo: tmp.path)
        XCTAssertTrue(b.contains("必须交实机录屏"),
                      "新登记的契约尚未进入稳定 worktree 时也不能漏注入")
    }

    // MARK: 证据条款（事前，同一个 agent 闭环）

    private func registry(manualReview: Bool) throws {
        let f = tmp.appendingPathComponent("repos.json")
        let entry: [String: Any] = [
            "alias": "t", "path": tmp.path, "isDefault": true,
            "pathByMachine": [Paths.machineName(): tmp.path],
            "manualReview": manualReview,
        ]
        let d = try JSONSerialization.data(withJSONObject: [entry])
        try d.write(to: f)
        RepoRegistry.fileOverride = f
    }

    func testCodingTaskInManualReviewRepoGetsTheClause() throws {
        try registry(manualReview: true)
        let c = EvidenceGate.inlineClause(repoPath: tmp.path, prompt: "把主角的跳跃手感调轻一点")
        XCTAssertTrue(c.contains("docs/evidence/"),
                      "干活的 agent 要在同一次执行里自己交证据 —— "
                      + "否则得再派一个对改动一无所知的 agent 从零认路")
        XCTAssertTrue(c.contains("只**碰了测试或文档") || c.contains("只碰了测试或文档")
                      || c.contains("**只**碰了测试或文档"),
                      "豁免要写明，条件必须和落地闸一致（测试/文档不用截图）：\(c.prefix(200))")
    }

    /// 评审 / 媒体 / 证据 / 刷新任务不加条款 —— 各有各的产出形态。
    func testNonCodingTasksGetNoClause() throws {
        try registry(manualReview: true)
        for p in ["【审查·合入】分支 x 的改动能不能合进 main。",
                  "【媒体】生成宣传图\nIMG a.png :: 图",
                  "【证据】把分支 x 的改动跑起来",
                  "【刷新】把分支 x 对齐 main"] {
            XCTAssertEqual(EvidenceGate.inlineClause(repoPath: tmp.path, prompt: p), "",
                           "这类任务不该被要求截图：\(p.prefix(20))")
        }
    }

    /// 不要证据的仓库不加条款 —— 条款和闸门的条件必须一致，
    /// 否则「条款要了、闸门不收」，agent 白干。
    func testPlainRepoGetsNoClause() throws {
        try registry(manualReview: false)
        XCTAssertEqual(EvidenceGate.inlineClause(repoPath: tmp.path,
                                                 prompt: "改个功能"), "")
    }

    /// **事前条款和事后补课必须说同一套「什么算证据」。**
    /// 两处各写一份的话，迟早 agent 按 A 标准交、闸门按 B 标准收。
    func testCriteriaIsSharedBetweenClauseAndBackstop() throws {
        try registry(manualReview: true)
        let clause = EvidenceGate.inlineClause(repoPath: tmp.path, prompt: "改功能")
        let backstop = EvidenceGate.evidencePrompt(.init(
            branch: "agent/a/x", repo: tmp.path, platform: nil,
            files: [], subject: "改功能"))
        for line in ["静态图证明不了动画", "那证明编译器高兴", "证据必须是这次改动之后拍的"] {
            XCTAssertTrue(clause.contains(line), "条款里缺:\(line)")
            XCTAssertTrue(backstop.contains(line), "补课提示词里缺:\(line)")
        }
    }
}

/// **证据的「要」和「收」必须是同一套标准。**
///
/// 2026-08-20 当场兑现的漂移：条款（criteria）写着「改了命令行行为 →
/// 实跑输出」，DragonTales 的测试任务照办交了
/// `docs/evidence/asset-integrity-tests.log`（64 行真实输出）——
/// 落地闸的过滤器却只认图片，判「没有证据」，又派了一个补证据 agent
/// 去跑截图。条款按 A 标准要、闸门按 B 标准收。
final class EvidenceFileRecognitionTests: XCTestCase {

    func testRunOutputUnderEvidenceDirCounts() {
        XCTAssertTrue(EvidenceGate.isEvidenceFile("docs/evidence/asset-integrity-tests.log"),
                      "criteria 白纸黑字说实跑输出算证据 —— 收的时候不能不认")
        XCTAssertTrue(EvidenceGate.isEvidenceFile("docs/evidence/run-output.txt"))
    }

    /// 评审报告不算证据 —— 那是**评审的产出**，不是**改动的证据**。
    /// 混了的话每份 EVAL 报告都会给自己发证据豁免。
    func testReviewReportsDoNotCount() {
        XCTAssertFalse(EvidenceGate.isEvidenceFile("reviews/EVAL-合入-abc-def.md"))
        XCTAssertFalse(EvidenceGate.isEvidenceFile("reviews/notes.log"),
                       "文本证据只认 evidence 目录，reviews/ 下的不算")
    }

    func testVisualEvidenceStillWorksAsBefore() {
        XCTAssertTrue(EvidenceGate.isEvidenceFile("docs/evidence/home.png"))
        XCTAssertTrue(EvidenceGate.isEvidenceFile("shots/before-after.mov"))
        XCTAssertFalse(EvidenceGate.isEvidenceFile("Assets/hero.png"),
                       "随便一张美术资源不因为是图片就算证据")
    }

    /// pbxproj 是 xcodegen 的机器产物：加个测试文件它就变。
    /// 它不该触发「改了人看得见的东西 → 要截图」；
    /// 它的风险由 isRiskyPath 的 2 票审核单独看着，那道闸不动。
    func testMachineArtifactsAreNotVisibleBehavior() {
        XCTAssertFalse(EvidenceGate.changesVisibleBehavior(
            ["DragonTales.xcodeproj/project.pbxproj",
             "DragonTalesTests/AssetIntegrityTests.swift",
             "docs/evidence/run.log"]),
            "测试 + 工程文件 + 证据日志 —— 没有一样是人看得见的行为")
        XCTAssertTrue(GitWorkspace.isRiskyPath("DragonTales.xcodeproj/project.pbxproj"),
                      "豁免的只是「要不要截图」，2 票审核那道闸必须还在")
    }
}

extension EvidenceFileRecognitionTests {
    /// 媒体产物本身就是证据 —— 音频和图片同理。
    /// 实测:主题曲+立绘的分支被 .mp3 判成「看得见、没证据」,
    /// 系统给一首歌派了截图任务。
    func testAudioDeliverablesAreNotVisibleBehavior() {
        XCTAssertFalse(EvidenceGate.changesVisibleBehavior(
            ["docs/audio/theme-demo.mp3", "docs/artdirection/operator-yan.png"]),
            "给一首歌拍截图证明不了任何事")
        XCTAssertTrue(EvidenceGate.changesVisibleBehavior(["Flint/Sim/Audio.swift"]),
                      "音频**代码**照样算看得见 —— 豁免的只是媒体产物文件")
    }
}
