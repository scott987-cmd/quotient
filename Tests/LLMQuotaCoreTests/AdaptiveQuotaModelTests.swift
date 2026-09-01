import XCTest
@testable import LLMQuotaCore

final class AdaptiveQuotaModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-quota-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        AdaptiveQuotaModel.pathOverride = directory.appendingPathComponent("model.json")
    }

    override func tearDownWithError() throws {
        AdaptiveQuotaModel.pathOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func estimate(value: Double, samples: Int = 8,
                          spread: Double = 0.05) -> LimitLearner.Estimate {
        LimitLearner.Estimate(
            platform: .qwen, windowMinutes: 300, windowLabel: "5 小时",
            metric: .prompts, value: value, method: .calibrated,
            samples: samples, spread: spread, note: "测试",
            alternatives: [
                .init(metric: .prompts, value: value, spread: spread),
                .init(metric: .requests, value: value * 10, spread: 0.3),
            ])
    }

    func testTrustedObservationsPersistAndUpdateInsteadOfNeedingManualApply() throws {
        let first = AdaptiveQuotaModel.update(estimates: [estimate(value: 100)],
                                              ceilings: [], now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(first.first?.limit ?? 0, 100, accuracy: 0.001)

        let second = AdaptiveQuotaModel.update(estimates: [estimate(value: 140)],
                                               ceilings: [], now: Date(timeIntervalSince1970: 2_000))
        let learned = try XCTUnwrap(second.first)
        XCTAssertGreaterThan(learned.limit, 100)
        XCTAssertLessThan(learned.limit, 140, "新样本应校准而非粗暴覆盖历史")
        XCTAssertEqual(learned.samples, 8,
                       "重复覆盖同一历史窗不能虚增样本量")
        XCTAssertEqual(AdaptiveQuotaModel.load().first?.limit,
                       learned.limit)
    }

    func testRepeatingSameHistoricalScanDoesNotFakeNewLearning() throws {
        let sample = estimate(value: 100)
        let first = AdaptiveQuotaModel.update(estimates: [sample], ceilings: [],
                                              now: Date(timeIntervalSince1970: 1_000))
        let second = AdaptiveQuotaModel.update(estimates: [sample], ceilings: [],
                                               now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(second.first?.samples, first.first?.samples)
        XCTAssertEqual(second.first?.updatedAt, first.first?.updatedAt)
        XCTAssertEqual(second.first?.limit, first.first?.limit)
    }

    func testLegacyDocumentWithoutFingerprintFieldStillLoads() throws {
        let json = """
        {
          "schemaVersion": 1,
          "refreshedAt": "1970-01-01T00:16:40Z",
          "records": []
        }
        """
        try Data(json.utf8).write(to: AdaptiveQuotaModel.pathOverride!)
        XCTAssertTrue(AdaptiveQuotaModel.load().isEmpty)

        _ = AdaptiveQuotaModel.update(
            estimates: [estimate(value: 100)], ceilings: [],
            now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(AdaptiveQuotaModel.load().first?.limit, 100)
    }

    func testRuntimeUsesFreshLearnedLimitButNeverOverwritesUserConfiguredLimit() throws {
        _ = AdaptiveQuotaModel.update(estimates: [estimate(value: 120)], ceilings: [],
                                      now: Date(timeIntervalSince1970: 1_000))
        let unknown = PlansConfig(plans: [PlatformPlan(
            platform: .qwen, planName: "Qwen",
            limits: [QuotaLimit(id: "5h", label: "5 小时", windowMinutes: 300,
                                kind: .session, metric: .requests)])])
        let learned = AdaptiveQuotaModel.applying(
            to: unknown, now: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(learned.plans[0].limits[0].limit, 120)
        XCTAssertEqual(learned.plans[0].limits[0].metric, .prompts)
        XCTAssertTrue(learned.plans[0].limits[0].hint?.contains("持续学习") == true)

        var configured = unknown
        configured.plans[0].limits[0].limit = 77
        configured.plans[0].limits[0].hint = "用户填写"
        let preserved = AdaptiveQuotaModel.applying(
            to: configured, now: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(preserved.plans[0].limits[0].limit, 77)
        XCTAssertEqual(preserved.plans[0].limits[0].metric, .requests)
    }

    func testUntrustworthyFitIsNotPublishedAsPreciseRemainingQuota() {
        let weak = estimate(value: 100, samples: 3, spread: 0.4)
        XCTAssertFalse(weak.isTrustworthy)
        XCTAssertTrue(AdaptiveQuotaModel.update(
            estimates: [weak], ceilings: [], now: Date()).isEmpty)
    }

    func testQuotaExhaustionObservationRaisesLearnedFloor() throws {
        _ = AdaptiveQuotaModel.update(estimates: [estimate(value: 100)], ceilings: [],
                                      now: Date(timeIntervalSince1970: 1_000))
        let records = AdaptiveQuotaModel.update(
            estimates: [],
            ceilings: [(.qwen, 300, "5 小时", "prompts", 135, 1)],
            now: Date(timeIntervalSince1970: 2_000))
        let learned = try XCTUnwrap(records.first)
        XCTAssertEqual(learned.limit, 135,
                       "服务端已拒绝时的真实用量是硬下界，模型不能继续显示更低上限")
        XCTAssertEqual(learned.samples, 8)
    }
}
