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

    func testLegacyWeeklyRequestCalibrationCannotBecomeTokenRemaining() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let oldWeekly = QuotaLimit(
            id: "weekly", label: "每周", windowMinutes: 7 * 24 * 60,
            kind: .periodic, metric: .requests, limit: 500,
            anchor: anchor, hint: "旧请求次数校准"
        )
        let saved = PlansConfig(
            plans: [PlatformPlan(
                platform: .qwen, planName: "Qwen Code", limits: [oldWeekly]
            )],
            quotaPools: [QuotaPoolBinding(
                poolID: "qwen-owned", platform: .qwen,
                machineID: "machine-owned", limits: [oldWeekly]
            )]
        )

        let reconciled = PlansStore.reconcileWindows(saved)
        let platformWeekly = try XCTUnwrap(
            reconciled.plan(for: .qwen)?.limits.first { $0.id == "weekly" }
        )
        let poolWeekly = try XCTUnwrap(
            reconciled.plan(for: .qwen, quotaPoolID: "qwen-owned")?
                .limits.first { $0.id == "weekly" }
        )

        for weekly in [platformWeekly, poolWeekly] {
            XCTAssertEqual(weekly.metric, .billableTokens)
            XCTAssertEqual(weekly.kind, .session)
            XCTAssertNil(weekly.limit,
                         "旧请求次数不能成为 Token 上限并制造虚假剩余百分比")
            XCTAssertNil(weekly.anchor,
                         "自然周期锚点不能污染首次调用起算的 7 天窗口")
            XCTAssertFalse((weekly.hint ?? "").contains("旧请求次数"))
        }
    }
}
