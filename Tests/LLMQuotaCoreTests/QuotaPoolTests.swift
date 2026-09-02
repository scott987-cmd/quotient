import XCTest
@testable import LLMQuotaCore

final class QuotaPoolTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-pool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
        Paths.machineIDOverride = "machine-b"
    }

    override func tearDown() {
        Paths.machineIDOverride = nil
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private struct StubRunner: AgentRunner {
        let platform: Platform = .qwen
        var binaryName: String { "echo" }
        var canEdit: Bool { false }

        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/bin/echo", [prompt], [:])
        }
    }

    private func snapshot(machineID: String, usedPercent: Double, observedAt: Date,
                          explicitPoolID: String? = nil) -> MachineSnapshot {
        MachineSnapshot(
            machineID: machineID, machineName: machineID,
            generatedAt: observedAt,
            retentionStart: observedAt.addingTimeInterval(-86400),
            platforms: [PlatformSnapshot(
                platform: .qwen, detected: true, installed: true,
                officialQuotas: [OfficialQuota(
                    id: "weekly", label: "每周", usedPercent: usedPercent,
                    windowMinutes: 10_080,
                    resetsAt: observedAt.addingTimeInterval(3600),
                    observedAt: observedAt)],
                quotaPoolID: explicitPoolID)])
    }

    private func config(bindings: [QuotaPoolBinding]) -> PlansConfig {
        PlansConfig(
            plans: [PlatformPlan(platform: .qwen, planName: "Qwen")],
            quotaPools: bindings)
    }

    func testDifferentSubscriptionsStaySeparateAndSchedulerUsesLocalPool() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cfg = config(bindings: [
            QuotaPoolBinding(poolID: "qwen-a", platform: .qwen,
                             displayName: "订阅 A", machineID: "machine-a"),
            QuotaPoolBinding(poolID: "qwen-b", platform: .qwen,
                             displayName: "订阅 B", machineID: "machine-b"),
        ])
        let dashboard = QuotaEngine(config: cfg).buildDashboard(
            snapshots: [snapshot(machineID: "machine-a", usedPercent: 100, observedAt: now),
                        snapshot(machineID: "machine-b", usedPercent: 20, observedAt: now)],
            now: now, tasks: [], machineID: "machine-b", cooldowns: [:])

        let report = try! XCTUnwrap(dashboard.reports.first { $0.platform == .qwen })
        XCTAssertEqual(report.quotaPools?.count, 2)
        XCTAssertEqual(report.localQuotaPoolID, "qwen-b")
        XCTAssertEqual(report.quotaPool(id: "qwen-a")?.statuses.first?.usedFraction, 1)
        XCTAssertEqual(report.quotaPool(id: "qwen-b")?.statuses.first?.usedFraction, 0.2)

        let decision = WorkScheduler().decide(
            dashboard: dashboard, runners: [StubRunner()], now: now,
            requiresEditing: false)
        XCTAssertEqual(decision.candidates.first?.platform, .qwen,
                       "另一份订阅耗尽不能挡住本机仍有 80% 的订阅")
    }

    func testMachinesSharingOneSubscriptionStillDeduplicateOfficialQuota() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cfg = config(bindings: [
            QuotaPoolBinding(poolID: "shared-qwen", platform: .qwen,
                             displayName: "共享订阅", machineID: "machine-a"),
            QuotaPoolBinding(poolID: "shared-qwen", platform: .qwen,
                             displayName: "共享订阅", machineID: "machine-b"),
        ])
        let dashboard = QuotaEngine(config: cfg).buildDashboard(
            snapshots: [snapshot(machineID: "machine-a", usedPercent: 30,
                                 observedAt: now.addingTimeInterval(-60)),
                        snapshot(machineID: "machine-b", usedPercent: 40, observedAt: now)],
            now: now, tasks: [], machineID: "machine-b", cooldowns: [:])

        let report = try! XCTUnwrap(dashboard.reports.first { $0.platform == .qwen })
        XCTAssertEqual(report.quotaPools?.count, 1)
        XCTAssertEqual(report.quotaPools?.first?.machineIDs.sorted(), ["machine-a", "machine-b"])
        XCTAssertEqual(report.quotaPools?.first?.statuses.count, 1)
        XCTAssertEqual(report.quotaPools?.first?.statuses.first?.usedFraction, 0.4,
                       "同一订阅由两台机器观测时只采信最新官方值")
    }

    func testCooldownOnlyBlocksItsQuotaPool() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = CooldownLedger.record(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            quotaPoolID: "qwen-a", cause: .quotaExhausted, detail: "weekly quota",
            knownResetAt: now.addingTimeInterval(3600), now: now)

        XCTAssertNotNil(CooldownLedger.active(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            quotaPoolID: "qwen-a", now: now))
        XCTAssertNil(CooldownLedger.active(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            quotaPoolID: "qwen-b", now: now),
            "一个订阅撞限额不能冻结同平台的另一份订阅")
    }

    func testLegacyCooldownDoesNotFreezeANamedSubscription() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        CooldownLedger.save([Cooldown(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            cause: .quotaExhausted, since: now,
            until: now.addingTimeInterval(3600), strikes: 1, detail: "legacy")])
        let named = config(bindings: [QuotaPoolBinding(
            poolID: "qwen-b", platform: .qwen, machineID: "machine-b")])

        XCTAssertNil(CooldownLedger.active(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            quotaPoolID: "qwen-b", now: now, config: named),
            "无法归属的旧冷却不能冻结一份已命名订阅")

        XCTAssertNotNil(CooldownLedger.active(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            quotaPoolID: "qwen:default", now: now,
            config: PlansConfig(plans: [PlatformPlan(platform: .qwen, planName: "Qwen")])),
            "没有显式分池的旧配置仍要兼容旧冷却")
    }

    func testOldSnapshotWithoutPoolIdentityStillDecodes() throws {
        let json = """
        {"platform":"qwen","detected":true,"installed":true,"sources":[],
         "buckets":[],"officialQuotas":[]}
        """.data(using: .utf8)!
        let decoded = try SnapshotCoding.decoder().decode(PlatformSnapshot.self, from: json)
        XCTAssertNil(decoded.quotaPoolID)
    }

    func testPoolOnlyLimitsCountAsConfigured() {
        var weekly = QuotaLimit(
            id: "weekly", label: "每周", windowMinutes: 10_080,
            kind: .periodic, metric: .requests)
        weekly.limit = 800
        let cfg = PlansConfig(
            plans: [PlatformPlan(platform: .qwen, planName: "Qwen")],
            quotaPools: [QuotaPoolBinding(
                poolID: "qwen-b", platform: .qwen,
                machineID: "machine-b", limits: [weekly])])

        XCTAssertEqual(cfg.filledLimitCount, 1,
                       "只有某个订阅池填了上限时也不能被误判为空模板")
    }

    func testCalibratedLimitIsWrittenOnlyIntoRequestedPool() throws {
        var cfg = PlansConfig.template()
        cfg.quotaPools = [
            QuotaPoolBinding(poolID: "qwen-a", platform: .qwen,
                             machineID: "machine-a"),
            QuotaPoolBinding(poolID: "qwen-b", platform: .qwen,
                             machineID: "machine-b"),
        ]

        XCTAssertTrue(cfg.setQuotaLimit(
            platform: .qwen, poolID: "qwen-b", limitID: "daily",
            limit: 900, hint: "pool-b calibration"))
        XCTAssertNil(cfg.plan(for: .qwen)?.limits.first { $0.id == "daily" }?.limit)
        XCTAssertNil(cfg.plan(for: .qwen, quotaPoolID: "qwen-a")?
            .limits.first { $0.id == "daily" }?.limit)
        XCTAssertEqual(cfg.plan(for: .qwen, quotaPoolID: "qwen-b")?
            .limits.first { $0.id == "daily" }?.limit, 900)
    }

    func testPoolOverridesReceiveNewWindowDefinitionsWithoutLosingValues() {
        let cfg = PlansConfig(
            plans: [PlatformPlan(platform: .kimi, planName: "Kimi")],
            quotaPools: [QuotaPoolBinding(
                poolID: "kimi-a", platform: .kimi, machineID: "machine-a",
                limits: [QuotaLimit(
                    id: "5h", label: "旧五小时", windowMinutes: 300,
                    kind: .session, metric: .requests, limit: 777)])])

        let reconciled = PlansStore.reconcileWindows(cfg)
        let limits = reconciled.plan(for: .kimi, quotaPoolID: "kimi-a")?.limits ?? []
        XCTAssertEqual(limits.first { $0.id == "5h" }?.limit, 777)
        XCTAssertTrue(limits.contains { $0.id == "weekly" },
                      "平台窗口升级也必须到达订阅池 override")
    }

    func testLegacyCeilingEvidenceCannotContaminateANamedQuotaPool() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func observation(pool: String?, usage: Double) -> QuotaCeiling.Observation {
            QuotaCeiling.Observation(
                platform: .qwen, quotaPoolID: pool, at: now,
                windowMinutes: 10_080, windowLabel: "每周",
                windowStart: now.addingTimeInterval(-600),
                usage: [QuotaMetric.requests.rawValue: usage], detail: "weekly quota")
        }
        QuotaCeiling.append([
            observation(pool: nil, usage: 9_000),
            observation(pool: "qwen-a", usage: 100),
            observation(pool: "qwen-b", usage: 200),
        ])

        let poolB = QuotaCeiling.estimates(quotaPoolIDs: [.qwen: "qwen-b"])
        XCTAssertEqual(poolB.first?.value, 200,
                       "无法归属的旧样本不能污染另一份真实订阅的学习值")
        let legacy = QuotaCeiling.estimates()
        XCTAssertEqual(legacy.first?.value, 9_000,
                       "没有显式额度池的旧配置只能读取旧样本")
        let syntheticDefault = QuotaCeiling.estimates(
            quotaPoolIDs: [.qwen: "qwen:default"])
        XCTAssertEqual(syntheticDefault.first?.value, 9_000,
                       "自动生成的默认池必须延续旧配置的历史学习证据")
    }

    func testSavingConflictingBindingsForOneRunnerIsRejected() throws {
        let cfg = config(bindings: [
            QuotaPoolBinding(poolID: "qwen-a", platform: .qwen,
                             machineID: "machine-b", runnerID: "qwen.code"),
            QuotaPoolBinding(poolID: "qwen-b", platform: .qwen,
                             machineID: "machine-b", runnerID: "qwen.code"),
        ])

        XCTAssertThrowsError(try PlansStore.save(cfg, force: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("额度池绑定冲突"))
            XCTAssertTrue(error.localizedDescription.contains("qwen-a"))
            XCTAssertTrue(error.localizedDescription.contains("qwen-b"))
        }
    }

    func testDifferentMachinesMayUseDifferentSubscriptions() throws {
        let cfg = config(bindings: [
            QuotaPoolBinding(poolID: "qwen-a", platform: .qwen,
                             machineID: "machine-a", runnerID: "qwen.code"),
            QuotaPoolBinding(poolID: "qwen-b", platform: .qwen,
                             machineID: "machine-b", runnerID: "qwen.code"),
        ])

        XCTAssertNoThrow(try PlansStore.save(cfg, force: true))
        XCTAssertTrue(cfg.quotaPoolBindingConflicts().isEmpty)
        XCTAssertEqual(cfg.quotaPoolID(
            for: .qwen, machineID: "machine-a", runnerID: "qwen.code"), "qwen-a")
        XCTAssertEqual(cfg.quotaPoolID(
            for: .qwen, machineID: "machine-b", runnerID: "qwen.code"), "qwen-b")
    }

    func testLegacyConflictingConfigReadsDeterministically() {
        let first = config(bindings: [
            QuotaPoolBinding(poolID: "qwen-a", platform: .qwen,
                             machineID: "machine-b", runnerID: "qwen.code"),
            QuotaPoolBinding(poolID: "qwen-b", platform: .qwen,
                             machineID: "machine-b", runnerID: "qwen.code"),
        ])
        let reversed = config(bindings: first.quotaPools!.reversed())

        XCTAssertEqual(
            first.quotaPoolID(for: .qwen, machineID: "machine-b", runnerID: "qwen.code"),
            reversed.quotaPoolID(for: .qwen, machineID: "machine-b", runnerID: "qwen.code"))
    }
}
