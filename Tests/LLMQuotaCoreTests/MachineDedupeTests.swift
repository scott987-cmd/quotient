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
    func testRoleMachineSelectorsSeparateSameNamedComputers() {
        let selectors = ["hardware-A"]
        XCTAssertTrue(AgentRoles.matchesMachine(
            selectors, machineID: "hardware-A", machineName: "MacBook Pro"))
        XCTAssertFalse(AgentRoles.matchesMachine(
            selectors, machineID: "hardware-B", machineName: "MacBook Pro"),
            "稳定 ID 绑定不能误伤另一台同名电脑")
        XCTAssertTrue(AgentRoles.matchesMachine(
            ["legacy-name"], machineID: "hardware-C", machineName: "legacy-name"),
            "旧 roles.json 的机器名绑定仍须兼容")
    }
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
        XCTAssertEqual(d.reports.first { $0.platform == .kimi }?.machineIDs,
                       ["hardware-A", "hardware-B"],
                       "同名机器的跨端关联必须使用稳定 machineID")
        XCTAssertEqual(status?.byMachine.count, 2)
        XCTAssertEqual(Set(status.map { Array($0.byMachine.keys) } ?? []),
                       ["Mac mini · ARDWAREA", "Mac mini · ARDWAREB"])
    }

    func testLiveAndOfflineSameNamedMachinesAreBothPreserved() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let presence = ClusterPresence(
            machineID: "current", machineName: "Mac mini", nodeName: nil,
            lanIP: nil, port: 8443, serving: true, boundAddress: nil,
            lanRouteInterface: nil, firewallOn: false, canReach: [:],
            updatedAt: now, version: "1")

        let result = SnapshotStore.reconcileIdentities(
            [snap("stale", "Mac mini", at: now.addingTimeInterval(-3600)),
             snap("current", "Mac mini", at: now)],
            presences: [presence], now: now)

        XCTAssertEqual(Set(result.map(\.machineID)), ["stale", "current"],
                       "同名但离线的真实机器不能被在线机器冒名清掉")
    }

    func testTwoLiveSameNamedMachinesAreBothPreserved() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func presence(_ id: String) -> ClusterPresence {
            ClusterPresence(
                machineID: id, machineName: "Mac mini", nodeName: nil,
                lanIP: nil, port: 8443, serving: true, boundAddress: nil,
                lanRouteInterface: nil, firewallOn: false, canReach: [:],
                updatedAt: now, version: "1")
        }

        let result = SnapshotStore.reconcileIdentities(
            [snap("A", "Mac mini", at: now), snap("B", "Mac mini", at: now)],
            presences: [presence("A"), presence("B")], now: now)

        XCTAssertEqual(Set(result.map(\.machineID)), ["A", "B"])
    }

    func testPublishedMachineDisplayNamesNeverContainTheComputerOwner() {
        XCTAssertEqual(Paths.privacySafeMachineName("杜师兵的Mac mini"), "Mac mini")
        XCTAssertEqual(Paths.privacySafeMachineName("dushibing MacBook Pro"),
                       "MacBook Pro")
        XCTAssertEqual(Paths.privacySafeMachineName("Dushibing-MacBook-Pro.local"),
                       "MacBook Pro")
        XCTAssertEqual(Paths.privacySafeMachineName("杜师兵的工作站"), "Mac")
        XCTAssertEqual(
            Paths.privacySafeMachineLabel("杜师兵的 MacBook Pro", machineID: "machine-A"),
            "MacBook Pro · MACHINEA")
        XCTAssertEqual(Paths.privacySafeMachineDisplayName(
            nodeName: "macbook-pro-m2", machineName: "杜师兵的 MacBook Pro",
            machineID: "machine-A"), "macbook-pro-m2")
        XCTAssertEqual(Paths.privacySafeMachineDisplayName(
            nodeName: "dushibing-macbook-pro", machineName: "dushibing MacBook Pro",
            machineID: "machine-A"), "MacBook Pro · MACHINEA",
            "节点路由名带登录用户名时也不能绕过展示层脱敏")
        XCTAssertEqual(Paths.privacySafeMachineDisplayName(
            nodeName: "杜师兵-M2", machineName: "杜师兵的 MacBook Pro",
            machineID: "machine-A"), "MacBook Pro · MACHINEA")

        let now = Date(timeIntervalSince1970: 1_000_000)
        let dashboard = QuotaEngine(config: PlansConfig(plans: [])).buildDashboard(
            snapshots: [snap("hardware-A", "杜师兵的Mac mini", at: now)],
            now: now, nodeNamesByMachineID: ["hardware-A": "mac-mini"])
        XCTAssertEqual(dashboard.machines.first?.machineName, "杜师兵的Mac mini",
                       "协议身份字段不能被显示层脱敏破坏")
        XCTAssertEqual(dashboard.machines.first?.displayName, "mac-mini")
    }

    func testPresenceCollaborationDisplayDoesNotExposeOwnerInNodeName() {
        let presence = ClusterPresence(
            machineID: "machine-A", machineName: "dushibing MacBook Pro",
            nodeName: "dushibing-macbook-pro", lanIP: nil, port: 8443,
            serving: true, boundAddress: nil, lanRouteInterface: nil,
            firewallOn: false, canReach: [:], updatedAt: Date(), version: "test")
        XCTAssertEqual(presence.displayName, "MacBook Pro · MACHINEA")
    }

    func testPrivacyDisplayDoesNotBreakReportToMachineIdentityJoin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "Kimi")])
        let dashboard = QuotaEngine(config: config).buildDashboard(
            snapshots: [snap("hardware-A", "杜师兵的Mac mini", at: now, requests: 1)],
            now: now, nodeNamesByMachineID: ["hardware-A": "mac-mini"])

        XCTAssertEqual(dashboard.reports.first?.machineIDs, ["hardware-A"],
                       "跨端关联必须只依赖稳定 machineID")
        XCTAssertEqual(dashboard.reports.first?.machines, ["Mac mini"],
                       "展示字段不能泄露电脑所有者姓名")
        XCTAssertEqual(dashboard.machines.first?.displayName, "mac-mini")
    }
}

extension MachineDedupeTests {
    func testLegacyInboxMachineNameMustBeUniqueAcrossStableIDs() {
        func presence(_ id: String) -> ClusterPresence {
            ClusterPresence(
                machineID: id, machineName: "MacBook Pro", nodeName: nil,
                lanIP: nil, port: 8443, serving: true, boundAddress: nil,
                lanRouteInterface: nil, firewallOn: false, canReach: [:],
                updatedAt: Date(), version: "test")
        }
        let sameName = [
            presence("hardware-A"),
            presence("hardware-B"),
        ]
        XCTAssertTrue(Inbox.legacyMachineNameIsAmbiguous(
            "MacBook Pro", presences: sameName))
        XCTAssertFalse(Inbox.legacyMachineNameIsAmbiguous(
            "Mac mini", presences: sameName))
        XCTAssertFalse(Inbox.legacyMachineNameIsAmbiguous(
            "MacBook Pro", presences: [sameName[0]]),
            "滚动升级期只有一台匹配时仍兼容旧手机客户端")
    }
}
