import XCTest
@testable import LLMQuotaCore

/// **做出来的东西要主动送到老板眼前。**
///
/// 老板(2026-08-22)的原话:「为啥没有录屏发给我进行评审?这个不应该
/// 你驱动,应该是我们的数字人程序在关键成果产出需要找我确认啊」。
///
/// 缺口是真的:manualReview 仓库由评审 agent 判合入、自动落地,分支
/// 从来不进「待验收」名单 —— 人被彻底跳过。而他看录屏发现的问题
/// (「跑的姿势不像真人」「手歪不拉几」)全是真的。
final class MilestoneTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmpDir() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRecordingWithVideoIsWorthShowing() {
        XCTAssertTrue(Milestone.isWorthShowing(files: [
            "Flint/Render/GameContainerView.swift",
            "docs/evidence/2026-08-21-bot-ai-v1-combat.mov"]),
            "带录屏 = 做出了能看效果的东西 = 该让老板看")
    }

    /// 纯文档/评审报告不打扰他 —— 天天弹的通知会被训练成背景噪音,
    /// 真成果那次也一起被划走。
    func testRoutineChangesDoNotNag() {
        XCTAssertFalse(Milestone.isWorthShowing(files: [
            "STATUS.md", "reviews/EVAL-合入-abc-def.md", "Flint/Sim/Economy.swift"]),
            "改代码但没有可看的效果 —— 不惊动他")
        XCTAssertFalse(Milestone.isWorthShowing(files: []))
    }

    /// 判据必须和证据闸同一套(isEvidenceFile),不许另写。
    /// 同一个概念多处判定,这个仓库已经踩过九次。
    func testUsesTheSameEvidenceJudgeAsTheGate() {
        XCTAssertEqual(Milestone.isWorthShowing(files: ["docs/evidence/run.log"]),
                       EvidenceGate.isEvidenceFile("docs/evidence/run.log"),
                       "文本实跑证据算不算,两边必须给同一个答案")
        XCTAssertEqual(Milestone.isWorthShowing(files: ["Assets/hero.png"]),
                       EvidenceGate.isEvidenceFile("Assets/hero.png"),
                       "随便一张美术图不因为是图片就算成果")
    }

    func testUnreviewedFiltersOutWhatBossAlreadySaw() {
        let seen = Milestone.Item(repo: "/r", repoName: "r", branch: "b1",
                                  mergeSHA: "aaa", subject: "看过的", landedAt: Date(),
                                  evidenceFiles: [], verdict: "行")
        let fresh = Milestone.Item(repo: "/r", repoName: "r", branch: "b2",
                                   mergeSHA: "bbb", subject: "没看的", landedAt: Date(),
                                   evidenceFiles: [], verdict: nil)
        Milestone.save([seen, fresh])
        XCTAssertEqual(Milestone.unreviewed().map(\.mergeSHA), ["bbb"],
                       "看过的不再打扰")
    }
}
