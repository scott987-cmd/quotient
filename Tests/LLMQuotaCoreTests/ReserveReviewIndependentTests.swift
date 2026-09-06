import XCTest
@testable import LLMQuotaCore

final class ReserveReviewIndependentTests: XCTestCase {
    private var root: URL!
    private var rolesFile: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reserve-review-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rolesFile = root.appendingPathComponent("roles.json")
        SharedConfigJournal.directoryOverride = nil
        ConfigIntentIngest.rootOverride = root
        AgentRoles.fileOverride = rolesFile
    }

    override func tearDown() {
        ConfigIntentIngest.rootOverride = nil
        AgentRoles.fileOverride = nil
        SharedConfigJournal.directoryOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func drop(_ id: String, fraction: Double, createdAt: String,
                      requestedAt: Double? = nil, filename: String) throws {
        ConfigIntentIngest.ensureDirectories()
        let requested = requestedAt.map { ",\"requestedAt\":\($0)" } ?? ""
        let body = """
        {"id":"\(id)","createdAt":"\(createdAt)","source":"phone",
         "kind":"reserve","platform":"kimi","fraction":\(fraction)\(requested)}
        """
        try Data(body.utf8).write(
            to: ConfigIntentIngest.dir!.appendingPathComponent(filename + ".json"))
    }

    func testLegacySameSecondConflictRejectsBothInsteadOfChoosingRandomFilename() throws {
        try drop("older", fraction: 0.2, createdAt: "2026-09-06T14:00:00Z", filename: "zzz-old")
        try drop("newer", fraction: 0.6, createdAt: "2026-09-06T14:00:00Z", filename: "aaa-new")

        let results = ConfigIntentIngest.run()
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.accepted })
        XCTAssertNil(AgentRoles.role(for: .kimi).reserveFraction,
                     "旧协议没有手势顺序，不能让随机 UUID 决定配置")
    }

    func testNewProtocolSameSecondUsesRequestedAtWithinOneScan() throws {
        let iso = "2026-09-06T14:00:00Z"
        try drop("older", fraction: 0.2, createdAt: iso, requestedAt: 1_788_700_000.100,
                 filename: "zzz-old")
        try drop("newer", fraction: 0.6, createdAt: iso, requestedAt: 1_788_700_000.200,
                 filename: "aaa-new")

        let results = ConfigIntentIngest.run()
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveIntentID, "newer")
        XCTAssertEqual(results.first(where: { $0.accepted })?.id, "newer")
    }

    func testLateArrivalCannotRollbackNewerValueAcrossScans() throws {
        let iso = "2026-09-06T14:00:00Z"
        try drop("newer", fraction: 0.6, createdAt: iso, requestedAt: 1_788_700_000.200,
                 filename: "newer")
        XCTAssertTrue(ConfigIntentIngest.run().first?.accepted == true)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)

        try drop("older", fraction: 0.2, createdAt: iso, requestedAt: 1_788_700_000.100,
                 filename: "older")
        let late = ConfigIntentIngest.run()
        XCTAssertFalse(late.first?.accepted ?? true)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveIntentID, "newer")
    }

    func testEqualRequestedAtWithDifferentIDsIsRejected() throws {
        let iso = "2026-09-06T14:00:00Z"
        try drop("one", fraction: 0.2, createdAt: iso, requestedAt: 1_788_700_000.100,
                 filename: "one")
        try drop("two", fraction: 0.6, createdAt: iso, requestedAt: 1_788_700_000.100,
                 filename: "two")
        let results = ConfigIntentIngest.run()
        XCTAssertTrue(results.allSatisfy { !$0.accepted })
        XCTAssertNil(AgentRoles.role(for: .kimi).reserveFraction)
    }

    func testDuplicateRequestIsIdempotentButIDReuseWithDifferentValueIsRejected() throws {
        let iso = "2026-09-06T14:00:00Z"
        let stamp = 1_788_700_000.100
        try drop("same", fraction: 0.6, createdAt: iso, requestedAt: stamp, filename: "first")
        XCTAssertTrue(ConfigIntentIngest.run().first?.accepted == true)

        try drop("same", fraction: 0.6, createdAt: iso, requestedAt: stamp, filename: "duplicate")
        XCTAssertTrue(ConfigIntentIngest.run().first?.accepted == true)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)

        try drop("same", fraction: 0.2, createdAt: iso, requestedAt: stamp, filename: "tampered")
        XCTAssertFalse(ConfigIntentIngest.run().first?.accepted ?? true)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)
    }

    func testInvalidLegacyDateIsRejectedAndPreservesCurrentValue() throws {
        try drop("valid", fraction: 0.6, createdAt: "2026-09-06T14:00:00Z",
                 requestedAt: 1_788_700_000.100, filename: "valid")
        XCTAssertTrue(ConfigIntentIngest.run().first?.accepted == true)

        try drop("invalid", fraction: 0.2, createdAt: "昨天下午", filename: "invalid")
        XCTAssertFalse(ConfigIntentIngest.run().first?.accepted ?? true)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveIntentID, "valid")
    }

    func testFirstCLIReserveEditCreatesWatermarkAndRejectsOlderPhoneIntent() throws {
        var roles = Array(AgentRoles.all().values)
        let index = try XCTUnwrap(roles.firstIndex { $0.platform == .kimi })
        XCTAssertNil(roles[index].reserveUpdatedAt)
        roles[index].reserveFraction = 0.6
        try AgentRoles.save(roles)
        let saved = AgentRoles.role(for: .kimi)
        let watermark = try XCTUnwrap(saved.reserveUpdatedAt,
            "从旧配置首次经CLI修改也必须建立顺序水位")
        XCTAssertNil(saved.reserveIntentID)

        try drop("late-phone", fraction: 0.2, createdAt: "2026-09-06T14:00:00Z",
                 requestedAt: watermark - 1, filename: "late-phone")
        XCTAssertFalse(ConfigIntentIngest.run().first?.accepted ?? true)
        XCTAssertEqual(AgentRoles.role(for: .kimi).reserveFraction, 0.6)
    }

    func testConcurrentJournalProjectsNewestReserveWithoutReplacingHeadRoleFields() throws {
        let journalA = root.appendingPathComponent("journal-a", isDirectory: true)
        let journalZ = root.appendingPathComponent("journal-z", isDirectory: true)
        let merged = root.appendingPathComponent("journal-merged", isDirectory: true)
        let configA = root.appendingPathComponent("a.json")
        let configZ = root.appendingPathComponent("z.json")
        try FileManager.default.createDirectory(at: merged, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970

        func payload(kimiFraction: Double, stamp: Double, intentID: String,
                     kimiTitle: String, claudeNote: String) throws -> Data {
            var kimi = AgentRole(platform: .kimi, title: kimiTitle, maxRisk: .normal,
                                 reserveFraction: kimiFraction)
            kimi.reserveUpdatedAt = stamp
            kimi.reserveIntentID = intentID
            let claude = AgentRole(platform: .claude, title: "主力开发", maxRisk: .sensitive,
                                   note: claudeNote)
            return try SnapshotCoding.prettyEncoder().encode([claude, kimi])
        }

        SharedConfigJournal.directoryOverride = journalA
        _ = try SharedConfigJournal.commit(document: "roles",
            payload: payload(kimiFraction: 0.6, stamp: now - 100, intentID: "new-60",
                             kimiTitle: "A 侧岗位", claudeNote: "A 侧说明"),
            expectedRevision: 0, compatibilityFile: configA, writerMachineID: "machine-a")
        SharedConfigJournal.directoryOverride = journalZ
        _ = try SharedConfigJournal.commit(document: "roles",
            payload: payload(kimiFraction: 0.2, stamp: now - 200, intentID: "old-20",
                             kimiTitle: "Z 侧岗位", claudeNote: "Z 侧说明"),
            expectedRevision: 0, compatibilityFile: configZ, writerMachineID: "machine-z")
        for directory in [journalA, journalZ] {
            for file in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                try FileManager.default.copyItem(at: file,
                    to: merged.appendingPathComponent(file.lastPathComponent))
            }
        }

        SharedConfigJournal.directoryOverride = merged
        let snapshot = SharedConfigJournal.snapshot(document: "roles", compatibilityFile: configZ)
        let roles = try SnapshotCoding.decoder().decode([AgentRole].self,
                                                         from: XCTUnwrap(snapshot.data))
        let kimi = try XCTUnwrap(roles.first { $0.platform == .kimi })
        let claude = try XCTUnwrap(roles.first { $0.platform == .claude })
        XCTAssertEqual(kimi.reserveFraction, 0.6, "较新的手机预留不能被 journal 头的旧值覆盖")
        XCTAssertEqual(kimi.reserveIntentID, "new-60")
        XCTAssertEqual(kimi.title, "Z 侧岗位", "预留投影不能覆盖 journal 头的岗位字段")
        XCTAssertEqual(claude.note, "Z 侧说明", "其他平台应继续采用原 journal 冲突策略")
    }

    func testConcurrentJournalEqualOrderIsVisibleConservativeAndResettable() throws {
        let journalA = root.appendingPathComponent("equal-a", isDirectory: true)
        let journalZ = root.appendingPathComponent("equal-z", isDirectory: true)
        let merged = root.appendingPathComponent("equal-merged", isDirectory: true)
        let compatibility = root.appendingPathComponent("equal-roles.json")
        try FileManager.default.createDirectory(at: merged, withIntermediateDirectories: true)
        let stamp = Date().timeIntervalSince1970 - 100

        func payload(_ fraction: Double, _ id: String, _ title: String) throws -> Data {
            var kimi = AgentRole(platform: .kimi, title: title, maxRisk: .normal,
                                 reserveFraction: fraction)
            kimi.reserveUpdatedAt = stamp
            kimi.reserveIntentID = id
            return try SnapshotCoding.prettyEncoder().encode([kimi])
        }
        for (directory, writer, fraction, id, title) in [
            (journalA, "machine-a", 0.2, "request-a", "A 岗位"),
            (journalZ, "machine-z", 0.6, "request-z", "Z 岗位"),
        ] {
            SharedConfigJournal.directoryOverride = directory
            _ = try SharedConfigJournal.commit(document: "roles",
                payload: payload(fraction, id, title), expectedRevision: 0,
                compatibilityFile: compatibility, writerMachineID: writer)
            for file in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                try FileManager.default.copyItem(at: file,
                    to: merged.appendingPathComponent(file.lastPathComponent))
            }
        }

        SharedConfigJournal.directoryOverride = merged
        AgentRoles.fileOverride = compatibility
        let conflicted = AgentRoles.role(for: .kimi)
        XCTAssertEqual(conflicted.reserveFraction, 0.6, "无法排序时应保守采用较高预留")
        XCTAssertTrue(conflicted.reserveConflict == true)
        XCTAssertNil(conflicted.reserveIntentID, "冲突状态不能冒充任一请求已获确认")
        XCTAssertEqual(conflicted.title, "Z 岗位", "岗位字段仍跟随原 journal 头")

        var roles = Array(AgentRoles.all().values)
        let index = try XCTUnwrap(roles.firstIndex { $0.platform == .kimi })
        roles[index].title = "只改岗位"
        try AgentRoles.save(roles)
        let roleOnly = AgentRoles.role(for: .kimi)
        XCTAssertTrue(roleOnly.reserveConflict == true, "仅改岗位不能偷偷解决预留冲突")
        XCTAssertEqual(roleOnly.reserveUpdatedAt, stamp, "仅改岗位不能制造新的预留顺序水位")
        XCTAssertEqual(roleOnly.reserveFraction, 0.6)

        roles = Array(AgentRoles.all().values)
        let resetIndex = try XCTUnwrap(roles.firstIndex { $0.platform == .kimi })
        roles[resetIndex].reserveFraction = 0.4
        try AgentRoles.save(roles)
        let reset = AgentRoles.role(for: .kimi)
        XCTAssertEqual(reset.reserveFraction, 0.4)
        XCTAssertFalse(reset.reserveConflict == true)
        XCTAssertNil(reset.reserveIntentID)
        XCTAssertGreaterThan(try XCTUnwrap(reset.reserveUpdatedAt), stamp)
    }
}
