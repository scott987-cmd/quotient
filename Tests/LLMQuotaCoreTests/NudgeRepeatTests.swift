import XCTest
@testable import LLMQuotaCore

/// 通知：**变了才响。**
///
/// 老板的原话（2026-08-17）：「出问题了，一直发消息，而且是重复发」。
///
/// 实测 `nudges.json`：`stranded-graph` 一条消息发了 8 次，
/// 最近四次是 08:02 / 10:04 / 12:08 / 14:30 / 16:31 —— 每两小时一次，
/// 内容完全相同。
///
/// 两个独立的病，两条都得治：
///
/// 1. **内容是错的**：那两条图的失败步骤全是「已丢弃」，图早就处置完了，
///    而 `TaskGraph.stranded` 把丢弃算成失败 → 永远判成搁浅。
///    （修在 TaskGraph，测试在 DiscardedUpstreamTests。）
/// 2. **重复本身是病**：`quietFor` 只管「同类别 2 小时内别刷屏」，
///    它隐含假设「过了 2 小时情况就变了」。在一个人还没处理的待办上，
///    这个假设是错的 —— 内容一字不差的提醒每 2 小时来一次，就是骚扰。
final class NudgeRepeatTests: XCTestCase {

    private let key = "stranded-graph"
    private let body = "一条任务链卡住了，已完成 4 步的产出还没落地"

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nudge-repeat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root
        try? FileManager.default.removeItem(at: Nudge.path)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: Nudge.path)
        Paths.appSupportOverride = nil
        super.tearDown()
    }

    /// **内容没变，过了刷屏窗口也不该再响。**
    func testSameBodyDoesNotRepeatAfterQuietWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        Nudge.remember(key, body: body, now: t0)

        // 刚过 2 小时的刷屏窗口
        let t1 = t0.addingTimeInterval(Nudge.quietFor + 60)
        XCTAssertTrue(Nudge.recentlySent(key, body: body, now: t1),
                      "内容一字不差就不该再响 —— 这正是实测那 8 次重复")
    }

    /// **内容变了要响**，哪怕刚过刷屏窗口。
    ///
    /// 不能为了不吵就把新情况一起吞掉 —— 那是从「太吵」滑到「聋了」。
    func testChangedBodyDoesFire() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        Nudge.remember(key, body: body, now: t0)

        let t1 = t0.addingTimeInterval(Nudge.quietFor + 60)
        XCTAssertFalse(
            Nudge.recentlySent(key, body: "两条任务链卡住了", now: t1),
            "内容变了说明情况变了，必须响")
    }

    /// 刷屏窗口内，内容变了也不响 —— 两条闸是**与**的关系。
    func testQuietWindowStillCapsBurst() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        Nudge.remember(key, body: body, now: t0)
        let t1 = t0.addingTimeInterval(60)
        XCTAssertTrue(Nudge.recentlySent(key, body: "换了个说法", now: t1),
                      "2 小时内不管内容变没变都不该刷屏")
    }

    /// **一天之后同样的内容可以再提一次。**
    ///
    /// 「变了才响」不能变成「永远不响」：一个持续存在的问题，
    /// 一天提一次是提醒，不是骚扰。
    func testSameBodyFiresAgainAfterADay() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        Nudge.remember(key, body: body, now: t0)
        let t1 = t0.addingTimeInterval(Nudge.repeatSameAfter + 60)
        XCTAssertFalse(Nudge.recentlySent(key, body: body, now: t1),
                       "一天之后该再提一次 —— 别让持续存在的问题被彻底忘掉")
    }

    /// 历史里没记正文（老记录）时，行为退回只用刷屏闸。
    ///
    /// 缺数据不该让它变得更吵，也不该让它彻底哑掉。
    func testMissingBodyInHistoryFallsBackToQuietWindowOnly() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        Nudge.remember(key, body: nil, now: t0)      // 老记录：没正文
        let t1 = t0.addingTimeInterval(Nudge.quietFor + 60)
        XCTAssertFalse(Nudge.recentlySent(key, body: body, now: t1),
                       "历史里没正文可比 → 只走刷屏闸，行为和以前一致")
    }

    /// 保留窗口要比内容比对窗口长。
    ///
    /// 只留 24 小时的话，边界上那条刚好被清掉 ——
    /// 于是「没变化」判不出来，又响一次。这种差一点的错最难查。
    func testHistoryIsKeptLongerThanTheComparisonWindow() {
        XCTAssertGreaterThan(48 * 3600.0, Nudge.repeatSameAfter,
                             "保留期必须严格长于比对窗口，否则边界上会漏判")
    }
}
