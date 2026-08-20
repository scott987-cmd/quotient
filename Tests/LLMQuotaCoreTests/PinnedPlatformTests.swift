import XCTest
@testable import LLMQuotaCore

/// **点名的平台,活着就该赢;但点名不是命令。**
///
/// ## 这条对应的真实失效(2026-08-20)
///
/// `preferredPlatform` 五处写入、调度零读取 —— 字段是死的,
/// 「--platform volcark」点名的任务照样被 Kimi 抢走(e4e35d32),
/// 老板「烧掉快到期的 opencode 套餐」的指令落空。
/// 和同日早上「审核结论写了没人读」同一形状:写侧读侧各自都对。
final class PinnedPlatformTests: XCTestCase {
    private var sandbox: URL!
    override func setUp() {
        super.setUp()
        // 沙箱理由同 LocalOnlySchedulingTests:decide 会读真机的
        // 冷却台账和角色配置,测试的世界必须自己带。
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
    }
    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private struct StubRunner: AgentRunner {
        let platform: Platform
        var binaryName: String { "echo" }   // 必须真实存在,前车之鉴见 LocalOnly
        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/bin/echo", [prompt], [:])
        }
    }

    private func dashboard(_ platforms: [Platform]) -> Dashboard {
        Dashboard(generatedAt: Date(), machines: [],
                  reports: platforms.map {
                      PlatformReport(platform: $0, planName: "p", monthlyCost: nil,
                                     currency: "CNY", detected: true, machines: ["本机"],
                                     lastActivity: nil, statuses: [],
                                     last30dRequests: 0, last30dBillableTokens: 0,
                                     last7dRequests: 0, topModels: [])
                  })
    }

    private func task(pin: Platform?) -> WorkTask {
        var t = WorkTask(id: "t1", prompt: "改个功能", repo: "/tmp/x")
        t.preferredPlatform = pin
        return t
    }

    func testPinnedPlatformWinsWhenAlive() {
        let d = dashboard([.kimi, .volcark])
        let dec = WorkScheduler().decide(
            dashboard: d,
            runners: [StubRunner(platform: .kimi), StubRunner(platform: .volcark)],
            task: task(pin: .volcark))
        XCTAssertEqual(dec.pick?.platform, .volcark,
                       "点名的平台活着就该排第一 —— 否则「烧到期套餐」这类"
                       + "调配意图永远落不了地")
        XCTAssertTrue(dec.pick?.reason.contains("点名") == true,
                      "首选理由要写明是点名 —— 排查时人要能看出为什么是它:"
                      + "\(dec.pick?.reason ?? "")")
    }

    /// 没点名时不引入任何新偏好 —— 两个中性平台都在候选里。
    func testNoPinChangesNothing() {
        let d = dashboard([.kimi, .volcark])
        let dec = WorkScheduler().decide(
            dashboard: d,
            runners: [StubRunner(platform: .kimi), StubRunner(platform: .volcark)],
            task: task(pin: nil))
        XCTAssertEqual(Set(dec.candidates.map(\.platform)), [.kimi, .volcark])
        XCTAssertFalse(dec.candidates.contains { $0.reason.contains("点名") })
    }

    /// **点名不是命令**:本机没有那个执行器,点名也变不出来。
    /// 硬闸(没装/用尽/静音/角色)都在打分之前,这条测的是最典型的一种。
    func testPinCannotConjureAMissingRunner() {
        let d = dashboard([.kimi, .volcark])
        let dec = WorkScheduler().decide(
            dashboard: d, runners: [StubRunner(platform: .kimi)],
            task: task(pin: .volcark))
        XCTAssertFalse(dec.candidates.contains { $0.platform == .volcark },
                       "点名压不倒硬闸 —— 否则一条点名任务能把活派进虚空")
        XCTAssertEqual(dec.pick?.platform, .kimi, "点名落空时其余候选照常")
    }
}
