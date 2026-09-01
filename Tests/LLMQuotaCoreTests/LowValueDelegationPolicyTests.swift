import XCTest
@testable import LLMQuotaCore

final class LowValueDelegationPolicyTests: XCTestCase {
    private func task(tier: TaskProfile.Tier = .complex,
                      minutes: Int = 30) -> WorkTask {
        var task = WorkTask(
            id: "main-task", prompt: "实现功能并补齐测试、日志和文档验收清单",
            repo: "/tmp/Flint")
        task.profile = TaskProfile(
            tier: tier, risk: .normal, estimatedMinutes: minutes,
            isSelfContained: true, rationale: "test")
        return task
    }

    private func agent(_ runnerID: String, _ platform: Platform,
                       machine: String = "m1") -> AgentRegistration {
        AgentRegistration(machineID: machine, machineName: machine,
                          runnerID: runnerID, platform: platform,
                          canConsult: true)
    }

    func testSubstantialMainTaskSelectsBestAvailableSidecarWithoutHardCodingVendor() throws {
        let instruction = try XCTUnwrap(LowValueDelegationPolicy.instruction(
            task: task(), runnerID: "kimi.code", events: [],
            candidates: [agent("claude.code", .claude),
                         agent("minimax.code", .minimax)],
            headroom: [.claude: 0.18, .minimax: 0.92]))

        XCTAssertEqual(instruction.stage, .delegate)
        XCTAssertEqual(instruction.recipientRunnerID, "minimax.code")
        XCTAssertEqual(instruction.questionID, "sidecar:main-task:helper-v1")
        XCTAssertTrue(instruction.clause.contains("只读辅助委派"))
        XCTAssertTrue(instruction.clause.contains("--to 'minimax.code'"))
        XCTAssertTrue(instruction.clause.contains("主任务 Owner 不变"))
        XCTAssertFalse(instruction.clause.contains("work add"),
                       "辅助委派不能偷偷拆成新的写入任务")
    }

    func testAnotherCapableAgentIsSelectedWhenMiniMaxIsUnavailable() throws {
        let instruction = try XCTUnwrap(LowValueDelegationPolicy.instruction(
            task: task(), runnerID: "kimi.code", events: [],
            candidates: [agent("claude.code", .claude)],
            headroom: [.claude: 0.7]))
        XCTAssertEqual(instruction.recipientRunnerID, "claude.code")
        XCTAssertTrue(instruction.clause.contains("--to 'claude.code'"))
        XCTAssertFalse(instruction.clause.contains("MiniMax"))
    }

    func testSmallTaskOrOnlySelfCandidateDoesNotDelegateForShow() {
        XCTAssertNil(LowValueDelegationPolicy.instruction(
            task: task(tier: .standard, minutes: 5),
            runnerID: "kimi.code", events: [],
            candidates: [agent("minimax.code", .minimax)]))
        XCTAssertNil(LowValueDelegationPolicy.instruction(
            task: task(), runnerID: "minimax.code", events: [],
            candidates: [agent("minimax.code", .minimax)]))
    }

    func testExistingSidecarQuestionDoesNotSpendTwice() throws {
        let work = task()
        let question = CollaborationEvent(
            id: "sidecar:main-task:helper-v1", project: work.repo,
            taskID: work.id, senderRunnerID: "kimi.code",
            recipientRunnerID: "minimax.code", kind: .question,
            summary: "请盘点测试缺口")

        let instruction = try XCTUnwrap(LowValueDelegationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question],
            candidates: []))
        XCTAssertEqual(instruction.stage, .waitingForAnswer)
        XCTAssertFalse(instruction.clause.contains("collaboration ask"))
        XCTAssertTrue(instruction.clause.contains("不要重复委派"))
    }

    func testMiniMaxAnswerMustBeAcknowledgedThenDecisionPointCloses() throws {
        let work = task()
        let question = CollaborationEvent(
            id: "sidecar:main-task:helper-v1", project: work.repo,
            taskID: work.id, senderRunnerID: "kimi.code",
            recipientRunnerID: "minimax.code", kind: .question,
            summary: "请盘点测试缺口")
        let answer = CollaborationEvent(
            id: "answer:sidecar", project: work.repo, taskID: work.id,
            senderRunnerID: "minimax.code", recipientRunnerID: "kimi.code",
            kind: .answer, summary: "缺少三个边界用例", replyTo: question.id)

        let instruction = try XCTUnwrap(LowValueDelegationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question, answer],
            candidates: []))
        XCTAssertEqual(instruction.stage, .acknowledgeAnswer)
        XCTAssertTrue(instruction.clause.contains("collaboration ack 'answer:sidecar'"))

        let ack = CollaborationEvent(
            id: "ack:sidecar", project: work.repo, taskID: work.id,
            senderRunnerID: "kimi.code", kind: .ack,
            summary: "已纳入实现", replyTo: answer.id)
        XCTAssertNil(LowValueDelegationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question, answer, ack],
            candidates: []))
    }

    func testMiniMaxCodeHasRealReadOnlyConsultationCommand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-readonly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.json")
        try Data("{\"api_key\":\"test-key\",\"region\":\"cn\"}".utf8).write(to: config)
        MiniMaxCodeRunner.configPathOverride = config.path
        defer { MiniMaxCodeRunner.configPathOverride = nil }

        let runner = MiniMaxCodeRunner()
        XCTAssertTrue(AgentConsultation.supportsReadOnlyConsultation(runner))
        let command = runner.readOnlyCommand(
            prompt: "只读盘点", cwd: dir.path, session: .fresh)
        XCTAssertTrue(command.args.contains("Read,Glob,Grep"))
        XCTAssertFalse(command.args.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(command.env["ANTHROPIC_MODEL"], "MiniMax-M3")
        XCTAssertEqual(command.env["ANTHROPIC_BASE_URL"],
                       "https://api.minimaxi.com/anthropic")
    }
}
