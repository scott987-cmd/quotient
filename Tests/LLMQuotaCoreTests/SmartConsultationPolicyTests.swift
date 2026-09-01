import XCTest
@testable import LLMQuotaCore

final class SmartConsultationPolicyTests: XCTestCase {
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
