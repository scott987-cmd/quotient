import XCTest
@testable import LLMQuotaCore

/// 多机共享文件：**每台机器只更新自己看得见的那部分，绝不整份覆盖。**
///
/// ## 这条对应的真实故障
///
/// 老板的原话（2026-08-18）：「移动端老是弹出一个消息，但是点进去看里面
/// 又没有」。
///
/// 机制是这样的：
///
/// - Mac mini 上有 Greed / Maw 两个仓库，算出 10 条待审，发推送；
/// - **MacBook 上根本没有这两个目录**（`~/dev/Greed` 不存在），
///   但它跑着同一个工作循环，`guard isRepo(path) else { continue }`
///   把它们跳过，算出 0 条，然后**整份写出去**把那 10 条抹掉；
/// - 人收到 Mac mini 发的通知，点进去看到的是 MacBook 清空后的页面。
///
/// 同一天里这个「多写者整份覆盖」的形状已经出现过第二次了
///（第一次是 verdicts/.done，收口记录被互相抹掉，导致同一条合并重试
/// 380 次）。共享文件 + 多写者 = 只能合并，不能覆盖。
final class MultiMachineDigestTests: XCTestCase {

    private func digest(repo: String, branch: String) -> Review.Digest {
        Review.Digest(
            repo: repo, repoName: URL(fileURLWithPath: repo).lastPathComponent,
            branch: branch, platform: "kimi", subject: "活",
            prompt: nil, files: ["A.swift"], insertions: 1, deletions: 0,
            mergesCleanly: true, overlapsWith: [], committedAt: nil,
            evidence: [], evidenceFiles: [])
    }

    /// **看不见的仓库，它的条目必须原样留着。**
    ///
    /// 这是这次故障的正面：MacBook 看不见 Greed，就不该动 Greed 的条目。
    func testEntriesForUnseenReposSurvive() {
        let previous = [
            digest(repo: "/Users/x/dev/Greed", branch: "agent/kimi/a1"),
            digest(repo: "/Users/x/dev/Maw", branch: "agent/kimi/b2"),
        ]
        // 本机只看得见 LLMQuotaBar
        let seen: Set<String> = ["/Users/x/dev/LLMQuotaBar"]
        let mine = [digest(repo: "/Users/x/dev/LLMQuotaBar", branch: "agent/kimi/c3")]

        let kept = previous.filter { !seen.contains($0.repo) }
        let merged = kept + mine

        XCTAssertEqual(merged.count, 3,
                       "看不见的两个仓库的条目必须留着 —— 抹掉它们就是"
                       + "「弹了消息点进去是空的」")
        XCTAssertTrue(merged.contains { $0.branch == "agent/kimi/a1" })
        XCTAssertTrue(merged.contains { $0.branch == "agent/kimi/b2" })
    }

    /// **看得见的仓库，它的条目要被替换成最新的**（而不是累加）。
    ///
    /// 不替换的话，已经合掉的分支会永远留在手机的列表里 ——
    /// 那是反方向的同一种病：人点了没反应。
    func testEntriesForSeenReposAreReplaced() {
        let previous = [
            digest(repo: "/Users/x/dev/LLMQuotaBar", branch: "agent/kimi/old"),
            digest(repo: "/Users/x/dev/Greed", branch: "agent/kimi/a1"),
        ]
        let seen: Set<String> = ["/Users/x/dev/LLMQuotaBar"]
        let mine = [digest(repo: "/Users/x/dev/LLMQuotaBar", branch: "agent/kimi/new")]

        let merged = previous.filter { !seen.contains($0.repo) } + mine

        XCTAssertFalse(merged.contains { $0.branch == "agent/kimi/old" },
                       "本机看得见的仓库，旧条目要被顶掉，不能累加")
        XCTAssertTrue(merged.contains { $0.branch == "agent/kimi/new" })
        XCTAssertTrue(merged.contains { $0.branch == "agent/kimi/a1" },
                      "别的机器的仓库照旧留着")
    }

    /// 一台机器什么都看不见时，不该把整份清单清空。
    ///
    /// 这正是 MacBook 的处境 —— 它没有任何一个游戏仓库。
    func testMachineThatSeesNothingWipesNothing() {
        let previous = [
            digest(repo: "/Users/x/dev/Greed", branch: "agent/kimi/a1"),
            digest(repo: "/Users/x/dev/Maw", branch: "agent/kimi/b2"),
        ]
        let seen: Set<String> = []          // 一个仓库都没有
        let merged = previous.filter { !seen.contains($0.repo) } + []

        XCTAssertEqual(merged.count, 2,
                       "看不见任何仓库的机器，不该有权把别人的清单清空")
    }
    // MARK: 空写不许盖掉别人（上一版测试漏掉的前提）

