import XCTest
@testable import LLMQuotaCore

/// **队列空了要自己按目标补活 —— 这一环原来是人(我)在做。**
///
/// 老板 2026-08-22:「总不能跑一步卡一步就需要你介入」「常设目标自动续活开干」。
final class AutoRefillTests: XCTestCase {
    private func task(_ repo: String, _ state: WorkTask.State) -> WorkTask {
        var t = WorkTask(id: "t-\(UUID().uuidString.prefix(6))", prompt: "活", repo: repo)
        t.state = state
        return t
    }

    /// **有活在排/在跑/被拦的时候绝不补** —— 那是火上浇油,
    /// 队列只会越堵越长,而老板看到的是「怎么越来越多」。
    func testNeverRefillsWhenBusy() {
        for st: WorkTask.State in [.queued, .running, .blocked] {
            XCTAssertFalse(AutoRefill.isIdle(repo: "/r", tasks: [task("/r", st)]),
                           "\(st) 也算忙")
        }
    }

    func testDoneTasksDoNotCountAsBusy() {
        XCTAssertTrue(AutoRefill.isIdle(repo: "/nonexistent-repo-xyz",
                                        tasks: [task("/nonexistent-repo-xyz", .done)]))
    }

    /// 两小时一次的闸:没有它,跑得快的仓库会被连续补活挤掉别人,
    /// 而且目标文档写含糊时会连着生成一串同样含糊的任务。
    func testRateLimitExists() {
        XCTAssertEqual(AutoRefill.minInterval, 2 * 3600)
    }

    /// 提示词要把「哪些不归你」写明 —— 否则自主任务会一头撞进
    /// 账号/签名/上架这类只有老板能拍板的事(见 BossGate)。
    func testPromptFencesOffBossOnlyWork() {
        let p = AutoRefill.prompt(repoName: "flint", goal: "P3 内容:三张地图")
        XCTAssertTrue(p.contains("拍板"), "要提醒它避开老板专属的决定")
        XCTAssertTrue(p.contains("一整块"), "要一次做一件完整的事,不开三个半成品")
        XCTAssertTrue(p.contains("什么都别改"), "没值得做的就该空跑,不能乱开坑")
    }
}
