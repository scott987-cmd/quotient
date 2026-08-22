import XCTest
@testable import LLMQuotaCore

/// **数据塌方要当场喊出来,但不能天天误报。**
///
/// 2026-08-22 晚:菜单栏 App 跑着旧二进制,采出 0 条用量,把 CLI 刚写好的
/// 482 桶盖成 0,手机看板上 Kimi 和 Codex 整个消失 —— 系统一声不吭。
///
/// 判据是「上一轮有、这一轮没了」,不是「装了却是 0」:后者会天天误报 ——
/// Gemini 装了没用过,MiniMax 根本不写本地日志(靠官方额度接口报)。
/// 老板 2026-08-22 提醒的正是这一点。
final class CollectCollapseTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmp() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func snap(_ counts: [Platform: Int]) -> MachineSnapshot {
        MachineSnapshot(
            machineID: "M1", machineName: "测试机", generatedAt: Date(),
            retentionStart: Date(timeIntervalSince1970: 0),
            platforms: counts.map { p, n in
                PlatformSnapshot(
                    platform: p, detected: n > 0,
                    buckets: (0..<n).map { _ in
                        UsageBucket(start: Date(), model: "m", requests: 1)
                    },
                    officialQuotas: [])
            })
    }

    func testCollapseIsDetected() throws {
        _ = try SnapshotStore.write(snap([.kimi: 482, .codex: 461]))
        let gone = SnapshotStore.collapsedPlatforms(incoming: snap([.kimi: 0, .codex: 0]))
        XCTAssertEqual(gone, ["codex", "kimi"], "上一轮有、这一轮没了 —— 必须喊")
    }

    /// 从来没有数据的平台不算塌方 —— 否则 Gemini / MiniMax 天天误报,
    /// 报警很快就被训练成背景噪音,真塌方那次也没人看。
    func testNeverHadDataIsNotACollapse() throws {
        _ = try SnapshotStore.write(snap([.kimi: 482, .gemini: 0]))
        let gone = SnapshotStore.collapsedPlatforms(incoming: snap([.kimi: 482, .gemini: 0]))
        XCTAssertTrue(gone.isEmpty, "本来就没有的,不是丢了")
    }

    func testNoPreviousSnapshotIsNotACollapse() {
        XCTAssertTrue(SnapshotStore.collapsedPlatforms(incoming: snap([.kimi: 0])).isEmpty,
                      "第一次采集没有对照,不能报警")
    }
}
