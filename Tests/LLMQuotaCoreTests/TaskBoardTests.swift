import XCTest
@testable import LLMQuotaCore

/// 「手机端看不到正在跑的任务」的那份数据。
///
/// 这里守三件会真的咬人的事：
/// 1. 上限砍下来时 `tasksTruncated` 必须置位 —— 静默截断会让手机上的
///    「一共 N 个任务」变成一句没人会去核对的假话。
/// 2. 标题按**字符**截。按字节截会把汉字劈成两半，输出是乱码。
/// 3. 老机器发来的、没有 `tasks` 键的看板还要能解出来 ——
///    解不出来的话手机上不是「少了任务列表」，是**连额度都没了**。
final class TaskBoardTests: XCTestCase {

    // MARK: - 造任务

    private func task(
        _ id: String,
        state: WorkTask.State = .queued,
        prompt: String = "干点活",
        stepTitle: String? = nil,
        repo: String = "/tmp/repo",
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000),
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        platform: Platform? = nil,
        graphID: String? = nil,
        stepIndex: Int? = nil
    ) -> WorkTask {
        var t = WorkTask(id: id, prompt: prompt, repo: repo)
        t.state = state
        t.createdAt = createdAt
        t.startedAt = startedAt
        t.endedAt = endedAt
        t.platform = platform
        t.graphID = graphID
        t.stepIndex = stepIndex
        t.stepTitle = stepTitle
        return t
    }

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func report(_ platform: Platform, health: QuotaHealth,
                        resetsAt: Date? = nil) -> PlatformReport {
        PlatformReport(
            platform: platform, planName: platform.displayName, monthlyCost: nil,
            currency: "CNY", detected: true, installed: true, enabled: true,
            machines: ["M"], lastActivity: now,
            statuses: [QuotaStatus(
                platform: platform, planName: platform.displayName,
                limitID: "test", label: "5 小时", metric: .percent,
                kind: .periodic, used: health == .exhausted ? 100 : 0,
                limit: 100, usedFraction: health == .exhausted ? 1 : 0,
                windowStart: now.addingTimeInterval(-3600), resetsAt: resetsAt,
                windowElapsedFraction: 0.5, projectedUsedFraction: nil,
                projectedWaste: nil, health: health, isOfficial: true,
                sourceNote: "测试")],
            last30dRequests: 0, last30dBillableTokens: 0, last7dRequests: 0,
            topModels: [])
    }

    // MARK: - 截断留痕

    func testCurrentBoardShowsPrimaryWorkInsteadOfFlatteningSupportingEvents() {
        var main = task("main", state: .running, prompt: "完成一项完整功能")
        main.ownerPlatform = .kimi

        var mergeReview = task("review", state: .queued, prompt: "【审查·合入】分支 x")
        mergeReview.origin = "merge-review"

        var architect = task("architect", state: .done, prompt: "【架构复核】给出结论")
        architect.origin = "architect-review:review"
        architect.endedAt = now.addingTimeInterval(-20)

        var frozen = task("frozen", state: .blocked, prompt: "继续旧角色美术")
        frozen.pausedAt = now.addingTimeInterval(-60)
        frozen.note = "本轮停止美术；冻结并保留旧分支"

        // 用户主动建立的独立评审没有机器 origin，仍是一个真正的主任务。
        let manualReview = task("manual", state: .queued, prompt: "【评审】独立安全审计")

        let result = TaskBoard.build(
            from: [main, mergeReview, architect, frozen, manualReview],
            machineName: "M", now: now)

        XCTAssertEqual(Set(result.tasks.map(\.id)), Set(["main", "manual"]))
    }

    func testFocusedBoardHidesPausedOtherProjectButExposesIllegalRunning() {
        let flint = task("flint", state: .running, repo: "/dev/Flint")
        var pausedMaw = task("maw-paused", state: .blocked, repo: "/dev/Maw")
        pausedMaw.pausedAt = now
        let runningMaw = task("maw-running", state: .running, repo: "/dev/Maw")
        let finishedMaw = task("maw-finished", state: .done, repo: "/dev/Maw")

        let result = TaskBoard.build(
            from: [flint, pausedMaw, runningMaw, finishedMaw], machineName: "M",
            executionScope: ProjectExecutionScope(allowedRepo: "/dev/Flint"), now: now)

        XCTAssertEqual(Set(result.tasks.map(\.id)), Set(["flint", "maw-running"]))
    }

    func testTruncationIsFlaggedAndCapped() {
        // 全是活的：61 条排队任务，一条终态都没有。
        let tasks = (0..<61).map {
            task("q\($0)", state: .queued,
                 createdAt: Date(timeIntervalSince1970: 1_000_000 + Double($0)))
        }
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)

        XCTAssertEqual(r.tasks.count, TaskBoard.maxTasks)
        XCTAssertTrue(r.truncated, """
            砍掉了 1 条却没置位 —— 手机上「一共 60 个任务」会变成假话，
            而且是没人会去核对的那种假话
            """)
    }

    func testNotTruncatedWhenExactlyAtLimit() {
        let tasks = (0..<TaskBoard.maxTasks).map {
            task("q\($0)", state: .queued,
                 createdAt: Date(timeIntervalSince1970: 1_000_000 + Double($0)))
        }
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        XCTAssertEqual(r.tasks.count, TaskBoard.maxTasks)
        XCTAssertFalse(r.truncated, "正好装下不算截断，否则界面会一直挂着「还有更多」")
    }

    /// 上限砍的时候，先砍终态 —— 会动的那些必须留住。
    func testLiveTasksSurviveTheCapBeforeFinishedOnes() {
        var tasks = (0..<58).map {
            task("q\($0)", state: .queued,
                 createdAt: Date(timeIntervalSince1970: 1_000_000 + Double($0)))
        }
        tasks.append(task("run", state: .running,
                          startedAt: Date(timeIntervalSince1970: 1_900_000)))
        tasks += (0..<15).map {
            task("d\($0)", state: .done,
                 endedAt: Date(timeIntervalSince1970: 1_500_000 + Double($0)))
        }

        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.tasks.count, 60)
        XCTAssertEqual(r.tasks.first?.id, "run")
        XCTAssertEqual(r.tasks.filter { $0.state == .queued }.count, 58)
        XCTAssertEqual(r.tasks.filter { $0.state == .done }.count, 1,
                       "60 个槽被活任务占了 59 个，终态只该进来 1 条")
    }

    /// 终态只保留最近 15 条 —— 这是**范围**，不是截断，不该置位。
    func testOnlyRecentFinishedAreIncluded() {
        let tasks = (0..<40).map {
            task("d\($0)", state: .done,
                 endedAt: Date(timeIntervalSince1970: 1_500_000 + Double($0)))
        }
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        XCTAssertEqual(r.tasks.count, TaskBoard.recentFinishedCount)
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.tasks.first?.id, "d39", "最近的排最前")
        XCTAssertEqual(r.tasks.last?.id, "d25")
    }

    // MARK: - 标题

    func testTitlePrefersStepTitle() {
        let t = task("a", prompt: "很长很长的完整指令，里面还带着 /Users/someone/dev/x 这种路径",
                     stepTitle: "为 Format.duration 补单元测试")
        XCTAssertEqual(TaskBrief.title(for: t), "为 Format.duration 补单元测试")
    }

    func testTitleFallsBackToFirstLineOfPrompt() {
        let t = task("a", prompt: "改一下 Format.duration\n\n细节：balabala\n还有更多")
        let title = TaskBrief.title(for: t)
        XCTAssertEqual(title, "改一下 Format.duration")
        XCTAssertFalse(title.contains("\n"), "标题里带换行，手机上一行会被撑成一段")
    }

    /// **按字符截，不是按字节。** 中文一个字 3 字节，按字节切必出乱码。
    func testChineseTitleIsClampedByCharactersNotBytes() {
        let raw = String(repeating: "汉", count: 200)
        let title = TaskBrief.title(for: task("a", prompt: raw))

        XCTAssertEqual(title.count, TaskBrief.titleMaxCharacters,
                       "长度要按字符数算，正好卡在上限上")
        XCTAssertEqual(title, String(repeating: "汉", count: 79) + "…")

        // 真正的乱码判定：编码成 UTF-8 再解回来必须一模一样，
        // 且一个替换字符（U+FFFD）都不许出现 —— 那正是被切断的多字节序列的样子。
        let data = Data(title.utf8)
        XCTAssertEqual(String(data: data, encoding: .utf8), title)
        XCTAssertFalse(title.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertGreaterThan(data.count, title.count, "汉字本来就不止一字节，前提没搞错")
    }

    /// emoji 和带修饰符的字素簇也不能被劈开。
    func testGraphemeClustersAreNotSplit() {
        let raw = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let title = TaskBrief.clampTitle(raw)
        XCTAssertEqual(title.count, TaskBrief.titleMaxCharacters)
        XCTAssertEqual(String(data: Data(title.utf8), encoding: .utf8), title)
        XCTAssertFalse(title.unicodeScalars.contains("\u{FFFD}"))
    }

    func testShortTitleIsUntouched() {
        XCTAssertEqual(TaskBrief.clampTitle("短标题"), "短标题")
    }

    func testBlankPromptStillGetsATitle() {
        let t = task("e048033c", prompt: "\n   \n")
        XCTAssertFalse(TaskBrief.title(for: t).trimmingCharacters(in: .whitespaces).isEmpty,
                       "手机上一行空白比什么都不显示更糟")
    }

    /// 整份看板里**任何一条**标题都不许超上限 —— 这条是给组装路径把关的，
    /// 光测 clampTitle 管不住「谁忘了调它」。
    func testEveryTitleInBoardRespectsTheLimit() {
        let tasks = [
            task("a", prompt: String(repeating: "汉", count: 500)),
            task("b", state: .running, prompt: String(repeating: "x", count: 500),
                 startedAt: now),
            task("c", state: .done, stepTitle: String(repeating: "步", count: 300),
                 endedAt: now),
        ]
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        for b in r.tasks {
            XCTAssertLessThanOrEqual(b.title.count, TaskBrief.titleMaxCharacters, b.id)
        }
    }

    // MARK: - 排序和字段

    func testOrderIsRunningThenQueuedThenBlockedThenFinished() {
        let tasks = [
            task("d", state: .done, endedAt: Date(timeIntervalSince1970: 1_800_000)),
            task("b", state: .blocked, createdAt: Date(timeIntervalSince1970: 1_000_001)),
            task("q", state: .queued, createdAt: Date(timeIntervalSince1970: 1_000_002)),
            task("r", state: .running, startedAt: Date(timeIntervalSince1970: 1_900_000)),
        ]
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        XCTAssertEqual(r.tasks.map(\.id), ["r", "q", "b", "d"])
    }

    func testBlockedTaskExposesStructuredWaitReasonToMobile() throws {
        var t = task("blocked", state: .blocked)
        t.waitReason = .dependency

        let result = TaskBoard.build(from: [t], machineName: "M", now: now)
        let brief = try XCTUnwrap(result.tasks.first)

        XCTAssertEqual(brief.waitReason, .dependency)
        XCTAssertEqual(brief.progressPhase, "等待上游任务")

        let roundTrip = try JSONDecoder().decode(
            TaskBrief.self, from: JSONEncoder().encode(brief))
        XCTAssertEqual(roundTrip.waitReason, .dependency)
    }

    func testLongestRunningComesFirst() {
        let tasks = [
            task("young", state: .running, startedAt: Date(timeIntervalSince1970: 1_999_000)),
            task("old", state: .running, startedAt: Date(timeIntervalSince1970: 1_000_100)),
        ]
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        XCTAssertEqual(r.tasks.first?.id, "old", "跑得最久的（可能卡住了）最该被看见")
    }

    func testElapsedAndMachineName() {
        let t = task("r", state: .running,
                     startedAt: now.addingTimeInterval(-273), platform: .claude)
        let r = TaskBoard.build(from: [t], machineName: "杜师兵的Mac mini", now: now)
        let b = try? XCTUnwrap(r.tasks.first)
        XCTAssertEqual(b?.elapsedSeconds, 273)
        XCTAssertEqual(b?.machineName, "杜师兵的Mac mini")
        XCTAssertEqual(b?.platform, .claude)
        XCTAssertEqual(b?.state, .running)
    }

    func testFinishedTaskReportsTotalRuntimeNotTimeSinceStart() {
        let t = task("d", state: .done,
                     startedAt: now.addingTimeInterval(-10_000),
                     endedAt: now.addingTimeInterval(-9_400))
        let r = TaskBoard.build(from: [t], machineName: "M", now: now)
        XCTAssertEqual(r.tasks.first?.elapsedSeconds, 600)
    }

    func testDoneButUnlandedTaskShowsDeliveryStateInsteadOfStaleProgress() throws {
        var t = task("waiting", state: .done, endedAt: now.addingTimeInterval(-60))
        t.branch = "agent/kimi/waiting"
        t.changedFiles = 20
        t.note = "架构师已放行隔离分支"
        let stale = WorkProgress(
            taskID: t.id, sequence: 8, phase: "等待架构师技术处置",
            summary: "旧阻塞快照", nextStep: "等待处置", evidence: [],
            evidenceFingerprint: "old", updatedAt: now.addingTimeInterval(-120))

        let result = TaskBoard.build(
            from: [t], machineName: "M",
            progressByTaskID: [t.id: stale], now: now)
        let brief = try XCTUnwrap(result.tasks.first)

        XCTAssertEqual(brief.progressPhase, "等待合入")
        XCTAssertTrue(brief.progressSummary?.contains("已放行") == true)
        XCTAssertTrue(brief.progressNextStep?.contains("main") == true)
        XCTAssertFalse(brief.progressSummary?.contains("旧阻塞") == true)
    }

    func testLandedTaskShowsLandedStateInsteadOfStaleProgress() throws {
        var t = task("landed", state: .done, endedAt: now.addingTimeInterval(-60))
        t.branch = "agent/kimi/landed"
        t.changedFiles = 3
        t.landedAt = now.addingTimeInterval(-30)
        t.note = "已合入 main"
        let stale = WorkProgress(
            taskID: t.id, sequence: 2, phase: "正在整改",
            summary: "旧进度", nextStep: "继续修改", evidence: [],
            evidenceFingerprint: "old", updatedAt: now.addingTimeInterval(-120))

        let result = TaskBoard.build(
            from: [t], machineName: "M",
            progressByTaskID: [t.id: stale], now: now)
        let brief = try XCTUnwrap(result.tasks.first)

        XCTAssertEqual(brief.progressPhase, "已合入 main")
        XCTAssertEqual(brief.progressSummary, "已合入 main")
        XCTAssertNil(brief.progressNextStep)
    }

    /// 排队中的任务身上可能挂着**上一轮**的 startedAt（重排、接力过的）。
    /// 照发的话手机上会显示「已经跑了 11 天」——一个在排队的任务。
    func testQueuedTaskDoesNotReportStaleElapsed() {
        let t = task("q", state: .queued, startedAt: Date(timeIntervalSince1970: 1_000_000))
        let r = TaskBoard.build(from: [t], machineName: "M", now: now)
        XCTAssertNil(r.tasks.first?.elapsedSeconds)
        XCTAssertNil(r.tasks.first?.startedAt)
    }

    func testQueuedOwnerQuotaWaitExplainsWhyRecoveredQwenDoesNotTakeOver() throws {
        var t = task("74726e09", state: .queued)
        t.ownerPlatform = .minimax
        t.ownerRunnerID = "minimax.code"
        let r = TaskBoard.build(
            from: [t], machineName: "M",
            platformReports: [
                report(.minimax, health: .exhausted,
                       resetsAt: now.addingTimeInterval(3 * 3600)),
                report(.qwen, health: .unconfigured),
            ], now: now)
        let brief = try XCTUnwrap(r.tasks.first)
        XCTAssertEqual(brief.progressPhase, "排队 · 等待 MiniMax 额度恢复")
        XCTAssertTrue(brief.progressSummary?.contains("Qwen 额度已恢复") == true)
        XCTAssertTrue(brief.progressSummary?.contains("minimax.code") == true)
        XCTAssertTrue(brief.progressNextStep?.contains("显式交接") == true)
    }

    func testStepTotalIsCountedByGraphID() {
        let tasks = [
            task("n1", state: .running, startedAt: now, graphID: "42266d0f", stepIndex: 0),
            task("n2", graphID: "42266d0f", stepIndex: 1),
            task("n3", graphID: "42266d0f", stepIndex: 2),
            task("m1", graphID: "other", stepIndex: 0),
            task("solo"),
        ]
        let r = TaskBoard.build(from: tasks, machineName: "M", now: now)
        var byID: [String: TaskBrief] = [:]
        for b in r.tasks { byID[b.id] = b }
        XCTAssertEqual(byID["n1"]?.stepTotal, 3)
        XCTAssertEqual(byID["n2"]?.stepTotal, 3)
        XCTAssertEqual(byID["m1"]?.stepTotal, 1)
        XCTAssertNil(byID["solo"]?.stepTotal, "不属于任何图的任务不该有步数")
        XCTAssertEqual(byID["n2"]?.stepIndex, 1)
    }

    /// 手机上不该出现 `/Users/<你>/...`：又长，在别的机器上还不一样。
    func testRepoAliasReplacesAbsolutePath() {
        var alias = RepoAlias(alias: "llmq", path: "/Users/x/dev/LLMQuotaBar")
        alias.pathByMachine = [Paths.machineName(): "/Users/x/dev/LLMQuotaBar"]
        let t = task("a", repo: "/Users/x/dev/LLMQuotaBar")
        let r = TaskBoard.build(from: [t], machineName: "M", repoAliases: [alias], now: now)
        XCTAssertEqual(r.tasks.first?.repoAlias, "llmq")

        let unknown = TaskBoard.build(from: [task("b", repo: "/tmp/other")],
                                      machineName: "M", repoAliases: [alias], now: now)
        XCTAssertNil(unknown.tasks.first?.repoAlias, "认不出来就别编一个别名出来")
    }

    /// 发出去的东西里不许夹带 prompt 全文，也不许有 `repo` 那个绝对路径字段。
    ///
    /// **注意这条守不住什么**：prompt 前 80 个字符里如果就写着一个绝对路径，
    /// 它会跟着标题一起过去。`TaskBrief` 是一份窄投影，不是脱敏器 ——
    /// 真要干净的标题就给任务写 `stepTitle`（拆解出来的图节点都有）。
    func testBriefCarriesNeitherFullPromptNorRepoPath() throws {
        let secret = "/Users/someone/Documents/秘密项目"
        let t = task("a", prompt: """
            \(String(repeating: "细节", count: 200))，顺便看看 \(secret)
            """,
            repo: secret)
        let r = TaskBoard.build(from: [t], machineName: "M", now: now)
        let json = String(decoding: try SnapshotCoding.encoder().encode(r.tasks),
                          as: UTF8.self)

        XCTAssertFalse(json.contains(secret),
                       "80 字之外的路径不该跟着漏出去，而 repo 字段根本就不在这份投影里")
        XCTAssertFalse(json.contains("\"repo\""))
        XCTAssertFalse(json.contains("\"prompt\""))
        XCTAssertLessThan(json.count, 500, "一条 brief 不该有 prompt 全文那么大")
    }

    // MARK: - 兼容老看板

    /// 老 Mac 发的看板里没有 `tasks` / `tasksTruncated` 这两个键。
    /// 合成解码器遇到缺键会抛 `keyNotFound`，**整份看板都解不出来** ——
    /// 手机上不是「少了任务列表」，是连额度都没了。
    func testDashboardWithoutTasksKeyStillDecodes() throws {
        let full = Dashboard(generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             machines: [MachineInfo(machineID: "id", machineName: "老 Mac",
                                                    lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
                                                    isStale: false)],
                             reports: [])
        let data = try SnapshotCoding.encoder().encode(full)
        var obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "tasks")
        obj.removeValue(forKey: "tasksTruncated")
        XCTAssertNil(obj["tasks"])

        let legacy = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try SnapshotCoding.decoder().decode(Dashboard.self, from: legacy)

        XCTAssertEqual(decoded.tasks, [])
        XCTAssertFalse(decoded.tasksTruncated)
        XCTAssertEqual(decoded.machines.first?.machineName, "老 Mac")
    }

    func testDashboardTasksRoundTrip() throws {
        let brief = TaskBrief(id: "e048033c", title: "为 Format.duration 补单元测试",
                              state: .running, platform: .claude,
                              machineName: "杜师兵的Mac mini",
                              startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              elapsedSeconds: 273, graphID: "42266d0f",
                              stepIndex: 1, stepTotal: 3, repoAlias: "llmq")
        let dash = Dashboard(generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                             machines: [], reports: [], tasks: [brief], tasksTruncated: true)
        let data = try SnapshotCoding.encoder().encode(dash)
        let back = try SnapshotCoding.decoder().decode(Dashboard.self, from: data)
        XCTAssertEqual(back.tasks, [brief])
        XCTAssertTrue(back.tasksTruncated)
    }

    /// 一条 brief 里缺可选字段（老版本 Mac 发的），不能带崩整个数组。
    func testTaskBriefTolerantOfMissingOptionalFields() throws {
        let json = """
        {"id":"abc","title":"只有必需字段","state":"running","machineName":"M"}
        """
        let b = try SnapshotCoding.decoder().decode(TaskBrief.self, from: Data(json.utf8))
        XCTAssertEqual(b.id, "abc")
        XCTAssertEqual(b.state, .running)
        XCTAssertNil(b.platform)
        XCTAssertNil(b.stepTotal)
    }

    /// 将来 Mac 侧加了新状态，老客户端要还能显示，而不是整份看板解不出来。
    func testUnknownStateDegradesInsteadOfThrowing() throws {
        let json = """
        {"id":"abc","title":"t","state":"teleporting","machineName":"M"}
        """
        let b = try SnapshotCoding.decoder().decode(TaskBrief.self, from: Data(json.utf8))
        XCTAssertEqual(b.state, .queued)
    }

    // MARK: - 真的接进看板了

    func testBuildDashboardCarriesTasks() {
        let engine = QuotaEngine(config: PlansConfig.template())
        let tasks = [
            task("r", state: .running, stepTitle: "跑着的那个", startedAt: now.addingTimeInterval(-60)),
            task("q"),
        ]
        let dash = engine.buildDashboard(snapshots: [], now: now, tasks: tasks,
                                         machineName: "杜师兵的Mac mini", repoAliases: [])
        XCTAssertEqual(dash.tasks.map(\.id), ["r", "q"])
        XCTAssertEqual(dash.tasks.first?.title, "跑着的那个")
        XCTAssertEqual(dash.tasks.first?.machineName, "杜师兵的Mac mini")
        XCTAssertFalse(dash.tasksTruncated)
    }
}
