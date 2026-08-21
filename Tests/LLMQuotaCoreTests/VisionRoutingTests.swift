import XCTest
@testable import LLMQuotaCore

/// **看不见图的平台不许评判图。**
///
/// 老板 2026-08-22:「MiniMax 支持视频输入,视频图片评审走它,不要走
/// opencode —— opencode 配的 GLM 仅支持文本内容」。
///
/// 这条很要紧:审查员岗位(volcark/opencode → GLM)是纯文本模型,
/// 让它评审录屏等于让瞎子看画,而它写出的结论会被当成正式否决记进名单。
/// 宁可这类活没人接,也不要一份编出来的「看起来没问题」。
final class VisionRoutingTests: XCTestCase {
    func testLooksLikeEyesTask() {
        XCTAssertTrue(TaskKind.needsEyes("【看效果】看一遍 docs/evidence/run.mov,跑姿对不对"))
        XCTAssertFalse(TaskKind.needsEyes("【审查·合入】分支 agent/a/b 的改动能不能合进 main"))
        XCTAssertFalse(TaskKind.needsEyes("【媒体】生成三张封面图"))
    }

    /// 看效果的活算评审类 —— 否则它会被当普通编码活派给写代码的 agent。
    func testEyesTaskCountsAsReviewNotCoding() {
        let p = "【看效果】看一遍录屏"
        XCTAssertTrue(TaskKind.isReview(p))
        XCTAssertFalse(TaskKind.isCoding(p))
    }

    /// MiniMax 是全系统唯一看得见的 —— 这个标记丢了,视觉评审就无人可派。
    func testMiniMaxIsTheOneThatCanSee() {
        XCTAssertTrue(MiniMaxMediaRunner().canSeeMedia,
                      "mmx 的本事包含图片/视频理解")
    }

    /// 默认看不见 —— 新接平台不会因为忘了声明就被当成多模态。
    func testPlatformsAreBlindByDefault() {
        struct Plain: AgentRunner {
            let platform: Platform = .glm
            var binaryName: String { "echo" }
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/bin/echo", [prompt], [:])
            }
        }
        XCTAssertFalse(Plain().canSeeMedia,
                       "默认瞎 —— 宁可漏派,也不要让看不见的去评判看得见的")
    }
}
