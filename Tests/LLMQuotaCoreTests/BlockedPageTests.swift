import XCTest
@testable import LLMQuotaCore

/// **别推人做不到的事。**
///
/// 老板 2026-08-22:「刚刚高危拦截,我确认了,但是手机端一直在重复弹出来
/// 让我确认」。通知说「1 个任务被拦下等你放行」,而 App 那边只把 blocked
/// 当成一个计数显示,没有任何按钮会写出放行指令 —— 他点了也没用,
/// 任务永远卡着,提醒永远在。和成果推送那次一模一样的形状。
final class BlockedPageTests: XCTestCase {
    private func task(_ id: String, state: WorkTask.State, note: String) -> WorkTask {
        var t = WorkTask(id: id, prompt: "改 Tools/gen-skin.py 生成皮肤贴图", repo: "/r/Flint")
        t.state = state
        t.note = note
        return t
    }

    func testWaitingForHumanGetsAnApproveButton() {
        let p = ViewFeed.blockedPage(tasks: [
            task("t1", state: .blocked, note: "碰到高危路径（Tools/gen-skin.py），等你确认")])
        let ids = p.sections.flatMap { $0.cards ?? [] }.flatMap { $0.actions ?? [] }.map(\.id)
        XCTAssertTrue(ids.contains("task:approve:t1"),
                      "有提醒就必须有按钮 —— 否则人点了也没用")
        XCTAssertTrue(ids.contains("task:discard:t1"), "也要能说「这步不做了」")
    }

    /// 上游没完成而冻住的不算「等你放行」—— 人对它们无事可做,
    /// 混进来只会让这一页变成噪音,真正要他拍板的那条反而被淹掉。
    func testFrozenByUpstreamIsNotListed() {
        let p = ViewFeed.blockedPage(tasks: [
            task("t2", state: .blocked, note: "上游「烘焙贴图」在等人处理，这一步先冻住。上游恢复后会自动解冻。")])
        XCTAssertTrue(p.sections.flatMap { $0.cards ?? [] }.isEmpty,
                      "自动会解冻的不该占人的注意力")
    }

    func testEmptyStateIsReassuring() {
        let p = ViewFeed.blockedPage(tasks: [])
        XCTAssertEqual(p.page, "blocked")
        XCTAssertFalse(p.sections.isEmpty, "空也要说一句话,不能是一片空白")
    }
}
