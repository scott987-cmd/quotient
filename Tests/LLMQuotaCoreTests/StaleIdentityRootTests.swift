import XCTest
@testable import LLMQuotaCore

/// 「删云端孪生」必须删到真正的 iCloud 根,不是本地暂存。
///
/// 实锤(2026-08-23):`run()` 的 iCloudRoot 默认值曾写成
/// `Paths.iCloudSnapshotsDir?.deletingLastPathComponent()` —— 那个属性名字里带 iCloud,
/// 指向早就改成本地 `sharedRoot/snapshots`。于是每轮「清掉 3 个」又被镜像拉回来,
/// 手机上一直两个 MacBook。名字会骗人,这里把路径钉死。
final class StaleIdentityRootTests: XCTestCase {
    func test_默认云端根是真的iCloud目录_不在本地暂存里() {
        let cloud = StaleIdentitySweep.defaultICloudRoot.standardizedFileURL.path
        let local = Paths.sharedRoot.standardizedFileURL.path
        XCTAssertFalse(cloud.hasPrefix(local), "云端根落在本地暂存里 = 删的是同一份文件:\(cloud)")
        XCTAssertTrue(cloud.contains("Mobile Documents/com~apple~CloudDocs/LLMQuotaBar"),
                      "云端根应是 iCloud Drive 里的 LLMQuotaBar/:\(cloud)")
    }

    func test_run会把本地和云端的旧身份一起删_保留最新与本机() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        let local = base.appendingPathComponent("local/presence", isDirectory: true)
        let cloud = base.appendingPathComponent("cloud/presence", isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        func write(_ dir: URL, _ id: String, _ name: String, _ at: String) throws {
            let obj: [String: Any] = ["machineID": id, "machineName": name, "updatedAt": at]
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent(id + ".json"))
        }
        // 同名两份:OLD 旧、NEW 新;两边目录都有。
        for d in [local, cloud] {
            try write(d, "OLD", "MacBook Pro", "2026-08-22T23:00:00Z")
            try write(d, "NEW", "MacBook Pro", "2026-08-23T05:00:00Z")
        }
        let n = StaleIdentitySweep.run(sharedRoot: base.appendingPathComponent("local"),
                                       iCloudRoot: base.appendingPathComponent("cloud"))
        XCTAssertEqual(n, 1)
        XCTAssertFalse(fm.fileExists(atPath: local.appendingPathComponent("OLD.json").path), "本地旧身份要删")
        XCTAssertFalse(fm.fileExists(atPath: cloud.appendingPathComponent("OLD.json").path), "云端孪生也要删,否则下一轮又被拉回来")
        XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("NEW.json").path))
        XCTAssertTrue(fm.fileExists(atPath: cloud.appendingPathComponent("NEW.json").path))
    }
}
