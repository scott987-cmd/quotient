import XCTest
@testable import LLMQuotaCore

/// 丢弃过的上游，下游必须能走。
///
/// ## 这个 bug 的形状很特别：看得见，却永远不跑
///
/// 实况（2026-08-17）：Greed 两条图的上游步骤要做的事都已由人工合并落地，
/// 把上游丢弃之后，剩下两步真验收卡成了这个状态：
///
/// ```
/// llmq brief      → 在跑 0 · 排队 2 · 卡住 0
/// llmq work run   → 没有排队中的任务。
/// ```
///
/// **同一件事两套判据，而且互相矛盾。** `brief` 数的是 `state == .queued`，
/// 所以说排队 2；`readyQueue` 走的是 `isReady`，它要求上游
/// `state == .done`，而丢弃把状态置成 `.failed` —— 于是恒为假。
///
/// 这类 bug 最难查：没有任何报错，任务安安静静躺在队列里，
/// 界面显示一切正常。
///
/// 修的时候还有一个教训：**上一轮先修了冻结那条路**（`blocker` 判定认了
/// `discardedAt`），**漏了就绪这条路**。两处判据一分叉就出这种事，
/// 所以现在共用 `upstreamCleared`。
final class DiscardedUpstreamTests: XCTestCase {

    private func step(_ id: String, state: WorkTask.State,
                      dependsOn: [String] = [], discarded: Bool = false) -> WorkTask {
        var t = WorkTask(id: id, prompt: "步骤 \(id)", repo: "/tmp/x")
        t.state = state
        t.dependsOn = dependsOn
        t.graphID = "g1"
        if discarded { t.discardedAt = Date() }
        return t
    }

    /// **丢弃过的上游 → 下游就绪。** 这就是那两条验收任务该有的行为。
    func testDiscardedUpstreamUnblocksDownstream() {
        let up = step("s1", state: .failed, discarded: true)
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        XCTAssertTrue(TaskGraph.isReady(down, in: [up, down]),
                      "上游被明确处置过了，下游必须能走 —— "
                      + "否则它会永远躺在队列里，而且界面显示一切正常")
    }

    /// 真失败（没丢弃）的上游还是要挡住 —— 别把分类做成「什么都放行」。
    func testGenuinelyFailedUpstreamStillBlocks() {
        let up = step("s1", state: .failed)
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        XCTAssertFalse(TaskGraph.isReady(down, in: [up, down]),
                       "真失败的上游该挡着 —— 它要做的事没人做")
    }

    /// 还在跑的上游要挡住。
    func testRunningUpstreamBlocks() {
        let up = step("s1", state: .running)
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        XCTAssertFalse(TaskGraph.isReady(down, in: [up, down]))
    }

    /// 上游记录整个没了 → 不放行。
    ///
    /// 宁可卡住也不能瞎放：记录没了说明我们**不知道**它跑完没有，
    /// 而「不知道」不该被当成「可以了」。这种情况会在
    /// `llmq work stale` 里带原因列出来，不是静默卡住。
    func testMissingUpstreamRecordDoesNotUnblock() {
        let down = step("s2", state: .queued, dependsOn: ["ghost"])
        XCTAssertFalse(TaskGraph.isReady(down, in: [down]),
                       "不知道 ≠ 可以了")
    }

    /// **两处判据必须一致。**
    ///
    /// 就绪判定（isReady）和冻结判定（reconcile 的 blocker）现在共用
    /// upstreamCleared。这条测试盯的就是「别再分叉」——
    /// 分叉一次的代价是任务看得见却永远不跑，而且没有任何报错。
    func testReadinessAndFreezeAgreeOnDiscardedUpstream() {
        let up = step("s1", state: .failed, discarded: true)
        let down = step("s2", state: .queued, dependsOn: ["s1"])

        // 就绪侧：能走
        XCTAssertTrue(TaskGraph.isReady(down, in: [up, down]))

        // 冻结侧：不该把它冻住
        let touched = TaskGraph.reconcile([up, down])
        let frozen = touched.first { $0.id == "s2" && $0.state == .blocked }
        XCTAssertNil(frozen,
                     "冻结侧不能把一个就绪侧认为能走的任务冻住 —— "
                     + "两套判据打架的后果就是这次这个 bug")
    }

