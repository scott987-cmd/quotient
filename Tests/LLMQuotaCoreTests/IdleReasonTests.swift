import XCTest
@testable import LLMQuotaCore

/// **「为什么现在没人干活」要说得出口。**
///
/// 老板 2026-08-22 一天里问了八次「任务停了」,八次原因都不同:
/// 磁盘满、评审判不合入、每小时限流、菜单栏 App 挂了、队里的活全被
/// 依赖挡着……每次都要人上机器查日志。这些原因系统自己全知道,
/// 只是从来没说出来 —— 看不见原因本身就是那个要修的问题。
final class IdleReasonTests: XCTestCase {
    func testDiskFirst() {
        let v = IdleReason.explain(queued: 5, blockedByDeps: 0, deferredByLease: 0,
                                   platformRejections: [], rateLimited: true, lowDisk: true,
                                   pendingLanding: 3)
        XCTAssertTrue(v.line.contains("磁盘"), "磁盘见底压过其它一切原因")
        XCTAssertFalse(v.isNormal)
    }

    /// 队列空 + 有产出卡在落地 = 不正常,要说出来。
    /// 这正是 2026-08-22 下午那 64 分钟空档的真实情形。
    func testEmptyQueueWithStuckOutputIsNotNormal() {
        let v = IdleReason.explain(queued: 0, blockedByDeps: 0, deferredByLease: 0,
                                   platformRejections: [], rateLimited: false, lowDisk: false,
                                   pendingLanding: 4)
        XCTAssertTrue(v.line.contains("落地"), "要点出真凶:产出合不进去")
        XCTAssertFalse(v.isNormal)
    }

    /// 真的没活干是正常状态 —— 别把它报成故障,否则报警会被当噪音。
    func testTrulyEmptyIsNormal() {
        let v = IdleReason.explain(queued: 0, blockedByDeps: 0, deferredByLease: 0,
                                   platformRejections: [], rateLimited: false, lowDisk: false,
                                   pendingLanding: 0)
        XCTAssertTrue(v.isNormal)
        XCTAssertTrue(v.line.contains("干完"))
    }

    func testRateLimitIsNormalAndSelfHealing() {
        let v = IdleReason.explain(queued: 9, blockedByDeps: 0, deferredByLease: 0,
                                   platformRejections: [], rateLimited: true, lowDisk: false,
                                   pendingLanding: 0)
        XCTAssertTrue(v.isNormal, "限流会自己过去,不是故障")
        XCTAssertTrue(v.line.contains("上限"))
    }

    func testPlatformRejectionsAreNamed() {
        let v = IdleReason.explain(queued: 2, blockedByDeps: 0, deferredByLease: 0,
                                   platformRejections: [("Kimi", "额度用尽"), ("Codex", "触到留白")],
                                   rateLimited: false, lowDisk: false, pendingLanding: 0)
        XCTAssertTrue(v.line.contains("Kimi") && v.line.contains("额度用尽"),
                      "谁挡的、为什么挡,都要写出来")
    }
}
