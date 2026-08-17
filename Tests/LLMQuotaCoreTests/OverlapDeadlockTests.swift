import XCTest
@testable import LLMQuotaCore

/// 重叠的分支必须**排队合**，不能互相卡死。
///
/// ## 这条为什么值钱
///
/// 老规则：`overlapsWith` 非空就跳过自动落地，注释写的理由是「顺序该人定」。
/// 听起来稳妥，实际后果是**一条都不合** —— 因为没有任何环节会去问人。
///
/// 2026-08-17 盘点 Maw：三条实质分支躺了两天没动。
///
/// - `agent/kimi/053f0384`   修换档叠影，715 行，带回归测试
/// - `agent/graph/cdce40f3`  同一个 BUG 的诊断证据，512 行
/// - `agent/codex/74c79d4b`  进食三拍动画，148 行
///
/// 三条两两都动了 `GameScene.swift` / `PlayerNode.swift` / `Tuning.swift`，
/// 于是每一条都被另外两条挡住。否决名单是空的 —— 它们根本没被**尝试**过，
/// 不是试了失败。
///
/// 更糟的是它自我加剧：躺着的时候新任务还在改这些文件，
/// 重叠组只会越滚越大。
///
/// 现在的规则：一组重叠里只放行**最老的那条**，合完之后其余的下一轮
/// 对着新 main 重新判定 —— 要么还能干净合入，要么 `mergesCleanly` 变 false，
/// 那才是真冲突、才该给人。安全性没放宽：合并前照样跑全量验收。
final class OverlapDeadlockTests: XCTestCase {

    private func item(_ branch: String, files: [String],
                      at seconds: TimeInterval) -> Review.Item {
        var i = Review.Item(
            branch: branch, taskID: branch, platform: "test", files: files,
            insertions: 1, deletions: 0, subject: branch,
            committedAt: Date(timeIntervalSince1970: seconds),
            mergesCleanly: true, overlapsWith: [],
            prompt: nil, hasWorktree: false, evidence: []
        )
        i.overlapsWith = []
        return i
    }

    /// 交叉填好 overlapsWith，模拟 list() 干的事
    private func linked(_ items: [Review.Item]) -> [Review.Item] {
        var out = items
        for i in out.indices {
            let mine = Set(out[i].files)
            out[i].overlapsWith = out.enumerated()
                .filter { $0.offset != i && !Set($0.element.files).isDisjoint(with: mine) }
                .map(\.element.branch)
        }
        return out
    }

    /// Maw 的真实局面：三条分支两两重叠，必须恰好放行一条 —— 最老的那条。
    func testExactlyOneOfAnOverlappingGroupIsReleased() {
        let group = linked([
            item("agent/kimi/053f0384",
                 files: ["Maw/GameScene.swift", "Maw/PlayerNode.swift"], at: 300),
            item("agent/graph/cdce40f3",
                 files: ["Maw/GameScene.swift", "Maw/Tuning.swift"], at: 100),
            item("agent/codex/74c79d4b",
                 files: ["Maw/PlayerNode.swift", "Maw/Tuning.swift"], at: 200),
        ])

        let released = group.filter { Review.isOldestInOverlapGroup($0, among: group) }
        XCTAssertEqual(released.count, 1,
                       "一组重叠里必须恰好放行一条 —— 0 条是死锁，多条是抢着合")
        XCTAssertEqual(released.first?.branch, "agent/graph/cdce40f3",
                       "放行的该是最老的那条，先排干积压")
    }

    /// **提交时间相同也必须分得出先后。**
    ///
    /// 判据得是全序。只按时间比，一组里同时间的几条会全都不是「最小」，
    /// 于是一条都不放行 —— 死锁原样还在，只是换了个触发条件。
    func testTiesAreStillTotallyOrdered() {
        let group = linked([
            item("agent/b/2", files: ["Same.swift"], at: 500),
            item("agent/a/1", files: ["Same.swift"], at: 500),
        ])
        let released = group.filter { Review.isOldestInOverlapGroup($0, among: group) }
        XCTAssertEqual(released.count, 1, "同时间也必须恰好放行一条")
        XCTAssertEqual(released.first?.branch, "agent/a/1", "同时间按分支名兜底，结果要稳定")
    }

    /// 缺提交时间的分支不该抢在有时间的前面 —— 它可能是刚推的。
    func testMissingTimestampSortsLast() {
        var noTime = item("agent/x/none", files: ["S.swift"], at: 0)
        noTime.committedAt = nil
        let group = linked([noTime, item("agent/y/old", files: ["S.swift"], at: 900)])
        let released = group.filter { Review.isOldestInOverlapGroup($0, among: group) }
        XCTAssertEqual(released.first?.branch, "agent/y/old",
                       "没有时间戳的排最后，不能靠「未知」插队")
    }

    /// **合不进去的分支不能占队首。**
    ///
    /// 这条是踩出来的：Maw 的 74c79d4b 刷新之后能干净合入了，但刷新这个动作
    /// 让它变成了组里**最新**的一条；而组里另外两条（cdce40f3、053f0384）
    /// 还是冲突、永远不会被放行。按「最老优先」排，刷好的那条排在两个
    /// 永远不会走的人后面 —— 于是它也永远轮不到。
    ///
    /// 死锁换了个形式又回来了：队列里排着一个不会走的人，
    /// 后面的人就永远走不了。所以排队只在**有资格落地**的分支之间排。
    func testUnmergeableBranchesDoNotHoldTheQueue() {
        let all = linked([
            item("agent/graph/cdce40f3",
                 files: ["Maw/GameScene.swift"], at: 100),      // 最老，但合不进去
            item("agent/kimi/053f0384",
                 files: ["Maw/GameScene.swift"], at: 200),      // 次老，也合不进去
            item("agent/codex/74c79d4b",
                 files: ["Maw/GameScene.swift"], at: 900),      // 刚刷新，最新，能合
        ])
        // 前两条合不进去 —— 它们不进候选队列
        let landable = all.filter { $0.branch == "agent/codex/74c79d4b" }

        XCTAssertTrue(
            Review.isOldestInOverlapGroup(all[2], among: landable),
            "唯一能合的那条必须放行 —— 不能被两条永远合不进去的分支挡着")

        // 反面：如果拿全量去排，它就被挡住了 —— 这正是修之前的行为
        XCTAssertFalse(
            Review.isOldestInOverlapGroup(all[2], among: all),
            "这条断言记录的是**错误行为**，用来说明为什么队列必须先过滤")
    }

    /// 不重叠的分支不受这条规则影响，照旧直接放行。
    func testNonOverlappingBranchesAreUnaffected() {
        let group = linked([
            item("agent/a/1", files: ["A.swift"], at: 100),
            item("agent/b/2", files: ["B.swift"], at: 200),
        ])
        for i in group {
            XCTAssertTrue(i.overlapsWith.isEmpty, "这两条本来就不该算重叠")
        }
    }
}
