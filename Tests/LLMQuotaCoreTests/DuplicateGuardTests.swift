import XCTest
@testable import LLMQuotaCore

/// 入队查重。
///
/// 这组用例的第一条用的是**今晚真实发生的那两条提示词** ——
/// 它们各自跑到 done，改了同样四个文件，两份额度。
/// 造的数据证明不了这个功能有用，只有真数据能。
final class DuplicateGuardTests: XCTestCase {

    /// 今晚 b6aa5e7f 的提示词，一字未改。
    private let realA = """
        为 LLMQuotaCore 里已有的 WasteMeter 增加一个命令行入口 llmq waste：第一步，\
        在 Sources/llmq/main.swift 里新增 case "waste"，读取 SnapshotStore.loadAll() \
        和 PlansStore.load()，对每个已探测到的平台合并各机器的用量桶，\
        调用 WasteMeter.measureAll（窗口长度取该平台 plan.limits 里的 windowMinutes，\
        起点取所有快照 retentionStart 的最小值），逐行打印 WasteMeter.sentence 的结果，\
        并把命令加进顶层用法说明。
        """

    /// 今晚 42266d0fs1 的提示词，一字未改。
    private let realB = """
        在 LLMQuotaCore 仓库里为已有的 WasteMeter 增加命令行入口 llmq waste。

        改哪里：Sources/llmq/main.swift。

        做什么：
        1. 先读代码摸清三个类型的真实接口，不要凭猜写：WasteMeter（重点是 measureAll \
        的参数签名和返回值、sentence 的入参）、SnapshotStore.loadAll()、PlansStore.load()。
        """

    private func task(_ id: String, _ prompt: String, state: WorkTask.State = .running,
                      repo: String = "/repo", endedAgo: TimeInterval? = nil) -> WorkTask {
        var t = WorkTask(id: id, prompt: prompt, repo: repo)
        t.state = state
        if let ago = endedAgo { t.endedAt = Date().addingTimeInterval(-ago) }
        return t
    }

    // MARK: - 真实案例

    /// **今晚那两条必须被判成重复。** 这是这个功能唯一的存在理由。
    func testTheRealDuplicatePairIsCaught() {
        let m = DuplicateGuard.matches(
            prompt: realB, repo: "/repo", in: [task("b6aa5e7f", realA)])
        XCTAssertEqual(m.count, 1, "今晚真实重复的那两条没被认出来")
        XCTAssertGreaterThanOrEqual(m[0].sharedSymbols.count, 2,
                                    "共同标识符：\(m[0].sharedSymbols)")
        // 证据要具体到能让人一眼认出是同一件事。
        XCTAssertTrue(m[0].sharedSymbols.contains("WasteMeter"), "\(m[0].sharedSymbols)")
        XCTAssertTrue(m[0].sharedSymbols.contains("Sources/llmq/main.swift"),
                      "\(m[0].sharedSymbols)")
        // 给人看的那句话要以**最具体的证据**开头 —— 文件路径。
        // 不能是「都动 LLMQuotaCore」那种：仓库名几乎每条提示词都有，等于没说。
        XCTAssertTrue(m[0].why.hasPrefix("都动 Sources/llmq/main.swift"),
                      "证据要先说最具体的：\(m[0].why)")
        XCTAssertFalse(m[0].why.hasPrefix("都动 LLMQuotaCore"),
                       "仓库名没有区分度，不该当成主要证据")
    }

    // MARK: - 不该误报

    /// 同一个仓库里两件**不相干**的活，不能判成重复。
    ///
    /// 误报比漏报更让人烦：它拦住的是真活，而且人会开始无视这个提示。
    func testUnrelatedTasksInSameRepoAreNotFlagged() {
        let other = "把 README 里的安装步骤按 macOS 26 更新一遍，顺便改掉过时的截图说明。"
        let m = DuplicateGuard.matches(
            prompt: other, repo: "/repo", in: [task("x", realA)])
        XCTAssertTrue(m.isEmpty, "误报了：\(m.map(\.why))")
    }

    /// **只提到同一个文件不算重复。** 这个仓库里什么活都可能碰 main.swift。
    func testOneSharedFileIsNotEnough() {
        let a = "在 Sources/llmq/main.swift 里给 doctor 增加一条磁盘检查。"
        let b = "在 Sources/llmq/main.swift 里把 report 的输出改成表格。"
        let m = DuplicateGuard.matches(prompt: a, repo: "/repo", in: [task("x", b)])
        XCTAssertTrue(m.isEmpty, "只共用一个文件就报重复会把人烦死：\(m.map(\.why))")
    }

    /// 不同仓库不比。
    func testDifferentRepoIsNeverADuplicate() {
        let m = DuplicateGuard.matches(
            prompt: realB, repo: "/repo-a", in: [task("x", realA, repo: "/repo-b")])
        XCTAssertTrue(m.isEmpty)
    }

