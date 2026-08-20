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

    // MARK: 派活上限：读不出结论时不能永远重派

    /// **隔夜跑飞的正面复刻。**
    ///
    /// 2026-08-19 早上盘点：同两条分支被派了 **16 次和 13 次**合入审核，
    /// 每次跑 8~20 秒、零产出，一夜 29 次调用全打了水漂。
    ///
    /// 机制：第二票要跳过查重，所以 `dispatch` 传了 `force: attempts > 0`。
    /// 审核任务读不出结论时票数恒为 0、attempts 却一直涨 ——
    /// 「读不出就再派一次」在读不出结论时等于「永远再派」。
    ///
    /// 这条规则原先内联在 `dispatch` 里，而 `dispatch` 要跑 git、没法单测，
    /// 于是最该被钉住的规则一行覆盖都没有。抽出来就是为了这条测试。
    func testRunawayRedispatchIsCutOff() {
        XCTAssertTrue(MergeReview.exhausted(attempts: 16, needed: 1),
                      "派了 16 次还读不出结论必须停 —— 这就是那一夜烧掉的 29 次调用")
        XCTAssertTrue(MergeReview.exhausted(attempts: 13, needed: 1))
    }

    /// **别把「不失控」做成「不重试」。**
    ///
    /// 第一次读不出结论、重试一次就成，是正常抖动。
    /// 一次都不给重试等于把这条路直接堵死 —— 那是反方向的同一种坏。
    func testNormalRetryIsStillAllowed() {
        XCTAssertFalse(MergeReview.exhausted(attempts: 0, needed: 1), "还没派过")
        XCTAssertFalse(MergeReview.exhausted(attempts: 1, needed: 1),
                       "第一次没读出结论，得允许再派一次")
        XCTAssertFalse(MergeReview.exhausted(attempts: 2, needed: 1),
                       "宽限 2 次，这次还在额度内")
    }

    /// 上限跟着要求的票数走：要两票的分支，本来就得多派几次。
    func testGraceScalesWithRequiredVotes() {
        XCTAssertFalse(MergeReview.exhausted(attempts: 3, needed: 2),
                       "要两票，派 3 次还在合理范围")
        XCTAssertTrue(MergeReview.exhausted(attempts: 4, needed: 2),
                      "要两票却派了 4 次还没凑齐 —— 停")
    }

    /// 边界钉死：是 `>=` 不是 `>`。差这一个，跑飞的那条路就又通了。
    func testBoundaryIsInclusive() {
        XCTAssertTrue(MergeReview.exhausted(attempts: 3, needed: 1),
                      "needed + 2 这个点上就该停，不是过了才停")
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
    // MARK: 结论必须真的读得到

    /// **审核 agent 的结论走 outputs 这条路，别让它断掉。**
    ///
    /// 实测（2026-08-20）：`WorkTask.outputs` 在整个仓库里**没有任何地方
    /// 被赋值**，而 `approvalsSoFar` 恰恰从 outputs + note 里找「结论」。
    /// 于是：
    ///
    /// - 审核执行器把报告写进 `reviews/EVAL-合入-*.md`（里面有结论）
    /// - 又把结论行回显到 stdout
    /// - **stdout 被丢掉**，note 是「改了 1 个文件，已提交到 …」这种通用文案
    /// - parseVerdict 拿到的文本里永远不含「结论」，永远返回 nil
    ///
    /// 后果是老板要的「代码合入让 agent 判」**从来没生效过**：
    /// 两份报告白纸黑字写着「结论：不合入」，其中一份还明确说
    /// 「不要把它的产物推进 main」—— 系统一个字都没读到，
    /// 那条分支照旧被文书豁免放行、合进了 main。
    func testVerdictInOutputsIsCounted() {
        var t = WorkTask(id: "r1",
                         prompt: "【审查·合入】分支 agent/kimi/x 的改动能不能合进 main。",
                         repo: "/tmp/x")
        t.state = .done
        // 执行器回显的那一行，原样落在 outputs 里
        t.outputs = ["已写 reviews/EVAL-合入-abc123-r1.md（1442 字）",
                     "**结论**：合入"]
        let r = MergeReview.approvalsSoFar(branch: "agent/kimi/x", tasks: [t])
        XCTAssertEqual(r.approvals, 1,
                       "结论就在 outputs 里，读不到就等于这套审核不存在")
        XCTAssertFalse(r.rejected)
    }

    /// 否决同样要读得到 —— 而且这个方向错了更危险。
    func testRejectionInOutputsIsCounted() {
        var t = WorkTask(id: "r2",
                         prompt: "【审查·合入】分支 agent/kimi/y 的改动能不能合进 main。",
                         repo: "/tmp/x")
        t.state = .done
        t.outputs = ["**结论**：不合入"]
        let r = MergeReview.approvalsSoFar(branch: "agent/kimi/y", tasks: [t])
        XCTAssertTrue(r.rejected, "「不合入」读不到 = 机器不敢合的东西被放进主干")
        XCTAssertEqual(r.approvals, 0)
    }

    /// **outputs 是空的时候要如实报「读不出结论」**，不能默认放行。
    ///
    /// 这正是修复前的状态：任务 done、报告写了、outputs 空 ——
    /// 那时候正确的行为是「不算票」，而不是「当成同意」。
    func testEmptyOutputsCountsAsNoVerdict() {
        var t = WorkTask(id: "r3",
                         prompt: "【审查·合入】分支 agent/kimi/z 的改动能不能合进 main。",
                         repo: "/tmp/x")
        t.state = .done
        t.outputs = []
        t.note = "改了 1 个文件，已提交到 agent/minimax/r3（1 个提交是它自己打的）"
        let r = MergeReview.approvalsSoFar(branch: "agent/kimi/z", tasks: [t])
        XCTAssertEqual(r.approvals, 0, "没结论不能算同意")
        XCTAssertFalse(r.rejected, "没结论也不是否决 —— 是「读不出来」")
        XCTAssertEqual(r.attempts, 1, "但这一次尝试要记账，否则会无限重派")
    }

}
