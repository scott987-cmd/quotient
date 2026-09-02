import XCTest
@testable import LLMQuotaCore

final class ContextAffinityTests: XCTestCase {
    func test恢复中的上下文超限会作废旧会话() {
        let error = "ellm.BadRequestError: context window exceeded"
        XCTAssertTrue(GraphSession.shouldInvalidate(
            output: error, timedOut: false, wasResuming: true))
        XCTAssertFalse(GraphSession.shouldInvalidate(
            output: error, timedOut: false, wasResuming: false))
        XCTAssertFalse(GraphSession.shouldInvalidate(
            output: error, timedOut: true, wasResuming: true))
    }

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-affinity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Paths.appSupportOverride = scratch
        GraphSession.fileOverride = scratch.appendingPathComponent("sessions.json")
        WorkAttemptStore.fileOverride = scratch.appendingPathComponent("attempts.jsonl")
    }

    override func tearDown() {
        MiniMaxCodeRunner.configPathOverride = nil
        GraphSession.fileOverride = nil
        WorkAttemptStore.fileOverride = nil
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testRunnerIdentityAndSessionSupportAreExplicit() {
        let runners = RunnerRegistry.all
        XCTAssertEqual(Set(runners.map(\.runnerID)).count, runners.count)
        XCTAssertEqual(ClaudeRunner().sessionSupport, .stableID)
        XCTAssertEqual(QwenRunner().sessionSupport, .projectLatest)
        XCTAssertEqual(ZcodeRunner().sessionSupport, .reportedID)
        XCTAssertEqual(KimiRunner().sessionSupport, .projectLatest)
        XCTAssertEqual(CodexRunner().sessionSupport, .projectLatest)
        XCTAssertEqual(OpenCodeRunner().sessionSupport, .projectLatest)
        XCTAssertEqual(MiniMaxCodeRunner().sessionSupport, .stableID)
        XCTAssertNotEqual(MiniMaxMediaRunner().runnerID, MiniMaxReviewRunner().runnerID)
    }

    func testMiniMaxCodeUsesTokenPlanEndpointAndClaudeToolShell() throws {
        let config = scratch.appendingPathComponent("mmx.json")
        try Data(#"{"region":"cn","api_key":"test-key"}"#.utf8)
            .write(to: config)
        MiniMaxCodeRunner.configPathOverride = config.path

        let command = MiniMaxCodeRunner().command(
            prompt: "继续", cwd: "/tmp/flint", session: .create("session-1"))

        XCTAssertEqual(command.env["ANTHROPIC_BASE_URL"],
                       "https://api.minimaxi.com/anthropic")
        XCTAssertEqual(command.env["ANTHROPIC_AUTH_TOKEN"], "test-key")
        XCTAssertEqual(command.env["ANTHROPIC_API_KEY"], "")
        XCTAssertTrue(command.args.contains("MiniMax-M3"))
        XCTAssertTrue(command.args.contains("--session-id"))
        XCTAssertTrue(command.args.contains("session-1"))
        XCTAssertTrue(MiniMaxCodeRunner().canReadFiles)
        XCTAssertTrue(MiniMaxCodeRunner().canEdit)
    }

    func testStableSessionsAreTaskScopedWithinTheAgentWorkspace() {
        let a = GraphSession.Context(taskID: "task-a", graphID: nil,
                                     capability: .coding, runnerID: "claude.code",
                                     machineID: "machine")
        let b = GraphSession.Context(taskID: "task-b", graphID: nil,
                                     capability: .coding, runnerID: "claude.code",
                                     machineID: "machine")
        guard case .create(let aid) = GraphSession.mode(
            context: a, support: .stableID, workspace: "/tmp/repo")
        else { return XCTFail("task-a 首次应创建会话") }
        guard case .create(let bid) = GraphSession.mode(
            context: b, support: .stableID, workspace: "/tmp/repo")
        else { return XCTFail("同一 Agent 工作区的新任务应创建轻量会话") }
        XCTAssertNotEqual(bid, aid)
        XCTAssertEqual(GraphSession.mode(
            context: a, support: .stableID, workspace: "/tmp/repo"), .resume(aid))

        guard case .create(let otherID) = GraphSession.mode(
            context: b, support: .stableID, workspace: "/tmp/other-repo")
        else { return XCTFail("不同项目工作区不能串会话") }
        XCTAssertNotEqual(otherID, aid)

        GraphSession.forget(context: a, workspace: "/tmp/repo")
        guard case .create = GraphSession.mode(
            context: a, support: .stableID, workspace: "/tmp/repo")
        else { return XCTFail("项目会话失效后应新建") }
        guard case .resume = GraphSession.mode(
            context: b, support: .stableID, workspace: "/tmp/other-repo")
        else { return XCTFail("清理一个项目不能误伤另一个项目") }
    }

    func testUnsupportedRunnerNeverCreatesSessionState() {
        let c = GraphSession.Context(taskID: "task", graphID: nil,
                                     capability: .coding, runnerID: "kimi.code",
                                     machineID: "machine")
        XCTAssertEqual(GraphSession.mode(
            context: c, support: .none, workspace: "/tmp/repo"), .fresh)
        XCTAssertTrue(GraphSession.load().isEmpty)
    }

    func testProjectLatestResumesOnlyTheSameTask() {
        let a = GraphSession.Context(taskID: "task-a", graphID: nil,
                                     capability: .coding, runnerID: "qwen.code",
                                     machineID: "machine")
        let b = GraphSession.Context(taskID: "task-b", graphID: nil,
                                     capability: .coding, runnerID: "qwen.code",
                                     machineID: "machine")
        XCTAssertEqual(GraphSession.mode(
            context: a, support: .projectLatest, workspace: "/tmp/shared"), .fresh)
        GraphSession.markLaunched(context: a, support: .projectLatest,
                                  workspace: "/tmp/shared")
        XCTAssertEqual(GraphSession.mode(
            context: a, support: .projectLatest, workspace: "/tmp/shared"), .projectResume)
        XCTAssertEqual(GraphSession.mode(
            context: b, support: .projectLatest, workspace: "/tmp/shared"), .fresh)
        XCTAssertEqual(GraphSession.mode(
            context: b, support: .projectLatest, workspace: "/tmp/other"), .fresh)
    }

    func testLegacyRepoAffinityDoesNotLeakIntoANewTask() throws {
        let context = GraphSession.Context(
            taskID: "new-task", graphID: nil, capability: .coding,
            runnerID: "kimi.code", machineID: "machine")
        let legacy = ["repo:/tmp/flint|kimi": "old-project-marker"]
        try JSONEncoder().encode(legacy).write(to: GraphSession.fileOverride!)

        XCTAssertEqual(GraphSession.mode(
            context: context, support: .projectLatest,
            workspace: "/tmp/flint-kimi"), .fresh)
    }

    func testGraphStepsShareOnlyTheirGraphSession() {
        let a = GraphSession.Context(taskID: "g-step-1", graphID: "graph-1",
                                     capability: .coding, runnerID: "kimi.code",
                                     machineID: "machine")
        let b = GraphSession.Context(taskID: "g-step-2", graphID: "graph-1",
                                     capability: .coding, runnerID: "kimi.code",
                                     machineID: "machine")
        let other = GraphSession.Context(taskID: "g-step-1", graphID: "graph-2",
                                         capability: .coding, runnerID: "kimi.code",
                                         machineID: "machine")
        XCTAssertEqual(GraphSession.mode(
            context: a, support: .projectLatest, workspace: "/tmp/shared"), .fresh)
        GraphSession.markLaunched(context: a, support: .projectLatest,
                                  workspace: "/tmp/shared")
        XCTAssertEqual(GraphSession.mode(
            context: b, support: .projectLatest, workspace: "/tmp/shared"), .projectResume)
        XCTAssertEqual(GraphSession.mode(
            context: other, support: .projectLatest, workspace: "/tmp/shared"), .fresh)
    }

    func testResetSessionAlsoRemovesLegacySourceSoItCannotResurrect() throws {
        let context = GraphSession.Context(
            taskID: "takeover", graphID: nil, capability: .coding,
            runnerID: "opencode.volcark.code", machineID: "machine")
        let legacy = ["repo:/tmp/flint|volcark": "old-project-marker"]
        try JSONEncoder().encode(legacy).write(to: GraphSession.fileOverride!)
        GraphSession.forget(
            context: context, workspace: "/tmp/flint-volcark",
            repo: "/tmp/flint", platform: .volcark)

        XCTAssertEqual(GraphSession.mode(
            context: context, support: .projectLatest,
            workspace: "/tmp/flint-volcark"), .fresh)
    }

    func testQwenUsesProjectResumeOnlyWhenRequested() {
        let fresh = QwenRunner().command(prompt: "p", cwd: "/tmp", session: .fresh).args
        let resume = QwenRunner().command(
            prompt: "p", cwd: "/tmp", session: .projectResume).args
        XCTAssertFalse(fresh.contains("-c"))
        XCTAssertTrue(resume.contains("-c"))
    }

    func testKimiUsesProjectResumeOnlyWhenRequested() {
        let fresh = KimiRunner().command(prompt: "p", cwd: "/tmp", session: .fresh).args
        let resume = KimiRunner().command(
            prompt: "p", cwd: "/tmp", session: .projectResume).args
        XCTAssertFalse(fresh.contains("-c"))
        XCTAssertTrue(resume.contains("-c"))
    }

    func testCodexUsesProjectResumeOnlyWhenRequested() {
        let fresh = CodexRunner().command(prompt: "p", cwd: "/tmp", session: .fresh).args
        let resume = CodexRunner().command(
            prompt: "p", cwd: "/tmp", session: .projectResume).args
        XCTAssertFalse(fresh.contains("resume"))
        XCTAssertTrue(resume.starts(with: ["exec", "--approve-for-me", "resume", "--last"]),
                      "exec 级选项必须放在 resume 子命令前；resume 自己不认识该选项")
    }

    func testOpenCodeUsesProjectResumeOnlyWhenRequested() {
        let fresh = OpenCodeRunner().command(prompt: "p", cwd: "/tmp", session: .fresh).args
        let resume = OpenCodeRunner().command(
            prompt: "p", cwd: "/tmp", session: .projectResume).args
        XCTAssertFalse(fresh.contains("-c"))
        XCTAssertTrue(resume.contains("-c"))
    }

    func testRetiredOxAlphaRunnerCannotBeCalledOrRegistered() {
        let runner = OpenCodeRunner(platform: .openrouter)
        let command = runner.command(prompt: "继续", cwd: "/tmp", session: .fresh)
        XCTAssertEqual(runner.runnerID, "opencode.openrouter.code")
        XCTAssertNil(runner.binaryPath)
        XCTAssertEqual(command.launchPath, "/usr/bin/false")
        XCTAssertTrue(command.args.isEmpty)
        XCTAssertFalse(RunnerRegistry.all.contains { $0.platform == .openrouter })
        XCTAssertFalse(RunnerRegistry.reasoning.contains { $0.platform == .openrouter })
        XCTAssertFalse(AgentRoles.defaults().contains { $0.platform == .openrouter })
        XCTAssertFalse(AgentConsultation.supportsReadOnlyConsultation(runner),
                       "退役 Runner 不能从只读咨询旁路重新执行")
        XCTAssertNil(RunnerConfig(models: ["openrouter": "openrouter/stealth/ox-alpha"])
            .model(for: .openrouter))
    }

    func testVolcarkRunnerPinsGatewayCodingModel() {
        let command = OpenCodeRunner(platform: .volcark)
            .command(prompt: "继续", cwd: "/tmp", session: .fresh)
        XCTAssertTrue(command.args.contains("gateway/volc-coding"))
    }

    func testOtherOpenCodeProvidersDoNotReceiveOxVisionGuard() {
        let prompt = OpenCodeRunner(platform: .volcark)
            .command(prompt: "查看截图后修复", cwd: "/tmp").args.last ?? ""
        XCTAssertFalse(prompt.contains("不要直接读取图片或视频文件"))
    }

    func testOpenCodeCredentialCheckOnlyNeedsProviderEntry() throws {
        let file = scratch.appendingPathComponent("opencode-auth.json")
        try Data(#"{"openrouter":{"type":"api","key":"secret-not-read"}}"#.utf8)
            .write(to: file)
        XCTAssertTrue(OpenCodeCredentials.hasProvider("openrouter", file: file))
        XCTAssertFalse(OpenCodeCredentials.hasProvider("gateway", file: file))
    }

    func testReportedSessionIDIsNeverInvented() {
        let context = GraphSession.Context(
            taskID: "z", graphID: nil, capability: .coding,
            runnerID: "zcode.code", machineID: "machine")
        XCTAssertEqual(GraphSession.mode(
            context: context, support: .reportedID, workspace: "/tmp/z"), .fresh)
        XCTAssertNil(ZcodeRunner().discoveredSessionID(from: "ordinary output"))
        XCTAssertNil(ZcodeRunner().discoveredSessionID(
            from: "edited fixture value sess_not-a-real-report"))
        let real = ZcodeRunner().discoveredSessionID(
            from: "created session sess_abc-123; keep working")
        XCTAssertEqual(real, "sess_abc-123")
        GraphSession.rememberReportedID(context: context, id: real!)
        XCTAssertEqual(GraphSession.mode(
            context: context, support: .reportedID, workspace: "/tmp/z"),
            .resume("sess_abc-123"))
    }

    func testSessionFailureDetectionDoesNotEraseOnOrdinaryFailure() {
        XCTAssertTrue(GraphSession.isSessionFailure("conversation not found"))
        XCTAssertTrue(GraphSession.isSessionFailure("invalid session id"))
        XCTAssertFalse(GraphSession.isSessionFailure("build failed: symbol not found"))
        XCTAssertFalse(GraphSession.isSessionFailure("request timed out"))
        XCTAssertFalse(GraphSession.shouldInvalidate(
            output: "earlier reasoning mentioned invalid session id",
            timedOut: true, wasResuming: true),
            "超时日志里碰巧出现会话错误词，不能销毁仍可恢复的上下文")
        XCTAssertTrue(GraphSession.shouldInvalidate(
            output: "invalid session id", timedOut: false, wasResuming: true))
    }

    func testOwnerRetryOnlyUsesRemainingOverallBudget() {
        XCTAssertEqual(ContextAffinityPolicy.cappedAttemptTimeout(
            requested: 5_400, totalBudget: 5_700, elapsed: 5_401), 299)
        XCTAssertEqual(ContextAffinityPolicy.cappedAttemptTimeout(
            requested: 5_400, totalBudget: 5_700, elapsed: 5_800), 0)
    }

    func testGraphCapabilityLaneInheritsItsOwnOwner() {
        var coding = WorkTask(id: "g1s1", prompt: "改代码", repo: "/tmp/repo")
        coding.graphID = "g1"
        coding.ownerPlatform = .qwen
        coding.ownerRunnerID = "qwen.code"
        coding.ownerAssignedAt = Date(timeIntervalSince1970: 1)

        var media = WorkTask(id: "g1s2", prompt: "【媒体】生成图片", repo: "/tmp/repo")
        media.graphID = "g1"
        media.ownerPlatform = .minimax
        media.ownerRunnerID = "minimax.media"
        media.ownerAssignedAt = Date(timeIntervalSince1970: 2)

        var nextCoding = WorkTask(id: "g1s3", prompt: "接入图片", repo: "/tmp/repo")
        nextCoding.graphID = "g1"
        XCTAssertEqual(TaskGraph.inheritedOwner(for: nextCoding, in: [coding, media])?.runnerID,
                       "qwen.code")

        var nextMedia = WorkTask(id: "g1s4", prompt: "【媒体】补一张图", repo: "/tmp/repo")
        nextMedia.graphID = "g1"
        XCTAssertEqual(TaskGraph.inheritedOwner(for: nextMedia, in: [coding, media])?.runnerID,
                       "minimax.media")
    }

    func testGraphCapabilityLanesHaveIsolatedSessions() {
        let coding = GraphSession.Context(
            taskID: "g1s1", graphID: "g1", capability: .coding,
            runnerID: "claude.code", machineID: "machine")
        let media = GraphSession.Context(
            taskID: "g1s2", graphID: "g1", capability: .media,
            runnerID: "claude.code", machineID: "machine")
        XCTAssertNotEqual(coding.storageKey, media.storageKey)

        guard case .create(let codingID) = GraphSession.mode(
            context: coding, support: .stableID, workspace: "/tmp/g1")
        else { return XCTFail("编码泳道首次运行应创建会话") }
        guard case .create(let mediaID) = GraphSession.mode(
            context: media, support: .stableID, workspace: "/tmp/g1")
        else { return XCTFail("媒体泳道不能恢复编码泳道的会话") }
        XCTAssertNotEqual(codingID, mediaID)
        XCTAssertEqual(GraphSession.mode(
            context: coding, support: .stableID, workspace: "/tmp/g1"),
            .resume(codingID))
        XCTAssertEqual(GraphSession.mode(
            context: media, support: .stableID, workspace: "/tmp/g1"),
            .resume(mediaID))
    }

    func testOwnerFieldsDecodeFromOldJSON() throws {
        let raw = #"{"id":"old","prompt":"p","repo":"/tmp/r","state":"queued","createdAt":"2026-08-24T00:00:00Z"}"#
        let task = try SnapshotCoding.decoder().decode(WorkTask.self, from: Data(raw.utf8))
        XCTAssertNil(task.ownerPlatform)
        XCTAssertNil(task.ownerRunnerID)
        XCTAssertEqual(task.handoffCount, 0)
        XCTAssertEqual(task.automaticHandoffCount, 0)
    }

    func testAttemptsPreserveIntermediateTimeout() throws {
        let first = WorkAttempt(taskID: "t", runnerID: "qwen.code", platform: .qwen,
                                startedAt: Date(timeIntervalSince1970: 1),
                                endedAt: Date(timeIntervalSince1970: 2),
                                outcome: .failed, failureKind: "timedOut", timedOut: true)
        let second = WorkAttempt(taskID: "t", runnerID: "kimi.code", platform: .kimi,
                                 startedAt: Date(timeIntervalSince1970: 3),
                                 endedAt: Date(timeIntervalSince1970: 4),
                                 outcome: .done, timedOut: false)
        try WorkAttemptStore.append(first)
        try WorkAttemptStore.append(second)

        let all = WorkAttemptStore.all()
        XCTAssertEqual(all.count, 2)
        let storedFirst = try XCTUnwrap(all.first)
        let storedSecond = try XCTUnwrap(all.dropFirst().first)
        XCTAssertTrue(storedFirst.timedOut)
        XCTAssertEqual(storedSecond.outcome, .done)
        let metrics = WorkAttemptMetrics.summarize(all)
        XCTAssertEqual(metrics.recovery.handoffAttempts, 1)
        XCTAssertEqual(metrics.recovery.handoffSuccesses, 1)
        XCTAssertEqual(metrics.recovery.sameOwnerAttempts, 0)
    }

    func testRunningAndTerminalEventsCountAsOneAttempt() throws {
        let id = "attempt-1"
        let running = WorkAttempt(
            attemptID: id, taskID: "t", runnerID: "qwen.code", platform: .qwen,
            startedAt: Date(timeIntervalSince1970: 1), outcome: .running,
            timedOut: false)
        var terminal = running
        terminal.endedAt = Date(timeIntervalSince1970: 2)
        terminal.outcome = .failed
        terminal.failureKind = "interrupted"

        try WorkAttemptStore.append(running)
        XCTAssertEqual(WorkAttemptStore.unresolvedRunning(taskID: "t").map(\.attemptID), [id])
        try WorkAttemptStore.append(terminal)
        XCTAssertTrue(WorkAttemptStore.unresolvedRunning(taskID: "t").isEmpty)

        let metrics = WorkAttemptMetrics.summarize(WorkAttemptStore.all())
        XCTAssertEqual(metrics.groups.count, 1)
        XCTAssertEqual(metrics.groups.first?.attempts, 1)
        XCTAssertEqual(metrics.groups.first?.successes, 0)
    }

    func testOwnerCanRetryEvenWhenItsPlatformIsInTriedPlatforms() {
        struct Stub: AgentRunner {
            let platform: Platform = .qwen
            let runnerID = "test.qwen.owner"
            let binaryName = "echo"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/bin/echo", [prompt], [:])
            }
        }
        var task = WorkTask(id: "owned", prompt: "改代码", repo: "/tmp/repo")
        task.ownerPlatform = .qwen
        task.ownerRunnerID = "test.qwen.owner"
        task.triedPlatforms = [.qwen]
        let dashboard = Dashboard(generatedAt: Date(), machines: [], reports: [
            PlatformReport(platform: .qwen, planName: "test", monthlyCost: nil,
                           currency: "CNY", detected: true, machines: ["本机"],
                           lastActivity: nil, statuses: [], last30dRequests: 0,
                           last30dBillableTokens: 0, last7dRequests: 0, topModels: [])
        ])
        let decision = WorkScheduler().decide(
            dashboard: dashboard, runners: [Stub()], task: task)
        XCTAssertEqual(decision.pick?.runner.runnerID, "test.qwen.owner")
    }

    func testSamePlatformRetryPinsLegacyTaskToItsOriginalRunner() throws {
        struct Stub: AgentRunner {
            let platform: Platform
            let runnerID: String
            let binaryName = "echo"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/bin/echo", [prompt], [:])
            }
        }
        var task = WorkTask(id: "legacy", prompt: "改玩法代码", repo: "/tmp/repo")
        task.platform = .kimi
        task.triedPlatforms = [.kimi]
        let runners: [AgentRunner] = [
            Stub(platform: .kimi, runnerID: "kimi.code"),
            Stub(platform: .minimax, runnerID: "minimax.code"),
        ]

        let owner = try XCTUnwrap(ContextAffinityPolicy.samePlatformRetryOwner(
            for: task, runners: runners))

        XCTAssertEqual(owner.runnerID, "kimi.code")
        XCTAssertEqual(owner.platform, .kimi)
    }

    func testDifferentOwnerRetryClearsEveryAffinityField() {
        var task = WorkTask(id: "retry", prompt: "继续实现", repo: "/tmp/repo")
        task.ownerPlatform = .kimi
        task.ownerRunnerID = "kimi.code"
        task.ownerAssignedAt = Date()
        task.platform = .kimi
        task.preferredPlatform = .kimi
        task.triedPlatforms = [.kimi, .qwen]

        ContextAffinityPolicy.prepareForDifferentOwner(task: &task)

        XCTAssertNil(task.ownerPlatform)
        XCTAssertNil(task.ownerRunnerID)
        XCTAssertNil(task.ownerAssignedAt)
        XCTAssertNil(task.platform)
        XCTAssertNil(task.preferredPlatform)
        XCTAssertTrue(task.triedPlatforms.isEmpty)
    }

    func testProcessTreeFindsAllDescendantsWithoutTouchingSiblings() {
        let parents: [Int32: Int32] = [
            20: 10, 30: 20, 40: 30,
            21: 10, 50: 99,
        ]

        XCTAssertEqual(Proc.descendants(of: 10, parents: parents), [20, 21, 30, 40])
        XCTAssertFalse(Proc.descendants(of: 10, parents: parents).contains(50))
        XCTAssertTrue(Proc.descendants(of: 0, parents: parents).isEmpty,
                      "0 代表进程组，绝不能作为清理根节点")
    }

    func testUnknownRunnerMigrationRefusesAmbiguousGuess() {
        struct Stub: AgentRunner {
            let runnerID: String
            let platform: Platform = .minimax
            let binaryName = "echo"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/bin/echo", [prompt], [:])
            }
        }
        let runners: [AgentRunner] = [Stub(runnerID: "new.a"), Stub(runnerID: "new.b")]
        XCTAssertNil(RunnerRegistry.resolve(
            ownerRunnerID: "retired.id", platform: .minimax,
            prompt: "【评审】方案", runners: runners))
        XCTAssertEqual(RunnerRegistry.resolve(
            ownerRunnerID: "new.a", platform: .minimax,
            prompt: "【评审】方案", runners: runners)?.runnerID, "new.a")
        XCTAssertNil(RunnerRegistry.resolve(
            ownerRunnerID: "new.a", platform: .qwen,
            prompt: "【评审】方案", runners: runners),
            "稳定 ID 与平台自相矛盾时不能跨平台猜")
    }

    func testManualAndAutomaticHandoffsHaveSeparateLimitsAndRollback() {
        var task = WorkTask(id: "counts", prompt: "p", repo: "/tmp/r")
        _ = ContextAffinityPolicy.assign(
            task: &task, runnerID: "a", platform: .qwen, cause: .initial,
            now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(task.handoffCount, 0)
        XCTAssertEqual(task.automaticHandoffCount, 0)

        _ = ContextAffinityPolicy.assign(
            task: &task, runnerID: "b", platform: .kimi, cause: .manualDisable)
        XCTAssertEqual(task.handoffCount, 1)
        XCTAssertEqual(task.automaticHandoffCount, 0)

        let beforeFailedLaunch = ContextAffinityPolicy.assign(
            task: &task, runnerID: "c", platform: .codex, cause: .automaticFailure)
        XCTAssertEqual(task.handoffCount, 2)
        XCTAssertEqual(task.automaticHandoffCount, 1)
        ContextAffinityPolicy.restore(task: &task, snapshot: beforeFailedLaunch)
        XCTAssertEqual(task.ownerRunnerID, "b")
        XCTAssertEqual(task.handoffCount, 1)
        XCTAssertEqual(task.automaticHandoffCount, 0)
    }

    func testTimeoutExperimentNeverConsumesTheFallbackSlot() {
        XCTAssertFalse(ContextAffinityPolicy.shouldRetryOwnerAfterTimeout(
            enabled: false, retryUsed: false,
            currentRunnerID: "a", ownerRunnerID: "a"))
        XCTAssertTrue(ContextAffinityPolicy.shouldRetryOwnerAfterTimeout(
            enabled: true, retryUsed: false,
            currentRunnerID: "a", ownerRunnerID: "a"))
        XCTAssertTrue(ContextAffinityPolicy.canProceedToNext(
            nextIsSameOwner: true, automaticHandoffCount: 1))
        XCTAssertFalse(ContextAffinityPolicy.canProceedToNext(
            nextIsSameOwner: false, automaticHandoffCount: 1))
    }

    func testOwnedTaskRecoverySaysContinueInsteadOfChangeAgent() {
        var task = WorkTask(id: "flint", prompt: "优化持枪动作", repo: "/flint")
        task.ownerPlatform = .kimi
        task.ownerRunnerID = "kimi.code"
        task.triedPlatforms = [.kimi]
        let option = StuckAsk.recoveryOption(for: task)
        XCTAssertEqual(option.platform, .kimi)
        XCTAssertTrue(option.label.contains("Kimi"))
        XCTAssertTrue(option.label.contains("保留会话和进度"))
        XCTAssertFalse(option.label.contains("换人"))
    }
}
