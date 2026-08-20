import XCTest
@testable import LLMQuotaCore

/// **补证据也要有收口 —— 派够次数还交不出来就别再派。**
///
/// ## 这条对应的真实故障（2026-08-20）
///
/// `dispatchEvidence` 原来只靠查重挡重复：查重挡得住「已经派过、还没跑完」，
/// 但任务一旦**失败或超时**，它就不再是重复项 —— 下一轮立刻重派，永远重派。
///
/// 实测：`agent/claude/009f44f5` 改的 107 个文件全是素材图片，
/// 而 AssetPacks 根本没有能跑起来截图的 App。补证据任务每轮派一次、
/// 每次跑满 **601 秒超时被杀**，然后再派。
///
/// ## 为什么这条特别值得钉
///
/// 这个洞旁边那条路**已经补过了**：审核派发有 `MergeReview.exhausted`，
/// 就是为同一件事写的（实测同两条分支一夜被派了 16 次和 13 次审核）。
/// 当时只补了审核那一侧，证据这一侧原样留着 ——
/// **同一个教训只学了一半**。
///
/// 所以这里复用同一个判据，不写第二份：两份迟早会漂移出不一样的答案，
/// 而那正是这个仓库反复踩的那种坑。
final class EvidenceRetryCapTests: XCTestCase {

    private func evidenceTask(_ branch: String, state: WorkTask.State) -> WorkTask {
        var t = WorkTask(id: "e-\(branch)-\(state.rawValue)-\(Int.random(in: 0...9999))",
                         prompt: "【证据】把分支 \(branch) 的改动跑起来，留下证据。",
                         repo: "/tmp/x")
        t.state = state
        return t
    }

    func testCountsEveryDispatchRegardlessOfOutcome() {
        let b = "agent/claude/009f44f5"
        let tasks = [evidenceTask(b, state: .failed),
                     evidenceTask(b, state: .done),
                     evidenceTask(b, state: .running)]
        XCTAssertEqual(EvidenceGate.evidenceAttempts(branch: b, tasks: tasks), 3,
                       "判「该不该再派」要数的是派出去过几次，跑成没跑成不影响")
    }

    /// 别把别的分支的次数算到这条头上。
    func testOtherBranchesDoNotCount() {
        let tasks = [evidenceTask("agent/a/x", state: .failed),
                     evidenceTask("agent/a/y", state: .failed)]
        XCTAssertEqual(
            EvidenceGate.evidenceAttempts(branch: "agent/a/x", tasks: tasks), 1)
    }

    /// 非证据任务不算 —— 提示词里提到分支名的任务多了去了。
    func testNonEvidenceTasksDoNotCount() {
        var review = WorkTask(
            id: "r1",
            prompt: "【审查·合入】分支 agent/a/x 的改动能不能合进 main。",
            repo: "/tmp/x")
        review.state = .done
        XCTAssertEqual(
            EvidenceGate.evidenceAttempts(branch: "agent/a/x", tasks: [review]), 0,
            "审核任务也提分支名，但它不是补证据")
    }

    /// **收口的判据只准有一处实现。**
    ///
    /// 这条不是形式主义：审核那一侧的宽限是「needed + 2」，
    /// 证据这一侧 needed 恒为 1，所以第 3 次之后停。
    /// 两边共用一个函数，改宽限时不会只改一半。
    func testStopsAfterTheSameGraceUsedByMergeReview() {
        XCTAssertFalse(MergeReview.exhausted(attempts: 2, needed: 1),
                       "第 2 次还在宽限内 —— 容得下「第一次挂了、重试一次成功」")
        XCTAssertTrue(MergeReview.exhausted(attempts: 3, needed: 1),
                      "第 3 次还交不出来，就该停了，留给人工")
    }
}

extension EvidenceRetryCapTests {
    /// 提示词里**提到**别的分支不算给那条分支派过证据。
    /// 同款污染在合入计票那边真实发生过（复查任务含「合入」+ 分支名）。
    func testMentioningAnotherBranchDoesNotCount() {
        var t = WorkTask(
            id: "ev-b",
            prompt: "【证据】把分支 agent/a/y 的改动跑起来，留下证据。"
                + "参考之前 agent/a/x 交证据的方式。",
            repo: "/tmp/x")
        t.state = .done
        XCTAssertEqual(EvidenceGate.evidenceAttempts(branch: "agent/a/x",
                                                     tasks: [t]), 0,
                       "这是给 y 派的证据任务，只是提了一嘴 x")
        XCTAssertEqual(EvidenceGate.evidenceAttempts(branch: "agent/a/y",
                                                     tasks: [t]), 1)
    }
}
