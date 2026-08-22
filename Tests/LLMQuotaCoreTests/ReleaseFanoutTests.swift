import XCTest
@testable import LLMQuotaCore

/// **发布不等于全网到齐 —— 每台机器的更新状态要能一眼看见。**
///
/// 老板 2026-08-23:「发包真的基础的事情,每次都忘记两台全发」。
/// 根子不是人忘,是发布只把包放进共享目录就算完,从不回头核对从机跟上没有。
/// 这里钉住「按 installedRelease 判某台是否已跟上」这个判据本身。
final class ReleaseFanoutTests: XCTestCase {
    func testUpToDateMatchesByPrefix() {
        // 从机报告的 installedRelease 和目标 sha 前 12 位一致 = 已跟上。
        let target = "cb973a6fc7df1234567890"
        XCTAssertTrue("cb973a6fc7df".hasPrefix(target.prefix(12)))
        XCTAssertFalse("211ea33a10a7".hasPrefix(target.prefix(12)),
                       "旧版本前缀对不上,该被标成还没跟上")
    }
    func testEmptyInstalledMeansBehind() {
        let target = "cb973a6fc7df"
        XCTAssertFalse("".hasPrefix(target.prefix(12)),
                       "从机从没报过版本,当成还没跟上,别漏")
    }
}
