import XCTest
@testable import LLMQuotaCore

final class QuotaCeilingBackfillTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-ceiling-backfill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        Paths.appSupportOverride = directory
    }

    override func tearDownWithError() throws {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testExpiredWeeklyExhaustionIsBackfilledFromImmutableEventLedger() throws {
        let firstUse = Date(timeIntervalSince1970: 1_789_000_000)
        let exhaustedAt = firstUse.addingTimeInterval(6 * 86_400)
        let now = exhaustedAt.addingTimeInterval(2 * 86_400)
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .qwen, planName: "Qwen",
            limits: [QuotaLimit(
                id: "weekly", label: "7 天", windowMinutes: 10_080,
                kind: .session, metric: .billableTokens)])])
        try PlansStore.save(config, force: true)

        _ = CooldownLedger.record(
            platform: .qwen, cause: .quotaExhausted,
            detail: "429 token-plan 1-week quota exhausted",
            knownResetAt: firstUse.addingTimeInterval(7 * 86_400),
            now: exhaustedAt)
        CooldownLedger.clear(.qwen)

        let events = [
            UsageEvent(id: "older-window", timestamp: firstUse.addingTimeInterval(-2 * 86_400),
                       platform: .qwen, model: "qwen", inputTokens: 9_000,
                       outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
            UsageEvent(id: "one", timestamp: firstUse, platform: .qwen,
                       model: "qwen", inputTokens: 600, outputTokens: 100,
                       cacheReadTokens: 0, cacheWriteTokens: 50),
            UsageEvent(id: "two", timestamp: exhaustedAt.addingTimeInterval(-60),
                       platform: .qwen, model: "qwen", inputTokens: 200,
                       outputTokens: 40, cacheReadTokens: 0, cacheWriteTokens: 10),
        ]
        let scan = RawScan(events: [.qwen: events], quotas: [:])

        let captured = QuotaCeiling.captureHistorical(
            scan: scan, config: config, now: now)

        let observation = try XCTUnwrap(captured.first)
        XCTAssertEqual(observation.platform, .qwen)
        XCTAssertEqual(observation.windowMinutes, 10_080)
        XCTAssertEqual(observation.windowStart, firstUse)
        XCTAssertEqual(observation.usage[QuotaMetric.billableTokens.rawValue], 1_000)
        XCTAssertEqual(QuotaCeiling.all().count, 1)
    }

    func testBackfillUsesAllMachinesInSharedQuotaPool() throws {
        let start = Date(timeIntervalSince1970: 1_789_500_000)
        let exhaustedAt = start.addingTimeInterval(6 * 86_400)
        let reset = start.addingTimeInterval(7 * 86_400)
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "Kimi",
            limits: [QuotaLimit(id: "weekly", label: "每周",
                                windowMinutes: 10_080, kind: .periodic,
                                metric: .billableTokens)])])
        try PlansStore.save(config, force: true)
        _ = CooldownLedger.record(
            platform: .kimi, cause: .quotaExhausted,
            detail: "current 7-day window ends", knownResetAt: reset,
            now: exhaustedAt)

        func snapshot(machine: String, tokens: Int) -> MachineSnapshot {
            MachineSnapshot(
                machineID: machine, machineName: machine, generatedAt: exhaustedAt,
                retentionStart: start,
                platforms: [PlatformSnapshot(
                    platform: .kimi, detected: true,
                    buckets: [UsageBucket(start: start, model: "kimi", requests: 1,
                                          inputTokens: tokens)],
                    quotaPoolID: "kimi:default")])
        }
        let captured = QuotaCeiling.captureHistorical(
            scan: RawScan(events: [:], quotas: [:]), config: config,
            now: reset.addingTimeInterval(60),
            snapshots: [snapshot(machine: "a", tokens: 400),
                        snapshot(machine: "b", tokens: 600)])

        XCTAssertEqual(captured.first?.usage[QuotaMetric.billableTokens.rawValue], 1_000,
                       "同一订阅在多台机器上的消耗必须一起进入撞顶容量")
    }

    func testFallbackCooldownDeadlineIsNotTreatedAsWeeklyResetBoundary() throws {
        let firstUse = Date(timeIntervalSince1970: 1_790_000_000)
        let exhaustedAt = firstUse.addingTimeInterval(6 * 86_400)
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "Kimi",
            limits: [QuotaLimit(id: "weekly", label: "7 天",
                                windowMinutes: 10_080, kind: .session,
                                metric: .billableTokens)])])
        try PlansStore.save(config, force: true)

        let cooldown = CooldownLedger.record(
            platform: .kimi, cause: .quotaExhausted,
            detail: "1-week quota exhausted; refreshed in the next cycle",
            now: exhaustedAt)
        XCTAssertEqual(cooldown.until, exhaustedAt.addingTimeInterval(5 * 3_600))

        let events = [
            UsageEvent(id: "first", timestamp: firstUse, platform: .kimi,
                       model: "kimi", inputTokens: 600, outputTokens: 100,
                       cacheReadTokens: 0, cacheWriteTokens: 0),
            UsageEvent(id: "last", timestamp: exhaustedAt.addingTimeInterval(-60),
                       platform: .kimi, model: "kimi", inputTokens: 200,
                       outputTokens: 100, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]
        let captured = QuotaCeiling.captureHistorical(
            scan: RawScan(events: [.kimi: events], quotas: [:]), config: config,
            now: cooldown.until.addingTimeInterval(60), snapshots: [])

        let observation = try XCTUnwrap(captured.first)
        XCTAssertEqual(observation.windowStart, firstUse,
                       "5 小时退避只是重试期限，不能冒充 7 天额度窗口的 reset")
        XCTAssertEqual(observation.usage[QuotaMetric.billableTokens.rawValue], 1_000)
    }

    func testLegacyAndRunnerRecordsForSameExhaustionAreOneHistoricalEvent() throws {
        let exhaustedAt = Date(timeIntervalSince1970: 1_790_500_000)
        let reset = Date(timeIntervalSince1970:
            floor(exhaustedAt.addingTimeInterval(2 * 86_400).timeIntervalSince1970 / 60) * 60)
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .qwen, planName: "Qwen",
            limits: [QuotaLimit(id: "weekly", label: "7 天",
                                windowMinutes: 10_080, kind: .session,
                                metric: .billableTokens)])])
        try PlansStore.save(config, force: true)
        CooldownLedger.save([Cooldown(
            platform: .qwen, cause: .quotaExhausted,
            since: exhaustedAt, until: reset, strikes: 1,
            detail: "1-week quota exhausted; resets 09-29 09:06 UTC")])
        _ = CooldownLedger.record(
            platform: .qwen, runnerID: "qwen.code", capability: "code",
            cause: .quotaExhausted, detail: "1-week quota exhausted; next cycle",
            now: exhaustedAt)

        let history = CooldownLedger.quotaExhaustionHistory(config: config)
        XCTAssertEqual(history.count, 1,
                       "同一额度池同一秒的兼容记录和 Runner 事件不能算两个周期")
        XCTAssertEqual(history.first?.until, reset,
                       "重复记录中应保留可由服务端原话重建的 reset")
    }
}
