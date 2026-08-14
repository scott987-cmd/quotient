import XCTest
@testable import LLMQuotaCore

/// 高危任务的指挥兜底。
///
/// 背景：角色规则里高危（.sensitive）只有架构师能接，而本机的架构师
/// （Claude）同时是指挥、不参与竞选 —— 于是**每一个**高危任务都会
/// 「没有平台能接」转人工，auto 模式名存实亡（用户原话：
/// 「不是 auto 模式，为啥有这么多需要我确认的」）。
///
/// 兜底规则：候选为空 + 任务是高危 + 本机有指挥 + 指挥自己的角色
/// 接得了高危 → 指挥亲自上。四个条件缺一不可，这个文件逐条验。
final class DispatcherFallbackTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-\(UUID().uuidString)")
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
        var binaryName: String { "echo" }
        func command(prompt: String, cwd: String)
            -> (launchPath: String, args: [String], env: [String: String]) {
            ("/bin/echo", [prompt], [:])
        }
    }

    private func dash(_ platforms: [Platform]) -> Dashboard {
        Dashboard(
            generatedAt: Date(), machines: [],
            reports: platforms.map { PlatformReport(
                platform: $0, planName: "p", monthlyCost: nil, currency: "CNY",
                detected: true, machines: [Paths.machineName()], lastActivity: nil,
                statuses: [], last30dRequests: 0, last30dBillableTokens: 0,
                last7dRequests: 0, topModels: []) })
    }

    private func sensitiveTask() -> WorkTask {
        var t = WorkTask(id: "hz", prompt: "改 release 发布脚本", repo: "/tmp")
        t.profile = TaskProfile(
            tier: .standard, risk: .sensitive, estimatedMinutes: 10,
            isSelfContained: true, rationale: "碰构建脚本")
        return t
    }

    /// 让 Claude 在本机当指挥（默认角色它就是唯一接得了高危的）。
    ///
    /// 从 `defaults()` 起步而不是 `all()`：后者有 30 秒缓存，
    /// 会把**上一个测试**改过的角色（比如 qwen 提到 sensitive）带进来 ——
    /// 单跑全绿、全量跑挂，就是这种串味。
    private func makeClaudeDispatcher(maxRisk: TaskProfile.Risk = .sensitive,
                                      qwenMaxRisk: TaskProfile.Risk = .normal) throws {
        var roles = AgentRoles.defaults()
        roles.removeAll { $0.platform == .claude }
        roles.append(AgentRole(platform: .claude, title: "架构师", maxRisk: maxRisk,
                               dispatcherOn: [Paths.machineName()]))
        for i in roles.indices where roles[i].platform == .qwen {
            roles[i].maxRisk = qwenMaxRisk
        }
        try AgentRoles.save(roles)   // save 会把缓存打掉，decide 读到的就是这份
    }

    /// 主场景：高危任务、其余角色全够不着 → 指挥兼任，而不是「没人能接」。
    func testSensitiveTaskFallsBackToDispatcher() throws {
        try makeClaudeDispatcher()
        let decision = WorkScheduler().decide(
            dashboard: dash([.claude, .qwen]),
            runners: [StubRunner(platform: .claude), StubRunner(platform: .qwen)],
            task: sensitiveTask())
        XCTAssertEqual(decision.candidates.map(\.platform), [.claude],
                       "高危活其他角色接不了时指挥必须兜底：\(decision.candidates.map(\.platform))")
        XCTAssertTrue(decision.candidates.first?.reason.contains("指挥兼任") == true)
    }

    /// 普通任务不触发兜底 —— 指挥照旧不竞选，活归别人。
    func testNormalTaskDoesNotWakeTheDispatcher() throws {
        try makeClaudeDispatcher()
        var t = sensitiveTask()
        t.profile = TaskProfile(
            tier: .standard, risk: .normal, estimatedMinutes: 10,
            isSelfContained: true, rationale: "常规改动")
        let decision = WorkScheduler().decide(
            dashboard: dash([.claude, .qwen]),
            runners: [StubRunner(platform: .claude), StubRunner(platform: .qwen)],
            task: t)
        XCTAssertFalse(decision.candidates.contains { $0.platform == .claude },
                       "普通任务不该惊动指挥 —— 兜底只对高危开")
        XCTAssertTrue(decision.candidates.contains { $0.platform == .qwen })
    }

    /// 有别的角色能接高危时轮不到指挥（兜底只在候选为空时生效）。
    func testFallbackOnlyWhenNobodyElseCan() throws {
        try makeClaudeDispatcher(qwenMaxRisk: .sensitive)
        let decision = WorkScheduler().decide(
            dashboard: dash([.claude, .qwen]),
            runners: [StubRunner(platform: .claude), StubRunner(platform: .qwen)],
            task: sensitiveTask())
        XCTAssertEqual(decision.candidates.map(\.platform), [.qwen],
                       "有正规候选就不该动指挥的额度")
    }

    /// 指挥自己的角色也接不了高危 → 不硬塞，照旧转人工。
    func testDispatcherWithoutClearanceDoesNotForceIt() throws {
        try makeClaudeDispatcher(maxRisk: .normal)
        let decision = WorkScheduler().decide(
            dashboard: dash([.claude, .qwen]),
            runners: [StubRunner(platform: .claude), StubRunner(platform: .qwen)],
            task: sensitiveTask())
        XCTAssertTrue(decision.candidates.isEmpty,
                      "指挥的 maxRisk 够不着时兜底不能生效：\(decision.candidates.map(\.platform))")
    }
}
