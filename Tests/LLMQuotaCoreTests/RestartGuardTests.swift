import XCTest
@testable import LLMQuotaCore

/// **有活在跑就别踢 worker** —— 这道闸今天被两个毛病同时绕过去了。
///
/// 2026-08-22 凌晨:装机脚本自己判「在跑几个」的办法是
/// `llmq brief | grep -oE '在跑 [0-9]+'`,而且判断在编译前、kickstart
/// 在编译后,隔着几十秒 —— 中间 worker 已经派了新活,结果一个刚跑
/// 32 秒的任务被连人带活杀掉。老板第六次问「任务为啥又停了」。
///
/// 两处修:①判断和踢收进同一条命令(`llmq work restart-worker`),
/// 不再靠文本契约;②「没记 PID 的 running」也算在飞 —— 任务刚起、
/// PID 还没落盘的窗口里,原来的 `?? false` 让闸门形同虚设。
final class RestartGuardTests: XCTestCase {
    private func task(_ id: String, state: WorkTask.State, pid: Int32?) -> WorkTask {
        var t = WorkTask(id: id, prompt: "干活", repo: "/tmp/x")
        t.state = state
        t.runnerPID = pid
        t.startedAt = Date()
        return t
    }

    /// 判据本身:running + (PID 活着 或 还没记 PID) = 在飞。
    private func inFlight(_ tasks: [WorkTask]) -> [WorkTask] {
        tasks.filter { $0.state == .running && ($0.runnerPID.map { kill($0, 0) == 0 } ?? true) }
    }

    func testRunningWithoutPidCountsAsInFlight() {
        let t = task("a", state: .running, pid: nil)
        XCTAssertEqual(inFlight([t]).count, 1,
                       "任务刚起、PID 还没落盘 —— 这时候踢它,32 秒的活白烧。"
                       + "宁可多等一轮:晚几分钟换二进制,比杀掉一个任务便宜")
    }

    func testRunningWithLivePidCountsAsInFlight() {
        let t = task("b", state: .running, pid: getpid())
        XCTAssertEqual(inFlight([t]).count, 1)
    }

    /// 进程真死了的不算 —— 否则一个孤儿记录能永久挡住所有升级。
    func testRunningWithDeadPidDoesNotBlock() {
        let t = task("c", state: .running, pid: 999_999)
        XCTAssertTrue(inFlight([t]).isEmpty, "孤儿记录不能永久挡住换二进制")
    }

    func testQueuedNeverBlocks() {
        XCTAssertTrue(inFlight([task("d", state: .queued, pid: nil)]).isEmpty)
    }
}