    /// **注入给 agent 的上下文里，丢弃的步骤也要算「已了结」。**
    ///
    /// 这是「为啥已经在了还重复执行」的更深一层，上一轮完全没看到：
    ///
    /// 一个步骤可能是被丢弃的，而丢弃的理由恰恰是「这活已经由别的路径
    /// 做完了」。那种步骤的改动**真实存在于仓库里**，只是记录被关掉了。
    /// 只认 `.done` 的话，下一步的 agent 会被告知「前面没有人做过任何改动」
    /// —— 于是它把已经有的东西重做一遍。
    ///
    /// 实测：Greed 的 3f68707cs5，兄弟步骤 s2/s3/s4（两个持久化开关、
    /// SettingsView、设置入口）全都已经在 main 上、全都被标成丢弃，
    /// 而它拿到的上下文是「你是第一步」。
    func testDiscardedSiblingsAppearAsSettledInAgentContext() {
        var s2 = step("s2", state: .failed, discarded: true)
        s2.stepTitle = "AudioManager 增加 BGM/SFX 两个持久化开关"
        s2.discardReason = "已由人工合入落地"
        var s3 = step("s3", state: .queued, dependsOn: ["s2"])
        s3.stepTitle = "实跑验收"

        let ctx = TaskGraph.briefing(for: s3, in: [s2, s3]) ?? ""
        XCTAssertFalse(ctx.contains("你是第一步"),
                       "前面有已了结的步骤，不能说「你是第一步」—— "
                       + "那等于让 agent 把已经有的东西重做一遍")
        XCTAssertTrue(ctx.contains("AudioManager"), "要把那一步列出来：\(ctx)")
        XCTAssertTrue(ctx.contains("已由人工合入落地"),
                      "要说清是怎么了结的 —— agent 得知道这活是别人做的")
        XCTAssertTrue(ctx.contains("不要重做"), "要明确禁止重做")
    }

    /// **这条测试盯的是一个模式，不是一个函数。**
    ///
    /// 今天六次「修得不彻底」里有三次同一个形状：**同一个概念在代码里有
    /// 多个判定点，只改了眼前那一个。**
    ///
    /// | 概念           | 改了                  | 漏了               |
    /// |----------------|-----------------------|--------------------|
    /// | 上游让开了吗   | reconcile 的 blocker  | isReady            |
    /// | 冻结说明       | 写入时机              | 已冻住的从不重写   |
    /// | 谁能参与排队   | autoland 的 guard     | 排队用的集合       |
    ///
    /// 所以「上游/兄弟步骤算不算了结」这个判断只准有**一个**实现。
    /// 这里把三个入口拿同一份数据比一遍 —— 谁再分叉，这条就红。
    func testAllSettledJudgementsAgree() {
        let up = step("s1", state: .failed, discarded: true)
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        let all = [up, down]

        // ① 就绪判定：能走
        XCTAssertTrue(TaskGraph.isReady(down, in: all))
        // ② 冻结判定：不冻它
        XCTAssertNil(TaskGraph.reconcile(all).first {
            $0.id == "s2" && $0.state == .blocked
        })
        // ③ 上下文判定：把它算成已了结
        let ctx = TaskGraph.briefing(for: down, in: all) ?? ""
        XCTAssertFalse(ctx.contains("你是第一步"),
                       "四个入口必须对「丢弃的上游算不算了结」给同一个答案")
    }

