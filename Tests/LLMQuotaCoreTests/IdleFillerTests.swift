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

    func testFocusedProjectSkipsOtherProjectPlaybook() throws {
        let maw = Playbook.Project(
            id: "maw", name: "Maw", brief: "旧项目", repo: "/dev/Maw",
            recipes: [.init(title: "继续", prompt: "继续 Maw")],
            approvedAt: Date(), runs: 0)
        let flint = Playbook.Project(
            id: "flint", name: "Flint", brief: "当前项目", repo: "/dev/Flint",
            recipes: [.init(title: "继续", prompt: "继续 Flint")],
            approvedAt: Date(), runs: 1)
        Playbook.save([maw, flint])
        let opp = IdleFiller.Opportunity(
            platform: .codex, windowLabel: "5 小时",
            remaining: 600, used: 0.01, reason: "test")

        let hit = try XCTUnwrap(IdleFiller.found(
            for: opp, repos: [], tasks: [],
            scope: ProjectExecutionScope(allowedRepo: "/dev/Flint")))
        XCTAssertEqual(hit.repo, "/dev/Flint")
        XCTAssertEqual(hit.projectID, "flint")
    }

    // MARK: 卡住的排队任务不该把所有平台一起饿死

    private func qTask(_ id: String, state: WorkTask.State,
                       dependsOn: [String] = []) -> WorkTask {
        var t = WorkTask(id: id, prompt: "活 \(id)", repo: "/tmp/x")
        t.state = state
        t.dependsOn = dependsOn
        if !dependsOn.isEmpty { t.graphID = "g1" }
        return t
    }

    /// **派得动的活排着队 → 填活器让开**，别抢调度器的事。
    func testDispatchableQueuedWorkSuppressesFilling() {
        let t = qTask("a", state: .queued)
        XCTAssertTrue(IdleFiller.schedulerWillHandle(t, in: [t]),
                      "没有依赖的排队任务，调度器下一轮就会派 —— 不用填")
    }

    /// **卡住的排队任务不算「会被处理」。**
    ///
    /// 这是 codex 空转 18 天的正面复刻：队列里确实躺着一条活，
    /// 但它的上游没让开、永远派不动。原先的判据只看 `state == .queued`，
    /// 于是填活器认定「调度器会处理」而闭嘴，所有平台跟着一起空转 ——
    /// 两天记了 249 次「没活可填」。
    func testStuckQueuedWorkDoesNotSuppressFilling() {
        let up = qTask("up", state: .running)
        let down = qTask("down", state: .queued, dependsOn: ["up"])
        XCTAssertFalse(IdleFiller.schedulerWillHandle(down, in: [up, down]),
                       "上游没让开，这条永远派不动 —— "
                       + "拿它当「调度器会处理」就是把所有平台一起饿死")
    }

    /// 上游整个没记录 → 同样派不动，同样不该压制填活。
    func testQueuedWithMissingUpstreamDoesNotSuppress() {
        let down = qTask("down", state: .queued, dependsOn: ["ghost"])
        XCTAssertFalse(IdleFiller.schedulerWillHandle(down, in: [down]),
                       "上游记录都没了，「不知道」不该当成「会被处理」")
    }

    /// 跑着的、干完的都不算排队 —— 别把闸做成「什么都压制」。
    func testNonQueuedStatesDoNotSuppress() {
        for st in [WorkTask.State.running, .done, .failed, .blocked] {
            let t = qTask("x", state: st)
            XCTAssertFalse(IdleFiller.schedulerWillHandle(t, in: [t]),
                           "\(st) 不是排队中，不该压制填活")
        }
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

/// MiniMax 的生图额度：要看得见，但不能拦下文本任务。
final class AdvisoryQuotaTests: XCTestCase {
    private func status(label: String, advisory: Bool) -> QuotaStatus {
        QuotaStatus(
            platform: .minimax, planName: "p", limitID: "l", label: label,
            metric: .requests, kind: .periodic, used: 3, limit: 3,
            usedFraction: 1.0, windowStart: Date(),
            resetsAt: Date().addingTimeInterval(3600),
            windowElapsedFraction: 0.5, projectedUsedFraction: 1.0,
            projectedWaste: 0, health: .exhausted, isOfficial: true,
            sourceNote: "test", advisory: advisory)
    }

    /// 视频额度用光了不该把整个平台拦在场外 ——
    /// MiniMax 还是本机的分诊器，冻住它整条调度都受影响。
    func testAdvisoryExhaustionDoesNotBlockDispatch() {
        let video = status(label: "video 1 天", advisory: true)
        let text = status(label: "4 小时", advisory: false)
        XCTAssertNil([video].first { $0.health == .exhausted && !$0.advisory },
                     "video 满了不该算作平台不可用")
        XCTAssertNotNil([video, text].first { $0.health == .exhausted && !$0.advisory },
                        "文本额度真满了还是要拦")
    }

    /// 绝对计数比百分比有用：「还能生几张」vs「已用 58%」。
    func testAbsoluteCountsSurviveIntoStatus() {
        let q = OfficialQuota(
            id: "weekly-video", label: "video 每周", usedPercent: 58,
            windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86400),
            planType: "MiniMax", observedAt: Date(),
            usedCount: 12, totalCount: 21, countUnit: "次", advisory: true)
        XCTAssertEqual(q.usedCount, 12)
        XCTAssertEqual(q.totalCount, 21)
        XCTAssertTrue(q.advisory)
    }
}

