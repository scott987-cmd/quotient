import XCTest
@testable import LLMQuotaCore

/// **续活默认关,只对专注的项目开;而且同时只专注一个。**
///
/// 老板 2026-08-23:「现在续的活不是我需要的,不要瞎续活」「我们应该专注于
/// 项目去派活」。原来续活对所有仓库默认开,队列一空就给他不关注的仓库
/// (DragonTales/AssetPacks)乱派活。
final class AutoRefillFocusTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-execution-scope-" + UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    func testAutoRefillDefaultsOff() {
        let r = RepoAlias(alias: "x", path: "/x")
        XCTAssertFalse(r.autoRefill, "默认必须关 —— 空闲不是问题,乱干才是")
    }

    /// 序列化往返:开关存得住(不然重启就丢)。
    func testFlagSurvivesRoundTrip() throws {
        var r = RepoAlias(alias: "flint", path: "/flint")
        r.autoRefill = true
        let d = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RepoAlias.self, from: d)
        XCTAssertTrue(back.autoRefill)
    }

    /// 老配置没有这个字段 → 解码成 false(不会因为字段缺失崩,也不会误开)。
    func testOldConfigDecodesToOff() throws {
        let json = #"{"alias":"old","path":"/old"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(RepoAlias.self, from: json)
        XCTAssertFalse(r.autoRefill)
    }

    func testOwnerAndQualityContractSurviveRoundTrip() throws {
        var r = RepoAlias(alias: "flint", path: "/flint")
        r.implementationOwner = .kimi
        r.qualityContract = "QUALITY.md"
        let back = try JSONDecoder().decode(RepoAlias.self,
            from: JSONEncoder().encode(r))
        XCTAssertEqual(back.implementationOwner, .kimi)
        XCTAssertEqual(back.qualityContract, "QUALITY.md")
    }

    func testImplementationOwnerOnlyConstrainsCoding() {
        var r = RepoAlias(alias: "flint", path: "/flint")
        r.implementationOwner = .kimi
        XCTAssertEqual(RepoExecutionPolicy.implementationOwner(
            for: "/flint", prompt: "优化持枪动作", repos: [r]), .kimi)
        XCTAssertNil(RepoExecutionPolicy.implementationOwner(
            for: "/flint", prompt: "【审查】检查 diff", repos: [r]))
        XCTAssertNil(RepoExecutionPolicy.implementationOwner(
            for: "/flint", prompt: "【媒体】生成贴图", repos: [r]))
    }

    func testFocusedProjectIsAHardExecutionBoundary() {
        let scope = ProjectExecutionScope(allowedRepo: "/dev/Flint")
        let flint = WorkTask(id: "flint", prompt: "功能", repo: "/dev/Flint")
        let maw = WorkTask(id: "maw", prompt: "功能", repo: "/dev/Maw")

        XCTAssertTrue(scope.allows(flint.repo))
        XCTAssertFalse(scope.allows(maw.repo))
        XCTAssertFalse(scope.canStart(maw, explicitOverride: false))
        XCTAssertTrue(scope.canStart(maw, explicitOverride: true))
        XCTAssertEqual(scope.filter([maw, flint]).map(\.id), ["flint"])
    }

    func testMachineLocalFocusSurvivesRoundTrip() throws {
        try ProjectExecutionScope.setFocusedRepo("/dev/Flint")
        let scope = ProjectExecutionScope.current(repos: [])
        XCTAssertTrue(scope.isConfigured)
        XCTAssertEqual(scope.allowedRepo, "/dev/Flint")
        XCTAssertFalse(scope.allows("/dev/Maw"))
    }

    func testExplicitFocusOffDoesNotFallBackToLegacySharedFlag() throws {
        var legacy = RepoAlias(alias: "flint", path: "/dev/Flint")
        legacy.autoRefill = true
        try ProjectExecutionScope.setFocusedRepo(nil)

        let scope = ProjectExecutionScope.current(repos: [legacy])
        XCTAssertTrue(scope.isConfigured)
        XCTAssertNil(scope.allowedRepo)
        XCTAssertEqual(scope.mode, .manualOnly)
        XCTAssertFalse(scope.allows("/dev/Maw"),
                       "显式关闭专注后不得把 nil 错当成自动执行全部项目")
        XCTAssertTrue(scope.includesForDisplay("/dev/Maw"),
                      "manualOnly 只关闭自动执行，不能把任务从看板隐藏")
        let manual = WorkTask(id: "manual", prompt: "人工启动", repo: "/dev/Maw")
        XCTAssertTrue(scope.canStart(manual, explicitOverride: true))
        XCTAssertFalse(scope.shouldAutoRefill("/dev/Flint"))
    }

    func testManualOnlyRejectsAutomaticQueueButAllowsExplicitStart() {
        let scope = ProjectExecutionScope(mode: .manualOnly)
        let task = WorkTask(id: "manual", prompt: "人工运行", repo: "/dev/Maw")
        XCTAssertTrue(scope.filter([task]).isEmpty)
        XCTAssertFalse(scope.canStart(task, explicitOverride: false))
        XCTAssertTrue(scope.canStart(task, explicitOverride: true))
    }

    func testAutomaticAllMustBeExplicit() throws {
        try ProjectExecutionScope.setExecutionMode(.automaticAll)
        let scope = ProjectExecutionScope.current(repos: [])
        XCTAssertEqual(scope.mode, .automaticAll)
        XCTAssertTrue(scope.allows("/dev/Flint"))
        XCTAssertTrue(scope.allows("/dev/Maw"))
        XCTAssertTrue(scope.shouldAutoRefill("/dev/Flint"))
    }

    func testLegacySharedFocusMigratesAsReadOnlyFallback() {
        var flint = RepoAlias(alias: "flint", path: "/dev/Flint")
        flint.autoRefill = true
        let scope = ProjectExecutionScope.current(repos: [flint])
        XCTAssertFalse(scope.isConfigured)
        XCTAssertEqual(scope.allowedRepo, "/dev/Flint")
        XCTAssertTrue(scope.shouldAutoRefill("/dev/Flint"))
        XCTAssertFalse(scope.allows("/dev/Maw"))
    }

    func testEveryTaskStartPathUsesTheSameHardScope() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent(
            "Sources/llmq/main.swift"), encoding: .utf8)

        XCTAssertGreaterThanOrEqual(
            main.components(separatedBy: "enforceProjectExecutionScope(").count - 1, 5,
            "handoff、unpause、retry、架构重审和手工 run 必须共用同一个项目守卫")
        XCTAssertGreaterThanOrEqual(
            main.components(separatedBy: "scope.filter(TaskStore.readyQueue())").count - 1, 2,
            "后台执行槽和单任务执行入口都必须过滤非专注项目")
        XCTAssertTrue(main.contains("ProjectExecutionScope.setFocusedRepo(all[i].localPath)"),
                      "repo focus 必须落本机硬作用域，不能只改共享补活提示")
        let focusStart = try XCTUnwrap(main.range(of: "case \"focus\":"))
        let ownerStart = try XCTUnwrap(main.range(of: "case \"owner\":",
                                                  range: focusStart.upperBound..<main.endIndex))
        let focusCommand = String(main[focusStart.lowerBound..<ownerStart.lowerBound])
        XCTAssertFalse(focusCommand.contains("coordinatorMachineID = Paths.machineID()"),
                       "切换本机专注项目不能顺手篡改共享协调机")
        XCTAssertTrue(main.contains("case \"coordinator\":"),
                      "共享协调机必须有独立、显式的管理入口")
        XCTAssertFalse(main.contains("all[j].autoRefill = (j == i)"),
                       "共享 autoRefill 不能继续冒充本机项目专注")
        XCTAssertEqual(
            main.components(separatedBy: "dispatchReadyTasks(lowDisk:").count - 1, 2,
            "定义之外每轮只能有一次派发，不能同轮重读配置和候选")
        let intake = try XCTUnwrap(main.range(of: "let intakeDeadline"))
        let dispatch = try XCTUnwrap(main.range(of:
            "let dispatchedThisRound = dispatchReadyTasks"))
        XCTAssertLessThan(intake.lowerBound, dispatch.lowerBound,
                          "必须先完成有界摄入，再冻结快照派发")
        XCTAssertTrue(main.contains("TaskStore.readyQueue(from: allTasks)"),
                      "候选与容量判断必须来自同一代任务 revision")
        XCTAssertTrue(main.contains(
            "let explicitManualStart = onlyTaskID != nil && scope.mode == .manualOnly"),
            "manualOnly 必须允许人工点名执行，不能被自动队列过滤器误伤")
    }
}
