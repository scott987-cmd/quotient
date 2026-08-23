import XCTest
@testable import LLMQuotaCore

/// 换过 machineID 的机器留下的旧身份:事件不进合并结果、没身份可读的每机文件也要清。
/// 老板 2026-08-23 晚:「办公室出现了一台未知的机器」。
final class DeadIdentityNoiseTests: XCTestCase {
    private func ev(_ mid: String, _ t: TimeInterval) -> OfficeEvent {
        OfficeEvent(kind: .finished, taskID: "t", platform: nil, detail: "d\(t)", taskTitle: "x",
                    at: Date(timeIntervalSince1970: t), machineID: mid)
    }

    func test_合并时丢掉已死身份的事件() {
        let local = [ev("DEAD", 1), ev("ME", 2), ev("", 3), ev("LIVE2", 4)]
        let out = OfficeLog.merged(local: local, machineID: "ME", liveIDs: ["ME", "LIVE2"])
        XCTAssertEqual(out.map { $0.machineID }.sorted(), ["", "LIVE2", "ME"], "DEAD 的事件不该出现在手机读的 office.json 里")
    }

    func test_没有presence的每机文件_超时才清_本机永不清() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orph-\(UUID().uuidString)")
        for d in ["presence", "office", "reviews", "taskboards"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func touch(_ rel: String, old: Bool) throws {
            let u = root.appendingPathComponent(rel)
            try "[]".write(to: u, atomically: true, encoding: .utf8)
            if old { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 3600)], ofItemAtPath: u.path) }
        }
        try touch("presence/LIVE.json", old: true)
        try touch("office/LIVE.json", old: true)
        try touch("office/DEAD.json", old: true)
        try touch("reviews/DEAD.json", old: true)
        try touch("taskboards/ME.json", old: true)      // 本机,即使没 presence 也不清
        try touch("reviews/NEW.json", old: false)        // 新机器刚起,还没写 presence:别误删
        let removed = StaleIdentitySweep.sweepOrphanNames(sharedRoot: root, selfID: "ME")
        XCTAssertEqual(Set(removed), ["office/DEAD.json", "reviews/DEAD.json"])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("office/LIVE.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("taskboards/ME.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("reviews/NEW.json").path))
    }
}
