import XCTest
@testable import LLMQuotaCore

/// **派生任务(审查/证据/刷新)的判重必须按对象,不按文风。**
///
/// 这三类的提示词都是模板,通用查重拿模板和模板比必然误判。实锤两次:
/// 2026-08-21 上午审核派发(菜单分支 40+ 轮派不出、整仓空转);
/// 同日深夜刷新派发(音效分支 18 个文件落后 20 个提交,--dispatch 每次
/// 「无输出」,老板问「任务停了」才查到)。
final class DerivedDispatchPrecisionTests: XCTestCase {
    private func task(_ prompt: String, _ state: WorkTask.State) -> WorkTask {
        var t = WorkTask(id: "d-\(UUID().uuidString.prefix(6))", prompt: prompt, repo: "/tmp/x")
        t.state = state
        return t
    }

    func testSameBranchPendingRefreshIsDetected() {
        let t = task("【刷新】把 main 合进分支 agent/kimi/ab94c520，解决冲突。", .queued)
        XCTAssertTrue(TaskKind.hasPendingDerived(branch: "agent/kimi/ab94c520",
                                                 tasks: [t], kind: TaskKind.isRefresh))
    }

    /// 别条分支的同类任务不算重复 —— 这正是模糊查重犯的错。
    func testOtherBranchRefreshIsNotADuplicate() {
        let t = task("【刷新】把 main 合进分支 agent/claude/other，解决冲突。", .queued)
        XCTAssertFalse(TaskKind.hasPendingDerived(branch: "agent/kimi/ab94c520",
                                                  tasks: [t], kind: TaskKind.isRefresh))
    }

    /// 跑完的不算在排 —— 否则一条分支一辈子只能刷新一次。
    func testFinishedRefreshIsNotPending() {
        let t = task("【刷新】把 main 合进分支 agent/kimi/ab94c520，解决冲突。", .done)
        XCTAssertFalse(TaskKind.hasPendingDerived(branch: "agent/kimi/ab94c520",
                                                  tasks: [t], kind: TaskKind.isRefresh))
    }

    /// 类别要分开:同一条分支的**证据**任务不挡它的**刷新**。
    func testDifferentKindsDoNotBlockEachOther() {
        let ev = task("【证据】把分支 agent/kimi/ab94c520 的改动跑起来，留下证据。", .queued)
        XCTAssertFalse(TaskKind.hasPendingDerived(branch: "agent/kimi/ab94c520",
                                                  tasks: [ev], kind: TaskKind.isRefresh),
                       "证据任务不是刷新任务 —— 混判会让分支永远刷不了")
        XCTAssertTrue(TaskKind.hasPendingDerived(branch: "agent/kimi/ab94c520",
                                                 tasks: [ev], kind: TaskKind.isEvidence))
    }
}

extension DerivedDispatchPrecisionTests {
    /// **刷新也要收口** —— 和审核/证据共用同一个宽限判据。
    /// 实锤(2026-08-22):Maw 的 cdce40f3 落后 102 个提交,Kimi 10 分钟超时、
    /// 火山接力 20 分钟又超时,而它还会一轮一轮接着派。
    func testRefreshSharesTheSameGiveUpRule() {
        XCTAssertFalse(MergeReview.exhausted(attempts: 2, needed: 1),
                       "第 2 次还在宽限内:容得下「第一次挂了、重试一次成功」")
        XCTAssertTrue(MergeReview.exhausted(attempts: 3, needed: 1),
                      "第 3 次还刷不动就停,留给人工")
    }
}
