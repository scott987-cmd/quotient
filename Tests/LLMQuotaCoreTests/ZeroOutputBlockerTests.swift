import XCTest
@testable import LLMQuotaCore

/// **上游「done 但零产出」时,下游要被冻成 blocked,不能留在 queued。**
///
/// 老板 2026-08-23:「手机端看不到进行中的任务」。根子:头发图 s1 跑完
/// 零产出、状态 done,upstreamCleared 正确地不放行 s2 —— 但 reconcile 的
/// blocker 判定只认 blocked/failed,漏了这种,s2 永远留在 queued:
/// 既不就绪、又不进搁浅识别、还占着「进行中」显示。三不管地带。
final class ZeroOutputBlockerTests: XCTestCase {
    private func step(_ id: String, _ state: WorkTask.State,
                      deps: [String] = [], changed: Int? = nil) -> WorkTask {
        var t = WorkTask(id: id, prompt: "x", repo: "/r")
        t.state = state; t.graphID = "g"; t.dependsOn = deps; t.changedFiles = changed
        return t
    }

    func testZeroOutputUpstreamFreezesDownstream() {
        let tasks = [
            step("s1", .done, changed: 0),          // 空跑
            step("s2", .queued, deps: ["s1"]),
        ]
        let s2 = TaskGraph.reconcile(tasks).last { $0.id == "s2" }!
        XCTAssertEqual(s2.state, .blocked, "零产出上游要把下游冻住,不能留 queued 假装在跑")
        XCTAssertEqual(s2.frozenBy, "s1")
    }

    /// 上游有产出就正常放行,别误冻。
    func testProductiveUpstreamDoesNotFreeze() {
        let tasks = [
            step("s1", .done, changed: 5),
            step("s2", .queued, deps: ["s1"]),
        ]
        // reconcile 只返回**改了状态**的任务;上游有产出时 s2 无需改动,
        // 所以它不在返回里 —— 这正证明它没被冻(没被 reconcile 动过)。
        XCTAssertFalse(TaskGraph.reconcile(tasks).contains { $0.id == "s2" },
                       "上游真干了活,s2 不该被冻(reconcile 不动它)")
    }

    /// 冻住之后,搁浅识别要能看到它(这样才进 work blocked,不是消失)。
    func testFrozenGraphBecomesVisibleAsStranded() {
        let base = [step("s1", .done, changed: 0), step("s2", .queued, deps: ["s1"])]
        var merged = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a,_ in a })
        for t in TaskGraph.reconcile(base) { merged[t.id] = t }   // 合并回全集
        XCTAssertFalse(TaskGraph.stranded(Array(merged.values)).isEmpty,
                       "冻住的图必须被搁浅识别到 —— 否则又消失在三不管地带")
    }
}
