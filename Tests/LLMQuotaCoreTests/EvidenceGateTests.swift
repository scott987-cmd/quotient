import XCTest
@testable import LLMQuotaCore

/// 证据闸：什么东西有资格出现在人面前。
///
/// 背景是老板的原话：「验收任务发给我的，怎么还有一堆合代码的，不是说过
/// 我只看人可阅读验证的成功，比如游戏截图、运行结果」。
///
/// 这里守两个方向的误判，两边都花钱：
/// - 漏判（该要证据没要）→ 人得自己 build + 装模拟器 + 跑一局才能判，
///   五分钟起步，而且每份都要重来；
/// - 误判（不该要却要了）→ 白派一次跑模拟器截图的重活。
final class EvidenceGateTests: XCTestCase {

    /// 纯文档 / 报告类不需要截图。
    ///
    /// 这是实测挡住的一批：Greed 有 7 条、Maw 有 1 条分支只改了一个
    /// `reviews/EVAL-项目-<sha>.md`。误判的话就是 8 次白跑的模拟器截图任务。
    func testDocOnlyBranchesNeedNoEvidence() {
        XCTAssertFalse(EvidenceGate.changesVisibleBehavior(
            ["reviews/EVAL-项目-8d55257.md"]),
            "一份评审报告截图截什么？")
        XCTAssertFalse(EvidenceGate.changesVisibleBehavior(
            ["STATUS.md", "docs/NOTES.md", "README.md"]))
        XCTAssertFalse(EvidenceGate.changesVisibleBehavior(
            ["project.yml", "config.json"]),
            "配置文件本身看不见 —— 它的效果要靠别的东西体现")
    }

    /// 动了源码就算看得见 —— 判据故意从宽。
    ///
    /// 宁可多要一次截图，也别让一个改了手感的分支悄悄合进去：
    /// 手感回归恰恰是测试测不出来的那类问题。
    func testSourceChangesNeedEvidence() {
        XCTAssertTrue(EvidenceGate.changesVisibleBehavior(
            ["Maw/PlayerNode.swift", "docs/NOTES.md"]),
            "混着文档也算 —— 只要有一个源码文件就得跑一遍")
        XCTAssertTrue(EvidenceGate.changesVisibleBehavior(["Sources/X/Format.swift"]))
    }

    /// 图片和录屏本身是证据，不是「被改的东西」。
    ///
    /// 不排掉的话会出现一个荒诞循环：一条只加了截图的分支被判成
    /// 「改了看得见的东西、没交证据」，于是派活去给截图截图。
    func testEvidenceFilesThemselvesDoNotCountAsChanges() {
        XCTAssertFalse(EvidenceGate.changesVisibleBehavior(
            ["docs/evidence/fix-form-s1.png", "reviews/eating-bite-review.mov"]),
            "给截图截图是个死循环")
    }

    /// 补证据的指令必须挡住「交一张构建成功的终端截图」。
    ///
    /// 这是最容易发生的偷懒：截图确实交了，人看到的信息量是零，
    /// 还得自己再跑一遍 —— 这次派活等于白花，而且外面看起来是「已交证据」。
    func testEvidencePromptRejectsBuildLogScreenshots() {
        let c = EvidenceGate.Candidate(
            branch: "agent/codex/74c79d4b", repo: "/tmp/x", platform: .codex,
            files: ["Maw/PlayerNode.swift"], subject: "进食三拍")
        let p = EvidenceGate.evidencePrompt(c)
        XCTAssertTrue(p.contains("「构建成功」的终端截图"),
                      "得点名挡住这条最省事的歪路")
        XCTAssertTrue(p.contains("录屏"),
                      "改动画的分支静态图证明不了，必须要求录屏")
        XCTAssertTrue(p.contains("agent/codex/74c79d4b"),
                      "提示词里要带分支名 —— 查重靠它")
        XCTAssertTrue(p.contains("跑不起来就说跑不起来"),
                      "得给它一条诚实的出路，否则它会拿构建日志凑")
    }

    /// 录屏必须算证据。
    ///
    /// 实测漏掉过：Maw 一条交了 29MB 咬合录屏的分支被判成「没交证据」，
    /// 因为过滤只认 png/jpg。动画类改动静态图根本证明不了，
    /// 录屏是它唯一能交的东西 —— 不认就等于逼它交一张没用的图。
    func testVideoCountsAsEvidence() {
        // 走 Review.list 的过滤逻辑：文件名带 review/evidence 且是视觉格式
        let names = ["reviews/eating-bite-review.mov",
                     "docs/evidence/flip.mp4",
                     "docs/playtest/90-flip.png"]
        for n in names {
            let l = n.lowercased()
            let isVisual = [".png", ".jpg", ".jpeg", ".gif", ".mov", ".mp4"]
                .contains { l.hasSuffix($0) }
            let named = l.contains("evidence") || l.contains("shot")
                || l.contains("screen") || l.contains("验收")
                || l.contains("playtest") || l.contains("review")
            XCTAssertTrue(isVisual && named, "\(n) 该被认成证据")
        }
    }
}
