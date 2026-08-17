import XCTest
@testable import LLMQuotaCore

/// 仓库级独占。
///
/// 这是架构级取舍，背景见 `RepoLease` 的文档注释：238 个任务的盘点显示，
/// 未派任务的 28 个丢弃是同一个根因 —— 任务被当成对共享代码库的独立并行
/// 单元，而它们共享文件、共享基线，基线还在移动。
///
/// 这个文件守的是两条**错了就形同虚设**的性质：同一轮内互斥、路径归一。
final class RepoLeaseTests: XCTestCase {

    private func task(_ id: String, repo: String,
                      state: WorkTask.State = .queued,
                      platform: Platform? = nil) -> WorkTask {
        var t = WorkTask(id: id, prompt: "活 \(id)", repo: repo)
        t.state = state
        t.platform = platform
        return t
    }

    /// 有人在改的仓库，新任务要让开。
    func testTaskWaitsWhenRepoIsBusy() {
        let running = task("r1", repo: "/dev/Maw", state: .running, platform: .kimi)
        let queued = task("q1", repo: "/dev/Maw")
        let (allowed, deferred) = RepoLease.filter([queued], tasks: [running, queued])
        XCTAssertTrue(allowed.isEmpty, "同一个仓库不能同时两个 agent 在改")
        XCTAssertEqual(deferred.count, 1)
        XCTAssertTrue(deferred[0].1.contains("Kimi") || deferred[0].1.contains("kimi"),
                      "说明里要点出是谁在改，否则人看不出为什么在等：\(deferred[0].1)")
    }

    /// 别的仓库照旧放行 —— 并行度就是从这儿来的。
    func testOtherReposRunInParallel() {
        let running = task("r1", repo: "/dev/Maw", state: .running, platform: .kimi)
        let q1 = task("q1", repo: "/dev/Greed")
        let q2 = task("q2", repo: "/dev/LLMQuotaBar")
        let (allowed, _) = RepoLease.filter([q1, q2], tasks: [running, q1, q2])
        XCTAssertEqual(allowed.count, 2, "跨仓库是白拿的并行，不该被挡")
    }

    /// **同一轮里也必须互斥。**
    ///
    /// 一轮可能连派好几个任务。只看已有的 running 的话，同一个仓库的两个
    /// 任务会在同一轮双双派出去 —— 独占就白做了，而且这种漏法最难发现：
    /// 单看代码「有 running 就让开」是对的，漏的是「本轮刚放行的还不是 running」。
    func testTwoTasksForSameRepoDoNotBothPassInOneRound() {
        let a = task("a", repo: "/dev/Maw")
        let b = task("b", repo: "/dev/Maw")
        let (allowed, deferred) = RepoLease.filter([a, b], tasks: [a, b])
        XCTAssertEqual(allowed.count, 1, "同一轮同一个仓库只能放行一个")
        XCTAssertEqual(allowed.first?.id, "a", "先来的先走")
        XCTAssertEqual(deferred.count, 1)
    }

    /// **路径写法不同不能各拿一把锁。**
    ///
    /// `~/dev/Maw` 和 `/Users/x/dev/Maw` 和末尾带斜杠的是同一个仓库。
    /// 不归一的后果是独占形同虚设 —— 换个写法就能绕过去，
    /// 而且绕过去的时候没有任何报错。
    func testPathFormsAreNormalized() {
        let home = NSString(string: "~").expandingTildeInPath
        let running = task("r1", repo: "~/dev/Maw", state: .running, platform: .kimi)
        let queued = task("q1", repo: home + "/dev/Maw/")
        let (allowed, _) = RepoLease.filter([queued], tasks: [running, queued])
        XCTAssertTrue(allowed.isEmpty,
                      "同一个仓库的两种写法必须算同一把锁")
    }

    /// 队列空 / 没人在跑的时候不该乱挡。
    func testIdleRepoIsFree() {
        let q = task("q1", repo: "/dev/Maw")
        let (allowed, deferred) = RepoLease.filter([q], tasks: [q])
        XCTAssertEqual(allowed.count, 1)
        XCTAssertTrue(deferred.isEmpty)
    }

    /// **媒体任务不开例外。**
    ///
    /// 「改新资源不会撞代码」这个直觉是错的：Greed 的媒体任务在
    /// `Assets.xcassets` 上撞了 add/add（两个 agent 各生成一套同名资源）。
    /// 开了例外就是把已经踩过的坑重新挖开。
    func testMediaTasksGetNoExemption() {
        let running = task("r1", repo: "/dev/Greed", state: .running, platform: .kimi)
        var media = task("m1", repo: "/dev/Greed")
        media.prompt = "【媒体】生成 4 张遗物图标"
        let (allowed, _) = RepoLease.filter([media], tasks: [running, media])
        XCTAssertTrue(allowed.isEmpty,
                      "媒体任务也会撞 —— Assets.xcassets 上实测撞过 add/add")
    }
}
