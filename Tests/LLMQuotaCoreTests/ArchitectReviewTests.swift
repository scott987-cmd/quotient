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

    func testNegativeReviewCreatesOneClaudeArchitectReview() throws {
        let review = mergeReview(id: "review1", verdict: "不合入")
        let made = ArchitectReview.reconcile([review])
        let task = try XCTUnwrap(made.only)
        XCTAssertEqual(task.origin, "architect-review:review1")
        XCTAssertEqual(task.preferredPlatform, .claude)
        XCTAssertTrue(TaskKind.isArchitectReview(task.prompt))
        XCTAssertTrue(task.prompt.contains("维持拒绝"))
        XCTAssertTrue(ArchitectReview.reconcile([review, task]).isEmpty,
                      "同一个负面结论只能生成一次架构复核")
    }

    func testManualArchitectReviewIntakePrefersClaude() throws {
        let outcome = try TaskIntake.enqueue(
            prompt: "【架构复核】检查状态机并发风险", repo: "/tmp/x",
            classify: false, split: false, force: true)
        guard case .single(let task) = outcome else {
            return XCTFail("架构复核应作为单任务入队")
        }
        XCTAssertEqual(task.preferredPlatform, .claude,
                       "手工创建的架构复核也不能回落到 Codex")
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
        let review = visualReview(id: "eyes", branch: branch, head: "abc123")
        let architect = try XCTUnwrap(ArchitectReview.reconcile([review]).only)
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: "abc123", tasks: [review, architect]), .pending)

        var overturn = architect
        overturn.state = .done
        overturn.outputs = ["**结论**：推翻拒绝"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: "abc123", tasks: [review, overturn]), .approved)

        var uphold = overturn
        uphold.outputs = ["**结论**：维持拒绝"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: "abc123", tasks: [review, uphold]), .rejected)

        var source = WorkTask(id: "source", prompt: "实现角色", repo: "/tmp/x")
        source.branch = branch
        source.state = .done
        source.ownerPlatform = .kimi
        let reopened = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review, uphold]).only)
        XCTAssertEqual(reopened.state, .queued)
    }

    func testArchitectReviewUsesClaudeDispatcherAndNoOtherRunner() throws {
        var roles = AgentRoles.defaults()
        roles.removeAll { $0.platform == .claude }
        roles.append(AgentRole(
            platform: .claude, title: "架构师", maxRisk: .sensitive,
            maxTier: .complex, dispatcherOn: [Paths.machineName()]))
        try AgentRoles.save(roles)

        var task = WorkTask(id: "arch", prompt: "【架构复核】检查负面结论",
                            repo: "/tmp/x")
        task.profile = TaskProfile(
            tier: .standard, risk: .safe, estimatedMinutes: 8,
            isSelfContained: true, rationale: "复核")
        let decision = WorkScheduler().decide(
            dashboard: dashboard([.claude, .codex, .minimax]),
            runners: [StubRunner(platform: .claude, runnerID: "claude.code"),
                      StubRunner(platform: .codex, runnerID: "codex.code"),
                      StubRunner(platform: .minimax, runnerID: "minimax.review",
                                 reviewOnly: true)],
            task: task)
        XCTAssertEqual(decision.candidates.map(\.platform), [.claude],
                       "架构复核只能由 Claude 承接，不能继续消耗 Codex")
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
        var binaryPath: String? { "/usr/bin/true" }
        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/usr/bin/true", [], [:])
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
