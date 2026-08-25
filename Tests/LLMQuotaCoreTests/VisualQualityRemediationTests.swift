import XCTest
@testable import LLMQuotaCore

final class VisualQualityRemediationTests: XCTestCase {
    func testLatestVerdictWinsInsteadOfFirstArrayEntry() {
        let branch = "agent/kimi/sample"
        let head = "abc123"
        var old = visual(id: "old", branch: branch, head: head,
                         verdict: "未达标", endedAt: Date(timeIntervalSince1970: 10))
        var fresh = visual(id: "fresh", branch: branch, head: head,
                           verdict: "达标", endedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: head, tasks: [old, fresh]), .approved)
        XCTAssertTrue(VisualQualityGate.hasApproved(branch: branch, tasks: [old, fresh]))

        // 变异钉：只交换新旧结论，必须跟着最新票变，不能退回“见过批准就算过”。
        old.outputs = ["**结论**：达标"]
        fresh.outputs = ["**结论**：未达标"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: branch, head: head, tasks: [old, fresh]), .rejected)
        XCTAssertFalse(VisualQualityGate.hasApproved(branch: branch, tasks: [old, fresh]))
    }

    func testRejectedReviewReopensExactOwnerTaskOnlyOnce() throws {
        let branch = "agent/kimi/source"
        var source = WorkTask(id: "source", prompt: "继续做黄金样板", repo: "/flint")
        source.state = .done
        source.branch = branch
        source.landedAt = Date(timeIntervalSince1970: 15)
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        source.preferredPlatform = .kimi
        source.triedPlatforms = [.kimi]
        source.production = ProductionContext(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-v1", requiresExperienceApproval: true)

        var review = visual(id: "eyes", branch: branch, head: "abc123",
                            verdict: "未达标", endedAt: Date(timeIntervalSince1970: 20))
        review.outputs.append("左手悬空，第三人称角色没有武器")

        let reopened = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [source, review], now: Date(timeIntervalSince1970: 30)).only)
        XCTAssertEqual(reopened.id, source.id, "不得另造一条从零加载上下文的新任务")
        XCTAssertEqual(reopened.state, .queued)
        XCTAssertEqual(reopened.ownerPlatform, .kimi)
        XCTAssertEqual(reopened.ownerRunnerID, "kimi.code")
        XCTAssertEqual(reopened.visualRemediationReviewID, review.id)
        XCTAssertNil(reopened.landedAt)
        XCTAssertTrue(reopened.triedPlatforms.isEmpty,
                      "上一轮成功使用过 Kimi 不能反过来把 Kimi 排除掉")
        XCTAssertTrue(reopened.prompt.contains("左手悬空"))

        XCTAssertTrue(VisualQualityGate.reconcileRemediation([reopened, review]).isEmpty,
                      "同一张否决票每轮对账只能重开一次")

        let throughGraph = try XCTUnwrap(TaskGraph.reconcile([source, review])
            .first(where: { $0.id == source.id }))
        XCTAssertEqual(throughGraph.state, .queued,
                       "worker 每轮实际调用的是 TaskGraph.reconcile，闭环不能只停在孤立 helper")
        XCTAssertEqual(throughGraph.ownerRunnerID, "kimi.code")

        var falselyCompleted = reopened
        falselyCompleted.state = .done
        falselyCompleted.note = "派活前核实：分支 \(branch) 已合入 main，产出早已落地"
        let recovered = try XCTUnwrap(VisualQualityGate.reconcileRemediation(
            [falselyCompleted, review]).only)
        XCTAssertEqual(recovered.state, .queued,
                       "旧分支已合入是上一轮事实，不能把本轮视觉整改判成早已完成")
        XCTAssertEqual(recovered.prompt, reopened.prompt,
                       "恢复假完成不能把同一份视觉报告重复追加进提示词")
    }

    func testOlderRejectedSampleIsIgnoredWhenNewerContinuationExists() {
        let branch = "agent/kimi/old"
        var old = WorkTask(id: "old", prompt: "第一轮", repo: "/flint")
        old.state = .done
        old.branch = branch
        old.createdAt = Date(timeIntervalSince1970: 1)
        old.production = ProductionContext(
            stage: .goldenSample, deliverableKind: "operator-character",
            goldenSampleID: "operator-v1", requiresExperienceApproval: true)
        let rejected = visual(id: "eyes-old", branch: branch, head: "aaa",
                              verdict: "未达标", endedAt: Date(timeIntervalSince1970: 10))
        var continuation = WorkTask(id: "new", prompt: "第二轮整改", repo: "/flint")
        continuation.createdAt = Date(timeIntervalSince1970: 20)
        continuation.production = old.production

        XCTAssertTrue(VisualQualityGate.reconcileRemediation(
            [old, rejected, continuation]).isEmpty,
            "部署闭环机制不能把已经被后续续作接住的历史否决重新翻出来")
    }

    private func visual(id: String, branch: String, head: String,
                        verdict: String, endedAt: Date) -> WorkTask {
        var task = WorkTask(
            id: id,
            prompt: "【看效果】分支 \(branch) 提交 \(head) 的视觉质量是否达到项目契约。",
            repo: "/flint")
        task.origin = "visual-quality-review"
        task.state = .done
        task.createdAt = endedAt.addingTimeInterval(-1)
        task.endedAt = endedAt
        task.outputs = ["**结论**：\(verdict)"]
        return task
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
