import XCTest
@testable import LLMQuotaCore

/// **单步零产出不冻死下游;整图零产出才算空转。**
///
/// 老板 2026-08-23 的头发图纠正了旧判据:s1 零产出(准备/空转步),但 s2
/// 不真依赖 s1 产物,自己就把整条头发产线写出来了。旧规则「上游零产出就
/// 冻死下游」把能独立干活的 s2 冻死,还害得整条真成果(22 文件)被误判空跑
/// 作废。系统在 s2 跑前无法知道它依不依赖 s1 —— 该乐观放行,别悲观冻死等人。
final class ZeroOutputBlockerTests: XCTestCase {
    private func step(_ id: String, _ state: WorkTask.State,
                      deps: [String] = [], changed: Int? = nil) -> WorkTask {
        var t = WorkTask(id: id, prompt: "x", repo: "/r")
        t.state = state; t.graphID = "g"; t.dependsOn = deps; t.changedFiles = changed
        return t
    }

    /// 零产出上游**不再冻死**下游 —— 放它试跑(头发 s2 的场景)。
    func testZeroOutputUpstreamDoesNotFreezeDownstream() {
        let tasks = [step("s1", .done, changed: 0), step("s2", .queued, deps: ["s1"])]
        XCTAssertTrue(TaskGraph.isReady(tasks[1], in: tasks),
                      "上游零产出,下游仍该就绪 —— 它可能不依赖上游产物,能独立干完")
        // reconcile 不把它冻成 blocked
        XCTAssertFalse(TaskGraph.reconcile(tasks).contains { $0.id == "s2" && $0.state == .blocked },
                       "不该被冻结")
    }

    /// 但**整张图全跑完却零产出** = 真空转(Greed 四步全空),要被搁浅识别。
    func testWholeGraphZeroOutputIsStranded() {
        let tasks = [
            step("s1", .done, changed: 0),
            step("s2", .done, deps: ["s1"], changed: 0),
        ]
        XCTAssertFalse(TaskGraph.stranded(tasks).isEmpty,
                       "整图零产出、全跑完 —— 这是空转,必须被看见")
    }

    /// 单步零产出但下游有产出(头发)→ 不是空转,正常放过。
    func testMixedOutputIsNotStranded() {
        let tasks = [
            step("s1", .done, changed: 0),
            step("s2", .done, deps: ["s1"], changed: 22),
        ]
        XCTAssertTrue(TaskGraph.stranded(tasks).isEmpty,
                      "s1 空转但 s2 干出 22 个文件 —— 这条图是好的,别误报搁浅")
    }
}
