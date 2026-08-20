import XCTest
@testable import LLMQuotaCore

/// **基线闸的亲任务豁免:任务自己的分支不算挡它的理由。**
///
/// ## 这条对应的真实死锁(2026-08-20,Flint 首日)
///
/// 移动手感任务在 Kimi 上超时失败,分支 agent/kimi/c3dcbbaa 躺着
/// 7 个文件的半成品。重试它时基线闸说「main 还差这条分支的成果没合,
/// 现在派会重造」—— **闸等分支合入,分支等任务跑完,任务被闸挡着**,
/// 三环扣死;而且旧顺序下这条被挡的任务还占着仓库租约的坑,
/// 排在后面的 10 条(含媒体)每轮被「让开」,整仓冻了半小时。
///
/// 豁免的道理和「审查/刷新任务豁免」同源:解锁钥匙不能被锁在门外。
/// 亲任务带着接力现场,是去**完成**那条分支的,不是拿旧基线重造。
final class BaselineOwnBranchTests: XCTestCase {

    private let stale = BaselineFreshness.Result.stale(
        branches: ["agent/kimi/c3dcbbaa"], files: 7)

    func testOwnBranchDoesNotBlockItsTask() {
        XCTAssertEqual(
            BaselineFreshness.blocks(stale, candidateBranch: "agent/kimi/c3dcbbaa"),
            .fresh,
            "任务自己的分支就是那份「没合的成果」—— 它是去完成的,不是重造")
    }

    func testOtherTasksAreStillBlocked() {
        XCTAssertEqual(
            BaselineFreshness.blocks(stale, candidateBranch: nil), stale,
            "没跑过的新任务(branch=nil)照样要等 —— 它真的会重造")
        XCTAssertEqual(
            BaselineFreshness.blocks(stale, candidateBranch: "agent/qwen/other"),
            stale,
            "别的任务照样要等")
    }

    /// 摘掉亲分支后还有别人的成果没合 → 仍然要等。
    /// 别把「豁免自己」做成「豁免一切」。
    func testExemptionRemovesOnlyOwnBranch() {
        let two = BaselineFreshness.Result.stale(
            branches: ["agent/kimi/c3dcbbaa", "agent/qwen/zzz"], files: 12)
        let out = BaselineFreshness.blocks(two, candidateBranch: "agent/kimi/c3dcbbaa")
        guard case .stale(let branches, _) = out else {
            return XCTFail("还有别人的成果没合,不能放行:\(out)")
        }
        XCTAssertEqual(branches, ["agent/qwen/zzz"],
                       "只摘自己的,别人的照挡")
    }

    func testFreshStaysFresh() {
        XCTAssertEqual(BaselineFreshness.blocks(.fresh, candidateBranch: "x"), .fresh)
    }
}