    /// **上面那条 `testMachineThatSeesNothingWipesNothing` 给了假安全感。**
    ///
    /// 它假设 `previous` 里**已经有**别的机器的条目，于是「保留看不见的
    /// 仓库」这段逻辑有东西可保。但真实情况不是这样：
    ///
    /// `previous` 读的是**本机自己的本地暂存文件**，而两台机器各写各的
    /// 本地文件、镜像时整份推到 iCloud **同一个路径**。MacBook 那份里
    /// 从来就没有 Mac mini 的条目 —— 它的 `previous` 是空的，
    /// 于是它推上去的就是个 `[]`，把 Mac mini 刚推的盖掉。
    ///
    /// 实测（2026-08-19，老板的原话「弹消息有两份待验收，但是点击去
    /// 验收的页面又没有，过了好几分钟才加载出来」）：
    /// MacBook 上**根本没有 Greed 和 Maw 这两个目录**，
    /// 它的本地 reviews.json 是 4 字节的 `[]`，而 Mac mini 那份是 6660 字节。
    func testBlindMachineWithEmptyLocalFileMustNotPublish() {
        XCTAssertFalse(Review.worthWriting(merged: [], previous: []),
                       "自己算不出内容、也没有别人的内容要保留 —— "
                       + "写出去的只能是个空数组，只会盖掉别人刚推的")
    }

    /// 但**别把「不写」做成「永远不写」**：真要清掉最后一条时得写得下去。
    ///
    /// 不写的话，已经合掉的分支会永远挂在手机列表上 ——
    /// 那是反方向的同一种病（人点了没反应）。
    func testClearingTheLastEntryStillWrites() {
        let prev = [digest(repo: "/Users/x/dev/Greed", branch: "agent/kimi/a1")]
        XCTAssertTrue(Review.worthWriting(merged: [], previous: prev),
                      "本机看得见、并且确实清空了 —— 这一份必须写出去")
    }

    /// 正常有内容当然要写。
    func testNormalPublishWrites() {
        let mine = [digest(repo: "/Users/x/dev/Maw", branch: "agent/kimi/b2")]
        XCTAssertTrue(Review.worthWriting(merged: mine, previous: []))
    }

    func testRejectedReminderUsesPublishedDigestWithoutRepositoryScan() {
        var rejected = digest(repo: "/Users/x/dev/Maw", branch: "agent/kimi/b2")
        rejected.evidence = ["evidence/frame.png"]
        rejected.rejected = true
        var accepted = digest(repo: "/Users/x/dev/Maw", branch: "agent/kimi/c3")
        accepted.evidence = ["evidence/frame.png"]
        var noEvidence = digest(repo: "/Users/x/dev/Maw", branch: "agent/kimi/d4")
        noEvidence.rejected = true

        let got = Review.publishedRejectedWithEvidence([rejected, accepted, noEvidence])

        XCTAssertEqual(got.map(\.branch), ["agent/kimi/b2"])
    }

    // MARK: 每机一份：根治，而不是靠守卫挡

    /// **两台机器永远不会写同一个文件。**
    ///
    /// 守卫（`worthWriting`）只挡得住「一边空一边有」。两台**都有内容**时
    /// 它一点用没有 —— 整份推到同一路径，先推的那台的条目照样消失。
    ///
    /// 每机一份把这个可能性从根上去掉：路径里带机器 ID，
    /// 谁也盖不着谁，不需要合并、不需要锁。合并交给读的一方。
    func testEachMachineWritesItsOwnFile() {
        let a = Review.machineDigestURL(machineID: "AAAA-1111")
        let b = Review.machineDigestURL(machineID: "BBBB-2222")
        XCTAssertNotEqual(a, b,
                          "两台机器写同一个路径 = 又回到互相覆盖")
        XCTAssertEqual(a.lastPathComponent, "AAAA-1111.json")
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "reviews",
                       "目录名要和 MirrorService.perMachineDirs 里登记的对上，"
                       + "对不上就根本不会被搬到 iCloud")
    }

}
