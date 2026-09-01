import XCTest
@testable import LLMQuotaCore

/// 平台健康汇总：**让「某台机器上某个平台坏了」一眼可见。**
///
/// ## 这东西对应的真实代价
///
/// 探针原先是「谁跑谁知道」，结果只打在终端上。2026-08-19 的两笔账：
///
/// - MacBook 上 codex 是 0.142.5（Mac mini 是 0.147.0），老到服务端
///   直接拒。系统照旧往它派活，**连着失败 27 次**才被人从原始任务
///   记录里翻出来 —— 推到手机的看板上那一栏是空的。
/// - 同一次探针顺带发现 MacBook 上 **Qwen 和 MiniMax 压根没装**。
///   一直如此，只是从来没人在那台机器上跑过探针。
final class PlatformHealthTests: XCTestCase {

    private struct PassiveRunner: AgentRunner {
        let platform: Platform = .minimax
        let runnerID: String
        let binaryName = "passive-test"
        let available: Bool
        let canEdit: Bool
        let canReadFiles: Bool
        let mediaOnly: Bool
        let reviewOnly: Bool
        let canSeeMedia: Bool

        var binaryPath: String? { available ? "/usr/bin/true" : nil }

        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            XCTFail("被动健康检查不得构造或启动真实模型命令")
            return ("/usr/bin/false", [], [:])
        }
    }

    private func entry(_ platform: String, _ status: String) -> PlatformHealth.Entry {
        .init(platform: platform, status: status, detail: "", seconds: 1)
    }

    private func report(_ machine: String, _ entries: [PlatformHealth.Entry],
                        ageSeconds: TimeInterval = 60) -> PlatformHealth.Report {
        .init(machineID: machine, machineName: machine,
              at: Date().addingTimeInterval(-ageSeconds), entries: entries)
    }

    /// **全都好的时候一个字都不说。**
    ///
    /// 每天都出现的「一切正常」会被训练成背景噪音，
    /// 真出事那天也一样被跳过。
    func testSilentWhenEverythingIsFine() {
        let r = report("mini", [entry("Claude", "可用"), entry("Codex", "可用")])
        XCTAssertTrue(PlatformHealth.problems(reports: [r]).isEmpty,
                      "没有坏消息就该闭嘴")
    }

    /// 坏了的要报，而且要带机器名 —— 不带的话人不知道该去哪台机器修。
    func testReportsBrokenPlatformWithMachineName() {
        let r = report("MacBook", [entry("Codex", "不可用")])
        let out = PlatformHealth.problems(reports: [r])
        guard let line = out.first else {
            return XCTFail("该报出来却一条都没有")
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(line.contains("MacBook"), line)
        XCTAssertTrue(line.contains("Codex"), line)
    }

    /// **冷却中的平台不重复报。**
    ///
    /// 额度用尽是已知的、会自愈的状态，`brief` 有专门一行写着
    /// 「还有几天恢复」。同一件事报两遍，人会开始跳过整段 ——
    /// 那时真故障也一起被跳过了。
    func testCoolingPlatformIsNotDoubleReported() {
        let r = report("mini", [entry("Qwen", "不可用")])
        XCTAssertTrue(
            PlatformHealth.problems(reports: [r], excusedBy: ["Qwen"]).isEmpty,
            "冷却那一行已经讲过这件事了")
    }

    /// **但冷却豁免不了「未安装」。**
    ///
    /// 这一条是被自己写的降噪规则打脸打出来的：第一版把
    /// 「不可用」和「未安装」一起豁免，于是「MacBook 上 Qwen 压根没装」
    /// 被另一台机器的冷却记录盖住 —— **降噪规则本身变成了新的静默失败**，
    /// 正好是这套机制要防的东西。
    ///
    /// 额度用尽等几天会好；没装等多久都不会好。两回事。
    ///
    /// 2026-08-20 更新：判据改成「装过又没了才算故障」之后，这一条的
    /// 前提要写明 —— 冷却豁免不了的是**故障性的**未安装
    /// （以前能用、现在没了）。一直没装的那种根本不进这个列表，
    /// 见 `testNeverInstalledIsNotAFault`。
    func testCoolingDoesNotExcuseNotInstalled() {
        let r = report("MacBook", [entry("Qwen", "未安装", wasUsable: true)])
        let out = PlatformHealth.problems(reports: [r], excusedBy: ["Qwen"])
        // **先 guard 再取下标。** 断言失败后继续 out[0] 会越界 fatalError，
        // 把整个测试进程连同同一批其他测试的结果一起带走 ——
        // 实测就是这样：变异验证时看到的是「一行输出都没有」，
        // 而不是「这一条红了」，白查了两轮。
        guard let line = out.first else {
            return XCTFail("「没装」等多久都不会好，冷却解释不了它 —— 却一条都没报")
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(line.contains("未安装"), line)
    }

    /// 同一个平台注册了多个执行器时不要报两遍。
    ///
    /// MiniMax 有媒体和评审两个 runner，显示名一样 ——
    /// 实测输出过 `MiniMax（未安装） · MiniMax（未安装）`。
    func testDuplicateRunnersOfSamePlatformAreCollapsed() {
        let r = report("MacBook", [entry("MiniMax", "未安装", wasUsable: true),
                                   entry("MiniMax", "未安装", wasUsable: true)])
        let out = PlatformHealth.problems(reports: [r])
        guard let line = out.first else { return XCTFail("该报出来却一条都没有") }
        XCTAssertEqual(out.count, 1)
        let hits = line.components(separatedBy: "MiniMax").count - 1
        XCTAssertEqual(hits, 1, "同一个平台同一个状态只报一次：\(line)")
    }

    /// **过期的结果不能冒充现状。**
    ///
    /// 平台可能早就修好了，而这里还在报「坏着」—— 人会学会忽略它。
    /// 所以过期时报的是「这台机器很久没探了」，而不是平台状态。
    func testStaleReportIsFlaggedAsStaleNotAsStatus() {
        let r = report("mini", [entry("Codex", "不可用")],
                       ageSeconds: 48 * 3600)
        let out = PlatformHealth.problems(reports: [r], staleAfter: 24 * 3600)
        guard let line = out.first else { return XCTFail("过期也该说一声") }
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(line.contains("过期"), line)
        XCTAssertFalse(line.contains("Codex"),
                       "48 小时前的结论不该被当成现在的平台状态：\(line)")
    }

    /// **「没探过」和「探过、没问题」必须分开。**
    ///
    /// 把「不知道」显示成「没问题」正是那 27 次失败的成因。
    func testNeverProbedMachinesAreListedSeparately() {
        let r = report("mini", [entry("Claude", "可用")])
        let missing = PlatformHealth.neverProbed(
            known: ["mini", "MacBook"], reports: [r])
        XCTAssertEqual(missing, ["MacBook"],
                       "没探过的机器要单独列 —— 我们不知道它怎么样，"
                       + "不等于它没问题")
    }
    // MARK: 「没装」是配置，不是故障

    private func entry(_ platform: String, _ status: String,
                       wasUsable: Bool) -> PlatformHealth.Entry {
        var e = PlatformHealth.Entry(platform: platform, status: status,
                                     detail: "", seconds: 1)
        e.wasUsableHere = wasUsable
        return e
    }

    /// **一直没装的平台不该天天报异常。**
    ///
    /// 老板（2026-08-20）：「不需要装，每台电脑本来安装的东西就不一样」。
    /// MacBook 上没有 Qwen 和 MiniMax 是那台机器的配置，不是坏了。
    /// 天天报一遍，人会被训练成跳过整段 —— 真出事那天也一起跳过。
    func testNeverInstalledIsNotAFault() {
        let r = report("MacBook", [entry("Qwen", "未安装", wasUsable: false)])
        XCTAssertTrue(PlatformHealth.problems(reports: [r]).isEmpty,
                      "这台机器本来就没装它，这是配置不是故障")
    }

    /// **但装过又没了是故障。**
    ///
    /// 要么被误删、要么 PATH 断了，而系统会继续往它派活 ——
    /// MacBook 上 codex 失败 27 次就是这么来的。
    func testWasWorkingThenVanishedIsAFault() {
        let r = report("MacBook", [entry("Codex", "未安装", wasUsable: true)])
        let out = PlatformHealth.problems(reports: [r])
        XCTAssertEqual(out.count, 1,
                       "以前能用、现在没了 —— 这是真出事了")
        XCTAssertTrue(out.first?.contains("Codex") == true, out.first ?? "")
    }

    /// **装着却跑不通，一律算故障。**
    ///
    /// 不管以前怎么样：二进制在、跑不起来，就是坏了。
    func testInstalledButBrokenIsAlwaysAFault() {
        let r = report("mini", [entry("Codex", "不可用", wasUsable: false)])
        XCTAssertEqual(PlatformHealth.problems(reports: [r]).count, 1,
                       "装着却跑不通就是坏了，跟以前能不能用无关")
    }

    /// 健康记录的身份必须落到 Runner + 能力，不能再只靠平台名。
    func testHealthIdentitySeparatesRunnersAndCapabilitiesOnSamePlatform() {
        let review = PassiveRunner(
            runnerID: "minimax.review", available: true,
            canEdit: false, canReadFiles: false,
            mediaOnly: false, reviewOnly: true, canSeeMedia: false)
        let media = PassiveRunner(
            runnerID: "minimax.media", available: true,
            canEdit: true, canReadFiles: false,
            mediaOnly: true, reviewOnly: false, canSeeMedia: true)

        let entries = PlatformHealth.passiveEntries(runners: [review, media], now: Date())

        XCTAssertEqual(Set(entries.map(\.runnerID)), ["minimax.review", "minimax.media"])
        XCTAssertEqual(Set(entries.map(\.capability)), [.review, .media])
        XCTAssertEqual(Set(entries.map(\.key)).count, 2)
    }

    /// 本地安装只能证明“可执行文件存在”，不能冒充远端认证/额度可用。
    func testPassiveCheckHasNoModelCallAndKeepsRemoteAvailabilityUnknown() {
        let runner = PassiveRunner(
            runnerID: "minimax.review", available: true,
            canEdit: false, canReadFiles: false,
            mediaOnly: false, reviewOnly: true, canSeeMedia: false)

        let entry = PlatformHealth.passiveEntries(runners: [runner], now: Date()).first

        XCTAssertEqual(entry?.state, .unknown)
        XCTAssertEqual(entry?.source, .localConfiguration)
        XCTAssertFalse(entry?.isUsable ?? true,
                       "只看到二进制存在，不等于平台、认证和额度都可用")
    }

    func testFreshTaskEvidenceWinsOverLocalConfigurationScan() {
        let now = Date()
        let proven = PlatformHealth.Entry(
            platform: "MiniMax", runnerID: "minimax.review", capability: .review,
            state: .available, source: .taskAttempt, observedAt: now,
            expiresAt: now.addingTimeInterval(3600), detail: "真实任务成功")
        let scan = PlatformHealth.Entry(
            platform: "MiniMax", runnerID: "minimax.review", capability: .review,
            state: .unknown, source: .localConfiguration, observedAt: now,
            expiresAt: now.addingTimeInterval(3600), detail: "只看到二进制")

        let merged = PlatformHealth.mergedEntries(
            incoming: [scan], previous: [proven], now: now)

        XCTAssertEqual(merged.first?.state, .available)
        XCTAssertEqual(merged.first?.source, .taskAttempt)
    }

    func testRunnerCooldownDoesNotHideSiblingRunnerFailure() {
        let now = Date()
        let review = PlatformHealth.Entry(
            platform: "MiniMax", runnerID: "minimax.review", capability: .review,
            state: .unavailable, source: .taskAttempt, observedAt: now,
            expiresAt: now.addingTimeInterval(3600), detail: "review auth")
        let media = PlatformHealth.Entry(
            platform: "MiniMax", runnerID: "minimax.media", capability: .media,
            state: .unavailable, source: .taskAttempt, observedAt: now,
            expiresAt: now.addingTimeInterval(3600), detail: "media broken")
        let r = report("mini", [review, media])

        let lines = PlatformHealth.problems(
            reports: [r], excusedKeys: [review.key], now: now)
        let joined = lines.joined(separator: " ")

        XCTAssertFalse(joined.contains("minimax.review"))
        XCTAssertTrue(joined.contains("minimax.media"), joined)
    }

}
