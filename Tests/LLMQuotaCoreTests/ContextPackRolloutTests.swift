import XCTest
@testable import LLMQuotaCore

/// Context Pack 发布保险丝（架构师决定）：默认影子模式，
/// 只有白名单里的已登记仓库才真正切换到新提示词。
final class ContextPackRolloutTests: XCTestCase {
    private var scratch: URL!
    private var appSupport: URL!
    private var repoA: URL!
    private var repoB: URL!
    private var registryFile: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rollout-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        appSupport = scratch.appendingPathComponent("support")
        Paths.appSupportOverride = appSupport
        CollaborationStore.directoryOverride = scratch.appendingPathComponent("collab")
        ContextTelemetry.fileOverride = scratch.appendingPathComponent("context-packs.jsonl")
        ContextPackRollout.fileOverride = scratch.appendingPathComponent("rollout.json")
        registryFile = scratch.appendingPathComponent("repos.json")
        RepoRegistry.fileOverride = registryFile

        repoA = makeRepo("repo-a")
        repoB = makeRepo("repo-b")
        register(alias: "alpha", path: repoA.path)
        register(alias: "beta", path: repoB.path)
    }

    override func tearDown() {
        RepoRegistry.fileOverride = nil
        ContextPackRollout.fileOverride = nil
        ContextTelemetry.fileOverride = nil
        CollaborationStore.directoryOverride = nil
        Paths.appSupportOverride = nil
        for repo in [repoA, repoB].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: repo)
        }
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: - 工具

    @discardableResult
    private func makeRepo(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name + "-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "# 产品 \(name)\n".write(to: dir.appendingPathComponent("AGENTS.md"),
                                       atomically: true, encoding: .utf8)
        // RepoRegistry.add 要求登记的是真 git 仓库。
        _ = GitWorkspace.git(["init", "-q"], in: dir.path)
        return dir
    }

    private func register(alias: String, path: String) {
        _ = try? RepoRegistry.add(alias: alias, path: path)
    }

    private func enable(_ aliases: [String]) {
        try? ContextPackRollout.save(.init(enabledAliases: aliases))
    }

    private func request(task t: WorkTask, budget: Int? = nil,
                         canReadFiles: Bool = true) -> ContextPackBuilder.Request {
        .init(task: t, allTasks: [t], events: [],
              runnerID: "claude.code", platform: .claude,
              canReadFiles: canReadFiles, workspacePath: t.repo,
              handoff: nil, resumedAnswer: nil, resumedAsk: nil,
              mayAsk: false, askFile: nil, tier: .standard,
              sessionAction: "fresh",
              budget: budget ?? ContextPackBuilder.defaultBudget)
    }

    private func refuserRequest(repo: URL) -> ContextPackBuilder.Request {
        // 一个必然触发新 pack 拒绝的场景：文本 Runner + 关键材料超预算。
        let reviewDir = repo.appendingPathComponent("docs/evidence")
        try? FileManager.default.createDirectory(at: reviewDir,
                                                 withIntermediateDirectories: true)
        var source = WorkTask(id: "t-refuse", prompt: "修复握枪动作", repo: repo.path)
        source.visualRemediationReviewID = "rev-x"
        var review = WorkTask(id: "rev-x",
                              prompt: "【看效果】分支 agent/x/s 提交 abc 的视觉质量。",
                              repo: repo.path)
        review.origin = "visual-quality-review"
        review.platform = .minimax
        review.state = .done
        review.outputs = ["**结论**：未达标", "报告：docs/evidence/r.md"]
        try? String(repeating: "画面证实手臂穿透枪身。", count: 700)
            .write(to: reviewDir.appendingPathComponent("r.md"),
                   atomically: true, encoding: .utf8)
        return .init(task: source, allTasks: [source, review], events: [],
                     runnerID: "minimax.text", platform: .minimax,
                     canReadFiles: false, workspacePath: repo.path,
                     handoff: nil, resumedAnswer: nil, resumedAsk: nil,
                     mayAsk: false, askFile: nil, tier: .standard,
                     sessionAction: "fresh", budget: 3_000)
    }

    private func legacyMarker() -> String { "LEGACY-MARKER-" + UUID().uuidString }

    // MARK: - 默认与隔离

    func testEverythingDefaultsToShadowWithoutAnyConfiguration() {
        XCTAssertFalse(ContextPackRollout.isActive(repo: repoA.path),
            "没有配置文件时必须是影子模式")
        XCTAssertFalse(ContextPackRollout.isActive(repo: repoB.path))
        XCTAssertFalse(ContextPackRollout.isActive(repo: "/tmp/not-even-a-repo"),
            "未登记仓库必须 fail-closed 为影子")
    }

    func testEnablingOneAliasLeavesOtherReposInShadow() throws {
        enable(["alpha"])
        XCTAssertTrue(ContextPackRollout.isActive(repo: repoA.path), "白名单内的仓库应启用")
        XCTAssertFalse(ContextPackRollout.isActive(repo: repoB.path),
            "白名单串仓了：beta 不能跟着 alpha 启用")
        XCTAssertFalse(ContextPackRollout.isActive(repo: "/tmp/unregistered"),
            "未登记仓库即使白名单非空也保持影子")
    }

    func testCorruptConfigAndUnknownAliasesFailClosed() throws {
        try Data("{ 这不是 JSON".utf8).write(to: ContextPackRollout.fileOverride!)
        XCTAssertFalse(ContextPackRollout.isActive(repo: repoA.path),
            "坏配置文件必须 fail-closed 为影子")

        enable(["ghost-alias"])
        XCTAssertFalse(ContextPackRollout.isActive(repo: repoA.path),
            "未知别名不能让任何已登记仓库被误启用")
    }

    // MARK: - 选择层

    func testShadowModeNeverBlocksDispatchAndKeepsRecordingTheNewPack() {
        let outcome = ContextDispatchPrompt.build(
            request: refuserRequest(repo: repoA),
            legacy: { "LEGACY-PROMPT-BODY" })

        XCTAssertEqual(outcome.mode, .shadow)
        XCTAssertFalse(outcome.refused,
            "影子模式下新 pack 的拒绝绝不能阻断派发")
        XCTAssertEqual(outcome.prompt, "LEGACY-PROMPT-BODY",
            "影子模式派发的必须是旧提示词语义")
        XCTAssertEqual(outcome.manifest.rolloutMode, "shadow")
        XCTAssertTrue(outcome.pack.refused, "影子也要照常构建新 pack 并记下它会拒绝")
        XCTAssertNotNil(outcome.manifest.refusedReason,
            "影子的拒绝数据要进 manifest，供 miss 统计")
    }

    func testActiveModeSwitchesToNewPackAndRefusalBlocks() {
        enable(["alpha"])
        let outcome = ContextDispatchPrompt.build(
            request: refuserRequest(repo: repoA),
            legacy: { "LEGACY-PROMPT-BODY" })

        XCTAssertEqual(outcome.mode, .active)
        XCTAssertTrue(outcome.refused, "只有 active 才允许因 refusal 阻断")
        XCTAssertEqual(outcome.manifest.rolloutMode, "active")
    }

    // MARK: - Legacy builder 不遗漏

    func testLegacyBuilderKeepsEverySectionTheOldAssemblyHad() throws {
        try "# 产品 A\n\n铁律：不许删导出按钮。\n"
            .write(to: repoA.appendingPathComponent("AGENTS.md"),
                   atomically: true, encoding: .utf8)
        // 登记为人工终审仓库，让证据条款出现（旧逻辑的条件路径）。
        // 复用 alpha 别名 —— 同一路径的多个别名会让「按路径找第一个」
        // 匹配到不带标记的那条。
        var entry = try RepoRegistry.add(alias: "alpha", path: repoA.path)
        entry.manualReview = true
        var list = RepoRegistry.all().filter { $0.alias != "alpha" }
        list.append(entry)
        try RepoRegistry.save(list)

        var upstream = WorkTask(id: "up", prompt: "上游步骤", repo: repoA.path)
        upstream.state = .done
        upstream.outputs = ["fire-rate.md"]
        upstream.graphID = "g1"
        var node = WorkTask(id: "node", prompt: "图内节点任务", repo: repoA.path)
        node.graphID = "g1"
        node.dependsOn = ["up"]

        let askFile = scratch.appendingPathComponent("ask.json").path
        let prompt = LegacyContextPromptBuilder.build(
            task: node, allTasks: [node, upstream], runnerID: "claude.code",
            workspacePath: repoA.path, handoff: Handoff(
                fromPlatform: .qwen, reason: "超时", touchedFiles: ["a.swift"],
                wipCommit: "abc123", elapsedSeconds: 120),
            resumedAnswer: nil, resumedAsk: nil,
            mayAsk: true, askFile: askFile)

        XCTAssertTrue(prompt.contains("## 当前任务\n\n图内节点任务"),
                      "任务正文必须紧跟高优先级协作契约")
        XCTAssertTrue(prompt.contains("## 接力说明"), "handoff 说明丢了")
        XCTAssertTrue(prompt.contains("a.swift"), "handoff 改动清单丢了")
        XCTAssertFalse(prompt.contains("这个仓库长什么样"),
            "接力场景旧逻辑不注入仓库地图 —— 别悄悄加回来")
        XCTAssertTrue(prompt.contains("这个产品是什么"), "ProductBrief 丢了")
        XCTAssertTrue(prompt.contains("## 交证据"), "证据条款丢了（manualReview 仓库）")
        XCTAssertTrue(prompt.contains("长任务进度与续期"), "进度契约丢了")
        XCTAssertTrue(prompt.contains("这是一个多步任务里的一步"), "任务图位置丢了")
        XCTAssertTrue(prompt.contains("【协作约定】"), "协作约定丢了")
        XCTAssertTrue(prompt.contains("如果你缺少必要信息"), "提问契约丢了")

        // 无接力的普通任务才有仓库地图。
        let plain = WorkTask(id: "plain", prompt: "普通任务", repo: repoA.path)
        let plainPrompt = LegacyContextPromptBuilder.build(
            task: plain, allTasks: [plain], runnerID: "claude.code",
            workspacePath: repoA.path, handoff: nil,
            resumedAnswer: nil, resumedAsk: nil,
            mayAsk: false, askFile: nil)
        XCTAssertTrue(plainPrompt.contains("这个仓库长什么样"), "仓库地图丢了")
    }

    func testLegacyBuilderKeepsCollaborationContractAheadOfLargeTaskBody() {
        let marker = "TASK-BODY-START"
        let source = WorkTask(
            id: "large-task",
            prompt: marker + String(repeating: "超长任务正文", count: 8_000),
            repo: repoA.path)

        let prompt = LegacyContextPromptBuilder.build(
            task: source, allTasks: [source], runnerID: "kimi.code",
            workspacePath: repoA.path, handoff: nil,
            resumedAnswer: nil, resumedAsk: nil,
            mayAsk: false, askFile: nil)

        let contract = try! XCTUnwrap(prompt.range(of: "【协作约定】"))
        let body = try! XCTUnwrap(prompt.range(of: marker))
        XCTAssertLessThan(contract.lowerBound, body.lowerBound,
            "超长正文可能在 Runner 入口被截断；协作能力必须在正文之前交付")
    }

    // MARK: - manifest 兼容

    func testOldManifestWithoutRolloutModeStillDecodes() throws {
        let json = """
            {"packVersion":1,"taskID":"t","runnerID":"r","totalCharacters":10,
             "charactersBySection":{},"includedFactIDs":[],"referencedFactIDs":[],
             "droppedFacts":[],"fullRepoMapUsed":false,
             "createdAt":"2026-08-26T00:00:00Z"}
            """
        let m = try SnapshotCoding.decoder().decode(ContextPackManifest.self,
                                                    from: Data(json.utf8))
        XCTAssertNil(m.rolloutMode, "旧记录缺 rolloutMode 必须能解码且读成 nil")
        XCTAssertNil(m.dispatchedSystemCharacters,
            "旧记录缺 dispatchedSystemCharacters 必须能解码且读成 nil")
    }

    // MARK: - 影子记账：实际派发的系统注入字符数

    func testShadowManifestRecordsLegacySystemInjectionExactly() {
        var legacyCalls = 0
        let systemSection = "SYS-INJECT-固定长度的旧拼装系统段"
        let outcome = ContextDispatchPrompt.build(
            request: request(task: WorkTask(id: "t", prompt: "任务正文XYZ",
                                            repo: repoA.path)),
            legacy: {
                legacyCalls += 1
                return "任务正文XYZ" + systemSection
            })

        XCTAssertEqual(legacyCalls, 1, "legacy 闭包必须恰好执行一次")
        XCTAssertEqual(outcome.manifest.rolloutMode, "shadow")
        XCTAssertEqual(outcome.manifest.dispatchedSystemCharacters,
                       systemSection.count,
            "影子必须记录旧拼装的系统注入字符数（扣除任务正文），"
                + "否则新旧 P50/P95 和节省率没法比")
        XCTAssertEqual(outcome.manifest.totalCharacters,
                       outcome.pack.manifest.totalCharacters,
            "totalCharacters 必须仍是新包的量，两套数字不能混")
    }

    func testShadowSubtractsResumedAnswerFromSystemInjection() {
        // 用户答复是用户材料，不算系统注入 —— 扣除逻辑收在纯函数里。
        // （Ask 结构要 taskID/machineID/轮次等一整套字段，
        // 端到端构造成本不成比例；这里钉死算术，build() 只负责喂参数。）
        XCTAssertEqual(ContextDispatchPrompt.dispatchedSystemCharacters(
            legacyPrompt: "正文" + "系统段" + "用户答复段",
            taskBody: "正文",
            userMaterial: "用户答复段"), "系统段".count)
        // 防御：legacy 异常短于正文时不得报负数。
        XCTAssertEqual(ContextDispatchPrompt.dispatchedSystemCharacters(
            legacyPrompt: "短", taskBody: "很长的任务正文", userMaterial: ""), 0)
    }

    func testActiveRecordsNewPackSizeAndRefusalRecordsNothing() throws {
        enable(["alpha"])
        let plain = ContextDispatchPrompt.build(
            request: request(task: WorkTask(id: "t", prompt: "正文", repo: repoA.path)),
            legacy: { "LEGACY" })
        XCTAssertEqual(plain.mode, .active)
        XCTAssertEqual(plain.manifest.dispatchedSystemCharacters,
                       plain.manifest.totalCharacters,
            "active 非拒绝时实际派发的就是新包")

        enable(["alpha"])
        let denied = ContextDispatchPrompt.build(
            request: refuserRequest(repo: repoA), legacy: { "LEGACY" })
        XCTAssertTrue(denied.refused)
        XCTAssertNil(denied.manifest.dispatchedSystemCharacters,
            "active 拒绝时没有派发任何提示词 —— 记 nil，别拿候选包充数")
    }

    // MARK: - list 的有效/忽略名单

    func testPartitionEnabledSplitsRegisteredFromGhost() {
        let registry = [
            RepoAlias(alias: "alpha", path: "/tmp/a"),
            RepoAlias(alias: "beta", path: "/tmp/b"),
        ]
        let split = ContextPackRollout.partitionEnabled(
            ["beta", "ghost", "alpha"], registry: registry)
        XCTAssertEqual(split.valid, ["beta", "alpha"],
            "只有登记表里的别名才算已启用")
        XCTAssertEqual(split.ignored, ["ghost"],
            "幽灵别名单独归入忽略名单，绝不能显示成已启用")
    }

    // MARK: - QUALITY.md 尾部验收条款

    func testQualityContractTailSurvivesBeyond8000Characters() throws {
        let sentence = "验收：开火节奏必须连续三帧稳定，散布不得超出准星圈。"
        let quality = "# 质量契约\n\n" + String(repeating: sentence, count: 300)
            + "\n尾部条款：TAIL-QA-888 特写镜头不得替代全景验收。\n"
        try quality.write(to: repoA.appendingPathComponent("QUALITY.md"),
                          atomically: true, encoding: .utf8)
        // 同上：复用 alpha 别名，避免多别名抢「按路径第一个」的匹配。
        var qEntry = try RepoRegistry.add(alias: "alpha", path: repoA.path)
        qEntry.qualityContract = "QUALITY.md"
        var qList = RepoRegistry.all().filter { $0.alias != "alpha" }
        qList.append(qEntry)
        try RepoRegistry.save(qList)

        // 旧 API 保持 per-file 截断兼容。
        let legacy = ProductBrief.qualityText(repo: repoA.path, registeredRepo: repoA.path) ?? ""
        XCTAssertLessThanOrEqual(legacy.count, ProductBrief.maxCharacters + 100)

        // builder 的 full 通路不丢尾部验收条款 —— 文本 Runner 也要拿全。
        let source = WorkTask(id: "t-q", prompt: "修复握枪动作", repo: repoA.path)
        let req: ContextPackBuilder.Request = .init(
            task: source, allTasks: [source], events: [],
            runnerID: "minimax.text", platform: .minimax,
            canReadFiles: false, workspacePath: repoA.path,
            handoff: nil, resumedAnswer: nil, resumedAsk: nil,
            mayAsk: false, askFile: nil, tier: .standard,
            sessionAction: "fresh")
        let pack = ContextPackBuilder.build(req)
        XCTAssertNil(pack.refusedReason)
        XCTAssertTrue(pack.text.contains("TAIL-QA-888"),
            "QUALITY.md 8000 字以后的尾部验收条款被预截断吃掉了")
    }
}
