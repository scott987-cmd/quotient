import XCTest
@testable import LLMQuotaCore

/// 手机「问题」页里真有一件事等人回答时，必须同步进入 APNs 提醒清单。
/// 反过来，任务已经结束但 iCloud 还残留旧问题时，绝不能再打扰人。
final class AskNudgeTests: XCTestCase {
    private func ask(id: String = "ask-1", taskID: String = "task-1") -> Ask {
        Ask(id: id, taskID: taskID, machineID: "machine-1", round: 1,
            platform: .kimi, taskPrompt: "继续做游戏", repoName: "Flint",
            questions: [Ask.Question(text: "要继续当前方案吗？")])
    }

    private func task(state: WorkTask.State, ask: Ask?) -> WorkTask {
        var task = WorkTask(id: "task-1", prompt: "继续做游戏", repo: "/r/Flint")
        task.state = state
        task.pendingAsk = ask
        return task
    }

    func testLiveQuestionIsIncludedInPushPendingList() {
        let pendingAsk = ask()
        let items = Nudge.pending(
            tasks: [task(state: .blocked, ask: pendingAsk)],
            publishedAsks: [pendingAsk])

        let item = items.first { $0.key.hasPrefix("question-") }
        XCTAssertEqual(item?.badge, 1)
        XCTAssertTrue(item?.body.contains("Kimi") == true)
        XCTAssertTrue(item?.body.contains("等你回答") == true)
    }

    func testStaleQuestionFromFinishedTaskDoesNotNotify() {
        let stale = ask()
        let items = Nudge.pending(
            tasks: [task(state: .failed, ask: stale)],
            publishedAsks: [stale])

        XCTAssertFalse(items.contains { $0.key.hasPrefix("question-") },
                       "iCloud 残留文件不能让已结束任务继续弹提醒")
    }

    func testUnpublishedQuestionDoesNotNotify() {
        let localOnly = ask()
        let items = Nudge.pending(
            tasks: [task(state: .blocked, ask: localOnly)],
            publishedAsks: [])

        XCTAssertFalse(items.contains { $0.key.hasPrefix("question-") },
                       "手机页面还看不到的问题不能先推横幅")
    }
}
