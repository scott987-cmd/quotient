import XCTest
@testable import LLMQuotaCore

/// **图任务的分支要能找回它的任务记录。**
///
/// ## 这条对应的真实故障
///
/// 老板（2026-08-19）：「为啥今天手机端看不到正在进行的任务」。
///
/// 答案是**真的什么都没在跑**，而停摆的源头是一次 ID 形状不匹配：
///
/// - 普通分支叫 `agent/<平台>/<任务ID>`，末段就是任务 ID，查得到；
/// - **图任务的分支叫 `agent/graph/<图ID>`**，而任务记录是按**步骤**
///   存的（`<图ID>s1`、`<图ID>s2`…）—— 图 ID 本身在任务库里不存在。
///
/// 于是 `byID[taskID]` 恒为 nil，这类分支被一律判成
/// 「任务记录没了 —— 自动环节一律不碰」。实测两个游戏仓库里
/// **全部 5 条 `agent/graph/*` 分支精确匹配都是 0** ——
/// 图任务的产出从来没进过自动落地，一条都没有。
///
/// 代价是连锁的：`agent/graph/3f68707c`（08-17，38 个文件，能干净合入）
/// 卡了两天 → main 基线落后 → `BaselineFreshness` 拿旧基线挡住队列里
/// 所有的活 → 什么都不跑 → 手机上「正在进行」永远空着。
///
/// **一条分支认不出记录，拖停了整套系统两天。**
final class GraphBranchLookupTests: XCTestCase {

    private func task(_ id: String, state: WorkTask.State,
                      graphID: String? = nil) -> WorkTask {
        var t = WorkTask(id: id, prompt: "活 \(id)", repo: "/tmp/x")
        t.state = state
        t.graphID = graphID
        return t
    }

    private func index(_ tasks: [WorkTask]) -> [String: WorkTask] {
        Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// **普通分支照旧走精确匹配** —— 别为了修图任务把常规路径改坏。
    func testPlainTaskIDStillMatchesExactly() {
        let t = task("51d4180c", state: .done)
        let found = Review.taskFor("51d4180c", in: index([t]), all: [t])
        XCTAssertEqual(found?.id, "51d4180c")
    }

    /// **图 ID 要能找回步骤记录。** 这是故障的正面复刻。
    func testGraphIDFallsBackToItsSteps() {
        let s2 = task("3f68707cs2", state: .failed, graphID: "3f68707c")
        let s5 = task("3f68707cs5", state: .done, graphID: "3f68707c")
        let all = [s2, s5]
        let found = Review.taskFor("3f68707c", in: index(all), all: all)
        XCTAssertNotNil(found,
                        "图 ID 在任务库里没有同名记录 —— 认不出来就等于"
                        + "「任务记录没了」，整条分支被自动环节拉黑")
        XCTAssertEqual(found?.state, .done,
                       "要挑 done 的那一步：分支上的提交是它打的，"
                       + "拿失败的那步去判闸会把能合的分支挡住")
    }

    /// 一步都没 done 时也要返回记录，让**上层的状态闸**去判 ——
    /// 而不是在这里假装记录不存在。
    ///
    /// 这两件事的区别很重要：「记录没了」走的是「只能人工处置」，
    /// 而「记录在、状态不对」走的是正常的状态闸，会自己好。
    func testNoDoneStepStillReturnsARecord() {
        let s1 = task("aabbccdds1", state: .failed, graphID: "aabbccdd")
        let s2 = task("aabbccdds2", state: .running, graphID: "aabbccdd")
        let all = [s1, s2]
        let found = Review.taskFor("aabbccdd", in: index(all), all: all)
        XCTAssertNotNil(found, "记录在，只是没跑完 —— 不该被当成「记录没了」")
    }

    /// **真没有记录时还是要返回 nil。**
    ///
    /// 别把「找得回」做成「什么都找得回」：记录真的没了的分支，
    /// 自动环节确实不该碰它 —— 那条闸本身是对的。
    func testGenuinelyMissingRecordStillReturnsNil() {
        let other = task("zzzzzzzzs1", state: .done, graphID: "zzzzzzzz")
        XCTAssertNil(Review.taskFor("deadbeef", in: index([other]), all: [other]),
                     "不相干的图的步骤不能算数")
        XCTAssertNil(Review.taskFor("", in: [:], all: []),
                     "空 ID（分支名不符合约定）不该匹配到任何东西")
    }

    /// 靠 `graphID` 和靠 `id` 前缀两条路都要认。
    ///
    /// 老任务可能没写 `graphID` 字段，只有 `<图ID>sN` 这个命名约定；
    /// 只认一条的话，老数据会继续卡着。
    func testMatchesByGraphIDOrByIDPrefix() {
        let byField = task("11112222s1", state: .done, graphID: "11112222")
        XCTAssertNotNil(Review.taskFor("11112222",
                                       in: index([byField]), all: [byField]))
        var byPrefix = task("33334444s1", state: .done)
        byPrefix.graphID = nil
        XCTAssertNotNil(Review.taskFor("33334444",
                                       in: index([byPrefix]), all: [byPrefix]),
                        "没写 graphID 的老任务要靠 id 前缀认出来")
    }
}
