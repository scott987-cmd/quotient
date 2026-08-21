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

/// **被否决的分支不冻结基线** —— 注释里承诺了很久、代码一直没做的那半句。
///
/// 实锤(2026-08-21 早):射击分支被评审判不合入,能干净合入、文件数
/// 也够,于是照样算「马上要落地的成果」——人物动捕/寻路/经济/菜单
/// 四路任务全部「等基线」,整仓冻住。老板的原话:「游戏人物为啥停了」。
///
/// 被否的分支有自己的处置路径(改好→否决过期→重审,或人工丢弃),
/// 挡新活等不来任何东西。注意语义要跟否决的绑提交走:测试直接压
/// check 之上那层没法做(check 要真 git 仓库),所以这条压的是
/// 「approvalsSoFar 的 rejected 判定 + check 里那个 guard 的组合行为」
/// 在 verdictIsStale 层面的正确性 —— 新提交出现后 rejected 翻回 false,
/// 分支重新有资格冻结基线,那是**对的**冻结。
final class RejectedBranchBaselineTests: XCTestCase {
    func testRejectionIsHeadBoundSoFreshCommitsFreezeAgain() {
        var review = WorkTask(
            id: "r-x",
            prompt: "【审查·合入】分支 agent/codex/a97a9027 的改动能不能合进 main。\n"
                + MergeReview.headMarker("aaa1111"),
            repo: "/tmp/x")
        review.state = .done
        review.outputs = ["**结论**：不合入"]
        let atOldHead = MergeReview.approvalsSoFar(
            branch: "agent/codex/a97a9027", tasks: [review], head: "aaa1111")
        XCTAssertTrue(atOldHead.rejected,
                      "被否那一版:rejected 为真 → 基线闸跳过它,仓库不冻")
        let afterFix = MergeReview.approvalsSoFar(
            branch: "agent/codex/a97a9027", tasks: [review], head: "bbb2222")
        XCTAssertFalse(afterFix.rejected,
                       "修复提交之后:否决过期 → 分支重新算待落地成果,"
                       + "重新冻结基线是**对的**行为")
    }
}
