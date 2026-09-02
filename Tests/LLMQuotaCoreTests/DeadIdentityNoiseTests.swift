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

    func test_旧办公室分片不能靠自己的文件名自证存活() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("office-live-\(UUID().uuidString)")
        defer {
            OfficeLog.dirOverride = nil
            try? fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root.appendingPathComponent("office"),
                               withIntermediateDirectories: true)
        OfficeLog.dirOverride = root
        try SnapshotCoding.prettyEncoder().encode([ev("STALE-OFFICE-ONLY", 1)])
            .write(to: root.appendingPathComponent("office/STALE-OFFICE-ONLY.json"))

        let live = OfficeLog.liveMachineIDs(selfID: "ME")

        XCTAssertFalse(live.contains("STALE-OFFICE-ONLY"),
                       "presence 才能证明机器存活；旧 office 文件不能给自己续命")
    }

    func test_没有presence的每机文件_超时才清_本机永不清() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orph-\(UUID().uuidString)")
        for d in ["presence", "office", "reviews", "taskboards", "probes", "agent-registry"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func touch(_ rel: String, old: Bool) throws {
            let u = root.appendingPathComponent(rel)
            try "[]".write(to: u, atomically: true, encoding: .utf8)
            if old { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 3600)], ofItemAtPath: u.path) }
        }
        try touch("presence/LIVE.json", old: false)
        try touch("office/LIVE.json", old: true)
        try touch("office/DEAD.json", old: true)
        try touch("reviews/DEAD.json", old: true)
        try touch("probes/DEAD.json", old: true)
        try touch("agent-registry/DEAD.json", old: true)
        try touch("taskboards/ME.json", old: true)      // 本机,即使没 presence 也不清
        try touch("reviews/NEW.json", old: false)        // 新机器刚起,还没写 presence:别误删
        let removed = StaleIdentitySweep.sweepOrphanNames(
            sharedRoot: root, selfID: "ME", olderThan: 2 * 3600)
        XCTAssertEqual(Set(removed), [
            "office/DEAD.json", "reviews/DEAD.json",
            "probes/DEAD.json", "agent-registry/DEAD.json",
        ])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("office/LIVE.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("taskboards/ME.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("reviews/NEW.json").path))
    }


    func test_一次巡检不会因为同名淘汰另一台机器() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("one-pass-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["presence", "office"] {
            try fm.createDirectory(at: root.appendingPathComponent(d),
                                   withIntermediateDirectories: true)
        }
        let me = Paths.machineID()
        func presence(_ id: String, at: String) throws {
            let json = #"{"machineID":"\#(id)","machineName":"同一台测试机","updatedAt":"\#(at)"}"#
            try json.write(to: root.appendingPathComponent("presence/\(id).json"),
                           atomically: true, encoding: .utf8)
        }
        try presence("OLD-ID", at: "2026-08-22T10:00:00Z")
        try presence(me, at: "2026-08-23T10:00:00Z")
        let staleOffice = root.appendingPathComponent("office/OLD-ID.json")
        try "[]".write(to: staleOffice, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 3600)],
                             ofItemAtPath: staleOffice.path)

        _ = StaleIdentitySweep.run(sharedRoot: root, iCloudRoot: nil,
                                   localSnapshotsDir: nil)

        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("presence/OLD-ID.json").path))
        XCTAssertTrue(fm.fileExists(atPath: staleOffice.path),
                      "同名不等于同机，30 天 TTL 未到前不得把离线真机当脏数据")
    }

    func test_无presence的旧问题收件箱目录会清理_新目录和活机器保留() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("question-orphan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["presence", "questions/DEAD", "questions/NEW", "questions/LIVE"] {
            try fm.createDirectory(at: root.appendingPathComponent(d),
                                   withIntermediateDirectories: true)
        }
        try "{}".write(to: root.appendingPathComponent("presence/LIVE.json"),
                       atomically: true, encoding: .utf8)
        for id in ["DEAD", "NEW", "LIVE"] {
            try "{}".write(to: root.appendingPathComponent("questions/\(id)/q.json"),
                           atomically: true, encoding: .utf8)
        }
        let old = Date(timeIntervalSinceNow: -3 * 3600)
        for id in ["DEAD", "LIVE"] {
            try fm.setAttributes([.modificationDate: old],
                                 ofItemAtPath: root.appendingPathComponent("questions/\(id)").path)
        }

        _ = StaleIdentitySweep.run(sharedRoot: root, iCloudRoot: nil,
                                   localSnapshotsDir: nil, olderThan: 2 * 3600)

        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("questions/DEAD").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("questions/NEW").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("questions/LIVE").path))
    }

    func test_过期presence本体和云端孪生会一起回收() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("stale-presence-\(UUID().uuidString)")
        let cloud = fm.temporaryDirectory.appendingPathComponent("stale-presence-cloud-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: cloud)
        }
        try fm.createDirectory(at: root.appendingPathComponent("presence"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud.appendingPathComponent("presence"),
                               withIntermediateDirectories: true)
        let stale = #"{"machineID":"DEAD","machineName":"MacBook Pro","updatedAt":"2025-01-01T00:00:00Z"}"#
        try stale.write(to: root.appendingPathComponent("presence/DEAD.json"),
                        atomically: true, encoding: .utf8)
        try stale.write(to: cloud.appendingPathComponent("presence/DEAD.json"),
                        atomically: true, encoding: .utf8)

        _ = StaleIdentitySweep.run(
            sharedRoot: root, iCloudRoot: cloud, localSnapshotsDir: nil,
            olderThan: 2 * 3600)

        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("presence/DEAD.json").path))
        XCTAssertFalse(fm.fileExists(atPath: cloud.appendingPathComponent("presence/DEAD.json").path))
    }

    func test_活机器的办公室分片也不能夹带旧身份事件() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("office-shard-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["presence", "office"] {
            try fm.createDirectory(at: root.appendingPathComponent(d),
                                   withIntermediateDirectories: true)
        }
        let presence: [String: Any] = [
            "machineID": "LIVE", "machineName": "MacBook Pro",
            "updatedAt": "2026-09-01T12:00:00Z",
        ]
        try JSONSerialization.data(withJSONObject: presence)
            .write(to: root.appendingPathComponent("presence/LIVE.json"))
        try SnapshotCoding.prettyEncoder().encode([ev("DEAD", 1), ev("LIVE", 2)])
            .write(to: root.appendingPathComponent("office/LIVE.json"))

        _ = StaleIdentitySweep.run(
            sharedRoot: root, iCloudRoot: nil, localSnapshotsDir: nil)

        let cleaned = try SnapshotCoding.decoder().decode(
            [OfficeEvent].self,
            from: Data(contentsOf: root.appendingPathComponent("office/LIVE.json")))
        XCTAssertEqual(cleaned.map(\.machineID), ["LIVE"],
                       "分片文件名已经声明当前身份，里面的旧 ID 不能靠自身长期存活")
    }
}
