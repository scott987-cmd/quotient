import XCTest
@testable import LLMQuotaCore

/// **各仓库的计划要在手机上看得见。**
///
/// 老板 2026-08-23:「flint 的后续计划应该在手机端计划清单展示吧,
/// 不然你留他的作用是什么」。PLAN.md 之前只有系统自己(续活)读,
/// 老板看不到,只能反复问「FPS 还在做吗」。
final class RoadmapPageTests: XCTestCase {
    func testExcerptDropsTableNoiseKeepsContent() {
        let plan = """
        # 燧石行动计划

        | 阶段 | 内容 |
        |---|---|
        | P1 | 灰盒核心 |

        当前阶段：打磨移动端
        """
        let e = RoadmapPage.excerpt(plan)
        XCTAssertTrue(e.contains("燧石行动计划"))
        XCTAssertTrue(e.contains("当前阶段"))
        XCTAssertFalse(e.contains("灰盒核心"), "表格正文在手机摘要里也是噪声")
        XCTAssertFalse(e.contains("|---|"), "表格分隔行对人没意义,该滤掉")
    }

    func testCardShowsProgressAndPlan() {
        let repos = [RoadmapPage.Repo(
            alias: "flint", goalExcerpt: "# 燧石行动\nP3 内容",
            recentLandings: ["merge 皮肤", "merge 僵尸"], openCount: 3)]
        let p = RoadmapPage.page(repos: repos)
        let card = p.sections.flatMap { $0.cards ?? [] }.first
        XCTAssertEqual(card?.title, "在做 3 项", "队列有活要显示在做几项")
        XCTAssertTrue((card?.body ?? "").contains("皮肤"), "要能看到最近做成了什么")
        XCTAssertTrue((card?.detail ?? "").contains("P3"), "点开能看到计划本身")
    }

    /// 没有 PLAN.md 的仓库不列,空状态给一句话而不是白屏。
    func testEmptyStateIsHelpful() {
        let p = RoadmapPage.page(repos: [])
        XCTAssertEqual(p.page, "roadmap")
        XCTAssertTrue((p.sections.first?.text ?? "").contains("PLAN.md"),
                      "空的时候要告诉人怎么让它有内容")
    }

    func testDynamicMenuOnlyContainsReadOnlyExtensions() {
        let pages = ViewFeed.menu().entries.map(\.page)
        XCTAssertEqual(pages, ["roadmap", "collaboration"])
        XCTAssertFalse(pages.contains("review"))
        XCTAssertFalse(pages.contains("blocked"))
        XCTAssertFalse(pages.contains("playbook"))
    }
}
