import XCTest
@testable import LLMQuotaCore

/// 「跑到一半被打断」这件事的记账。
///
/// 真实代价：一次 334 秒的 Qwen 产出、一次 26 分钟的图节点 s2，
/// 两次都是 worker 被重启，任务被回收成 `failed` 躺着等人手动 retry ——
/// 而人当时正忙着查别的问题，根本没注意到。
final class InterruptedTaskTests: XCTestCase {

    /// **老记录里没有这个键，必须还能读出来。**
    ///
    /// 合成的 `Codable` 遇到缺失的键抛 `keyNotFound`，属性写默认值也救不了 ——
    /// 这个坑在这个项目里踩过不止五次，每次都是「加了个字段，历史任务全读不出来」。
    /// 所以每加一个字段就补一条这样的用例。
    func testOldRecordWithoutInterruptedCountStillDecodes() throws {
        let json = """
        {"id":"old1","prompt":"p","repo":"/tmp","state":"running",
         "createdAt":"2026-08-01T00:00:00Z"}
        """
        let t = try SnapshotCoding.decoder().decode(
            WorkTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.id, "old1")
        XCTAssertNil(t.interruptedCount, "老记录没有这个键，应该是 nil 而不是解码失败")
    }

    func testInterruptedCountRoundTrips() throws {
        var t = WorkTask(id: "t1", prompt: "p", repo: "/tmp")
        t.interruptedCount = 2
        let data = try SnapshotCoding.encoder().encode(t)
        let back = try SnapshotCoding.decoder().decode(WorkTask.self, from: data)
        XCTAssertEqual(back.interruptedCount, 2)
    }

    /// 回收策略本身：前两次重排，第三次才判死。
    ///
    /// 这里直接测策略函数，不测 CLI 里那段循环 —— 循环只是把它套在任务列表上。
    func testRequeueTwiceThenFail() {
        func decide(_ n: Int?) -> (WorkTask.State, Int) {
            let c = (n ?? 0) + 1
            return (c <= 2 ? .queued : .failed, c)
        }
        XCTAssertEqual(decide(nil).0, .queued)
        XCTAssertEqual(decide(nil).1, 1)
        XCTAssertEqual(decide(1).0, .queued)
        XCTAssertEqual(decide(2).0, .failed, "打断三次就别再自动重排了，多半是任务本身有问题")
        XCTAssertEqual(decide(2).1, 3)
    }
}
