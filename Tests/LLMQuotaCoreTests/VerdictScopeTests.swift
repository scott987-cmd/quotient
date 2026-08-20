import XCTest
@testable import LLMQuotaCore

/// **审核结论是针对某一版 diff 的，不是针对分支名的。**
///
/// ## 这条对应的真实故障（2026-08-20）
///
/// `approvalsSoFar` 原来只按 `t.prompt.contains(branch)` 匹配审核任务 ——
/// 结论**永久绑在分支名上**。两个方向都出事，而且第二个更严重：
///
/// **① 被否的分支永远进不去。**
/// `agent/claude/009f44f5` 把 107 个伪装成 PNG 的 JPEG 转成真 PNG，
/// 评审判不合入，理由是「分支里看不到任何验证证据」—— 这条理由成立。
/// 证据（可重跑的核对脚本 + 真实输出）补进分支之后，`rejected` 照旧为真。
/// 唯一的出路变成「人工丢弃那条否决」，而**人工绕过一个 no**
/// 正是这套审核机制存在的意义所要防的事。
///
/// **② 拿到票之后往分支上推什么都能进。**
/// 一票同意之后追加任意提交，`approvals` 照样成立 ——
/// 审核闸对新提交等于不存在。这一头没人报过障，因为它不会让人卡住，
/// 只会让东西**悄悄合进去**。
final class VerdictScopeTests: XCTestCase {

    private func review(_ branch: String, head: String?, verdict: String,
                        endedAt: Date? = nil) -> WorkTask {
        var p = "【审查·合入】分支 \(branch) 的改动能不能合进 main。\n"
        if let head { p += MergeReview.headMarker(head) + "\n" }
        var t = WorkTask(id: "r-" + branch, prompt: p, repo: "/tmp/x")
        t.state = .done
        t.outputs = ["**结论**：\(verdict)"]
        t.endedAt = endedAt
        return t
    }

    // MARK: 标记要能写进去、读回来

    func testHeadMarkerRoundTrips() {
        let p = "【审查·合入】分支 agent/a/b\n" + MergeReview.headMarker("2b555f4")
        XCTAssertEqual(MergeReview.reviewedHead(in: p), "2b555f4")
    }

    /// 老格式（2026-08-20 之前派的）没有这个标记。
    func testOldPromptHasNoRecordedHead() {
        XCTAssertNil(MergeReview.reviewedHead(in: "【审查·合入】分支 agent/a/b 能不能合"))
    }

    /// 空 head 不写标记 —— 免得写出个「被审提交：」的空壳，
    /// 读回来是 nil 却看着像有记录。
    func testEmptyHeadWritesNoMarker() {
        XCTAssertEqual(MergeReview.headMarker(""), "")
    }

    // MARK: ① 改好了要能重新判

    func testRejectionDoesNotStickAfterBranchMovesOn() {
        let old = review("agent/claude/009f44f5", head: "2b555f4", verdict: "不合入")
        // 分支现在的头是 7a1c11d —— 补证据那个提交。
        let r = MergeReview.approvalsSoFar(branch: "agent/claude/009f44f5",
                                           tasks: [old], head: "7a1c11d")
        XCTAssertFalse(r.rejected,
                       "那条否决审的是 2b555f4；改动已经回应了意见并重新提交，"
                       + "结论不该跟着分支名一直生效 —— 否则唯一的出路是"
                       + "人工绕过一个 no，而那正是这套机制要防的事")
        XCTAssertEqual(r.attempts, 0,
                       "过期的结论连 attempts 都不能算：贴着上限的话 "
                       + "exhausted 会立刻收口，新的一版根本轮不到被审")
    }

    /// **但同一版被否就是被否** —— 别把「能重判」做成「否决无效」。
    func testRejectionStillHoldsForTheSameCommit() {
        let no = review("agent/a/x", head: "2b555f4", verdict: "不合入")
        let r = MergeReview.approvalsSoFar(branch: "agent/a/x",
                                           tasks: [no], head: "2b555f4")
        XCTAssertTrue(r.rejected, "同一个提交，结论照旧算数")
    }

