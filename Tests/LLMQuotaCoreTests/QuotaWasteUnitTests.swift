import XCTest
@testable import LLMQuotaCore

/// **projectedWaste 的单位是「原始计量单位」，两条生产线必须一致。**
///
/// ## 这条对应的真实故障（2026-08-20，老板在手机上看到 9741%）
///
/// 字段文档写着「原始计量单位」，本地日志那条生产线也是这么算的
/// （`cap - p * cap`）。但官方额度那条生产线写死了 `100 - p * 100`：
/// 百分比口径下碰巧对（cap 就是 100），**次数口径下发出去的单位就是错的**。
///
/// 同一个字段两种单位，消费端怎么读都有一半错 —— 手机看板把百分点
/// 当成 0–1 小数再乘 100，「预计浪费 97.4 个百分点」显示成 9741%。
/// 这是「文本当接口」的堂兄弟：一个没带单位的数字跨了进程边界。
final class QuotaWasteUnitTests: XCTestCase {

    private func status(_ q: OfficialQuota) -> QuotaStatus {
        let plan = PlatformPlan(platform: .minimax, planName: "测试", limits: [],
                                preferOfficialQuota: true)
        let eng = QuotaEngine(config: PlansConfig(plans: [plan]))
        return eng.officialStatus(q, plan: plan, now: Date())
    }

    /// 百分比口径：浪费的单位是**百分点**，永远 ≤ 100。
    func testPercentQuotaWasteIsInPoints() {
        let now = Date()
        let s = status(OfficialQuota(
            id: "w", label: "每周", usedPercent: 30, windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(1.75 * 86400), planType: nil, observedAt: now))
        guard let w = s.projectedWaste, let p = s.projectedUsedFraction else {
            return XCTFail("周期窗口该有预计浪费")
        }
        XCTAssertGreaterThan(w, 0,
            "夹具必须真有浪费 —— 浪费为 0 时两种单位算出来都是 0，"
            + "测试分辨不出对错（第一版夹具就是这么让变异溜过去的）")
        XCTAssertEqual(w, max(0, 100 - p * 100), accuracy: 0.001,
                       "百分比口径 cap=100，浪费=100-投影*100")
        XCTAssertLessThanOrEqual(w, 100)
    }

    /// 次数口径：浪费的单位是**次**，永远 ≤ 总次数。
    /// 改动前这里发的是百分点（比如 60），而总共只有 20 次 ——
    /// 「浪费 60 次」比总量还大三倍，哪个消费端都没法读对。
    func testCountQuotaWasteIsInRequests() {
        let now = Date()
        let s = status(OfficialQuota(
            id: "v", label: "video 每周", usedPercent: 30, windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(1.75 * 86400), planType: nil, observedAt: now,
            usedCount: 6, totalCount: 20))
        guard let w = s.projectedWaste, let p = s.projectedUsedFraction else {
            return XCTFail("周期窗口该有预计浪费")
        }
        XCTAssertGreaterThan(w, 0, "夹具必须真有浪费，理由同上")
        XCTAssertEqual(w, max(0, 20 - p * 20), accuracy: 0.001,
                       "次数口径 cap=totalCount，单位是次")
        XCTAssertLessThanOrEqual(w, 20, "浪费不可能超过总量")
    }
}
