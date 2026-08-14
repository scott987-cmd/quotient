import XCTest
@testable import LLMQuotaCore

final class WatchdogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Watchdog.resetForTesting()
    }

    func testFastBodyReturnsValue() {
        let r = Watchdog.run("fast", timeout: 5) { 42 }
        guard case .done(let v) = r else { return XCTFail("应该正常返回，实际 \(r)") }
        XCTAssertEqual(v, 42)
    }

    func testSlowBodyTimesOut() {
        let r = Watchdog.run("slow", timeout: 0.2) {
            Thread.sleep(forTimeInterval: 1.5)
            return 1
        }
        guard case .timedOut = r else { return XCTFail("应该超时，实际 \(r)") }
        // 等那个后台线程自己跑完，别污染后面的用例。
        Thread.sleep(forTimeInterval: 1.6)
    }

    /// 这条是整个看门狗存在的理由之一。
    ///
    /// 阻塞在内核里的线程杀不掉，所以超时之后它还挂着。如果不拦住后续调用，
    /// 每 30 秒一轮就泄漏一个线程 —— 真实事故里 iCloud 目录被写进了
    /// 四个孤儿临时文件，正是这么堆出来的。
    func testSecondCallSkippedWhileFirstStillStuck() {
        let first = Watchdog.run("stuck", timeout: 0.2) {
            Thread.sleep(forTimeInterval: 2.0)
            return 1
        }
        guard case .timedOut = first else { return XCTFail("第一次应该超时，实际 \(first)") }

        let second = Watchdog.run("stuck", timeout: 5) { 2 }
        guard case .skipped = second else {
            return XCTFail("上一次还卡着，第二次必须跳过而不是再派一个线程，实际 \(second)")
        }
        XCTAssertEqual(Watchdog.skipCounts()["stuck"], 1)

        Thread.sleep(forTimeInterval: 2.1)
    }

    func testKeyIsReleasedAfterBodyFinishes() {
        let first = Watchdog.run("release", timeout: 0.2) {
            Thread.sleep(forTimeInterval: 0.6)
            return 1
        }
        guard case .timedOut = first else { return XCTFail("第一次应该超时") }
        Thread.sleep(forTimeInterval: 0.8)   // 让它跑完，key 应该被释放

        let second = Watchdog.run("release", timeout: 5) { 2 }
        guard case .done(let v) = second else {
            return XCTFail("卡住的那次已经跑完了，这次应该正常派出去，实际 \(second)")
        }
        XCTAssertEqual(v, 2)
    }

    func testDifferentKeysDoNotBlockEachOther() {
        let a = Watchdog.run("keyA", timeout: 0.2) {
            Thread.sleep(forTimeInterval: 1.0)
            return 1
        }
        guard case .timedOut = a else { return XCTFail("keyA 应该超时") }

        let b = Watchdog.run("keyB", timeout: 5) { 2 }
        guard case .done(let v) = b else {
            return XCTFail("keyB 和 keyA 无关，不该被牵连，实际 \(b)")
        }
        XCTAssertEqual(v, 2)
        Thread.sleep(forTimeInterval: 1.1)
    }

    func testValueOrFallsBack() {
        let stuck = Watchdog.run("fallback", timeout: 0.2) {
            Thread.sleep(forTimeInterval: 0.6)
            return 99
        }
        XCTAssertEqual(stuck.valueOr(7), 7)
        XCTAssertTrue(stuck.stalled)
        Thread.sleep(forTimeInterval: 0.8)

        let ok = Watchdog.run("fallback2", timeout: 5) { 99 }
        XCTAssertEqual(ok.valueOr(7), 99)
        XCTAssertFalse(ok.stalled)
    }

    /// `.stalled` 不能被并进 `.unavailable`。
    ///
    /// 「没连 iCloud」和「iCloud 卡死把流水线冻住了」严重程度差着数量级，
    /// 合并成一个状态，人看到的就是前者，然后去查一个没坏的地方。
    func testStalledIsDistinctFromUnavailable() {
        XCTAssertNotEqual(ICloudSyncStatus.stalled("x"), .unavailable)
        XCTAssertFalse(ICloudSyncStatus.stalled("x").needsFullDiskAccess)
    }
}
