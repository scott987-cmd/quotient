import XCTest
@testable import LLMQuotaCore

/// 找我们自己留在 iCloud 上的半成品。
///
/// 一天之内攒了 166 个、21MB，散在六种名字下（快照 57、看板 50、
/// 仓库清单 45、办公室 8、任务回执 5、冷却 1）。我第一次统计只数了
/// 看板那一种，报出来的数字差了一个数量级 ——
/// **所以这里的用例专门盯「有没有扫全」，而不只是「能不能找到」。**
final class DebrisTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("debris-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func touch(_ rel: String, bytes: Int = 10) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// **子目录里的也要算。** 真实事故里 57 个（最多的一类）在 `snapshots/` 下面，
    /// 只扫顶层会漏掉三分之一。
    func testFindsDebrisInSubdirectories() {
        touch("dashboard.json")                       // 真文件
        touch("dashboard.json.sb-aaa")
        touch("snapshots/C15DF1AA.json")              // 真文件
        touch("snapshots/C15DF1AA.json.sb-bbb")
        touch("snapshots/C15DF1AA.json.sb-ccc")
        touch("outbox/task.json.sb-ddd")

        let r = Debris.scan(root: root)
        XCTAssertEqual(r.files.count, 4, "顶层 1 + snapshots 2 + outbox 1，实际扫到 "
            + r.files.map(\.lastPathComponent).joined(separator: ", "))
        XCTAssertFalse(r.incomplete)
    }

    /// 真文件一个都不能被当成半成品。
    func testNeverMatchesRealFiles() {
        for name in ["dashboard.json", "repos.json", "office.json",
                     "cooldowns.json", "sb.json", "a.sbjson"] {
            touch(name)
        }
        let r = Debris.scan(root: root)
        XCTAssertTrue(r.isEmpty, "误伤了：" + r.files.map(\.lastPathComponent).joined(separator: ", "))
    }

    func testTotalsAreReal() {
        touch("a.json.sb-1", bytes: 100)
        touch("a.json.sb-2", bytes: 300)
        let r = Debris.scan(root: root)
        XCTAssertEqual(r.files.count, 2)
        XCTAssertEqual(r.totalBytes, 400, "大小要真的加起来，不能只报个数")
        XCTAssertNotNil(r.newest)
    }

    /// 删除要二次判名字 —— 传进来一个真文件也不能删。
    func testRemoveRefusesRealFiles() {
        touch("important.json")
        let real = root.appendingPathComponent("important.json")
        let r = Debris.remove([real])
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path),
                      "名字里没有 .sb- 的文件绝对不能被删")
    }

    func testRemoveDeletesDebrisOnly() {
        touch("dashboard.json")
        touch("dashboard.json.sb-x")
        touch("snapshots/s.json.sb-y")

        let before = Debris.scan(root: root)
        XCTAssertEqual(before.files.count, 2)
        let r = Debris.remove(before.files)
        XCTAssertEqual(r.removed, 2)
        XCTAssertEqual(r.failed, 0)

        XCTAssertTrue(Debris.scan(root: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("dashboard.json").path),
            "真文件必须还在")
    }

    /// 大小要给人看得懂的单位。
    ///
    /// 1 字节印成「0.0 MB」会让人以为这条警告本身坏了 ——
    /// 于是真正该看的那句话被无视掉。这不是美观问题，是可信度问题。
    func testSizeTextUsesSensibleUnits() {
        touch("a.json.sb-1", bytes: 1)
        XCTAssertEqual(Debris.scan(root: root).sizeText, "1 字节")

        try? FileManager.default.removeItem(at: root.appendingPathComponent("a.json.sb-1"))
        touch("b.json.sb-1", bytes: 5000)
        XCTAssertEqual(Debris.scan(root: root).sizeText, "5 KB")

        try? FileManager.default.removeItem(at: root.appendingPathComponent("b.json.sb-1"))
        touch("c.json.sb-1", bytes: 3 * 1_048_576)
        XCTAssertEqual(Debris.scan(root: root).sizeText, "3.0 MB")
    }

    /// root 是 nil（没配 iCloud）时不能崩，也不能报「有问题」。
    func testNilRootIsEmptyNotAnError() {
        let r = Debris.scan(root: nil)
        XCTAssertTrue(r.isEmpty)
        XCTAssertFalse(r.incomplete, "没有 iCloud 不等于「扫不全」，别报成故障")
    }
}
