import XCTest
@testable import LLMQuotaCore

/// **续活由系统选块、标题写明 —— 不让 agent 猜,也让老板一眼看出在干哪块。**
/// 老板 2026-08-23:「续活任务也不知道在干啥」。
final class MainlinePickTests: XCTestCase {
    let plan = """
    # 燧石行动

    ## ⭐ 续活主线（自动续活严格按这个顺序挑下一块）

    > 老板原话……

    **当前主线：人物和僵尸。**

    1. 【人物·皮肤】人物有真皮肤。
       — 已完成
    2. 【人物·头发】头发+眉毛+睫毛。 — 已完成
    3. 【人物·装备第二版】四干员穿上完整作战服。
       验收：四人剪影一眼可辨。
    4. 【僵尸·八款差异】八款僵尸。

    做完 7 再回来找我。

    ## 阶段与分工
    | 阶段 | 内容 |
    """

    func testPicksFirstUnfinishedAndMergesContinuationLines() {
        let it = AutoRefill.nextMainlineItem(in: plan)
        XCTAssertEqual(it?.index, 3, "前两块标了已完成,该挑第 3 块")
        XCTAssertTrue(it?.text.contains("装备第二版") == true)
        XCTAssertTrue(it?.text.contains("剪影一眼可辨") == true, "续行要并进同一块,验收标准不能丢")
    }

    func testAllDoneMeansNothingToDo() {
        let done = plan.replacingOccurrences(of: "3. 【人物·装备第二版】", with: "3. 【人物·装备第二版】已完成 ")
                       .replacingOccurrences(of: "4. 【僵尸·八款差异】", with: "4. 【僵尸·八款差异】已完成 ")
        XCTAssertNil(AutoRefill.nextMainlineItem(in: done), "全完成就该停下等老板给下一段,不能瞎续")
    }

    func testNoMainlineSectionMeansNothing() {
        XCTAssertNil(AutoRefill.nextMainlineItem(in: "# 只有阶段表\n| P1 | 灰盒 |"),
                     "没有主线一节绝不自己猜活 —— 那正是「瞎续活」")
    }

    func testPromptNamesTheBlock() {
        let it = AutoRefill.MainlineItem(index: 3, text: "【人物·装备第二版】四干员穿上完整作战服")
        let p = AutoRefill.prompt(repoName: "flint", goal: plan, item: it)
        XCTAssertTrue(p.hasPrefix("【续活·主线 3】"), "标题第一行就写明在干第几块")
        XCTAssertTrue(p.contains("— 已完成"), "要告诉它做完把 PLAN.md 标上,系统靠这个进下一块")
    }
}
