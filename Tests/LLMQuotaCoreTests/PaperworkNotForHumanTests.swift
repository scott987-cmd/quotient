import XCTest
@testable import LLMQuotaCore

/// **系统自己的记账不该排队等人点。**
///
/// ## 这条对应的真实故障
///
/// 老板的原话（2026-08-18）：「验收任务发给我的，怎么还有一堆合代码的，
/// 不是说过我只看人可阅读验证的成功，比如游戏截图、运行结果」。
///
/// 实测（2026-08-19）：老板在手机上批完三条真产出，一分钟内待审列表里
/// 又冒出两条 ——
///
/// - `agent/kimi/51d4180c`：一份 42 行的单元测试复跑日志（.txt）
/// - `agent/minimax/b42387d0`：一份 30 行的 EVAL 合入报告（.md）
///
/// 两条都**一行游戏代码都没碰**。它们是系统在给自己记账，
/// 却因为落在 `manualReview` 仓库里，被当成「要人看效果的产出」
/// 推到人面前排队。
///
/// 根因不是循环（审查产出不再触发审查那道闸是好的），
/// 而是 `manualReview` 这个开关**分不清「产品改动」和「系统记账」**：
/// 证据那一关已经认 `changesVisibleBehavior`（文书不用交图），
/// 可 `needsReview` 那一关是无条件的 —— 于是文书落进
/// 「不用交证据、却要等 agent 审」的半卡死状态。
final class PaperworkNotForHumanTests: XCTestCase {

    /// **EVAL 报告不是「人看得见的改动」。**
    ///
    /// 这一条盯的是判据本身。判错的后果是让评审 agent
    /// 去评审一份评审报告 —— 循环，而且要人在中间点一下。
    func testReviewReportIsNotVisibleChange() {
        XCTAssertFalse(
            EvidenceGate.changesVisibleBehavior(["reviews/EVAL-合入-f0172ef-b42387d0.md"]),
            "一份 markdown 报告没有任何可看的效果")
    }

    /// 证据日志同理 —— 它本身就是证据，不需要再为它交一份证据。
    func testEvidenceLogIsNotVisibleChange() {
        XCTAssertFalse(
            EvidenceGate.changesVisibleBehavior(["docs/evidence/unit-tests-abc21d46-rerun.txt"]),
            "测试复跑日志是证据，不是要人验收的产出")
    }

    /// **但真碰了游戏代码的，一个都不能放过。**
    ///
    /// 别把「别拿文书烦人」做成「什么都不用审」——
    /// manualReview 存在的理由一个字没变：手感和画面只有实跑才看得出来。
    func testRealGameCodeStillNeedsTheHighBar() {
        XCTAssertTrue(
            EvidenceGate.changesVisibleBehavior(["Maw/Tuning.swift"]),
            "改了调参就是改了手感 —— 必须走「有证据 + agent 审」那条路")
        XCTAssertTrue(
            EvidenceGate.changesVisibleBehavior(
                ["docs/evidence/shot.png", "Maw/GameScene.swift"]),
            "混了游戏代码就算看得见 —— 不能因为顺带带了张图就放行")
    }

    /// 录屏本身也不算「被改的东西」—— 它是证据，不是产出。
    func testRecordingIsEvidenceNotProduct() {
        XCTAssertFalse(
            EvidenceGate.changesVisibleBehavior(
                ["docs/evidence/s7/00-save-survives-terminate.mp4"]),
            "录屏是拿来看的，不是拿来验收的")
    }
    // MARK: 统一判据本身

    /// **纯文书在人工终审仓库里也不用过 agent 审。**
    ///
    /// 这一条盯的是抽出来的那个统一判据。它之所以存在，是因为
    /// 「这条要不要过 agent 审」原先在三个地方各写一份 ——
    /// 落地过滤、诊断输出、排队过滤。2026-08-19 我只改了落地那一处，
    /// 于是落地放行了、`llmq work why` 还在说「要 agent 审核……
    /// 还没派过审核」。**是系统自己的诊断把我的不彻底暴露的。**
    func testPaperworkSkipsAgentReviewEvenInManualReviewRepo() {
        XCTAssertFalse(Review.requiresAgentReview(
            files: ["reviews/EVAL-合入-f0172ef-b42387d0.md"],
            isStranded: false, repoNeedsManualReview: true, risk: nil),
            "让评审 agent 去评审一份评审报告是循环的，还要人在中间点一下")
    }

    /// **真碰了游戏代码的，人工终审仓库里一定要审。**
    func testGameCodeInManualReviewRepoNeedsAgentReview() {
        XCTAssertTrue(Review.requiresAgentReview(
            files: ["Maw/Tuning.swift"],
            isStranded: false, repoNeedsManualReview: true, risk: nil),
            "改了调参就是改了手感 —— manualReview 存在的理由一个字没变")
    }

    /// 非人工终审的仓库，普通改动本来就不用 agent 审。
    func testOrdinaryRepoDoesNotNeedAgentReview() {
        XCTAssertFalse(Review.requiresAgentReview(
            files: ["Sources/Foo.swift"],
            isStranded: false, repoNeedsManualReview: false, risk: nil))
    }

    /// **另外三个理由一个都不能被文书豁免顺手带掉。**
    ///
    /// 别把「别拿文书烦人」做成「什么都不用审」：搁浅图捞回来的、
    /// 敏感档的、碰构建/CI/签名的，哪怕改的全是 .md 也照样要审。
    func testOtherReasonsSurviveThePaperworkExemption() {
        let doc = ["docs/notes.md"]
        XCTAssertTrue(Review.requiresAgentReview(
            files: doc, isStranded: true,
            repoNeedsManualReview: false, risk: nil),
            "搁浅图捞回来的 —— 没人知道它当初为什么停")
        XCTAssertTrue(Review.requiresAgentReview(
            files: doc, isStranded: false,
            repoNeedsManualReview: false, risk: .sensitive),
            "敏感档就是敏感档，跟改了什么文件无关")
        XCTAssertTrue(Review.requiresAgentReview(
            files: ["build-app.sh"], isStranded: false,
            repoNeedsManualReview: false, risk: nil),
            "碰构建脚本 —— 验证会不会被绕过只有人/agent 看得出来")
    }

}
