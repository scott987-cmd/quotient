import XCTest
@testable import LLMQuotaCore

/// 第三轮 review 逮到的两个并发 bug 的回归测试。
final class ConcurrencyFixTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmp() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// **TaskStore.append 并发写不丢记录。** landing 挪后台后,它和主派活
    /// 线程同进程并发写 tasks.jsonl,原来无锁会互相覆盖丢状态。
    func testConcurrentAppendLosesNothing() {
        let n = 200
        let g = DispatchGroup()
        for i in 0..<n {
            g.enter()
            DispatchQueue.global().async {
                var t = WorkTask(id: "c\(i)", prompt: "x", repo: "/r")
                t.state = .queued
                try? TaskStore.append(t)
                g.leave()
            }
        }
        g.wait()
        let ids = Set(TaskStore.all().map(\.id))
        XCTAssertEqual(ids.count, n, "200 条并发写,一条都不能丢(原来会丢)")
    }

    /// **续活跨机抢占:第二台看到新鲜 claim 就让开。**
    func testRefillClaimIsExclusive() {
        let now = Date()
        // 第一次认领成功
        XCTAssertTrue(AutoRefill.claimRefill(repo: "/dev/Flint", now: now))
        // 模拟"另一台"：换 machineID 再抢同一个仓库 → 该被挡
        let saved = Paths.machineIDOverride
        Paths.machineIDOverride = "OTHER-MACHINE"
        defer { Paths.machineIDOverride = saved }
        XCTAssertFalse(AutoRefill.claimRefill(repo: "/dev/Flint", now: now.addingTimeInterval(60)),
                       "另一台机器在 2 小时内不该抢到同一仓库的续活")
    }

    /// 同机两个前台都看见空队列时，第二个不能凭“是自己”再派一份。
    func testOwnFreshClaimBlocksDuplicateRefill() {
        let now = Date()
        XCTAssertTrue(AutoRefill.claimRefill(repo: "/dev/Maw", now: now))
        XCTAssertFalse(AutoRefill.claimRefill(repo: "/dev/Maw", now: now.addingTimeInterval(60)),
                       "同一台机器的第二个前台不能重复派同一块主线")
    }

    /// 本机并发抢同一仓库，只能有一个成功。
    func testConcurrentLocalRefillClaimHasSingleWinner() {
        let now = Date()
        let lock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            if AutoRefill.claimRefill(repo: "/dev/Flint", now: now) {
                lock.lock(); winners += 1; lock.unlock()
            }
        }
        XCTAssertEqual(winners, 1)
    }
}
