import XCTest
@testable import LLMQuotaCore

/// **否决记的是「哪个提交没过验收」，不是「哪条分支坏了」。**
///
/// ## 这条对应的真实洞（2026-08-20）
///
/// 审核结论那层当天刚改成绑提交（见 `VerdictScopeTests`），修的是
/// 「被否 → 改好 → 重新判」这条闭环。但否决名单 `autoLandVeto` 还绑着
/// 分支名 —— 验收失败一次，之后不管推多少修复提交，走到落地那步都被
/// 旧否决按名字扣住，唯一出路仍是人工清单子。
///
/// **同一个洞的两层，只修一层等于没修。** 这不是修 bug 顺手多改一处，
/// 是同一条闭环上的串联闸门 —— 全通才算通。
final class AutoLandVetoScopeTests: XCTestCase {

    func testVetoBlocksTheCommitThatFailed() {
        let m = ["agent/a/x": Review.VetoEntry(note: "验收失败：测试红了",
                                               head: "aaa1111", at: nil)]
        XCTAssertNotNil(Review.activeVeto(m, branch: "agent/a/x", head: "aaa1111"),
                        "被否的那个提交原样再来，当然还是否")
    }

    func testVetoExpiresWhenBranchMovesOn() {
        let m = ["agent/a/x": Review.VetoEntry(note: "验收失败：测试红了",
                                               head: "aaa1111", at: nil)]
        XCTAssertNil(Review.activeVeto(m, branch: "agent/a/x", head: "bbb2222"),
                     "否决是给那一版提交的；改好重新提交要能重进验收 —— "
                     + "否则唯一出路是人工绕过，正是这套机制要防的事")
    }

    /// 老格式没记提交 —— 粘性，维持旧行为。
    /// 升级本身不该放行一批没验过的分支。
    func testLegacyEntryStaysSticky() {
        let m = ["agent/a/x": Review.VetoEntry(note: "老数据", head: "", at: nil)]
        XCTAssertNotNil(Review.activeVeto(m, branch: "agent/a/x", head: "ccc3333"))
    }

    /// 从机上可能还留着老格式文件（值是纯文字）。读得回来，且按粘性处理。
    func testOldFormatFileDecodesToStickyEntries() throws {
        let d = try JSONEncoder().encode(["agent/a/x": "上次验收没过"])
        let m = Review.decodeVetoes(d)
        XCTAssertEqual(m["agent/a/x"]?.note, "上次验收没过")
        XCTAssertEqual(m["agent/a/x"]?.head, "",
                       "老格式不知道是哪个提交 —— head 必须是空串（粘性），"
                       + "不能瞎填一个")
    }

    func testNewFormatRoundTrips() throws {
        let entry = Review.VetoEntry(note: "n", head: "abc1234", at: Date())
        let d = try JSONEncoder().encode(["b": entry])
        XCTAssertEqual(Review.decodeVetoes(d)["b"]?.head, "abc1234")
    }
}
