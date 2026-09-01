import XCTest
@testable import LLMQuotaCore

final class WorkRunTargetTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-run-target-" + UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private struct Runner: AgentRunner {
        let platform: Platform = .qwen
        var binaryName: String { "echo" }

        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/bin/echo", [prompt], [:])
        }
    }

    private func task(_ id: String) -> WorkTask {
        WorkTask(id: id, prompt: "任务 \(id)", repo: "/tmp/repo")
    }

    func testExplicitIDIgnoresOptions() {
        XCTAssertEqual(
            WorkRunTarget.explicitID(arguments: ["74726e09", "--dry-run"]),
            "74726e09")
        XCTAssertNil(WorkRunTarget.explicitID(arguments: ["--dry-run"]))
    }

    func testExplicitRunCannotFallThroughToAnotherReadyTask() {
        let target = task("74726e09")
        let unrelated = task("274147a0")

        XCTAssertEqual(
            WorkRunTarget.select(
                ready: [target, unrelated], explicitID: "74726e09").map(\.id),
            ["74726e09"])
    }

    func testUnavailableExplicitTargetDoesNotSelectQueueFallback() {
        let unrelated = task("274147a0")

        XCTAssertTrue(
            WorkRunTarget.select(
                ready: [unrelated], explicitID: "74726e09").isEmpty,
            "点名任务不可运行时必须退出，不能偷跑队列里的其他任务")
    }

    func testUnscopedWorkerStillReceivesWholeReadyQueue() {
        let tasks = [task("a"), task("b")]
        XCTAssertEqual(
            WorkRunTarget.select(ready: tasks, explicitID: nil).map(\.id),
            ["a", "b"])
    }

    func testExplicitRunCanBypassHumanActivityGrace() {
        let now = Date()
        let dashboard = Dashboard(
            generatedAt: now, machines: [],
            reports: [PlatformReport(
                platform: .qwen, planName: "p", monthlyCost: nil, currency: "CNY",
                detected: true, lastHumanActivityHere: now,
                machines: ["local"], lastActivity: now, statuses: [],
                last30dRequests: 0, last30dBillableTokens: 0,
                last7dRequests: 0, topModels: [])])
        let scheduler = WorkScheduler(humanIdleGrace: 20 * 60)

        let automatic = scheduler.decide(
            dashboard: dashboard, runners: [Runner()], now: now)
        XCTAssertTrue(automatic.candidates.isEmpty,
                      "后台调度仍应在人正在使用平台时礼让")

        let explicit = scheduler.decide(
            dashboard: dashboard, runners: [Runner()], now: now,
            bypassHumanActivityGrace: true)
        XCTAssertEqual(explicit.candidates.map(\.platform), [.qwen],
                       "用户明确点名任务时，不应被自己的交互活动永久挡住")
    }
}
