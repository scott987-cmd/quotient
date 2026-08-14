import XCTest
@testable import LLMQuotaCore

/// 中断不能记成「这个平台干不了」。
///
/// `triedPlatforms` 是**派活那一刻**就写进去的，不是失败之后。
/// 所以一次中断（worker 重启、机器崩了、被杀）会让那个平台永久背上
/// 「本任务已在该平台失败过」，而调度对这条是**永久排除**。
///
/// 今天的实际后果：图节点 s2 被 TCC 闸门、发布重启、机器崩十小时轮流打断七次，
/// Qwen 和 Kimi 双双被拉黑，最后调度报「没有平台能接」把它冻住 ——
///
///     没有平台能接：Qwen（本任务已在该平台失败过）；
///     Kimi（本任务已在该平台失败过）；火山方舟（任务是复杂档…）
///
/// 而**没有任何一次是 agent 真的干不了**。基础设施故障被记成了能力问题，
/// 一个本来能做完的任务就此永久停摆 —— 这正好是「一分不浪费」的反面。
final class InterruptionBlameTests: XCTestCase {

    /// 回收时对一条被打断的任务做的决定。抽出来单独测，
    /// 因为它埋在 CLI 的循环里，而它决定了任务还能不能被派出去。
    private func reclaim(_ t: WorkTask) -> WorkTask {
        var x = t
        let n = (t.interruptedCount ?? 0) + 1
        x.interruptedCount = n
        if n <= 2 {
            x.state = .queued
            // startedAt **保留** —— 防自锁靠它认出「这笔用量是我们自己烧的」。
            if let p = t.platform { x.triedPlatforms.removeAll { $0 == p } }
        } else {
            x.state = .failed
        }
        return x
    }

    private func running(on p: Platform) -> WorkTask {
        var t = WorkTask(id: "t", prompt: "p", repo: "/tmp")
        t.state = .running
        t.platform = p
        t.triedPlatforms = [p]          // 派活那一刻就写进去了
        t.startedAt = Date()
        return t
    }

    func testInterruptionClearsPlatformBlame() {
        let after = reclaim(running(on: .qwen))
        XCTAssertEqual(after.state, .queued)
        XCTAssertFalse(after.triedPlatforms.contains(.qwen),
                       "被打断不是 Qwen 干不了 —— 留着这条它会被永久排除")
    }

    /// 别的平台身上真实的失败记录不能被顺手擦掉。
    func testOnlyTheInterruptedPlatformIsCleared() {
        var t = running(on: .kimi)
        t.triedPlatforms = [.qwen, .kimi]   // qwen 是真失败过的
        let after = reclaim(t)
        XCTAssertEqual(after.triedPlatforms, [.qwen],
                       "只摘掉被打断的那个，别的平台的真实失败要留着")
    }

    /// 连着被打断三次就该判失败 —— 但那时也不该再赖平台。
    func testThirdInterruptionFailsWithoutBlamingPlatform() {
        var t = running(on: .qwen)
        t.interruptedCount = 2
        let after = reclaim(t)
        XCTAssertEqual(after.state, .failed, "打断三次不再自动重排")
        XCTAssertEqual(after.interruptedCount, 3)
    }

    /// 端到端：一条被打断过的任务，调度还愿不愿意派给同一个平台。
    func testSchedulerWillDispatchAgainAfterInterruption() {
        struct R: AgentRunner {
            let platform: Platform
            var binaryName: String { "echo" }
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/bin/echo", [prompt], [:])
            }
        }
        let d = Dashboard(
            generatedAt: Date(), machines: [],
            reports: [PlatformReport(
                platform: .qwen, planName: "p", monthlyCost: nil, currency: "CNY",
                detected: true, machines: ["本机"], lastActivity: nil, statuses: [],
                last30dRequests: 0, last30dBillableTokens: 0, last7dRequests: 0,
                topModels: [])])

        // 没摘干净的样子：Qwen 被永久排除。
        var blamed = running(on: .qwen)
        blamed.state = .queued
        let before = WorkScheduler().decide(
            dashboard: d, runners: [R(platform: .qwen)], task: blamed)
        XCTAssertFalse(before.candidates.contains { $0.platform == .qwen },
                       "triedPlatforms 里有它就该被排除 —— 这条规则本身是对的")

        // 摘干净之后：可以再派。
        let cleared = reclaim(running(on: .qwen))
        let after = WorkScheduler().decide(
            dashboard: d, runners: [R(platform: .qwen)], task: cleared)
        XCTAssertTrue(after.candidates.contains { $0.platform == .qwen },
                      "中断之后必须还能派给同一个平台，否则一次重启就烧掉一个候选")
    }

    /// **被打断之后，调度不能把自己刚烧的那笔用量当成「人在用」。**
    ///
    /// 让开逻辑会把落在我们自己执行窗口里的用量排除掉，判据是任务的
    /// startedAt / endedAt。第一版回收时把 `startedAt` 抹成了 nil
    /// （为了不显示「已经跑了 11 天」），窗口就没了：
    ///
    ///     [23:15] 派给 Qwen 跑 s2 → 被打断 → startedAt 抹掉
    ///     [23:21] 排除 Qwen「你 6 分钟前还在用它，先让着你」
    ///
    /// 当时 Kimi 额度耗尽、Claude 是指挥、火山档次不够 ——
    /// 唯一可用的平台被自己锁死 20 分钟。**是修复引入的回归。**
    func testReclaimKeepsTheExecutionWindow() {
        let t = running(on: .qwen)
        let after = reclaim(t)
        XCTAssertNotNil(after.startedAt,
                        "startedAt 是防自锁的唯一证据，回收时不能抹掉 —— "
                        + "抹了它调度就会把自己刚烧的用量当成人在用")
        XCTAssertEqual(after.startedAt, t.startedAt)
    }

    /// 显示层已经单独处理过「排队任务不该显示时长」，
    /// 所以保留 startedAt 不会让手机上出现假时长。这条把那个前提钉住。
    func testQueuedTaskDoesNotReportElapsedEvenWithStartedAt() {
        var t = reclaim(running(on: .qwen))
        t.state = .queued
        let board = TaskBoard.build(from: [t], machineName: "M")
        let brief = board.tasks.first
        XCTAssertNotNil(brief)
        XCTAssertNil(brief?.startedAt, "排队中的任务不该把上一轮的 startedAt 发给手机")
        XCTAssertNil(brief?.elapsedSeconds)
    }
}
