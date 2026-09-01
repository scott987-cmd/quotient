import XCTest
@testable import LLMQuotaCore

/// 手机看到的那几页,和「有没有活在跑」无关。
/// 实锤 2026-08-23:19:07 起主循环一直卡在一条 Kimi 任务里,views/review.json 就停在 19:07,
/// 期间新产出的待验收分支手机上一条都看不到 —— 老板看到的是「半小时没更新」。
final class ShowcaseTests: XCTestCase {
    override func setUp() { Showcase.markStale() }

    func test_到点才刷_不到点不刷() {
        var n = 0
        let pub: [() -> Void] = [{ n += 1 }]
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(Showcase.refresh(now: t0, publishers: pub))
        XCTAssertEqual(n, 1)
        XCTAssertFalse(Showcase.refresh(now: t0.addingTimeInterval(5), publishers: pub), "5 秒后不该重刷")
        XCTAssertEqual(n, 1)
        XCTAssertTrue(Showcase.refresh(now: t0.addingTimeInterval(Showcase.interval), publishers: pub))
        XCTAssertEqual(n, 2)
    }

    func test_force能立刻刷() {
        var n = 0
        let pub: [() -> Void] = [{ n += 1 }]
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(Showcase.refresh(now: t0, publishers: pub))
        XCTAssertTrue(Showcase.refresh(force: true, now: t0.addingTimeInterval(1), publishers: pub),
                      "轮末尾/状态刚变时要能强制刷")
        XCTAssertEqual(n, 2)
    }

    func test_并发不重入_每个发布器只跑一次() {
        let counter = NSLock(); var n = 0
        let slow: [() -> Void] = [{ Thread.sleep(forTimeInterval: 0.3); counter.lock(); n += 1; counter.unlock() }]
        let done = expectation(description: "both")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global().async {
                _ = Showcase.refresh(force: true, publishers: slow)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        counter.lock(); let got = n; counter.unlock()
        XCTAssertEqual(got, 1, "同一时刻只允许一个在发布,否则两份内容互相覆盖")
    }

    /// 契约:手机真正读的每一页都要在默认发布器里。
    /// 少一份,那一页就永远停在旧内容上 —— 而这种「静止」在界面上和「没有新东西」长得一样。
    func test_默认发布器覆盖手机读的每一页() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/LLMQuotaCore/Showcase.swift"), encoding: .utf8)
        for must in ["OfficeLog.publish", "TaskBoardStore.publishNow", "ClusterPresenceStore.publish",
                     "ViewFeed.reviewPage", "ViewFeed.blockedPage", "RoadmapPage.page",
                     "ViewFeed.playbookPage", "ViewFeed.menu"] {
            XCTAssertTrue(src.contains(must), "默认发布器少了 \(must)")
        }
        // 发布必须在独立 Projector，不再是 Coordinator 里的定时器或轮末尾任务。
        let main = try String(contentsOf: root.appendingPathComponent("Sources/llmq/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("case \"projector\""), "CLI 必须能独立启动 Projector")
        XCTAssertTrue(main.contains("ProjectorService.publishAll(token: token)"),
                      "独立 Projector 必须走唯一发布入口")
        XCTAssertTrue(main.contains("com.llmquotabar.projector"),
                      "安装常驻循环时必须同时安装独立 Projector")
        let loopStart = try XCTUnwrap(main.range(of: "func cmdWorkLoop("))
        let projectorStart = try XCTUnwrap(main.range(of: "func cmdWorkProjector("))
        let loopBody = main[loopStart.lowerBound..<projectorStart.lowerBound]
        XCTAssertFalse(loopBody.contains("Showcase.trigger"),
                       "Coordinator 不得再发布手机视图")
    }
}
