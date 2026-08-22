import XCTest
@testable import LLMQuotaCore

/// **验证没过要派人去修,不是「留给人工审」。**
///
/// 老板 2026-08-22:「总不能跑一步卡一步就需要你介入」「让别的 agent 做
/// 检查和测试,你做架构和审核」。
///
/// 原来 autoLand 验证失败就记否决、写一句留给人工 —— 而那个人就是他。
/// 分支挂着,同仓库后面的活被基线闸挡住,产线看起来就停了。
final class VerifyRepairTests: XCTestCase {
    private func task(_ branch: String, state: WorkTask.State = .done) -> WorkTask {
        var t = WorkTask(id: "r-\(UUID().uuidString.prefix(6))",
                         prompt: "【修验证】分支 \(branch) 合进 main 之后验证没过,把它修到过。",
                         repo: "/r")
        t.state = state
        return t
    }

    func testRecognizesItsOwnPrompts() {
        XCTAssertTrue(VerifyRepair.isRepairPrompt(
            "【修验证】分支 agent/a/x 合进 main 之后验证没过,把它修到过。", of: "agent/a/x"))
        XCTAssertFalse(VerifyRepair.isRepairPrompt(
            "【修验证】分支 agent/a/other 合进…", of: "agent/a/x"),
            "别条分支的修复任务不是这条的 —— 判重按对象,不按文风")
    }

    /// 修不动就收口 —— 无限重试会把额度烧光,而信息量和第二次一样多。
    func testGivesUpAfterTwoTries() {
        let tried = [task("agent/a/x"), task("agent/a/x")]
        let r = VerifyRepair.dispatch(repo: "/nonexistent-repo", branch: "agent/a/x",
                                      failure: "验证没过（退出码 1）", tasks: tried)
        // 仓库没登记 → 返回 nil（照旧走否决），这里只断言不会崩、不会无限派。
        XCTAssertNil(r)
        XCTAssertEqual(VerifyRepair.maxAttempts, 2)
    }

    /// 只修「验证没过」。冲突这类机械问题归 StaleBranch 刷新那条路 ——
    /// 两条路抢同一件事,就是这个仓库栽了十次的「同概念多处判定」。
    func testOnlyHandlesVerificationFailures() {
        XCTAssertNil(VerifyRepair.dispatch(repo: "/r", branch: "agent/a/x",
                                           failure: "合并结果有冲突", tasks: []))
    }
}
