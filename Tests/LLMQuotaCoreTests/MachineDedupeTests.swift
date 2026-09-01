import XCTest
@testable import LLMQuotaCore

/// **同一台机器只该出现一次。**
///
/// 老板 2026-08-23 早:「手机展示了好几个 mac mini,有的显示离线,有的显示正常」。
/// 机器身份原来是随机 UUID + 文件缓存 —— 文件一丢就换个身份,历史上漂出
/// 十几个。已经改成硬件派生(见 Paths.machineID),但那些旧快照散在三个
/// 目录里,而且会被镜像来回同步回来:我逐个删了三轮,每轮都被同步回来。
///
/// 旧身份由 StaleIdentitySweep 清理；看板只按稳定 machineID 去重。
/// 同名机器必须同时存在，不能拿显示名冒充身份。
final class MachineDedupeTests: XCTestCase {
    private func snap(_ id: String, _ name: String, at: Date,
                      requests: Int = 0) -> MachineSnapshot {
        MachineSnapshot(
            machineID: id, machineName: name, generatedAt: at,
            retentionStart: Date(timeIntervalSince1970: 0),
            platforms: [PlatformSnapshot(
                platform: .kimi, detected: requests > 0,
                buckets: (0..<requests).map {
                    UsageBucket(start: at.addingTimeInterval(Double(-$0) * 300),
                                model: "m", requests: 1)
                },
                officialQuotas: [])])
    }

    func testSameMachineIDCollapsesToNewest() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = old.addingTimeInterval(3600)
        let d = QuotaEngine(config: PlansConfig(plans: []))
            .buildDashboard(snapshots: [snap("HARDWARE", "旧名字", at: old),
                                   snap("HARDWARE", "Mac mini", at: new)], now: new)
        XCTAssertEqual(d.machines.count, 1, "一台机器就是一台")
        XCTAssertEqual(d.machines.first?.machineID, "HARDWARE", "留最新那份")
    }

    /// 不同机器不能被合掉 —— 去重不能把多机汇总这个核心能力干掉。
    func testDifferentMachinesSurvive() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let d = QuotaEngine(config: PlansConfig(plans: []))
            .buildDashboard(snapshots: [snap("A", "Mac mini", at: t),
                                   snap("B", "MacBook Pro", at: t)], now: t)
        XCTAssertEqual(d.machines.count, 2)
    }

    /// **用量也要用去重后的** —— 否则旧身份的桶被重复计入,百分比虚高。
    func testSameMachineIDUsageIsNotDoubleCounted() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let cfg = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "测试", currency: "CNY",
            limits: [QuotaLimit(id: "5h", label: "5 小时", windowMinutes: 300,
                                kind: .session, metric: .requests)])])
        let d = QuotaEngine(config: cfg)
            .buildDashboard(snapshots: [snap("HARDWARE", "旧名字", at: t, requests: 5),
                                   snap("HARDWARE", "Mac mini", at: t.addingTimeInterval(60),
                                        requests: 5)],
                       now: t.addingTimeInterval(60))
        let kimi = d.reports.first { $0.platform == Platform.kimi }
        XCTAssertEqual(kimi?.last30dRequests, 5, "两个身份是同一台机器,用量不能加两遍")
    }

    func testSameNamedDifferentMachinesKeepSeparateUsageRows() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let cfg = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "测试", currency: "CNY",
            limits: [QuotaLimit(id: "5h", label: "5 小时", windowMinutes: 300,
                                kind: .session, metric: .requests)])])
        let d = QuotaEngine(config: cfg).buildDashboard(
            snapshots: [snap("hardware-A", "Mac mini", at: t, requests: 2),
                        snap("hardware-B", "Mac mini", at: t, requests: 3)], now: t)
        let status = d.reports.first { $0.platform == .kimi }?.statuses.first
        XCTAssertEqual(status?.byMachine.count, 2)
        XCTAssertEqual(Set(status.map { Array($0.byMachine.keys) } ?? []),
                       ["Mac mini · hardware-A", "Mac mini · hardware-B"])
    }
}
