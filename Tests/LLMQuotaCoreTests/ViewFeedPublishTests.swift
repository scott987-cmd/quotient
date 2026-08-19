import XCTest
@testable import LLMQuotaCore

/// 手机页面：**空页面不许盖掉有内容的页面。**
///
/// ## 这条对应的真实故障
///
/// 老板的原话（2026-08-19）：「弹消息有两份待验收，但是点击去验收的
/// 页面又没有，过了好几分钟才加载出来」。
///
/// `views/` 在 MirrorService 里归在「只推不拉」：每台机器整份推到
/// iCloud 同一个路径，后推的盖先推的。而**每台机器看得见的东西不一样**：
///
/// - Mac mini 有 Greed / Maw，生成的待审页 6032 字节、3 张卡；
/// - **MacBook 上根本没有这两个目录**，它生成的同一页只有 268 字节、
///   一张卡都没有 —— 推上去就把上面那份盖掉了。
///
/// 人收到的是 Mac mini 发的推送，点开看到的是 MacBook 盖出来的空页。
/// 「过几分钟又出来了」是 Mac mini 下一轮把它写回去。
///
/// ## 这是同一个病的第二次犯
///
/// 上一轮已经给 `reviews.json` 加了同样的守卫（`Review.worthWriting`），
/// 但**手机真正读的是 `views/review.json`** —— 只堵了内部文件，
/// 没堵手机真正读的那个，于是同一个形状换个位置继续犯。
final class ViewFeedPublishTests: XCTestCase {

    private func card(_ id: String) -> ViewFeed.Card {
        ViewFeed.Card(id: id, title: "待审 \(id)")
    }

    /// 有卡片的页面。
    private func page(cards: Int) -> ViewFeed.Page {
        ViewFeed.Page(page: "review", sections: [
            // banner 是框架，空页面上照样有 —— 它不该被算成内容
            ViewFeed.Section(kind: "banner", title: "待验收"),
            ViewFeed.Section(kind: "cards", title: "greed",
                             cards: (0..<cards).map { card("c\($0)") }),
        ])
    }

    /// 一张卡都没有、只剩框架的页面 —— MacBook 生成的就是这个。
    private func emptyPage() -> ViewFeed.Page {
        ViewFeed.Page(page: "review", sections: [
            ViewFeed.Section(kind: "banner", title: "待验收"),
            ViewFeed.Section(kind: "cards", title: "greed", cards: []),
        ])
    }

    /// **框架不算内容。**
    ///
    /// 这一条盯的是判据本身：拿字节数或 section 数判「有没有内容」
    /// 会被 banner 骗过去 —— 实测那份一张卡都没有的页面
    /// 仍有 2 个 section、6032 字节。
    func testFrameworkSectionsAreNotContent() {
        XCTAssertEqual(ViewFeed.contentCount(emptyPage()), 0,
                       "只有 banner 和空卡片组 —— 内容是 0，别被 section 数骗了")
        XCTAssertEqual(ViewFeed.contentCount(page(cards: 3)), 3)
    }

    /// **看不见任何仓库的机器，不许把有内容的页面盖成空。**
    ///
    /// 这是故障的正面：MacBook 自己上一份也是空的，
    /// 说明它从来就没有内容可发 —— 它这一次也不该发。
    func testEmptyPageFromBlindMachineIsNotPublished() {
        XCTAssertFalse(
            ViewFeed.worthPublishing(emptyPage(), over: emptyPage()),
            "自己没内容、自己上一份也没内容 —— 发出去只可能盖掉别人的")
    }

    /// **但别把「不发」做成「永远不发」。**
    ///
    /// 本机确实清掉了最后一条时必须发得出去，
    /// 否则已经合掉的分支会永远挂在手机上 —— 那是反方向的同一种病。
    func testClearingOwnLastCardStillPublishes() {
        XCTAssertTrue(
            ViewFeed.worthPublishing(emptyPage(), over: page(cards: 2)),
            "自己上一份有 2 张卡、这次清空了 —— 这是真的清空，必须发")
    }

    /// 有内容当然要发。
    func testPageWithContentAlwaysPublishes() {
        XCTAssertTrue(ViewFeed.worthPublishing(page(cards: 1), over: emptyPage()))
        XCTAssertTrue(ViewFeed.worthPublishing(page(cards: 1), over: page(cards: 5)))
    }

    /// 还没有过这一页时要建立初始页面 —— 否则手机上一直是「页面不存在」。
    func testFirstEverPublishGoesThrough() {
        XCTAssertTrue(ViewFeed.worthPublishing(emptyPage(), over: nil),
                      "第一次发布要把页面建起来，哪怕它是空的")
    }
}
