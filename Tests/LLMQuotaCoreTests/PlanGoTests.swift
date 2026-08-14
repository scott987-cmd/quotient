import XCTest
@testable import LLMQuotaCore

/// 手机放行计划任务：目标机器仲裁 + 完整入队流程。
final class PlanGoTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plango-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigIntentIngest.rootOverride = root
        PlannedStore.fileOverride = root.appendingPathComponent("planned.json")
        Paths.appSupportOverride = root
    }

    override func tearDown() {
        ConfigIntentIngest.rootOverride = nil
        PlannedStore.fileOverride = nil
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func drop(_ json: String) {
        ConfigIntentIngest.ensureDirectories()
        let url = ConfigIntentIngest.dir!.appendingPathComponent("\(UUID().uuidString).json")
        try? Data(json.utf8).write(to: url)
    }

    /// **发给别的机器的放行，本机必须拒绝并说明真相。**
    ///
    /// 镜像抢占按 target 过滤是第一道，这里是最后防线：万一抢错了，
    /// 回执不能写「计划里没有这个 id」—— 那是假话，真相是「不归我」。
    func testWrongTargetIsRejectedHonestly() {
        let intent = """
        {"kind":"plan-go","platform":"","planID":"abc12345",
         "targetMachineID":"NOT-THIS-MACHINE"}
        """
        drop(intent)
        let out = ConfigIntentIngest.run()
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].accepted)
        XCTAssertTrue(out[0].note.contains("不该把它给我") || out[0].note.contains("是给"),
                      "要说清是归属错了，不能谎称「计划里没有」：\(out[0].note)")
    }

    /// 放行一条真实存在的计划：入队成功、从清单移除。
    func testReleaseEnqueuesAndRemovesFromPlan() throws {
        // 造一个真 git 仓库当 repo（TaskIntake 不挑，但 resolve 要能过）
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = GitWorkspace.git(["init", "-q", "-b", "main"], in: repo)

        AgentRoles.fileOverride = root.appendingPathComponent("roles.json")
        RepoRegistry.fileOverride = root.appendingPathComponent("repos.json")
        defer { AgentRoles.fileOverride = nil; RepoRegistry.fileOverride = nil }
        try RepoRegistry.add(alias: "t", path: repo)

        let planned = try PlannedStore.add(prompt: "写一个 hello world 文件", repoAlias: "t")

        let intent = """
        {"kind":"plan-go","platform":"","planID":"\(planned.id)",
         "targetMachineID":"\(Paths.machineID())"}
        """
        drop(intent)
        let out = ConfigIntentIngest.run()
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].accepted, out[0].note)

        XCTAssertTrue(PlannedStore.all().isEmpty, "放行成功要从计划清单移除")
        let queued = TaskStore.all().filter { $0.state == .queued }
        XCTAssertEqual(queued.count, 1, "任务要真的进队列")
        XCTAssertEqual(queued.first?.origin, "phone-plan-go", "来源要可追溯")
    }

    /// 放行一个不存在的 id（已放行过/被删了）—— 拒绝，但计划清单不受伤。
    func testUnknownPlanIDIsRejected() throws {
        try PlannedStore.add(prompt: "别动我", repoAlias: nil)
        let intent = """
        {"kind":"plan-go","platform":"","planID":"no-such-id",
         "targetMachineID":"\(Paths.machineID())"}
        """
        drop(intent)
        let out = ConfigIntentIngest.run()
        XCTAssertFalse(out[0].accepted)
        XCTAssertTrue(out[0].note.contains("已经放行过或被删"), out[0].note)
        XCTAssertEqual(PlannedStore.all().count, 1, "别的计划条目不能被牵连")
    }

    /// 同一轮放行**两条不同**计划 —— 都要生效。
    ///
    /// 去重键原来是 kind|platform，两条 plan-go 的 platform 都是空串，
    /// 键相同 → 先发的那条被「被更晚的取代」无声吃掉。修了，钉住。
    func testTwoDifferentPlanGosBothApply() throws {
        let repo = root.appendingPathComponent("repo2").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = GitWorkspace.git(["init", "-q", "-b", "main"], in: repo)
        AgentRoles.fileOverride = root.appendingPathComponent("roles.json")
        RepoRegistry.fileOverride = root.appendingPathComponent("repos.json")
        defer { AgentRoles.fileOverride = nil; RepoRegistry.fileOverride = nil }
        try RepoRegistry.add(alias: "t2", path: repo)

        let a = try PlannedStore.add(prompt: "给 README 加一节关于安装的说明文档", repoAlias: "t2")
        let b = try PlannedStore.add(prompt: "把 Sources 里的调试打印语句全部清理掉", repoAlias: "t2")
        for planned in [a, b] {
            drop("""
            {"kind":"plan-go","platform":"","planID":"\(planned.id)",
             "targetMachineID":"\(Paths.machineID())","createdAt":"2026-08-14T0\(planned.id.hashValue % 2 + 1):00:00Z"}
            """)
        }
        let out = ConfigIntentIngest.run()
        XCTAssertEqual(out.filter(\.accepted).count, 2,
                       "两条放行的是不同计划，必须都生效：\(out.map(\.note))")
        XCTAssertTrue(PlannedStore.all().isEmpty)
    }
}
