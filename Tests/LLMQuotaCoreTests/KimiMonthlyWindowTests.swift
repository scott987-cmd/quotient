import XCTest
@testable import LLMQuotaCore

/// Kimi 的月额度窗口:模板要有它,用户给的锚点要能搬过来,
/// 没填数字但给了锚点的自加窗口不能被 reconcile 洗掉。
/// 实锤 2026-08-21:老板升级全年尊享后给了周(8-28 14:47)和月(9-21)到期时间,
/// 月窗口写进配置后报表不显示 —— 模板没有月档 + reconcile 只认 limit。
final class KimiMonthlyWindowTests: XCTestCase {
    func testTemplateHasMonthlyForKimi() {
        let ids = PlansConfig.template().plan(for: .kimi)?.limits.map(\.id) ?? []
        XCTAssertTrue(ids.contains("monthly"), "Kimi 模板要有月额度:\(ids)")
        XCTAssertTrue(ids.contains("weekly") && ids.contains("5h"), "原有两档不能丢")
    }

    func testReconcileCarriesUserAnchorAndKeepsAnchoredCustomWindows() {
        var cfg = PlansConfig.template()
        let anchor = ISO8601DateFormatter().date(from: "2026-09-21T06:47:00Z")!
        guard let k = cfg.plans.firstIndex(where: { $0.platform == Platform.kimi }) else {
            return XCTFail("模板里没有 kimi")
        }
        // 用户配置:月窗口只有锚点没有数字;外加一个自加的窗口也只有锚点
        cfg.plans[k].limits = cfg.plans[k].limits.map { l in
            var l = l; if l.id == "monthly" { l.anchor = anchor }; return l
        }
        cfg.plans[k].limits.append(QuotaLimit(id: "promo", label: "活动加赠", windowMinutes: 1440,
                                              kind: .periodic, metric: .requests,
                                              limit: nil, anchor: anchor, hint: nil))
        let out = PlansStore.reconcileWindows(cfg)
        let lims = out.plan(for: .kimi)!.limits
        XCTAssertEqual(lims.first { $0.id == "monthly" }?.anchor, anchor,
                       "锚点是用户给的真信息,reconcile 要搬过来")
        XCTAssertTrue(lims.contains { $0.id == "promo" },
                      "只有锚点没数字的自加窗口不是模板残骸,不能洗掉")
    }
}
