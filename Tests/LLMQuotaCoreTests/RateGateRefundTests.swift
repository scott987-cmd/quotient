import XCTest
@testable import LLMQuotaCore

/// 派发速率闸：**没花出去的额度要退回来。**
///
/// ## 这条对应的真实故障
///
/// 实测（2026-08-19）：队列里躺着一条【证据】任务，钉在 qwen 上，
/// 而 **qwen 额度用尽、冷却还有 5 天**。工作循环每一轮：
///
/// 1. `TaskStore.nextQueued()` 取出它；
/// 2. `gate.allow()` —— **先扣一个额度槽**（闸必须在跑之前判）；
/// 3. `runOneTask` 返回 `.noPlatform`：所有平台都在冷却，
///    **一个字都没发出去**，任务原样留在队列里；
/// 4. 槽却已经扣掉了。
///
/// 20 分钟把每小时 12 个槽全烧光（worker.log 里 12 次「取到任务」、
/// 0 个任务创建、0 个完成），然后上限把**所有真活**挡在门外，
/// 剩下 40 分钟整台机器空转。
///
/// 这个形状和「零产出却算成完成」是同一类：**把「什么都没发生」
/// 记成了「发生过」。**
final class RateGateRefundTests: XCTestCase {

    /// **跑不成的那次不该算数。**
    ///
    /// 这是故障的正面复刻：一条永远派不动的任务，
    /// 不管循环转多少轮，都不该吃掉任何额度。
    func testRefundedAttemptsDoNotConsumeBudget() {
        var g = RateGate(maxPerHour: 12)
        // 模拟 50 轮「取出 → 没有可用平台 → 退回」
        for _ in 0..<50 {
            XCTAssertTrue(g.allow(), "退回过的槽必须能再用 —— "
                          + "不然一条跑不了的任务就能把整个小时烧光")
            g.refund()
        }
        XCTAssertEqual(g.usedInWindow, 0, "一次都没真跑过，额度不该有任何消耗")
        XCTAssertNil(g.nextAllowed(), "没到上限就不该报「等多久」")
    }

    /// 但**真跑过的必须照扣** —— 别把退款做成「永远不限速」。
    func testRealDispatchesStillCountAgainstTheCap() {
        var g = RateGate(maxPerHour: 3)
        XCTAssertTrue(g.allow())
        XCTAssertTrue(g.allow())
        XCTAssertTrue(g.allow())
        XCTAssertFalse(g.allow(), "跑满 3 个就该拦下来")
        XCTAssertEqual(g.usedInWindow, 3)
        XCTAssertNotNil(g.nextAllowed(), "到上限了要能说出什么时候恢复")
    }

    /// 跑不成的混在真跑的中间时，只退跑不成的那些。
    func testOnlyTheFailedAttemptIsRefunded() {
        var g = RateGate(maxPerHour: 3)
        XCTAssertTrue(g.allow())            // 真跑了一个
        XCTAssertTrue(g.allow()); g.refund() // 没平台，退回
        XCTAssertTrue(g.allow())            // 又真跑了一个
        XCTAssertEqual(g.usedInWindow, 2, "扣的应该只有真跑的那两个")
        XCTAssertTrue(g.allow(), "第三个槽还在")
        XCTAssertFalse(g.allow(), "这才到上限")
    }

    /// 空闸上退款不该把计数退成负的（或者崩）。
    func testRefundOnEmptyGateIsHarmless() {
        var g = RateGate(maxPerHour: 2)
        g.refund()
        g.refund()
        XCTAssertEqual(g.usedInWindow, 0)
        XCTAssertTrue(g.allow(), "退款不该把闸弄坏")
    }
}
