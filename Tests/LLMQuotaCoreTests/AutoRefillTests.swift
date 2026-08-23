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
        let p = AutoRefill.prompt(repoName: "flint", goal: "P3 内容:三张地图",
                                  item: AutoRefill.MainlineItem(index: 1, text: "【关卡】三张地图"))
        XCTAssertTrue(p.contains("拍板"), "要提醒它避开老板专属的决定")
        XCTAssertTrue(p.hasPrefix("【续活·主线 1】"), "系统选块,标题第一行写明第几块")
        XCTAssertTrue(p.contains("不顺手开别的块"), "一次只做这一块,保证连续性")
        XCTAssertTrue(p.contains("什么都别改"), "没值得做的就该空跑,不能乱开坑")
    }
}

extension AutoRefillTests {
    /// **被已死上游冻住的 blocked 不算忙。** 实锤 2026-08-23:人物形象图 s6/s7
    /// 被 failed 的 s4 冻住永不解冻,却让 Flint 永远 isIdle=false,续活一次没触发。
    func testDeadFrozenBlockedDoesNotCountAsBusy() {
        var up = WorkTask(id: "s4", prompt: "x", repo: "/f"); up.state = .failed
        var down = WorkTask(id: "s6", prompt: "x", repo: "/f"); down.state = .blocked; down.frozenBy = "s4"
        XCTAssertTrue(AutoRefill.isIdle(repo: "/f", tasks: [up, down]),
                      "僵尸冻结不是在干活,不该挡续活")
    }
    /// 但等人拍板的 blocked(frozenBy==nil)仍算忙 —— 别在人没答复时硬塞新活。
    func testWaitingOnHumanStillCountsAsBusy() {
        var t = WorkTask(id: "b", prompt: "x", repo: "/f"); t.state = .blocked; t.frozenBy = nil
        XCTAssertFalse(AutoRefill.isIdle(repo: "/f", tasks: [t]))
    }
}
