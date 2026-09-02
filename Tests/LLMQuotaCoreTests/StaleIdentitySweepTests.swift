import XCTest
@testable import LLMQuotaCore

/// **同名机器不能互删。** 过时身份只允许按稳定 ID + TTL 回收。
///
/// 老板 2026-08-23:「好几个 mac mini,有的离线有的正常」「任务队列展示又问题」。
/// machineID 漂移期间,每个身份都在 snapshots/taskboards/presence 留了一份
/// `<那次ID>.json`。dashboard 去重挡得住快照,但任务板/在线状态是手机按文件
/// 直读的 —— 一台机器裂成十几个。逐个删是打地鼠,这里每轮自动扫。
final class StaleIdentitySweepTests: XCTestCase {
    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("sis-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ dir: URL, id: String, name: String, at: String) {
        let j = #"{"machineID":"\#(id)","machineName":"\#(name)","generatedAt":"\#(at)"}"#
        try? j.write(to: dir.appendingPathComponent(id + ".json"),
                     atomically: true, encoding: .utf8)
    }

    func testSameNamedMachinesAreNeverDeletedByDisplayName() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        write(d, id: "OLD1", name: "Mac mini", at: "2026-08-22T10:00:00Z")
        write(d, id: "OLD2", name: "Mac mini", at: "2026-08-22T18:00:00Z")
        write(d, id: "NEW",  name: "Mac mini", at: "2026-08-23T06:00:00Z")
        write(d, id: "MBP",  name: "MacBook Pro", at: "2026-08-23T06:00:00Z")
        let removed = StaleIdentitySweep.sweepDir(d)
        XCTAssertEqual(removed, 0, "无法仅凭同名证明是同一台机器")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: d.path))?
            .sorted() ?? []
        XCTAssertEqual(left, ["MBP.json", "NEW.json", "OLD1.json", "OLD2.json"])
    }

    /// **同名不同机绝不互删本机文件。** 三轮 review 都点名缺这条边界。
    /// 两台真机都叫「Mac mini」时,不能把当前机器(selfID)的活文件删掉 ——
    /// 否则镜像把对方文件拉来、sweep 每轮删本机的,两台在世机器互删。
    func testNeverDeletesCurrentMachineFile() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        // 本机较旧,对方较新,但同名。本机文件必须保住。
        func w(_ id: String, _ at: String) {
            let j = #"{"machineID":"\#(id)","machineName":"Mac mini","generatedAt":"\#(at)"}"#
            try? j.write(to: d.appendingPathComponent(id + ".json"),
                         atomically: true, encoding: .utf8)
        }
        w("ME", "2026-08-22T10:00:00Z")     // 本机,较旧
        w("OTHER", "2026-08-23T06:00:00Z")   // 另一台同名机,较新
        _ = StaleIdentitySweep.sweepDir(d, selfID: "ME")
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("ME.json").path),
                      "本机文件哪怕较旧也绝不能删")
    }

    /// presence 即使带 updatedAt，也不能只因同名就删除另一台机器。
    func testUpdatedAtDoesNotAuthorizeNameBasedDeletion() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        func writeP(_ id: String, _ name: String, _ at: String) {
            let j = #"{"machineID":"\#(id)","machineName":"\#(name)","updatedAt":"\#(at)"}"#
            try? j.write(to: d.appendingPathComponent(id + ".json"),
                         atomically: true, encoding: .utf8)
        }
        writeP("OLD", "Mac mini", "2026-08-22T10:00:00Z")
        writeP("NEW", "Mac mini", "2026-08-23T06:00:00Z")
        XCTAssertEqual(StaleIdentitySweep.sweepDir(d), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("OLD.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("NEW.json").path))
    }

    /// 只有一份的机器不能被误删 —— 正常情况绝大多数机器就一份。
    func testSingleFilePerMachineUntouched() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        write(d, id: "A", name: "Mac mini", at: "2026-08-23T06:00:00Z")
        write(d, id: "B", name: "MacBook Pro", at: "2026-08-23T06:00:00Z")
        XCTAssertEqual(StaleIdentitySweep.sweepDir(d), 0)
    }
}
