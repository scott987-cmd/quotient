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
}
