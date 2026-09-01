import XCTest
@testable import LLMQuotaCore

/// 手机↔Mac 对账(2026-08-23)抓出来的三处,钉住:
/// 办公室事件流每机一份+合并、本地日志不被 publish 清空、下发页动作记台账。
final class OfficeContractTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        OfficeLog.dirOverride = d
        Paths.appSupportOverride = d
    }
    override func tearDown() { OfficeLog.dirOverride = nil; Paths.appSupportOverride = nil; super.tearDown() }

    private func ev(_ at: TimeInterval, _ detail: String, kind: OfficeEvent.Kind = .dispatched) -> OfficeEvent {
        OfficeEvent(kind: kind, taskID: "t", platform: .kimi, toPlatform: nil,
                    detail: detail, taskTitle: "x", excluded: [],
                    at: Date(timeIntervalSince1970: at), machineID: "ME")
    }

    /// **合并:根上的 office.json 要带上别的机器的事件。** 原来内容只来自本机
    /// 私有 jsonl,两台机器 last-writer-wins 互相覆盖 —— 和当年 reviews.json 同病。
    func testPublishMergesOtherMachinesEvents() throws {
        let other = OfficeLog.perMachineDir.appendingPathComponent("OTHER-MACHINE.json")
        try FileManager.default.createDirectory(at: OfficeLog.perMachineDir, withIntermediateDirectories: true)
        try SnapshotCoding.prettyEncoder().encode([ev(100, "别的机器干的")]).write(to: other)
        let merged = OfficeLog.merged(local: [ev(200, "本机干的")], machineID: "ME")
        XCTAssertEqual(merged.map(\.detail), ["别的机器干的", "本机干的"], "要按时间并在一起")
    }

    /// **本地日志绝不能被 publish 清空。** 对账实锤:Mac mini 的事件日志只剩 2 行,
    /// 历史全没了 —— all() 一次解空,publish 就把整份回写成空。
    func testPublishNeverWipesLocalLogOnShortRead() throws {
        // 造一份 10 行的本地日志
        for i in 0..<10 { OfficeLog.record(ev(Double(i), "e\(i)")) }
        let before = try String(contentsOf: OfficeLog.localFile, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(before, 10)
        OfficeLog.publish()   // 10 < keep(200),不该截短
        let after = try String(contentsOf: OfficeLog.localFile, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(after, 10, "没超长就不许动本地日志 —— 更不许清空")
    }

    func testPublishDoesNotCarryPreviousMachineIdentityIntoCurrentOfficeShard() throws {
        let current = Paths.machineID()
        OfficeLog.record(OfficeEvent(
            kind: .finished, taskID: "old", platform: .kimi,
            detail: "旧身份事件", taskTitle: "x", at: Date(timeIntervalSince1970: 1),
            machineID: "D127-OLD"))
        OfficeLog.record(OfficeEvent(
            kind: .dispatched, taskID: "new", platform: .kimi,
            detail: "当前身份事件", taskTitle: "x", at: Date(timeIntervalSince1970: 2),
            machineID: current))

        OfficeLog.publish()

        let file = OfficeLog.perMachineDir.appendingPathComponent(current + ".json")
        let events = try SnapshotCoding.decoder().decode(
            [OfficeEvent].self, from: Data(contentsOf: file))
        XCTAssertEqual(events.map(\.machineID), [current],
                       "当前机器的办公室分片不能继续发布旧 machineID 的历史")
    }

    /// **下发页动作办成后要记进同一个台账**,卡片才会消失。
    func testMarkDecidedHidesFromPending() {
        XCTAssertFalse(Review.decidedBranches().contains("/r|agent/a/b"))
        Review.markDecided(repo: "/r", branch: "agent/a/b")
        XCTAssertTrue(Review.decidedBranches().contains("/r|agent/a/b"),
                      "verdicts 和 actions 两条路必须写同一个台账")
    }
}
