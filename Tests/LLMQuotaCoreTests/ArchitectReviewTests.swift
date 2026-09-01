import XCTest
@testable import LLMQuotaCore

final class ArchitectReviewTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("architect-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox,
                                                  withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    func testPassingReviewAndMachineTestCreateNoArchitectWork() {
        var pass = mergeReview(id: "pass", verdict: "合入")
        var test = WorkTask(id: "test", prompt: "【测试】跑全量测试\n"
            + ArchitectReview.contractMarker, repo: "/tmp/x")
        test.state = .done
        test.outputs = ["**结论**：不达标", "退出码 1"]

        XCTAssertTrue(ArchitectReview.reconcile([pass, test]).isEmpty,
                      "通过结论和机器退出码都不能浪费架构师额度")
        pass.outputs = ["**结论**：不合入"]
        pass.prompt = pass.prompt.replacingOccurrences(
            of: ArchitectReview.contractMarker, with: "")
        XCTAssertTrue(ArchitectReview.reconcile([pass]).isEmpty,
                      "上线前的历史否决不能一次性回灌")
    }

    func testNegativeReviewCreatesOneConfiguredCodexArchitectReview() throws {
        let review = mergeReview(id: "review1", verdict: "不合入")
        let made = ArchitectReview.reconcile([review])
        let task = try XCTUnwrap(made.only)
        XCTAssertEqual(task.origin, "architect-review:review1")
        XCTAssertEqual(task.preferredPlatform, .codex)
        XCTAssertTrue(TaskKind.isArchitectReview(task.prompt))
        XCTAssertTrue(task.prompt.contains("维持拒绝"))
        XCTAssertTrue(ArchitectReview.reconcile([review, task]).isEmpty,
                      "同一个负面结论只能生成一次架构复核")
    }

    func testSameBranchAndHeadShareOneArchitectReview() throws {
        let first = mergeReview(id: "review-a", verdict: "不合入")
        let second = mergeReview(id: "review-b", verdict: "不合入")

        let made = ArchitectReview.reconcile([first, second])
        let architect = try XCTUnwrap(made.only)
        XCTAssertTrue(architect.prompt.contains(first.id))
        XCTAssertTrue(architect.prompt.contains(second.id),
                      "同一分支同一提交的负面材料应合并给架构师，不能再造多张票")

        var decided = architect
        decided.state = .done
        decided.outputs = ["**结论**：维持拒绝"]
        XCTAssertEqual(ArchitectReview.decision(
            for: first, tasks: [first, second, decided]), .uphold)
        XCTAssertEqual(ArchitectReview.decision(
            for: second, tasks: [first, second, decided]), .uphold)
        XCTAssertTrue(ArchitectReview.reconcile([first, second, decided]).isEmpty)
    }

    func testQuotaFailedArchitectReviewIsRequeuedInsteadOfDeadlocking() throws {
        let review = mergeReview(id: "quota1", verdict: "不合入")
        var architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        architect.state = .failed
        architect.platform = .codex
        architect.ownerPlatform = .codex
        architect.ownerRunnerID = "codex.code"
        architect.triedPlatforms = [.codex]
        architect.startedAt = Date(timeIntervalSince1970: 10)
        architect.endedAt = Date(timeIntervalSince1970: 20)
        architect.note = "Codex：退出码 1：You've hit your session limit · resets 5:50pm"

        let retried = try XCTUnwrap(
            ArchitectReview.reconcile([review, architect]).only)
        XCTAssertEqual(retried.id, architect.id, "应恢复原复核任务，不能再造重复任务")
        XCTAssertEqual(retried.state, .queued)
        XCTAssertTrue(retried.triedPlatforms.isEmpty,
                      "额度失败不是能力失败，恢复后 Codex 仍应可在冷却结束后承接")
        XCTAssertNil(retried.startedAt)
        XCTAssertNil(retried.endedAt)
        XCTAssertEqual(retried.preferredPlatform, .codex)
        XCTAssertNil(retried.terminalFailureKind)
        XCTAssertNil(retried.retryNotBefore)
    }

    func testArchitectPromptDoesNotCopyUnboundedSourceHistory() throws {
        var review = mergeReview(id: "large1", verdict: "不合入")
        review.prompt += "\n" + String(repeating: "历史视觉整改与完整报告。", count: 20_000)

        let architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        XCTAssertLessThan(architect.prompt.count, 20_000,
                          "架构复核不能复制整条累积历史，避免上下文和 token 失控")
        XCTAssertTrue(architect.prompt.contains("agent/kimi/work"))
        XCTAssertTrue(architect.prompt.contains("abc123"))
    }

    func testManualArchitectReviewIntakePrefersConfiguredCodex() throws {
        let outcome = try TaskIntake.enqueue(
            prompt: "【架构复核】检查状态机并发风险", repo: "/tmp/x",
            classify: false, split: false, force: true)
        guard case .single(let task) = outcome else {
            return XCTFail("架构复核应作为单任务入队")
        }
        XCTAssertEqual(task.preferredPlatform, .codex,
                       "手工创建的架构复核必须使用配置中的 Codex 架构师")
    }

    func testMergeRejectionWaitsForArchitectThenUsesDecision() throws {
        let review = mergeReview(id: "review2", verdict: "不合入")
        let pending = try XCTUnwrap(ArchitectReview.reconcile([review]).only)

        var count = MergeReview.approvalsSoFar(
            branch: "agent/kimi/work", tasks: [review, pending])
        XCTAssertEqual(count.approvals, 0)
        XCTAssertFalse(count.rejected)
        XCTAssertTrue(ArchitectReview.hasUnresolvedMergeRejection(
            branch: "agent/kimi/work", head: "abc123", headAt: nil,
            tasks: [review, pending]))

        var uphold = pending
        uphold.state = .done
        uphold.outputs = ["**结论**：维持拒绝"]
        count = MergeReview.approvalsSoFar(
            branch: "agent/kimi/work", tasks: [review, uphold])
        XCTAssertTrue(count.rejected)

        var overturn = uphold
        overturn.outputs = ["**结论**：推翻拒绝"]
        count = MergeReview.approvalsSoFar(
            branch: "agent/kimi/work", tasks: [review, overturn])
        XCTAssertEqual(count.approvals, 1)
        XCTAssertFalse(count.rejected)
    }

    func testPostLandFindingWaitsForArchitectBeforeRepair() throws {
        var source = WorkTask(id: "source", prompt: "实现功能", repo: "/tmp/x")
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        source.branch = "agent/kimi/source"
        var review = WorkTask(
            id: "review3",
            prompt: "【审查】（来源分支 agent/kimi/source）。\n"
                + PostLandRepair.contractMarker + "\n"
                + ArchitectReview.contractMarker,
            repo: "/tmp/x")
        review.origin = "post-land-review"
        review.state = .done
        review.outputs = ["### 1. Store.swift:42 — 会丢记录（高）"]
        let report = review.outputs.joined(separator: "\n")

        let architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        XCTAssertTrue(PostLandRepair.reconcile(
            [source, review, architect], reportText: { _ in report }).isEmpty)

        var overturn = architect
        overturn.state = .done
        overturn.outputs = ["**结论**：推翻拒绝"]
        XCTAssertTrue(PostLandRepair.reconcile(
            [source, review, overturn], reportText: { _ in report }).isEmpty)

        var uphold = overturn
        uphold.outputs = ["**结论**：维持拒绝"]
        let repair = try XCTUnwrap(PostLandRepair.reconcile(
            [source, review, uphold], reportText: { _ in report }).only)
        XCTAssertEqual(repair.ownerRunnerID, "kimi.code")
    }

    func testVisualRejectionIsPendingUntilArchitectDecision() throws {
        let branch = "agent/kimi/source"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var review = visualReview(id: "eyes", branch: branch, head: fixture.head)
        review.repo = fixture.repo.path
        let architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: fixture.head, tasks: [review, architect]), .pending)

        var overturn = architect
        overturn.state = .done
        overturn.outputs = ["**结论**：推翻拒绝"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: fixture.head, tasks: [review, overturn]), .approved)

        var uphold = overturn
        uphold.outputs = ["**结论**：维持拒绝"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: fixture.head, tasks: [review, uphold]), .rejected)

        var source = WorkTask(id: "source", prompt: "实现角色", repo: fixture.repo.path)
        source.branch = branch
        source.state = .done
        source.ownerPlatform = .kimi
        let reopened = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review, uphold]).only)
        XCTAssertEqual(reopened.state, .queued)
    }

    func testArchitectDecisionIgnoresHeadingBeforeFinalVerdict() throws {
        let branch = "agent/kimi/source"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }
        var review = visualReview(id: "heading", branch: branch, head: fixture.head)
        review.repo = fixture.repo.path
        var architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        architect.state = .done
        architect.outputs = [
            "## 架构复核结论",
            "逐项核验后，负面视觉证据成立。",
            "**结论**：维持拒绝",
        ]

        XCTAssertEqual(ArchitectReview.decision(
            for: review, tasks: [review, architect]), .uphold,
            "报告标题不能吞掉后面的最终契约结论")

        var source = WorkTask(id: "source", prompt: "继续角色整改", repo: fixture.repo.path)
        source.branch = branch
        source.state = .done
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        let reopened = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review, architect]).only)
        XCTAssertEqual(reopened.state, .queued)
        XCTAssertEqual(reopened.ownerRunnerID, "kimi.code")
    }

    func testUpheldOrdinaryMergeRejectionReopensOriginalImplementation() throws {
        let branch = "agent/kimi/source"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }

        var source = WorkTask(
            id: "source",
            prompt: "【功能 Alpha｜冻结美术】只修功能，不得修改 Production。",
            repo: fixture.repo.path)
        source.branch = branch
        source.state = .done
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        source.preferredPlatform = .kimi

        var review = WorkTask(
            id: "merge-no",
            prompt: "【审查·合入】分支 \(branch) 的改动能不能合进 main。\n"
                + "被审提交：\(fixture.head)\n" + ArchitectReview.contractMarker,
            repo: fixture.repo.path)
        review.origin = "merge-review"
        review.state = .done
        review.outputs = ["**结论**：不合入", "暂停后感染音频不会恢复"]

        var architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        architect.state = .done
        architect.outputs = [
            "越界修改 Production/*.blend1；暂停后感染音频不会恢复。",
            "**结论**：维持拒绝",
        ]

        let reopened = try XCTUnwrap(TaskGraph.reconcile([source, review, architect])
            .first(where: { $0.id == source.id }))
        XCTAssertEqual(reopened.state, .queued)
        XCTAssertEqual(reopened.id, source.id)
        XCTAssertEqual(reopened.branch, branch)
        XCTAssertEqual(reopened.ownerPlatform, .kimi)
        XCTAssertEqual(reopened.ownerRunnerID, "kimi.code")
        XCTAssertEqual(reopened.visualRemediationReviewID, review.id)
        XCTAssertEqual(reopened.qualityRejectionCount, 0,
                       "代码合入拒绝不能冒充视觉质量连续失败")
        XCTAssertNil(reopened.architectureReviewRequestedAt)
        XCTAssertNil(reopened.pausedAt)
        XCTAssertTrue(reopened.prompt.contains("冻结美术"), "原任务范围必须保留")
        XCTAssertTrue(reopened.prompt.contains("暂停后感染音频不会恢复"))
        XCTAssertTrue(reopened.prompt.contains("Production/*.blend1"))

        var completedWithoutNewHead = reopened
        completedWithoutNewHead.state = .done
        XCTAssertTrue(MergeReview.reconcileRemediation(
            [completedWithoutNewHead, review, architect]).isEmpty,
            "同一份维持拒绝不能重复重开任务")
    }

    func testLegacyMergeRejectionVisualCounterPauseIsHealed() throws {
        let branch = "agent/kimi/source"
        let fixture = try makeVisualGitFixture(branch: branch)
        defer { try? FileManager.default.removeItem(at: fixture.repo) }

        var source = WorkTask(id: "source", prompt: "功能 Alpha；冻结美术",
                              repo: fixture.repo.path)
        source.branch = branch
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        source.visualRemediationReviewID = "merge-no"
        source.qualityRejectionCount = 2
        source = TaskPause.requestArchitectureReview(
            source, reason: "黄金样板连续 2 轮未收敛")

        var review = WorkTask(
            id: "merge-no",
            prompt: "【审查·合入】分支 \(branch) 的改动能不能合进 main。\n"
                + "被审提交：\(fixture.head)\n" + ArchitectReview.contractMarker,
            repo: fixture.repo.path)
        review.origin = "merge-review"
        review.state = .done
        review.outputs = ["**结论**：不合入"]
        var architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        architect.state = .done
        architect.outputs = ["测试不能捕获原始缺陷", "**结论**：维持拒绝"]

        var obsolete = WorkTask(id: "wrong-architecture", prompt: "黄金样板前置设计",
                                repo: fixture.repo.path)
        obsolete.origin = QualityArchitectureReview.originPrefix + source.id + ":123"
        obsolete.state = .queued
        obsolete.preferredPlatform = .codex

        let updates = TaskGraph.reconcile([source, review, architect, obsolete])
        let resumed = try XCTUnwrap(updates.first { $0.id == source.id })
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertEqual(resumed.ownerRunnerID, "kimi.code")
        XCTAssertNil(resumed.pausedAt)
        XCTAssertNil(resumed.architectureReviewRequestedAt)
        XCTAssertEqual(resumed.qualityRejectionCount, 0)
        let cancelled = try XCTUnwrap(updates.first { $0.id == obsolete.id })
        XCTAssertEqual(cancelled.state, .failed)
        XCTAssertNotNil(cancelled.discardedAt)
        XCTAssertTrue(cancelled.note?.contains("错误派生") == true)
    }

    func testCompletedArchitectOutputsDoNotReopenGitForEveryHistoricalReview() throws {
        let repo = sandbox.appendingPathComponent("decision-performance").path
        try FileManager.default.createDirectory(atPath: repo,
                                                withIntermediateDirectories: true)
        _ = GitWorkspace.git(["init", "-q", "-b", "main"], in: repo)
        try "base\n".write(toFile: (repo as NSString).appendingPathComponent("README.md"),
                           atomically: true, encoding: .utf8)
        _ = GitWorkspace.git(["add", "-A"], in: repo)
        _ = GitWorkspace.git(["-c", "user.email=t@t", "-c", "user.name=t",
                              "commit", "-qm", "base"], in: repo)

        var tasks: [WorkTask] = []
        for index in 0..<30 {
            var review = mergeReview(id: "history\(index)", verdict: "不合入")
            review.repo = repo
            var architect = WorkTask(id: "architect\(index)", prompt: "架构复核", repo: repo)
            architect.origin = "architect-review:" + review.id
            architect.branch = "main"
            architect.state = .done
            architect.outputs = ["**结论**：维持拒绝"]
            tasks.append(contentsOf: [review, architect])
        }

        let started = Date()
        for review in tasks where review.origin == "merge-review" {
            XCTAssertEqual(ArchitectReview.decision(for: review, tasks: tasks), .uphold)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "结构化输出已有结论时，不应为每张历史票再启动一次 git show")
    }

    func testArchitectReviewOnlyUsesConfiguredCodexArchitect() throws {
        var roles = AgentRoles.defaults()
        roles.removeAll { $0.platform == .codex }
        roles.append(AgentRole(
            platform: .codex, title: "架构师", maxRisk: .sensitive,
            maxTier: .complex, dispatcherOn: [Paths.machineName()]))
        try AgentRoles.save(roles)

        var task = WorkTask(id: "arch", prompt: "【架构复核】检查负面结论",
                            repo: "/tmp/x")
        task.preferredPlatform = .codex
        task.profile = TaskProfile(
            tier: .standard, risk: .safe, estimatedMinutes: 8,
            isSelfContained: true, rationale: "复核")
        var decision = WorkScheduler().decide(
            dashboard: dashboard([.claude, .codex, .minimax]),
            runners: [StubRunner(platform: .claude, runnerID: "claude.code"),
                      StubRunner(platform: .codex, runnerID: "codex.code"),
                      StubRunner(platform: .minimax, runnerID: "minimax.review",
                                 reviewOnly: true)],
            task: task)
        XCTAssertEqual(decision.candidates.map(\.platform), [.codex],
                       "普通开发 Claude 不能再进入架构复核候选")

        decision = WorkScheduler().decide(
            dashboard: dashboard([.claude, .codex, .minimax]),
            runners: [StubRunner(platform: .claude, runnerID: "claude.code",
                                 binaryPath: nil),
                      StubRunner(platform: .codex, runnerID: "codex.code"),
                      StubRunner(platform: .minimax, runnerID: "minimax.review",
                                 reviewOnly: true)],
            task: task)
        XCTAssertEqual(decision.candidates.map(\.platform), [.codex],
                       "Claude 是否可用不应改变 Codex 架构师的归属")
    }

    func testCodexArchitectDoesNotCompeteForOrdinaryImplementation() throws {
        var task = WorkTask(id: "implementation", prompt: "修改构建配置", repo: "/tmp/x")
        task.profile = TaskProfile(
            tier: .standard, risk: .sensitive, estimatedMinutes: 8,
            isSelfContained: true, rationale: "高危实现")

        let decision = WorkScheduler().decide(
            dashboard: dashboard([.claude, .codex]),
            runners: [StubRunner(platform: .claude, runnerID: "claude.code"),
                      StubRunner(platform: .codex, runnerID: "codex.code")],
            task: task)

        XCTAssertEqual(decision.candidates.map(\.platform), [.claude])
        XCTAssertEqual(decision.dispatcher, .codex,
                       "Codex 架构师应保留在控制面，不抢普通实现任务")

        let noDeveloper = WorkScheduler().decide(
            dashboard: dashboard([.claude, .codex]),
            runners: [StubRunner(platform: .claude, runnerID: "claude.code",
                                 binaryPath: nil),
                      StubRunner(platform: .codex, runnerID: "codex.code")],
            task: task)
        XCTAssertTrue(noDeveloper.candidates.isEmpty,
                      "普通开发不可用时也不能把 Codex 架构师降级为实现者")
        XCTAssertEqual(noDeveloper.dispatcher, .codex)
    }

    private func mergeReview(id: String, verdict: String) -> WorkTask {
        var task = WorkTask(
            id: id,
            prompt: "【审查·合入】分支 agent/kimi/work 的改动能不能合进 main。\n"
                + "被审提交：abc123\n" + ArchitectReview.contractMarker,
            repo: "/tmp/x")
        task.origin = "merge-review"
        task.state = .done
        task.outputs = ["**结论**：\(verdict)", "A.swift:10 有明确问题"]
        return task
    }

    private func visualReview(id: String, branch: String, head: String) -> WorkTask {
        var task = WorkTask(
            id: id,
            prompt: "【看效果】分支 \(branch) 提交 \(head) 的视觉质量。\n"
                + ArchitectReview.contractMarker,
            repo: "/tmp/x")
        task.origin = "visual-quality-review"
        task.state = .done
        task.outputs = ["**结论**：未达标", "左手悬空"]
        return task
    }

    private func dashboard(_ platforms: [Platform]) -> Dashboard {
        Dashboard(generatedAt: Date(), machines: [], reports: platforms.map {
            PlatformReport(
                platform: $0, planName: "p", monthlyCost: nil, currency: "CNY",
                detected: true, machines: [Paths.machineName()], lastActivity: nil,
                statuses: [], last30dRequests: 0, last30dBillableTokens: 0,
                last7dRequests: 0, topModels: [])
        })
    }

    private struct StubRunner: AgentRunner {
        let platform: Platform
        let runnerID: String
        var reviewOnly = false
        var binaryName: String { "true" }
        var binaryPath: String? = "/usr/bin/true"
        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/usr/bin/true", [], [:])
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
