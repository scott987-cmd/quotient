import XCTest
@testable import LLMQuotaCore

/// **派生任务(审查/证据/刷新)要能读出自己绑的分支** —— 派活前核
/// 「分支还在且未合」的第一步。对应 2026-08-20 一晚五例的过期白跑。
///
/// 三条用例的提示词全部取自**真实模板**(reviewPrompt / evidencePrompt /
/// StaleBranch 刷新),模板改了这里必须跟着红 —— 两侧契约。
final class BoundBranchTests: XCTestCase {

    func testReadsBranchFromAllThreeTemplates() {
        XCTAssertEqual(TaskKind.boundBranch(
            "【审查·合入】分支 agent/minimax/2841e486 的改动能不能合进 main。"),
            "agent/minimax/2841e486")
        XCTAssertEqual(TaskKind.boundBranch(
            "【证据】把分支 agent/kimi/e2c99415 的改动跑起来，留下人一眼能看出成败的证据。"),
            "agent/kimi/e2c99415")
        XCTAssertEqual(TaskKind.boundBranch(
            "【刷新】把 main 合进分支 agent/graph/ebbf79ab，解决冲突。"),
            "agent/graph/ebbf79ab",
            "刷新模板的分支名后面跟的是中文逗号,截取必须认它")
    }

    /// 普通任务没有目标分支 —— 别把提示词里顺嘴提到的分支当成绑定。
    func testOrdinaryPromptsBindNothing() {
        XCTAssertNil(TaskKind.boundBranch("给主角加一个二段跳"))
        XCTAssertNil(TaskKind.boundBranch(
            "参考 agent/kimi/xxx 的做法改一下移动参数"),
            "正文里提到分支不算绑定 —— 只认三份模板的固定开头")
        XCTAssertNil(TaskKind.boundBranch("【媒体】生成一张图\nIMG a.png :: 图"))
    }

    func testSupportingTaskBecomesObsoleteWhenSourceIsFrozenOrHandedOff() {
        var source = WorkTask(id: "74726e09", prompt: "旧黄金样板", repo: "/tmp/flint")
        source.branch = "agent/kimi/74726e09"
        source.pausedAt = Date()
        source.note = "旧美术任务冻结并保留"
        var review = WorkTask(
            id: "review1",
            prompt: "【审查·合入】分支 agent/kimi/74726e09 的改动能不能合进 main。",
            repo: "/tmp/flint")
        review.origin = "merge-review"

        XCTAssertEqual(
            TaskKind.obsoleteSupportingReason(review, among: [source, review]),
            "来源任务 74726e09 已冻结归档")

        source.pausedAt = nil
        source.note = nil
        source.branch = "agent/qwen/74726e09"
        XCTAssertEqual(
            TaskKind.obsoleteSupportingReason(review, among: [source, review]),
            "来源任务 74726e09 已交接到 agent/qwen/74726e09")

        source.branch = "agent/kimi/74726e09"
        source.landedAt = Date()
        XCTAssertEqual(
            TaskKind.obsoleteSupportingReason(review, among: [source, review]),
            "来源任务 74726e09 已合入 main，过程评审已完成使命")
    }
}