    /// **第四个入口：搁浅判定。**
    ///
    /// 这一条是被真实骚扰逼出来的。上一轮统一了前三个入口（isReady /
    /// reconcile 的 blocker / briefing），**漏了 stranded** —— 而它也有
    /// 自己一套「哪些步骤算挂了」。
    ///
    /// 后果不是静默，是反过来：**一直响**。老板的原话
    /// 「出问题了，一直发消息，而且是重复发」。Greed 两条图的失败步骤
    /// 全部是丢弃（2/2 和 3/3）、冻住的已清零，可 stranded 照旧判成搁浅，
    /// 于是「任务链卡住了」每两小时推一次，永远停不下来。
    ///
    /// 所以这条测试和上面那条是一对：一个盯「该走的不走」，
    /// 一个盯「该停的不停」。同一个概念分叉，两个方向都会出事。
    func testFullyDiscardedGraphIsNotStranded() {
        var s1 = step("g1s1", state: .done)
        s1.graphID = "g1"
        var s2 = step("g1s2", state: .failed, discarded: true)
        s2.graphID = "g1"
        s2.stepTitle = "已由人工落地"

        let strands = TaskGraph.stranded([s1, s2])
        XCTAssertTrue(strands.isEmpty,
                      "失败步骤全是丢弃 = 图已经处置完了，不是搁浅 —— "
                      + "判错的后果是每两小时骚扰一次，永远停不下来：\(strands)")
    }

    /// 但真挂了的图还是要报 —— 别把「不吵」做成「哑巴」。
    func testGenuinelyStrandedGraphIsStillReported() {
        var s1 = step("g2s1", state: .done)
        s1.graphID = "g2"
        var s2 = step("g2s2", state: .failed)   // 没丢弃 = 真挂了
        s2.graphID = "g2"

        XCTAssertFalse(TaskGraph.stranded([s1, s2]).isEmpty,
                       "真挂了的图必须报 —— 它已经不会自己好了")
    }

    /// **上游「done 但零产出」不放行下游。**
    ///
    /// 图里的步骤首尾相接：s2 的提示词写着「依据上一步产出的
    /// `reviews/privacy-api-audit.md`」。上一步零产出，那文件就不存在，
    /// s2 只能对着空气干活 —— 它也零产出，s3、s4 接着空跑。
    ///
    /// 实测（2026-08-18）：Greed 隐私清单那张图**四步全跑完、全零产出**，
    /// 烧掉 262 + 159 + 52 + 40 秒，一个文件都没产出，
    /// 而外面看起来每一步都是「完成」。
    func testZeroOutputUpstreamBlocksDownstream() {
        var up = step("s1", state: .done)
        up.changedFiles = 0
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        XCTAssertFalse(TaskGraph.isReady(down, in: [up, down]),
                       "上游一个文件都没产出，下游只能对着空气干活")
    }

    /// 有产出就放行 —— 别把闸做成「什么都不许过」。
    func testUpstreamWithOutputUnblocks() {
        var up = step("s1", state: .done)
        up.changedFiles = 3
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        XCTAssertTrue(TaskGraph.isReady(down, in: [up, down]))
    }

    /// **`nil` 不等于 `0`。**
    ///
    /// nil 是「没记录过」（老任务、执行器没回报），0 是「真的没改」。
    /// 拿 nil 当 0 会把所有历史任务判成断点 ——
    /// 宁可放过不知道的，也不能把「不知道」当成「没干」。
    func testUnrecordedChangeCountIsNotTreatedAsZero() {
        let up = step("s1", state: .done)      // changedFiles 没设 = nil
        let down = step("s2", state: .queued, dependsOn: ["s1"])
        XCTAssertTrue(TaskGraph.isReady(down, in: [up, down]),
                      "没记录过改动数的上游不该被当成零产出")
    }

    /// 多个上游里只要有一个没让开，就还是不能走。
    func testAllUpstreamsMustClear() {
        let a = step("s1", state: .failed, discarded: true)
        let b = step("s2", state: .running)
        let down = step("s3", state: .queued, dependsOn: ["s1", "s2"])
        XCTAssertFalse(TaskGraph.isReady(down, in: [a, b, down]),
                       "一个丢弃了、一个还在跑 —— 不能走")
    }
}
