import XCTest
@testable import LLMQuotaCore

/// **GLM 终于能接活了。**
///
/// 老板 2026-08-22:「macbook 装了 zcode,以后 GLM 我主要用官方的 zcode 了」。
/// 查下来执行器名单里**从来没有 GLM** —— 它只作为「有额度的平台」被统计,
/// 没有任何办法派活给它。日志里「空窗 GLM,闲了 1 天 23 小时」天天在喊,
/// 而额度最富余的恰恰是它。
final class ZcodeRunnerTests: XCTestCase {
    func testDispatchesToGLM() {
        XCTAssertEqual(ZcodeRunner().platform, .glm)
        XCTAssertTrue(RunnerRegistry.all.contains { $0.platform == .glm },
                      "名单里必须有 GLM —— 否则它的额度永远用不掉")
    }

    /// ZCode 是桌面 App,CLI 藏在包里,`which zcode` 找不到。
    /// 判据必须看那个脚本在不在,否则装了也用不上、没装还会误判成可用。
    func testAvailabilityLooksAtTheBundledScript() {
        let r = ZcodeRunner()
        let installed = FileManager.default.isReadableFile(atPath: ZcodeRunner.scriptPath)
        XCTAssertEqual(r.isAvailable, installed,
                       "装了才算可用 —— 没装的机器上调度要能正确跳过")
    }

    func testHeadlessFlags() {
        let c = ZcodeRunner().command(prompt: "干活", cwd: "/tmp/repo")
        XCTAssertTrue(c.args.contains("--prompt"), "无界面执行,不能弹 TUI")
        XCTAssertTrue(c.args.contains("--cwd") && c.args.contains("/tmp/repo"))
        XCTAssertTrue(c.args.contains("yolo"), "自主干活,不能停下来等人点确认")
        XCTAssertFalse(c.args.contains("--resume"), "全新会话不该带 resume")
    }

    /// 续接会话省去重读仓库 —— 和别的执行器一个待遇。
    func testResumeIsPassedThrough() {
        let c = ZcodeRunner().command(prompt: "接着干", cwd: "/tmp/repo",
                                      session: .resume("sess_abc123"))
        XCTAssertTrue(c.args.contains("--resume") && c.args.contains("sess_abc123"))
    }
}
