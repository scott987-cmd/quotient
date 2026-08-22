import XCTest
@testable import LLMQuotaCore

/// 搁浅的任务图必须被看见。
///
/// 真实事故（Greed，2026-08-16 → 08-17）：任务图 f2872114 的 s1–s4 全部完成，
/// 产出 AudioManager、存档层、主菜单外壳共 19 个文件，s5 跑挂了。
/// 于是整条分支躺了一整天，**没有任何界面提过一个字**：
///
///     一步失败 → reconcile 把下游冻成 blocked
///     → Review.list 把「有 blocked 节点」当成「图还在跑」，跳过这条分支
///     → 分支进不了待验收名单，手机上看不见
///     → Nudge 第 3 条特意排掉 frozenBy 那些（「上游恢复后会自动解冻」），
///        可上游是 failed，根本不会恢复 → 推送也不喊
///
/// 三道各自正确的规则串起来，成了一条完整的静默死亡链。
/// 最后是人手工敲 `git branch` 发现的。
///
/// 这些测试钉住的是那条链上的分岔：**搁浅**必须和**还在跑**、
/// **等人放行**分开，因为三者要的处置完全不同。
final class StrandedGraphTests: XCTestCase {

    private func step(_ id: String, _ graph: String, _ state: WorkTask.State,
                      frozenBy: String? = nil, title: String? = nil) -> WorkTask {
        var t = WorkTask(id: id, prompt: "x", repo: "/tmp/demo")
        t.graphID = graph
        t.state = state
        t.frozenBy = frozenBy
        t.stepTitle = title ?? id
        return t
    }

    /// 事故本身：完成几步、挂一步、剩下被冻 —— 这是搁浅。
    func testFailedStepWithFrozenDownstreamIsStranded() {
        let tasks = [
            step("s1", "g1", .done),
            step("s2", "g1", .done),
            step("s3", "g1", .failed, title: "应用外壳"),
            step("s4", "g1", .blocked, frozenBy: "s3"),
            step("s5", "g1", .blocked, frozenBy: "s3"),
        ]
        let strands = TaskGraph.stranded(tasks)
        XCTAssertEqual(strands.count, 1, "这正是 f2872114 的形状，必须认出来")
        XCTAssertEqual(strands.first?.doneCount, 2)
        XCTAssertEqual(strands.first?.frozenCount, 2)
        XCTAssertEqual(strands.first?.failedTitles, ["应用外壳"])
    }

    /// 还有步骤在跑 —— 不算搁浅，别打扰人。
    func testStillRunningIsNotStranded() {
        let tasks = [
            step("s1", "g1", .done),
            step("s2", "g1", .failed),
            step("s3", "g1", .running),
        ]
        XCTAssertTrue(TaskGraph.stranded(tasks).isEmpty,
                      "还有活在动，喊人是噪音")
    }

    /// **等人放行 ≠ 搁浅。** frozenBy == nil 的 blocked 是人工闸门拦下的，
    /// 人一点头就继续。把它算成搁浅，等于喊两遍同一件事。
    func testWaitingOnHumanIsNotStranded() {
        let tasks = [
            step("s1", "g1", .done),
            step("s2", "g1", .failed),
            step("s3", "g1", .blocked, frozenBy: nil),   // 人工闸门
        ]
        XCTAssertTrue(TaskGraph.stranded(tasks).isEmpty,
                      "这是在等人做决定，走审批那条路，不是搁浅")
    }

    /// 全挂、一步没成 —— 分支上没东西可捞，不占「搁浅」这个名额。
    func testAllFailedWithNoOutputIsNotStranded() {
        let tasks = [
            step("s1", "g1", .failed),
            step("s2", "g1", .failed),
        ]
        XCTAssertTrue(TaskGraph.stranded(tasks).isEmpty,
                      "没有完成的步骤也没有被冻的，走失败重试那条路")
    }

    /// 全部完成 —— 正常图，不该出现在搁浅名单里。
    func testFullyDoneIsNotStranded() {
        let tasks = [
            step("s1", "g1", .done),
            step("s2", "g1", .done),
        ]
        XCTAssertTrue(TaskGraph.stranded(tasks).isEmpty)
    }

    /// 产出多的排前面 —— 那条最该先捞。
    func testSortedBySalvageValue() {
        let tasks = [
            step("a1", "small", .done),
            step("a2", "small", .failed),
            step("a3", "small", .blocked, frozenBy: "a2"),
            step("b1", "big", .done),
            step("b2", "big", .done),
            step("b3", "big", .done),
            step("b4", "big", .failed),
            step("b5", "big", .blocked, frozenBy: "b4"),
        ]
        let strands = TaskGraph.stranded(tasks)
        XCTAssertEqual(strands.count, 2)
        XCTAssertEqual(strands.first?.graphID, "big", "完成得多的该排前面")
    }

    /// **搁浅了必须有人知道 —— 但那个人是 Claude,不是老板。**
    ///
    /// 原来这条断言的是「要推给老板」。理由(搁浅的活会整条躺一天没人发现)
    /// 照旧成立,变的是**喊给谁**:老板 2026-08-22 的常设指示是
    /// 「阻塞任务你来看处理,给我应该就是风险类或者验收类」。
    /// 而且这条推送一直没有对应页面,他点进去是空的 —— 报过两次。
    ///
    /// 所以现在:不进他的推送,进 `llmq work blocked`(Claude 的队列)。
    /// 这条测试守的是**不能悄无声息**,不是「必须推给老板」。
    func testStrandedIsVisibleToClaudeNotPushedToBoss() {
        let tasks = [
            step("s1", "g1", .done),
            step("s2", "g1", .failed),
            step("s3", "g1", .blocked, frozenBy: "s2"),
        ]
        XCTAssertFalse(Nudge.pending(tasks: tasks).contains { $0.key == "stranded-graph" },
                       "纯技术问题不该占用老板的注意力")
        XCTAssertFalse(TaskGraph.stranded(tasks).isEmpty,
                       "但它必须仍然被识别出来 —— `llmq work blocked` 靠这个列出来")
    }
}
