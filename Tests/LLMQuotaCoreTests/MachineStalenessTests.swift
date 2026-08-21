import XCTest
@testable import LLMQuotaCore

/// **对端快照超过 1 小时没更新就得标陈旧** —— 和手机看板的红点同一条线。
/// 2026-08-21:MacBook 的 App 被自动更新杀掉、镜像停了三小时,
/// 手机已红,Mac 报表仍「● 活跃」(旧阈值 6 小时)。
final class MachineStalenessTests: XCTestCase {
    func testOneHourOldSnapshotIsStale() {
        let eng = QuotaEngine(config: PlansConfig(plans: []))
        XCTAssertGreaterThanOrEqual(eng.machineStaleAfter, 30 * 60, "别松过头也别紧过头")
        XCTAssertLessThanOrEqual(eng.machineStaleAfter, 3600,
                                 "手机看板 >1 小时就红,Mac 侧不能比它还迟钝")
    }
}
