import XCTest
@testable import LLMQuotaCore

final class ProjectorInstallationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMissingServiceIsInstalledWithoutTouchingWorkerAndIsIdempotent() throws {
        var loaded = false
        var commands: [[String]] = []
        let run: ([String]) -> Int32 = { args in
            commands.append(args)
            if args.first == "bootstrap" { loaded = true; return 0 }
            return loaded ? 0 : 113
        }
        XCTAssertTrue(try ProjectorInstallation.ensure(executable: "/usr/bin/true", home: root,
            support: root, uid: 501, onlyIfWorkerInstalled: false, run: run))
        XCTAssertTrue(loaded, "必须真实走 bootstrap，不能只写 plist 就宣称安装完成")
        XCTAssertEqual(commands.filter { $0.first == "bootstrap" }.count, 1)
        let plist = root.appendingPathComponent("Library/LaunchAgents/com.llmquotabar.projector.plist")
        let object = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(object["ProgramArguments"] as? [String], ["/usr/bin/true", "work", "projector"])
        XCTAssertFalse(commands.flatMap { $0 }.contains { $0.contains("worker") || $0.contains("executor") })
        commands.removeAll()
        XCTAssertTrue(try ProjectorInstallation.ensure(executable: "/usr/bin/true", home: root,
            support: root, uid: 501, onlyIfWorkerInstalled: false, run: run))
        XCTAssertEqual(commands, [["print", "gui/501/com.llmquotabar.projector"]])
    }

    func testUpgradeDoesNotEnrollMachineWithoutWorker() throws {
        XCTAssertFalse(try ProjectorInstallation.ensure(executable: "/usr/bin/true", home: root,
            support: root, run: { _ in XCTFail("不应启动任何服务"); return 0 }))
    }

    func testBootstrapFailureIsReported() {
        XCTAssertThrowsError(try ProjectorInstallation.ensure(executable: "/usr/bin/true", home: root,
            support: root, onlyIfWorkerInstalled: false, run: { _ in 113 }))
    }

    func testUpgradeAndSelfCheckIncludeProjector() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/LLMQuotaCore")
        let release = try String(contentsOf: source.appendingPathComponent("ReleaseChannel.swift"))
        let migration = try XCTUnwrap(release.range(of: "try ProjectorInstallation.ensure"))
        let ack = try XCTUnwrap(release.range(of: "markInstalled(manifest.sha256)"))
        XCTAssertLessThan(migration.lowerBound, ack.lowerBound, "补装失败不能假报安装验收成功")
        let check = try String(contentsOf: source.appendingPathComponent("SelfCheck.swift"))
        XCTAssertEqual(check.components(separatedBy: "\"com.llmquotabar.projector\"").count - 1, 2)
    }
}
