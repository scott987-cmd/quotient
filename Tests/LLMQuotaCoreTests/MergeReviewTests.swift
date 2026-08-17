import XCTest
@testable import LLMQuotaCore

/// 代码合入审核交给专用 agent 判，人不参与。
///
/// 老板的原话：「代码合入审核，你让专用 agent 去判断就可以了」。
///
/// 这个文件里最要紧的是 `parseVerdict`：**读错方向的后果是把机器不敢合的
/// 东西直接合进主干**。「不合入」里包含「合入」二字，先匹配哪个决定了
/// 所有否决是被当成否决、还是被当成放行。
final class MergeReviewTests: XCTestCase {

    // MARK: 结论解析 —— 这一组是安全关键

    /// **「不合入」不能被读成「合入」。**
    ///
    /// 「不合入」这三个字里就含着「合入」。如果先匹配「合入」，
    /// 每一次否决都会变成放行 —— 而且外面看起来一切正常：
    /// 报告里明明白白写着不合入，机器却合了。
    func testRejectIsNeverReadAsApproval() {
        let forms = [
            "**结论**：不合入",
            "结论：不合入",
            "**结论**： 不合入（改动会破坏存档兼容）",
            "## 结论\n不合入",   // 结论在标题行，正文在下一行
        ]
        for f in forms {
            XCTAssertNotEqual(MergeReview.parseVerdict(f), .land,
                              "「\(f)」被读成了放行 —— 这是最危险的一种错")
        }
        // 前三种应该明确读出否决；第四种「结论」和「不合入」不同行，
        // 读不出来（返回 nil）是可以接受的 —— 不算票也不算否，会再派一次。
        XCTAssertEqual(MergeReview.parseVerdict("**结论**：不合入"), .reject)
        XCTAssertEqual(MergeReview.parseVerdict("结论：不合入"), .reject)
    }

    func testApprovalIsRead() {
        XCTAssertEqual(MergeReview.parseVerdict("**结论**：合入"), .land)
        XCTAssertEqual(MergeReview.parseVerdict("结论：合入\n\n## 判断依据"), .land)
    }

    /// 读不出结论就是读不出，别猜。
    ///
    /// 猜的代价不对称：猜成「合入」会把没过审的东西合进主干；
    /// 猜成「不合入」会把好产出永久钉死。返回 nil 让它再派一次，
    /// 是唯一不押注的选择。
    func testUnparseableVerdictIsNil() {
        XCTAssertNil(MergeReview.parseVerdict("报告写歪了，没给结论"))
        XCTAssertNil(MergeReview.parseVerdict(""))
        XCTAssertNil(MergeReview.parseVerdict("结论：看不出来"))
    }

    // MARK: 票数

    /// 碰构建 / CI / 签名的要两票。
    ///
    /// 这一类决定「验收通过」这句话算不算数：改坏了它，之后所有改动都会
    /// 自动过关，而且没人会发现。不是不信任 agent，是这一类的失败**会静默地
    /// 废掉后面所有的把关**，所以要两次独立审核都点头。
    func testSelfReferentialChangesNeedTwoApprovals() {
        XCTAssertEqual(MergeReview.requiredApprovals(
            files: [".github/workflows/ci.yml"]), 2)
        XCTAssertEqual(MergeReview.requiredApprovals(files: ["build-app.sh"]), 2)
        XCTAssertEqual(MergeReview.requiredApprovals(
            files: ["Sources/X/Format.swift"]), 1, "普通代码一票就够")
    }

    /// 一票否决：有一个说不合入，就不再派、不再合。
    ///
    /// 不搞「多数通过」—— 一个审核人明确指出了问题，再找一个说没问题
    /// 就放行，等于把审核变成了摇号。
    func testOneRejectionBlocksEvenWithApprovals() {
        let tasks = [
            reviewTask("r1", branch: "agent/a/x", verdict: "**结论**：合入"),
            reviewTask("r2", branch: "agent/a/x", verdict: "**结论**：不合入"),
        ]
        XCTAssertFalse(MergeReview.approved(branch: "agent/a/x",
                                            files: ["A.swift"], tasks: tasks),
                       "一票否决 —— 再凑同意票不能翻案")
    }

    /// 没派过审核的分支不算过审 —— 默认不放行。
    func testUnreviewedBranchIsNotApproved() {
        XCTAssertFalse(MergeReview.approved(branch: "agent/a/never",
                                            files: ["A.swift"], tasks: []),
                       "没审过就默认不放行，不能靠「没人反对」过关")
    }

    /// 两票门槛下，一票不够。
    func testOneApprovalIsNotEnoughForRiskyPaths() {
        let tasks = [reviewTask("r1", branch: "agent/a/ci",
                                verdict: "**结论**：合入")]
        XCTAssertFalse(MergeReview.approved(branch: "agent/a/ci",
                                            files: ["build-app.sh"], tasks: tasks),
                       "碰构建脚本要两票，一票不能放行")
        let two = tasks + [reviewTask("r2", branch: "agent/a/ci",
                                      verdict: "**结论**：合入")]
        XCTAssertTrue(MergeReview.approved(branch: "agent/a/ci",
                                          files: ["build-app.sh"], tasks: two))
    }

    /// 还在跑的审核任务不算票。
    func testRunningReviewDoesNotCount() {
        var t = reviewTask("r1", branch: "agent/a/x", verdict: "**结论**：合入")
        t.state = .running
        XCTAssertFalse(MergeReview.approved(branch: "agent/a/x",
                                            files: ["A.swift"], tasks: [t]),
                       "跑着的审核还没出结论，不能算票")
    }

    /// 碰构建脚本的提示词要点名让它查「验证会不会被绕过」。
    func testTwoVotePromptAsksAboutVerificationBypass() {
        let c = MergeReview.Candidate(
            branch: "agent/a/ci", repo: "/tmp/x", files: ["build-app.sh"],
            subject: "改构建脚本", whyNotMechanical: "碰了构建路径", needed: 2)
        let p = MergeReview.reviewPrompt(c)
        XCTAssertTrue(p.contains("还会真的跑测试吗"),
                      "得点名问「验证有没有被绕过」—— 那是这一类唯一真正要紧的事")
        XCTAssertTrue(p.contains("【审查·合入】"),
                      "前缀决定它走评审平台、以及执行器选哪套材料")
    }

    // MARK: 辅助

    private func reviewTask(_ id: String, branch: String,
                            verdict: String) -> WorkTask {
        var t = WorkTask(id: id,
                         prompt: "【审查·合入】分支 \(branch) 的改动能不能合进 main。",
                         repo: "/tmp/x")
        t.state = .done
        t.outputs = ["# 合入审核：\(branch)", verdict]
        return t
    }
}