    // MARK: ② 拿到票之后不能再推东西进去

    func testApprovalDoesNotCarryOverToNewCommits() {
        let yes = review("agent/a/y", head: "aaaaaaa", verdict: "合入")
        XCTAssertTrue(
            MergeReview.approved(branch: "agent/a/y", files: ["a.swift"],
                                 tasks: [yes], head: "aaaaaaa"),
            "审过的那一版当然算数")
        XCTAssertFalse(
            MergeReview.approved(branch: "agent/a/y", files: ["a.swift"],
                                 tasks: [yes], head: "bbbbbbb"),
            "拿到票之后又推了新提交 —— 那一票没审过它。"
            + "这一头不会让人卡住，只会让没审过的东西悄悄合进 main")
    }

    // MARK: 老审核任务的兜底

    /// 老格式没记 sha。全当有效则上面第二个洞继续开着；
    /// 全当无效会把判过的分支重派一遍白烧额度。用时间兜底。
    func testOldVerdictGoesStaleWhenBranchGotNewerCommits() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let old = review("agent/a/z", head: nil, verdict: "不合入", endedAt: t0)
        let after = MergeReview.approvalsSoFar(
            branch: "agent/a/z", tasks: [old],
            headAt: t0.addingTimeInterval(60))     // 审完之后又提交了
        XCTAssertFalse(after.rejected, "审核结束之后分支又动了 —— 那条结论过期")

        let before = MergeReview.approvalsSoFar(
            branch: "agent/a/z", tasks: [old],
            headAt: t0.addingTimeInterval(-60))    // 分支停在审核之前
        XCTAssertTrue(before.rejected, "分支没动过，老结论照旧算数")
    }

    /// 什么都不传时保持老行为 —— 还没接上的调用点不该被这次改动改变语义。
    func testWithoutHeadInfoBehaviourIsUnchanged() {
        let no = review("agent/a/w", head: "aaaaaaa", verdict: "不合入")
        XCTAssertTrue(MergeReview.approvalsSoFar(branch: "agent/a/w",
                                                  tasks: [no]).rejected)
    }
}

/// **高危提示词要点名是哪个文件触发的，不要替评审下结论。**
///
/// ## 这条对应的真实故障（2026-08-20）
///
/// 触发判据 `GitWorkspace.isRiskyPath` 很粗：**任何** `.sh` 都算，
/// 包括 `reviews/verify-*.sh` 这种纯核对脚本 —— 它跟「验收算不算数」
/// 毫无关系。而提示词原来直接断言「这条改动碰了决定验收通过算不算数的
/// 东西（构建脚本 / CI / 签名配置）」。
///
/// 后果：评审拿**整个第 1 条**去反驳这句话（「分诊器判成高危是误报」），
/// 而它是对的。一句不准确的断言，换来的是评审注意力被引开。
///
/// **判据本身不放松。** 它的假阳性只是多要一票，假阴性是审核闸被绕过 ——
/// 不对称摆在那，为了减少摩擦去放松一道安全闸是本末倒置。该改的是措辞。
final class RiskyPromptWordingTests: XCTestCase {

    private func candidate(files: [String]) -> MergeReview.Candidate {
        .init(branch: "agent/a/x", repo: "/tmp/x", files: files,
              subject: "改了点东西", whyNotMechanical: "分诊判成高危",
              needed: 2, head: "abc1234", headAt: nil)
    }

    func testNamesTheFileThatTriggeredIt() {
        let p = MergeReview.reviewPrompt(
            candidate(files: ["reviews/verify-png.sh", "pack-01/a.png"]))
        XCTAssertTrue(p.contains("reviews/verify-png.sh"),
                      "要点名是哪个文件触发的，评审才能自己判断是不是误报：\n\(p)")
        XCTAssertFalse(p.contains("pack-01/a.png"),
                       "没触发判据的文件别混进来 —— 那会让这份名单失去意义")
    }