/// 推送只喊「真的需要你做决定」的事。
final class NudgeTruthTests: XCTestCase {
    private var sandbox: URL!
    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("nudge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
    }
    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    /// 上游失败连带冻结的下游，**不需要人做任何事**（上游恢复会自动解冻），
    /// 不该被喊成「等你放行」。
    ///
    /// blocked 有两种含义完全相反的来源，WorkTask.frozenBy 就是为了区分
    /// 它们而存在的 —— 而 Nudge 一开始漏用了，于是推送反复喊人去放行
    /// 两个他根本无从操作的任务（App 里连入口都没有）。
    func testAutoFrozenTasksAreNotApprovalRequests() {
        var frozen = WorkTask(id: "t1", prompt: "下游步骤", repo: "/tmp")
        frozen.state = .blocked
        frozen.frozenBy = "t0s3"          // 上游冻的
        var gated = WorkTask(id: "t2", prompt: "碰签名配置的活", repo: "/tmp")
        gated.state = .blocked            // 人工闸门拦的，frozenBy 为 nil
        gated.note = "碰到高危路径（ExportOptions.plist），等你确认"   // 归老板(BossGate)
        // 归 Claude 处置的技术拦截也是 blocked + frozenBy nil,但**不该喊老板**
        // (老板 2026-08-22:「给我应该就是风险类或者验收类」)。口径与 blockedPage
        // 同一份(ViewFeed.awaitsBoss),否则角标有数、页面没卡片。
        var mine = WorkTask(id: "t3", prompt: "改 Tools 脚本的活", repo: "/tmp")
        mine.state = .blocked
        mine.note = "碰到高危路径（Tools/x.sh），等 Claude 处置"
        try? TaskStore.append(frozen)
        try? TaskStore.append(gated)
        try? TaskStore.append(mine)

        let keys = Nudge.pending().map(\.key)
        let blockedItem = Nudge.pending().first { $0.key.hasPrefix("blocked") }
        XCTAssertNotNil(blockedItem, "人工闸门拦下、归老板的那个要喊：\(keys)")
        XCTAssertEqual(blockedItem?.badge, 1,
                       "只该算 1 个（归老板那个），上游冻的和归 Claude 的都不算")
    }

    /// 一个都不需要决定时，一条都不推。
    func testNothingPendingMeansNoPush() {
        var frozen = WorkTask(id: "t1", prompt: "下游", repo: "/tmp")
        frozen.state = .blocked
        frozen.frozenBy = "t0s1"
        try? TaskStore.append(frozen)
        XCTAssertTrue(Nudge.pending().filter { $0.key.hasPrefix("blocked") }.isEmpty,
                      "全是自动冻结的，不该有任何「等你放行」")
    }
}
