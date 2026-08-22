import XCTest
@testable import LLMQuotaCore

/// **人的待批队列里只放「有东西可看」的。**
///
/// 老板 2026-08-22:「minimax 咋都让人审批,不是说没有图片或者视频的
/// 申请不要找我批」。他在这条链上的角色是看效果 —— 没有图没有录屏,
/// 就没有他能判的东西。实测:四条只含 reviews/EVAL-*.md(评审 agent
/// 自己写的报告)的分支排在他队列里,还各自被另一个评审 agent 判不合入。
final class HumanQueueTests: XCTestCase {
    func testReportOnlyBranchIsNotForHuman() {
        XCTAssertFalse(
            ["reviews/EVAL-合入-362965b-5da7c996.md"].contains(where: EvidenceGate.isEvidenceFile),
            "评审报告不是效果证据 —— 让人去看一份 Markdown 报告没有意义")
    }

    func testRecordingIsForHuman() {
        XCTAssertTrue(
            ["docs/evidence/2026-08-21-bot-ai-v1-combat.mov"].contains(where: EvidenceGate.isEvidenceFile),
            "录屏正是他要看的东西")
    }

    /// 「要不要过 agent 审核」只准有一个实现 —— 抄条件就会漏条件。
    /// 实测漏的正是「且真碰了人看得见的东西」那一句(2026-08-22,第九次)。
    func testReportOnlyDoesNotRequireAgentReviewEither() {
        XCTAssertFalse(Review.requiresAgentReview(
            files: ["reviews/EVAL-合入-x.md"], isStranded: false,
            repoNeedsManualReview: true, risk: nil),
            "「看效果才合」的仓库里,一份纯报告也没有效果可看")
        XCTAssertTrue(Review.requiresAgentReview(
            files: ["Flint/Render/GameContainerView.swift"], isStranded: false,
            repoNeedsManualReview: true, risk: nil),
            "改了看得见的东西,该审还是要审")
    }
}