    /// **别再断言它「碰了构建/CI/签名」** —— 那句话可能是假的。
    func testDoesNotAssertWhatTheChangeTouched() {
        let p = MergeReview.reviewPrompt(candidate(files: ["reviews/x.sh"]))
        XCTAssertFalse(p.contains("**这条改动碰了决定「验收通过」算不算数的东西**"),
                       "这是断言，不是事实 —— 判据粗到任何 .sh 都算")
        XCTAssertTrue(p.contains("误报"),
                      "要明确告诉评审「判据很粗，可能误报，误报就直说」，"
                      + "否则它会花一整条去反驳这个前提：\n\(p)")
    }

    /// 需要 1 票的改动不该看到这一整段。
    func testSingleVoteChangesGetNoRiskSection() {
        var c = candidate(files: ["reviews/x.sh"])
        c.needed = 1
        XCTAssertFalse(MergeReview.reviewPrompt(c).contains("误报"))
    }

    /// 被审提交要写进提示词 —— 结论绑提交靠的就是它。
    func testPromptCarriesTheReviewedHead() {
        let p = MergeReview.reviewPrompt(candidate(files: ["a.png"]))
        XCTAssertEqual(MergeReview.reviewedHead(in: p), "abc1234")
    }
}

/// **计票只认「审这条分支」的任务 —— 提到这条分支的不算。**
///
/// ## 这条对应的真实污染（2026-08-20 实测）
///
/// 原判法是 `isReview && prompt.contains("合入") && prompt.contains(branch)`。
/// 而落地后系统会自动排**复查**任务，提示词长这样：
///
///     【审查】复查刚合入 main 的合并 8dbb47c（来源分支 agent/graph/3f68707c）
///
/// 「刚合入」含「合入」、括号里含分支名 —— 三个条件全中。于是一条
/// **复查**任务被当成那条分支的合入审核计票、计次数。票数被无关任务
/// 污染的审核闸，判出来的就不是这条分支的事实。
final class VoteMatchingPrecisionTests: XCTestCase {

    func testPostLandRecheckDoesNotPolluteTheVote() {
        var t = WorkTask(
            id: "rc1",
            prompt: "【审查】复查刚合入 main 的合并 8dbb47c（来源分支 "
                + "agent/graph/3f68707c）。\n步骤：用 `git show 8dbb47c` 读完整 diff",
            repo: "/tmp/x")
        t.state = .done
        t.outputs = ["**结论**：不合入"]   // 就算它写了结论也不关这条分支的事
        let r = MergeReview.approvalsSoFar(branch: "agent/graph/3f68707c",
                                           tasks: [t])
        XCTAssertEqual(r.attempts, 0,
                       "复查任务不是这条分支的合入审核 —— 计进去，"
                       + "attempts 会被污染、exhausted 会提前收口")
        XCTAssertFalse(r.rejected,
                       "更糟的是它的「结论」会被当成这条分支的否决")
    }

    /// 前缀吞并：`agent/a/x` 不能匹配到 `agent/a/xy` 的审核。
    func testBranchNameDoesNotSwallowSiblings() {
        var t = WorkTask(
            id: "rv1",
            prompt: "【审查·合入】分支 agent/a/xy 的改动能不能合进 main。",
            repo: "/tmp/x")
        t.state = .done
        t.outputs = ["**结论**：合入"]
        let r = MergeReview.approvalsSoFar(branch: "agent/a/x", tasks: [t])
        XCTAssertEqual(r.attempts, 0, "xy 的审核不是 x 的审核")
        XCTAssertEqual(r.approvals, 0, "更不能把 xy 的同意票记到 x 头上")
    }
}
