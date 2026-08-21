import XCTest
@testable import LLMQuotaCore

/// 按订阅页百分比反推上限 —— 只给比例不给数字的平台(Kimi)唯一的校准路。
final class QuotaCalibrationTests: XCTestCase {
    func testDividesUsageByPercent() throws {
        // 本周用了 140,300 token,页面说 23% → 上限 ≈ 610,000
        XCTAssertEqual(try QuotaCalibration.limit(used: 140_300, percentUsed: 23), 610_000)
        // 5 小时用了 230 次,页面说 40% → 575 → 取整到十 → 580
        XCTAssertEqual(try QuotaCalibration.limit(used: 230, percentUsed: 40), 580)
    }
    func testGuards() {
        XCTAssertThrowsError(try QuotaCalibration.limit(used: 100, percentUsed: 0))
        XCTAssertThrowsError(try QuotaCalibration.limit(used: 100, percentUsed: 101))
        XCTAssertThrowsError(try QuotaCalibration.limit(used: 0, percentUsed: 10),
                             "没用过除不出来,不能返回 0 或无穷大当上限")
    }
    func testHundredPercentMeansUsedIsTheLimit() throws {
        XCTAssertEqual(try QuotaCalibration.limit(used: 1234, percentUsed: 100), 1200,
                       "100% 时上限≈用量(再按量级取整)")
    }
}
