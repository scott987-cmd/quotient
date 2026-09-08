import XCTest
@testable import LLMQuotaCore

final class QwenTokenPlanTests: XCTestCase {
    func testTemplateTracksTokenPlanOnItsSevenDayWindow() throws {
        let plan = try XCTUnwrap(PlansConfig.template().plan(for: .qwen))
        let weekly = try XCTUnwrap(plan.limits.first { $0.id == "weekly" })

        XCTAssertEqual(weekly.windowMinutes, 7 * 24 * 60)
        XCTAssertEqual(weekly.kind, .session,
                       "7 天窗口从首次调用起算，不能按自然周对齐")
        XCTAssertEqual(weekly.metric, .billableTokens)
        XCTAssertFalse(plan.limits.contains { $0.id == "daily" },
                       "Token Plan 不应继续显示旧版每日请求窗口")
        XCTAssertTrue((weekly.hint ?? "").contains("Credits"),
                      "本机 Token 活动不能冒充官方 Credits 余量")
    }

    func testLegacyDailyRequestWindowMigratesWithoutLeavingDuplicateUsage() throws {
        let saved = PlansConfig(plans: [PlatformPlan(
            platform: .qwen,
            planName: "Qwen Code",
            limits: [QuotaLimit(
                id: "daily", label: "每日", windowMinutes: 24 * 60,
                kind: .periodic, metric: .requests, limit: 97
            )]
        )])

        let plan = try XCTUnwrap(PlansStore.reconcileWindows(saved).plan(for: .qwen))
        XCTAssertEqual(plan.planName, "Qwen Token Plan")
        XCTAssertEqual(plan.limits.map(\.id), ["weekly"])
        XCTAssertEqual(plan.limits[0].metric, .billableTokens)
    }
}
