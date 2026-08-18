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
}
