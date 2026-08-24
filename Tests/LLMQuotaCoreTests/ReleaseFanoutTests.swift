import XCTest
@testable import LLMQuotaCore

/// **发布不等于全网到齐 —— 每台机器的更新状态要能一眼看见。**
///
/// 老板 2026-08-23:「发包真的基础的事情,每次都忘记两台全发」。
/// 根子不是人忘,是发布只把包放进共享目录就算完,从不回头核对从机跟上没有。
/// 这里钉住「按 installedRelease 判某台是否已跟上」这个判据本身。
final class ReleaseFanoutTests: XCTestCase {
    func testUpToDateMatchesByPrefix() {
        // 从机报告的 installedRelease 和目标 sha 前 12 位一致 = 已跟上。
        let target = "cb973a6fc7df1234567890"
        XCTAssertTrue(ReleaseFanout.matches(target: target, installed: "cb973a6fc7df"))
        XCTAssertFalse(ReleaseFanout.matches(target: target, installed: "211ea33a10a7"),
                       "旧版本前缀对不上,该被标成还没跟上")
    }
    func testEmptyInstalledMeansBehind() {
        let target = "cb973a6fc7df"
        XCTAssertFalse(ReleaseFanout.matches(target: target, installed: ""),
                       "从机从没报过版本,当成还没跟上,别漏")
    }

    private func presence(_ id: String, installed: String?, age: TimeInterval,
                          now: Date) -> ClusterPresence {
        ClusterPresence(machineID: id, machineName: id, nodeName: id,
                        lanIP: nil, port: 8443, serving: true, boundAddress: nil,
                        lanRouteInterface: nil, firewallOn: false, canReach: [:],
                        updatedAt: now.addingTimeInterval(-age), version: "1",
                        installedRelease: installed)
    }

    func testOnlyFreshOnlineMachinesBlockCompletion() {
        let now = Date()
        let peers = [
            presence("local", installed: "old", age: 0, now: now),
            presence("online-old", installed: "old", age: 30, now: now),
            presence("online-new", installed: "cb973a6fc7df", age: 30, now: now),
            presence("offline-old", installed: "old", age: 16 * 60, now: now),
        ]
        let pending = ReleaseFanout.pending(
            target: "cb973a6fc7df999", localMachineID: "local",
            presences: peers, now: now)
        XCTAssertEqual(pending.map(\.machineID), ["online-old"],
                       "本机和离线机器不阻塞；在线旧版本必须阻塞")
    }

    func testChangingTargetMakesPreviouslyCurrentPeerPending() {
        let now = Date()
        let peer = presence("peer", installed: "cb973a6fc7df", age: 0, now: now)
        XCTAssertTrue(ReleaseFanout.pending(
            target: "cb973a6fc7df999", localMachineID: "local",
            presences: [peer], now: now).isEmpty)
        XCTAssertEqual(ReleaseFanout.pending(
            target: "aaaaaaaaaaaa999", localMachineID: "local",
            presences: [peer], now: now).map(\.machineID), ["peer"],
            "发了新包以后，旧的成功票必须立即失效")
    }
}
