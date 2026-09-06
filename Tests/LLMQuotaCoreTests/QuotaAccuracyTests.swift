import XCTest
@testable import LLMQuotaCore

final class QuotaAccuracyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var sandbox: URL!

    override func setUp() {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
        Paths.machineIDOverride = "fixture"
    }
    override func tearDown() {
        Paths.appSupportOverride = nil
        Paths.machineIDOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func parse(_ rateLimits: [String: Any], at: Date) throws -> [OfficialQuota] {
        let event: [String: Any] = ["type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: at),
            "payload": ["type": "token_count", "rate_limits": rateLimits]]
        return CodexAdapter().parse(file: URL(fileURLWithPath: "/fixture.jsonl"),
                                   data: try JSONSerialization.data(withJSONObject: event)).quotas
    }
    private func window(_ used: Double, minutes: Int) -> [String: Any] {
        ["used_percent": used, "window_minutes": minutes,
         "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]
    }
    private func report(_ quotas: [OfficialQuota], platform: Platform = .codex,
                        limits: [QuotaLimit] = []) -> PlatformReport {
        let config = PlansConfig(plans: [PlatformPlan(platform: platform,
            planName: "ChatGPT Plus", limits: limits)])
        let snapshot = MachineSnapshot(machineID: "fixture", machineName: "Fixture",
            generatedAt: now, retentionStart: now.addingTimeInterval(-86400),
            platforms: [PlatformSnapshot(platform: platform, detected: true,
                installed: true, officialQuotas: quotas)])
        return QuotaEngine(config: config).buildDashboard(snapshots: [snapshot], now: now,
            tasks: [], machineID: "fixture", repoAliases: [], cooldowns: [:]).reports[0]
    }

    func testCodexSparkDoesNotOverwriteMainSubscription() throws {
        let main = try parse(["limit_id": "codex", "plan_type": "pro",
            "primary": window(55, minutes: 10080), "secondary": NSNull()], at: now)
        let spark = try parse(["limit_id": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark", "primary": window(0, minutes: 300),
            "secondary": window(0, minutes: 10080)], at: now.addingTimeInterval(1))
        let r = report(main + spark)
        XCTAssertEqual(r.statuses.filter { !$0.advisory }.map(\.usedFraction), [0.55])
        XCTAssertEqual(r.statuses.filter(\.advisory).count, 2)
        XCTAssertTrue(r.statuses.filter(\.advisory).allSatisfy { $0.label.contains("Spark") })
        XCTAssertEqual(r.planName, "ChatGPT Pro")
        XCTAssertEqual(r.headline?.usedFraction, 0.55,
                       "远端/桌面摘要不能使用 Spark 的空窗口代替普通 Codex")
    }

    func testRemovedWindowAndLegacySnapshotCannotReappear() throws {
        let old = try parse(["limit_id": "codex", "primary": window(12, minutes: 300),
            "secondary": window(80, minutes: 10080)], at: now.addingTimeInterval(-60))
        let current = try parse(["limit_id": "codex", "primary": window(55, minutes: 10080),
            "secondary": NSNull()], at: now)
        let legacy = OfficialQuota(id: "secondary", label: "每周", usedPercent: 0,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), observedAt: now)
        let r = report(old + current + [legacy])
        XCTAssertEqual(r.statuses.count, 1)
        XCTAssertEqual(r.statuses.first?.usedFraction, 0.55)
    }

    func testResetInFutureDoesNotMakeOldObservationFreshForAWeek() {
        let q = OfficialQuota(id: "primary", label: "每周", usedPercent: 0,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400),
            observedAt: now.addingTimeInterval(-7 * 3600))
        XCTAssertTrue(q.isStale(now: now))
        let engine = QuotaEngine(config: PlansConfig(plans: []))
        let status = engine.officialStatus(q, plan: PlatformPlan(platform: .codex, planName: "Codex"), now: now)
        XCTAssertFalse(status.isFresh(now: now))
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

    func testExpiredFactsDoNotBlockReserveDecision() {
        let cfg = PlansConfig(plans: [PlatformPlan(platform: .qwen, planName: "Qwen")])
        let q = OfficialQuota(id: "weekly", label: "每周", usedPercent: 95,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(3600), observedAt: now)
        let snapshot = MachineSnapshot(machineID: "fixture", machineName: "Fixture",
            generatedAt: now, retentionStart: now.addingTimeInterval(-86400),
            platforms: [PlatformSnapshot(platform: .qwen, detected: true,
                installed: true, officialQuotas: [q])])
        let dashboard = QuotaEngine(config: cfg).buildDashboard(snapshots: [snapshot],
            now: now, tasks: [], machineID: "fixture", repoAliases: [], cooldowns: [:])
        let decision = WorkScheduler().decide(dashboard: dashboard, runners: [StubRunner()],
            now: now.addingTimeInterval(7200), requiresEditing: false)
        XCTAssertEqual(decision.candidates.first?.platform, .qwen)
    }

    func testCodexCurrentWindowSetSuppressesUnconfiguredTemplateWindows() throws {
        let main = try parse(["limit_id": "codex", "primary": window(55, minutes: 10080),
                              "secondary": NSNull()], at: now)
        let r = report(main, limits: [QuotaLimit(id: "5h", label: "5 小时",
            windowMinutes: 300, kind: .rolling, metric: .requests)])
        XCTAssertEqual(r.statuses.count, 1)
        XCTAssertTrue(r.statuses.allSatisfy(\.isOfficial))
    }

    func testQuotaOnlyLogIsNotPrunedAsAnEmptyOldFile() throws {
        let event: [String: Any] = ["type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: now),
            "payload": ["type": "token_count", "info": NSNull(),
                        "rate_limits": ["limit_id": "codex", "primary": window(55, minutes: 10080)]]]
        let parsed = CodexAdapter().parse(file: URL(fileURLWithPath: "/quota-only.jsonl"),
            data: try JSONSerialization.data(withJSONObject: event))
        XCTAssertTrue(parsed.events.isEmpty)
        XCTAssertEqual(parsed.quotas.count, 1)
        XCTAssertEqual(parsed.lastEventAt, now,
                       "Collector 会按 lastEventAt 清理无 usage 的文件，额度回报也必须保留采集时间")
    }

    func testMenuAlertsIgnoreAuxiliaryAndExpiredQuota() {
        let time = Date()
        let plan = PlatformPlan(platform: .codex, planName: "Codex")
        let engine = QuotaEngine(config: PlansConfig(plans: [plan]))
        var r = report([])
        r.statuses = [
            engine.officialStatus(OfficialQuota(id: "spark", label: "Spark", usedPercent: 100,
                windowMinutes: 300, resetsAt: time.addingTimeInterval(3600), observedAt: time,
                advisory: true), plan: plan, now: time),
            engine.officialStatus(OfficialQuota(id: "old", label: "旧窗口", usedPercent: 100,
                windowMinutes: 10080, resetsAt: time.addingTimeInterval(3600),
                observedAt: time.addingTimeInterval(-7 * 3600)), plan: plan, now: time)]
        let d = Dashboard(generatedAt: time, machines: [], reports: [r])
        XCTAssertTrue(d.alerts.isEmpty)
    }

    func testAuxiliaryQuotaDoesNotFreezeReadOnlyHelperSelection() {
        let time = Date()
        let plan = PlatformPlan(platform: .qwen, planName: "Qwen")
        let engine = QuotaEngine(config: PlansConfig(plans: [plan]))
        var r = report([], platform: .qwen)
        r.quotaPools = nil
        r.statuses = [engine.officialStatus(OfficialQuota(id: "code", label: "代码", usedPercent: 20,
            windowMinutes: 300, resetsAt: time.addingTimeInterval(3600), observedAt: time), plan: plan, now: time),
            engine.officialStatus(OfficialQuota(id: "video", label: "视频", usedPercent: 100,
            windowMinutes: 300, resetsAt: time.addingTimeInterval(3600), observedAt: time,
            advisory: true), plan: plan, now: time)]
        let available = LowValueDelegationPolicy.currentHeadroom(
            dashboard: Dashboard(generatedAt: time, machines: [], reports: [r]), now: time)
        XCTAssertEqual(available[.qwen], 0.8, "只读编码咨询不能被辅助媒体额度冻结")
    }

    func testLegacyHelperFallbackCannotSpendPlatformReserve() throws {
        var roles = AgentRoles.defaults()
        let i = try XCTUnwrap(roles.firstIndex { $0.platform == .qwen })
        roles[i].reserveFraction = 0.3
        try AgentRoles.save(roles)
        var candidate = AgentRegistration(machineID: "fixture", machineName: "fixture",
            runnerID: "qwen.test", platform: .qwen, canConsult: true)
        candidate.schemaVersion = 1
        XCTAssertNil(LowValueDelegationPolicy.selectHelper(senderRunnerID: "kimi.code",
            candidates: [candidate], headroom: [.qwen: 0.2]), "旧注册数据回退同样必须扣除预留")
    }

}
