import XCTest
@testable import LLMQuotaCore

/// 空窗填活的三条闸。
///
/// 这段逻辑会**自动花钱**（主动派活给平台），所以每条闸都得钉死：
/// 填早了是跟人抢额度，填错对象是白烧，编造任务是把浪费换个地方发生。
final class IdleFillerTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
    }
    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func status(label: String, used: Double?, resetsIn: TimeInterval,
                        platform: Platform = .codex) -> QuotaStatus {
        QuotaStatus(
            platform: platform, planName: "p", limitID: "w", label: label,
            metric: .percent, kind: .periodic, used: (used ?? 0) * 100, limit: 100,
            usedFraction: used, windowStart: Date(),
            resetsAt: Date().addingTimeInterval(resetsIn),
            windowElapsedFraction: 0.8, projectedUsedFraction: used,
            projectedWaste: nil, health: .healthy, isOfficial: false, sourceNote: "test")
    }

    private func dash(_ statuses: [QuotaStatus], platform: Platform = .codex) -> Dashboard {
        Dashboard(generatedAt: Date(), machines: [],
                  reports: [PlatformReport(
                    platform: platform, planName: "p", monthlyCost: nil, currency: "CNY",
                    detected: true, machines: [Paths.machineName()], lastActivity: nil,
                    statuses: statuses, last30dRequests: 0, last30dBillableTokens: 0,
                    last7dRequests: 0, topModels: [])])
    }

    /// 主场景：窗口快过期 + 用得少 → 是个填活机会。
    func testNearExpiryAndIdleIsAnOpportunity() {
        let opps = IdleFiller.opportunities(
            dashboard: dash([status(label: "5 小时", used: 0.05, resetsIn: 30 * 60)]))
        XCTAssertEqual(opps.count, 1, "剩 30 分钟、只用了 5% —— 不填就清零")
        XCTAssertEqual(opps.first?.platform, .codex)
    }

    /// 窗口还早 → 不填。那段时间人可能自己要用，抢了就是添乱。
    func testEarlyInWindowIsLeftAlone() {
        let opps = IdleFiller.opportunities(
            dashboard: dash([status(label: "5 小时", used: 0.05, resetsIn: 4 * 3600)]))
        XCTAssertTrue(opps.isEmpty, "还剩四小时就去抢额度，是跟人抢：\(opps)")
    }

    /// 已经用得不少 → 不填。它没闲着。
    func testBusyWindowIsNotFilled() {
        let opps = IdleFiller.opportunities(
            dashboard: dash([status(label: "5 小时", used: 0.8, resetsIn: 20 * 60)]))
        XCTAssertTrue(opps.isEmpty, "用了 80% 不叫空窗：\(opps)")
    }

    /// 没有重置时间 → 不填。「快过期」无从判断，硬猜会在错误时刻抢额度。
    func testWindowWithoutResetTimeIsSkipped() {
        var s = status(label: "每月", used: 0.01, resetsIn: 60)
        s.resetsAt = nil
        XCTAssertTrue(IdleFiller.opportunities(dashboard: dash([s])).isEmpty)
    }

    /// 冷却中的平台不填 —— 额度打空了，塞活只会立刻失败。
    func testCoolingPlatformIsSkipped() {
        CooldownLedger.record(platform: .codex, cause: .quotaExhausted,
                              detail: "test", knownResetAt: Date().addingTimeInterval(3600))
        let opps = IdleFiller.opportunities(
            dashboard: dash([status(label: "5 小时", used: 0.02, resetsIn: 20 * 60)]))
        XCTAssertTrue(opps.isEmpty, "冷却中还塞活：\(opps)")
    }

    /// 填活时先派真需求 —— 空窗只填得下一个，得是最值钱的那个。
    func testRealDemandOutranksChores() {
        XCTAssertLessThan(ReservePool.Fact.Rule.reviewFinding.priority,
                          ReservePool.Fact.Rule.missingDoc.priority,
                          "审查发现是人读完 diff 写的，补注释是扫出来的格式问题")
        XCTAssertLessThan(ReservePool.Fact.Rule.todoMarker.priority,
                          ReservePool.Fact.Rule.noTestReference.priority)
    }

    /// 队列里已经有活 → 不填。调度器自己会派，填了只是插队。
    func testDoesNotFillWhenQueueHasWork() {
        var t = WorkTask(id: "q1", prompt: "已有的活", repo: "/tmp")
        t.state = .queued
        let opp = IdleFiller.Opportunity(platform: .codex, windowLabel: "5 小时",
                                         remaining: 600, used: 0.01, reason: "test")
        XCTAssertNil(IdleFiller.findWork(for: opp, repos: [], tasks: [t]),
                     "队列有活时不该再填")
    }
}

/// 方向清单：**方向是人的决定，不是 agent 该自己拍的。**
final class PlaybookTopicTests: XCTestCase {
    private func project(backlog: [String]) -> Playbook.Project {
        Playbook.Project(
            id: "p1", name: "测试项目", brief: "b",
            backlog: backlog, shipped: ["旧方向"],
            recipes: [Playbook.Recipe(
                title: "出一个", prompt: "做 {{topic}}，别重复 {{shipped}}",
                platform: "minimax")],
            approvedAt: Date())
    }

    func testTopicIsFilledIntoThePrompt() {
        let hit = Playbook.nextWork(for: .minimax, projects: [project(backlog: ["新方向"])])
        XCTAssertEqual(hit?.prompt, "做 新方向，别重复 旧方向")
    }

    /// 清单空了就别出活 —— 让它自己编方向，做出来的东西没人要。
    /// 那不是省额度，是把浪费从「窗口过期」换成「产出没人要」。
    func testEmptyBacklogStopsTheProject() {
        XCTAssertNil(Playbook.nextWork(for: .minimax, projects: [project(backlog: [])]),
                     "没方向时应该停下来问人，不是随便挑一个")
    }

    /// 不点名平台的配方，谁来都能干。
    func testUnpinnedRecipeAcceptsAnyPlatform() {
        var p = project(backlog: ["x"])
        p.recipes[0].platform = nil
        XCTAssertNotNil(Playbook.nextWork(for: .codex, projects: [p]))
    }

    /// 点名了 MiniMax 的活，别拿 Codex 去跑 —— 点名是有理由的（它会生图）。
    func testPinnedRecipeRejectsOtherPlatforms() {
        XCTAssertNil(Playbook.nextWork(for: .codex, projects: [project(backlog: ["x"])]))
    }
}
