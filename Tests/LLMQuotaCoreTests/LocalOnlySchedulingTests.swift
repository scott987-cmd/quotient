import XCTest
@testable import LLMQuotaCore

/// **自动调度永远不跨机器。**
///
/// 这条不是偶然成立的，是有意为之，而且它撑着一个很实际的好处：
/// **每台机器的开发目录可以放在它自己喜欢的地方。**
/// 别名 `llmq` 在这台是 `~/dev/LLMQuotaBar`，在另一台可以完全不同
/// （`RepoAlias.pathByMachine` 就是干这个的）。一旦自动调度开始跨机，
/// 路径就必须两边一致，这个自由立刻没了。
///
/// 跨机只有一条路：人手敲 `llmq cluster dispatch <对方> "<任务>"`。
/// 那条路会在对面按**别名**重新解析成对面的本地路径，而不是把路径发过去。
///
/// 这组用例存在的理由是防「顺手」：看板本来就是跨机聚合的，
/// 某天有人看到「那台机器的 Kimi 额度还剩很多」，很自然会想
/// 「那就派给它」—— 那一步就把上面这个自由拆了。
final class LocalOnlySchedulingTests: XCTestCase {

    private struct StubRunner: AgentRunner {
        let platform: Platform
        /// 用一个**真实存在**的二进制名。
        ///
        /// 第一版写的是 `stub-qwen`，于是调度器一句「没装或不可执行」
        /// 把它永久拒绝了 —— 三条用例里有两条照样"通过"，
        /// 因为它们断言的是「不该出现」。是那条对照用例把这件事抓出来的。
        /// **只断言否定命题的测试，可以在功能完全不工作时全绿。**
        var binaryName: String { "echo" }
        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/bin/echo", [prompt], [:])
        }
    }

    /// 造一份「这个平台只装在别的机器上」的看板。
    private func dashboard(platform: Platform, onMachines: [String]) -> Dashboard {
        Dashboard(
            generatedAt: Date(), machines: [],
            reports: [PlatformReport(
                platform: platform, planName: "p", monthlyCost: nil, currency: "CNY",
                detected: true, machines: onMachines, lastActivity: nil,
                statuses: [], last30dRequests: 0, last30dBillableTokens: 0,
                last7dRequests: 0, topModels: [])])
    }

    /// 看板说别的机器有 Kimi、额度充裕，但本机没有它的执行器 ——
    /// **它不能出现在候选里。**
    func testPlatformPresentOnlyElsewhereIsNeverACandidate() {
        let d = dashboard(platform: .kimi, onMachines: ["另一台 Mac"])
        let decision = WorkScheduler().decide(dashboard: d, runners: [])

        XCTAssertFalse(decision.candidates.contains { $0.platform == .kimi },
                       "本机没有 Kimi 的执行器，看板里别的机器有不算数 —— "
                       + "自动调度一旦跨机，每台机器的仓库路径就必须一致")
        XCTAssertNil(decision.pick)
    }

    /// 候选**只能**来自传进去的 runners（那是本机的执行器列表）。
    ///
    /// 这一条比上一条更强：不管看板里有多少平台，候选集必须是 runners 的子集。
    func testCandidatesAreAlwaysASubsetOfLocalRunners() {
        var d = dashboard(platform: .kimi, onMachines: ["另一台 Mac"])
        d.reports.append(PlatformReport(
            platform: .qwen, planName: "p", monthlyCost: nil, currency: "CNY",
            detected: true, machines: ["另一台 Mac"], lastActivity: nil,
            statuses: [], last30dRequests: 0, last30dBillableTokens: 0,
            last7dRequests: 0, topModels: []))

        let local: [AgentRunner] = [StubRunner(platform: .qwen)]
        let decision = WorkScheduler().decide(dashboard: d, runners: local)

        let localPlatforms = Set(local.map(\.platform))
        for c in decision.candidates {
            XCTAssertTrue(localPlatforms.contains(c.platform),
                          "候选 \\(c.platform) 不在本机执行器列表里 —— 调度伸手到别的机器了")
        }
    }

    /// 反过来的对照：本机**有**执行器时要选得出来。
    ///
    /// 没有这条的话，上面两条可以靠「decide 永远返回空」作弊通过。
    func testLocalRunnerCanStillBePicked() {
        let d = dashboard(platform: .qwen, onMachines: ["本机"])
        let decision = WorkScheduler().decide(
            dashboard: d, runners: [StubRunner(platform: .qwen)])
        XCTAssertTrue(decision.candidates.contains { $0.platform == .qwen },
                      "本机有执行器、平台也检测到了，必须能被选中 —— "
                      + "否则上面两条只是因为什么都选不出来才通过的")
    }

    /// `Pick` 里不该有「哪台机器」这个概念。
    ///
    /// 这是结构层面的兜底：只要 Pick 不携带机器，执行路径就没有地方
    /// 去读「派给谁」，跨机自动派活写不出来。
    func testPickCarriesNoMachine() {
        let p = WorkScheduler.Pick(
            platform: .qwen, runner: StubRunner(platform: .qwen), reason: "r")
        let fields = Mirror(reflecting: p).children.compactMap(\.label)
        XCTAssertEqual(Set(fields), ["platform", "runner", "reason"],
                       "Pick 多了字段。如果新加的是机器/节点，先想清楚："
                       + "自动跨机会让每台机器的仓库路径必须一致。实际字段：\\(fields)")
    }
}
