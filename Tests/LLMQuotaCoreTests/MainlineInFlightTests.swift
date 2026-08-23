import XCTest
@testable import LLMQuotaCore

/// 派过还没落地的主线块不能再派第二遍。
/// 实锤 2026-08-23:第 3 块做完等审核期间,续活又派了一次第 3 块(Kimi 10 分钟零产出)。
final class MainlineInFlightTests: XCTestCase {
    let plan = """
    ## ⭐ 续活主线
    1. 【人物·皮肤】 — 已完成
    2. 【人物·头发】 — 已完成
    3. 【人物·装备第二版】四干员穿上完整作战服。
    4. 【僵尸·八款差异】八款僵尸。
    ## 别的
    """

    private func task(_ title: String, _ state: WorkTask.State, branch: String? = nil,
                      discarded: Bool = false) -> WorkTask {
        var t = WorkTask(id: "t-\(UUID().uuidString.prefix(6))", prompt: title + "\n正文", repo: "/r")
        t.state = state; t.branch = branch; t.origin = "auto-refill"
        if discarded { t.discardedAt = Date() }
        return t
    }

    func test_标题解析() {
        XCTAssertEqual(AutoRefill.mainlineIndex(ofTitle: "【续活·主线 3】【人物·装备第二版】…\n正文"), 3)
        XCTAssertNil(AutoRefill.mainlineIndex(ofTitle: "【续活】flint 的队列空了"))
        XCTAssertNil(AutoRefill.mainlineIndex(ofTitle: "正文第一行\n【续活·主线 3】不在首行"))
    }

    func test_done但分支没合_算在飞_合了或丢了不算() {
        let pending = task("【续活·主线 3】装备", .done, branch: "agent/kimi/a")
        let merged = task("【续活·主线 2】头发", .done, branch: "agent/kimi/b")
        let gone = task("【续活·主线 1】皮肤", .done, branch: "agent/kimi/c")
        let dropped = task("【续活·主线 4】僵尸", .done, branch: "agent/kimi/d", discarded: true)
        let failed = task("【续活·主线 5】x", .failed, branch: "agent/kimi/e")
        let states: [String: AutoRefill.BranchState] = ["agent/kimi/a": .pending, "agent/kimi/b": .merged,
                                                        "agent/kimi/c": .gone, "agent/kimi/d": .pending, "agent/kimi/e": .pending]
        let inFlight = AutoRefill.mainlineItemsInFlight(
            repo: "/r", tasks: [pending, merged, gone, dropped, failed],
            branchState: { states[$0] ?? .gone })
        XCTAssertEqual(inFlight, [3], "只有「做完、分支还在、没合、没丢」的算在飞")
    }

    func test_在排在跑的也算在飞() {
        let q = task("【续活·主线 4】僵尸", .queued)
        XCTAssertEqual(AutoRefill.mainlineItemsInFlight(repo: "/r", tasks: [q], branchState: { _ in .gone }), [4])
    }

    func test_在飞的块被跳过_挑下一块() {
        let it = AutoRefill.nextMainlineItem(in: plan, skipping: [3])
        XCTAssertEqual(it?.index, 4, "第 3 块在飞,该挑第 4 块,别重复派第 3 块")
        XCTAssertEqual(AutoRefill.nextMainlineItem(in: plan, skipping: [3, 4])?.index, nil, "都在飞就没得派")
        XCTAssertEqual(AutoRefill.nextMainlineItem(in: plan)?.index, 3)
    }

    /// 最新一条记录说了算:同一任务先 running 后 done+分支已合,不算在飞。
    func test_同一任务取最新记录() {
        var a = task("【续活·主线 3】装备", .running, branch: "agent/kimi/a")
        var b = a; b.state = .done
        a.id = "same"; b.id = "same"
        let f = AutoRefill.mainlineItemsInFlight(repo: "/r", tasks: [a, b], branchState: { _ in .merged })
        XCTAssertEqual(f, [])
    }
}