    // MARK: - 范围

    /// 正在跑的、排队的、卡住的都要比。
    func testLiveStatesAreCompared() {
        for st in [WorkTask.State.queued, .running, .blocked] {
            let m = DuplicateGuard.matches(
                prompt: realB, repo: "/repo", in: [task("x", realA, state: st)])
            XCTAssertEqual(m.count, 1, "\(st) 状态的任务也该参与查重")
        }
    }

    /// 太久以前做完的不算 —— 那时候该做第二遍了。
    func testOldDoneTaskIsNotADuplicate() {
        let old = task("x", realA, state: .done, endedAgo: 30 * 86400)
        XCTAssertTrue(DuplicateGuard.matches(prompt: realB, repo: "/repo", in: [old]).isEmpty)

        let fresh = task("y", realA, state: .done, endedAgo: 3600)
        XCTAssertEqual(DuplicateGuard.matches(prompt: realB, repo: "/repo", in: [fresh]).count, 1,
                       "一小时前刚做完的必须拦")
    }

    /// **失败过的不算重复** —— 那正说明这活还没人干成。
    func testFailedTaskIsNotADuplicate() {
        let f = task("x", realA, state: .failed)
        XCTAssertTrue(DuplicateGuard.matches(prompt: realB, repo: "/repo", in: [f]).isEmpty,
                      "失败的任务不该拦住重做 —— 那等于永久放弃这件事")
    }

    /// **被你否决过的也不算** —— 丢弃恰恰意味着「换个做法再来」。
    func testDiscardedTaskIsNotADuplicate() {
        var d = task("x", realA, state: .done, endedAgo: 3600)
        d.discardedAt = Date()
        XCTAssertTrue(DuplicateGuard.matches(prompt: realB, repo: "/repo", in: [d]).isEmpty)
    }

    /// 自己不跟自己比（重排、重试时会把自己也传进来）。
    func testExcludesItself() {
        let m = DuplicateGuard.matches(
            prompt: realA, repo: "/repo", excluding: "me", in: [task("me", realA)])
        XCTAssertTrue(m.isEmpty)
    }

    /// 正在跑的排在做完的前面 —— 那是「现在就在烧额度」。
    func testLiveMatchesRankFirst() {
        let m = DuplicateGuard.matches(prompt: realB, repo: "/repo", in: [
            task("done1", realA, state: .done, endedAgo: 3600),
            task("live1", realA, state: .running),
        ])
        XCTAssertEqual(m.first?.taskID, "live1", "还在烧额度的那条要排最前")
    }

    // MARK: - 分词

    /// 中文按字符二元组切 —— 按空格切的话两段中文永远零重合。
    func testChineseTokenization() {
        let t = DuplicateGuard.tokens(in: "增加命令行入口")
        XCTAssertTrue(t.contains("增加"), "\(t)")
        XCTAssertTrue(t.contains("命令"), "\(t)")
        XCTAssertGreaterThan(
            DuplicateGuard.jaccard(
                DuplicateGuard.tokens(in: "给这个平台补一条命令行入口"),
                DuplicateGuard.tokens(in: "给这个平台补一个命令行入口")),
            0.5, "只差一个字的两句话相似度不该低")
    }

    /// 普通英文单词和单个大写词**不**当标识符，否则满屏误报。
    func testOnlyDistinctiveSymbolsAreExtracted() {
        let s = DuplicateGuard.symbols(in: "更新 README 里的 install 步骤，参考 Sources 目录")
        XCTAssertFalse(s.contains("README"), "\(s)")
        XCTAssertFalse(s.contains("install"), "\(s)")
        XCTAssertFalse(s.contains("Sources"), "\(s)")
    }

    /// 类型名要能从 `A.b()` 里剥出来，这样「同一个类型不同方法」也对得上。
    func testTypeNameExtractedFromMemberAccess() {
        let s = DuplicateGuard.symbols(in: "调用 SnapshotStore.loadAll() 之后再 PlansStore.load()")
        XCTAssertTrue(s.contains("SnapshotStore"), "\(s)")
        XCTAssertTrue(s.contains("PlansStore"), "\(s)")
    }

    /// 绝对路径和相对路径要能对上。
    func testPathsNormalize() {
        let a = DuplicateGuard.symbols(in: "改 /Users/x/dev/repo/Sources/llmq/main.swift")
        let b = DuplicateGuard.symbols(in: "改 Sources/llmq/main.swift")
        XCTAssertFalse(a.intersection(b).isEmpty, "\(a) vs \(b)")
    }

    /// `llmq waste` 这种子命令算标识符，单独一个 llmq 不算。
    func testSubcommandIsASymbol() {
        let s = DuplicateGuard.symbols(in: "给 llmq waste 补文档")
        XCTAssertTrue(s.contains("llmq waste"), "\(s)")
        XCTAssertFalse(s.contains("llmq"), "\(s)")
    }
}
