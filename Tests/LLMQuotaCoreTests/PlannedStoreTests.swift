import XCTest
@testable import LLMQuotaCore

/// 计划清单：人排的、由人放行的任务。
final class PlannedStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PlannedStore.fileOverride = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planned-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let f = PlannedStore.fileOverride { try? FileManager.default.removeItem(at: f) }
        PlannedStore.fileOverride = nil
        super.tearDown()
    }

    /// **顺序就是承诺。** 这个清单存在的理由就是「按我排的顺序来」。
    func testOrderIsPreserved() throws {
        try PlannedStore.add(prompt: "第一件", repoAlias: "maw")
        try PlannedStore.add(prompt: "第二件", repoAlias: nil)
        try PlannedStore.add(prompt: "插队的", repoAlias: "maw", first: true)

        XCTAssertEqual(PlannedStore.all().map(\.prompt), ["插队的", "第一件", "第二件"])
    }

    func testRemoveByPosition() throws {
        try PlannedStore.add(prompt: "a", repoAlias: nil)
        try PlannedStore.add(prompt: "b", repoAlias: nil)
        let removed = try PlannedStore.remove(at: 1)
        XCTAssertEqual(removed?.prompt, "a")
        XCTAssertEqual(PlannedStore.all().map(\.prompt), ["b"])

        XCTAssertNil(try PlannedStore.remove(at: 9), "越界要返回 nil，不能崩也不能误删")
        XCTAssertEqual(PlannedStore.all().count, 1)
    }

    func testMoveUpAndDown() throws {
        try PlannedStore.add(prompt: "a", repoAlias: nil)
        try PlannedStore.add(prompt: "b", repoAlias: nil)
        try PlannedStore.move(position: 2, up: true)
        XCTAssertEqual(PlannedStore.all().map(\.prompt), ["b", "a"])
        // 第 1 条再上移不是错误，是没事可做。
        try PlannedStore.move(position: 1, up: true)
        XCTAssertEqual(PlannedStore.all().map(\.prompt), ["b", "a"])
    }

    /// 老文件缺键不能让整个清单读不出来 —— keyNotFound 在这个项目里翻过五次车。
    func testDecodesWithMissingKeys() throws {
        let json = #"[{"prompt":"只有提示词"},{"id":"x","prompt":"带 id"}]"#
        try Data(json.utf8).write(to: PlannedStore.fileOverride!)
        let list = PlannedStore.all()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].prompt, "只有提示词")
        XCTAssertFalse(list[0].id.isEmpty, "缺 id 要补一个，不能空着")
    }

    /// 空 prompt 的行不进清单 —— 那是半截写入的残骸，放行它等于派一个空任务。
    func testEmptyPromptsAreDropped() throws {
        let json = #"[{"prompt":""},{"prompt":"真的"}]"#
        try Data(json.utf8).write(to: PlannedStore.fileOverride!)
        XCTAssertEqual(PlannedStore.all().map(\.prompt), ["真的"])
    }
}
