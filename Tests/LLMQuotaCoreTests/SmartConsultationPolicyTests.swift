import XCTest
@testable import LLMQuotaCore

final class SmartConsultationPolicyTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        Paths.appSupportOverride = scratch
        CollaborationStore.directoryOverride = scratch.appendingPathComponent("collaboration")
        WorkAttemptStore.fileOverride = scratch.appendingPathComponent("attempts.jsonl")
    }

    override func tearDown() {
        WorkAttemptStore.fileOverride = nil
        Paths.appSupportOverride = nil
        CollaborationStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func closedConsultation(_ work: WorkTask) -> [CollaborationEvent] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            CollaborationEvent(id: "smart-consult:\(work.id):architecture-v1",
                project: work.repo, taskID: work.id, senderRunnerID: "kimi.code",
                recipientRunnerID: "codex.code", kind: .question, summary: "路线如何定？",
                createdAt: start),
            CollaborationEvent(id: "answer", project: work.repo, taskID: work.id,
                senderRunnerID: "codex.code", recipientRunnerID: "kimi.code", kind: .answer,
                summary: "保留当前路线", replyTo: "smart-consult:\(work.id):architecture-v1",
                createdAt: start.addingTimeInterval(1)),
            CollaborationEvent(id: "ack", project: work.repo, taskID: work.id,
                senderRunnerID: "kimi.code", kind: .ack, summary: "采用并落实于现有增量",
                replyTo: "answer", createdAt: start.addingTimeInterval(2)),
        ]
    }

    private func failedAttempt(_ work: WorkTask, id: String = "failed-1",
                               kind: String = "timedOut", offset: Double = 10) throws {
        try WorkAttemptStore.append(WorkAttempt(attemptID: id, taskID: work.id,
            runnerID: "kimi.code", platform: .kimi,
            startedAt: Date(timeIntervalSince1970: 1_700_000_003),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            outcome: .failed, failureKind: kind, timedOut: kind == "timedOut"))
    }

    func testNewFailureAfterAcknowledgementOpensStableNewDecisionPoint() throws {
        let work = task("调整数据模型与迁移策略")
        let events = closedConsultation(work)
        try failedAttempt(work)
        let next = try XCTUnwrap(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: events))
        XCTAssertEqual(next.stage, .ask)
        XCTAssertNotEqual(next.questionID, events[0].id)
        XCTAssertTrue(next.clause.contains("failed-1"), "必须锚定真实失败，而不是每轮随机开会")
        XCTAssertEqual(next.questionID, SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: events.reversed())?.questionID)

        let question = CollaborationEvent(id: next.questionID, project: work.repo,
            taskID: work.id, senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            kind: .question, summary: "新超时原因？", createdAt: events[2].createdAt.addingTimeInterval(20))
        try failedAttempt(work, id: "failed-2", offset: 30)
        let waiting = SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: events + [question])
        XCTAssertEqual(waiting?.questionID, question.id, "未闭环时禁止并行制造第二个问题")
        XCTAssertEqual(waiting?.stage, .waitingForAnswer)
        let answer = CollaborationEvent(id: "new-answer", project: work.repo, taskID: work.id,
            senderRunnerID: "codex.code", recipientRunnerID: "kimi.code", kind: .answer,
            summary: "拆除循环等待", replyTo: question.id, createdAt: question.createdAt.addingTimeInterval(20))
        let acknowledge = SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: events + [question, answer])
        XCTAssertEqual(acknowledge?.stage, .acknowledgeAnswer)
        XCTAssertTrue(acknowledge?.clause.contains("new-answer") == true)
        let ack = CollaborationEvent(id: "new-ack", project: work.repo, taskID: work.id,
            senderRunnerID: "kimi.code", kind: .ack, summary: "部分采用，保留现有测试",
            replyTo: answer.id, createdAt: answer.createdAt.addingTimeInterval(1))
        XCTAssertNil(SmartConsultationPolicy.instruction(task: work, runnerID: "kimi.code",
            events: events + [question, answer, ack]), "确认后的同一批故障不能反复开咨询")
    }

    func testFailureConsultationIgnoresQuotaOtherTasksAndFailuresAlreadyAddressed() throws {
        let work = task("调整数据模型")
        let events = closedConsultation(work)
        try failedAttempt(work, kind: "quotaExhausted")
        try failedAttempt(work, id: "old", offset: 1)
        var other = work
        other.id = "unrelated"
        try failedAttempt(other, id: "unrelated")
        XCTAssertNil(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: events))
    }

    func testRunningOwnerReceivesAcknowledgementActionWithoutForgedEvents() throws {
        var work = task("调整数据模型")
        work.ownerRunnerID = "kimi.code"
        work.state = .running
        try TaskStore.create(work, actor: "test", reason: "isolated fixture")
        for event in closedConsultation(work).prefix(2) { try CollaborationStore.publish(event) }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 8, "method": "tools/call",
            "params": ["name": "collaboration_get_context", "arguments": [
                "project": work.repo, "taskID": work.id, "runnerID": "kimi.code"]]]
        let result = try XCTUnwrap(CollaborationMCP.response(for: request)?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2, "运行中的 Agent 读上下文也必须收到下一动作，而非只在启动时提醒")
        let json = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertTrue((content.last?["text"] as? String)?.contains("collaboration ack 'answer'") == true)
        XCTAssertEqual(CollaborationStore.all().count, 2, "读取不允许冒充 Agent 发问或确认")
        XCTAssertNil(SmartConsultationPolicy.currentInstruction(project: "/tmp/other", taskID: work.id,
                                                                runnerID: "kimi.code"))
        XCTAssertNil(SmartConsultationPolicy.currentInstruction(project: work.repo, taskID: work.id,
                                                                runnerID: "qwen.code"))
    }

    func testTwoRealFailuresTriggerConsultationWithoutArchitectureKeyword() throws {
        let work = task("修复实际试玩卡死")
        try failedAttempt(work)
        XCTAssertNil(SmartConsultationPolicy.instruction(task: work, runnerID: "kimi.code", events: []))
        try failedAttempt(work, id: "failed-2", offset: 20)
        XCTAssertEqual(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [])?.stage, .ask)
    }

    func testFailedConsultationDoesNotKeepWaitingOrFakeAnAnswer() throws {
        let work = task("调整数据模型")
        let question = closedConsultation(work)[0]
        let failed = CollaborationEvent(id: "consultation-failure:\(question.id):mini",
            project: work.repo, taskID: work.id, senderRunnerID: "consultation-executor",
            kind: .finding, summary: "接收方未登录", replyTo: question.id)
        let next = try XCTUnwrap(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question, failed]))
        XCTAssertEqual(next.stage, .consultationFailed)
        XCTAssertTrue(next.clause.contains("接收方未登录"))
        XCTAssertFalse(next.clause.contains("collaboration ack"))
        XCTAssertFalse(next.clause.contains("collaboration ask"))
    }

    private func task(_ prompt: String, tier: TaskProfile.Tier = .standard) -> WorkTask {
        var task = WorkTask(id: "task-architecture", prompt: prompt, repo: "/tmp/Flint")
        task.profile = TaskProfile(
            tier: tier, risk: .normal, estimatedMinutes: 20,
            isSelfContained: true, rationale: "test")
        return task
    }

    func testArchitectureBoundaryRequiresOneCodexConsultation() throws {
        let work = task("重构跨模块状态机和持久化契约", tier: .complex)

        let instruction = try XCTUnwrap(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: []))

        XCTAssertEqual(instruction.stage, .ask)
        XCTAssertEqual(instruction.recipientRunnerID, "codex.code")
        XCTAssertEqual(instruction.questionID,
                       "smart-consult:task-architecture:architecture-v1")
        XCTAssertTrue(instruction.clause.contains("必须先完成一次定向架构咨询"))
        XCTAssertTrue(instruction.clause.contains("--to 'codex.code'"))
        XCTAssertTrue(instruction.clause.contains("--id 'smart-consult:task-architecture:architecture-v1'"))
    }

    func testRepeatedFailureRequiresConsultationWithoutArchitectureKeywords() throws {
        var work = task("修复当前功能回归")
        work.interruptedCount = 2

        let instruction = try XCTUnwrap(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: []))

        XCTAssertEqual(instruction.stage, .ask)
        XCTAssertTrue(instruction.reason.contains("连续失败"))
    }

    func testBoundedImplementationDoesNotCreatePerformativeConsultation() {
        let work = task("在列表底部增加一个刷新按钮并补单元测试")

        XCTAssertNil(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: []))
    }

    func testQualityContractReferenceAloneDoesNotTriggerArchitectureMeeting() {
        let work = task("按 Production/operator/contract.json 完成五机位视觉验收",
                        tier: .complex)

        XCTAssertNil(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: []))
    }

    func testExistingQuestionWaitsAndDoesNotAskAgain() throws {
        let work = task("调整数据模型与迁移策略", tier: .complex)
        let question = CollaborationEvent(
            id: "smart-consult:task-architecture:architecture-v1",
            project: work.repo, taskID: work.id,
            senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            kind: .question, summary: "迁移边界怎么定？")

        let instruction = try XCTUnwrap(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question]))

        XCTAssertEqual(instruction.stage, .waitingForAnswer)
        XCTAssertFalse(instruction.clause.contains("collaboration ask"))
        XCTAssertTrue(instruction.clause.contains("不要重复提问"))
    }

    func testAnswerRequiresOwnerAcknowledgementThenClosesDecisionPoint() throws {
        let work = task("调整数据模型与迁移策略", tier: .complex)
        let question = CollaborationEvent(
            id: "smart-consult:task-architecture:architecture-v1",
            project: work.repo, taskID: work.id,
            senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            kind: .question, summary: "迁移边界怎么定？")
        let answer = CollaborationEvent(
            id: "answer:architecture", project: work.repo, taskID: work.id,
            senderRunnerID: "codex.code", recipientRunnerID: "kimi.code",
            kind: .answer, summary: "采用单写者迁移", replyTo: question.id)

        let instruction = try XCTUnwrap(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question, answer]))
        XCTAssertEqual(instruction.stage, .acknowledgeAnswer)
        XCTAssertTrue(instruction.clause.contains("collaboration ack 'answer:architecture'"))

        let ack = CollaborationEvent(
            id: "ack:answer:architecture:kimi.code", project: work.repo,
            taskID: work.id, senderRunnerID: "kimi.code", kind: .ack,
            summary: "已采用到实现", replyTo: answer.id)
        XCTAssertNil(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: [question, answer, ack]))
    }

    func testArchitectAndDerivedReviewDoNotConsultThemselves() {
        var work = task("评审状态机架构", tier: .complex)
        XCTAssertNil(SmartConsultationPolicy.instruction(
            task: work, runnerID: "codex.code", events: []))

        work.origin = "architect-review:source-task"
        XCTAssertNil(SmartConsultationPolicy.instruction(
            task: work, runnerID: "kimi.code", events: []))
    }

    func testActiveContextPackCarriesSmartConsultationAsAuditableContract() {
        let work = task("重构跨模块状态机和持久化契约", tier: .complex)
        let pack = ContextPackBuilder.build(.init(
            task: work, allTasks: [work], events: [], runnerID: "kimi.code",
            platform: .kimi, canReadFiles: true, workspacePath: work.repo,
            handoff: nil, resumedAnswer: nil, resumedAsk: nil,
            mayAsk: false, askFile: nil, tier: .complex,
            sessionAction: "fresh"))

        XCTAssertFalse(pack.refused)
        XCTAssertTrue(pack.manifest.includedFactIDs.contains(
            "contract:smart-consultation"))
        XCTAssertTrue(pack.text.contains("【智能咨询 · 强制决策点】"))
        XCTAssertTrue(pack.text.contains("smart-consult:task-architecture:architecture-v1"))
    }
}
