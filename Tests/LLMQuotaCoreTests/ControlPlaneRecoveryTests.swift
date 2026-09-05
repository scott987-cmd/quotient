import XCTest
@testable import LLMQuotaCore

final class ControlPlaneRecoveryTests: XCTestCase {
    func testLaunchdPathFindsExistingNpmGlobalTools() {
        XCTAssertTrue(Proc.toolDirs.contains(NSHomeDirectory() + "/.npm-global/bin"))
        XCTAssertTrue(Proc.augmentedPATH("/usr/bin:/bin").split(separator: ":").contains(Substring(NSHomeDirectory() + "/.npm-global/bin")))
    }
    func testProhibitedPublishingDoesNotReserveSigningWhileSimulatorWorkStillDoes() {
        let r = TaskResourcePolicy.infer(prompt: "用 Xcode 和模拟器验证游戏。禁止发布 TestFlight；不要签名。")
        XCTAssertFalse(r.claims.contains("device:apple-signing"))
        XCTAssertTrue(r.claims.contains("device:ios-simulator"))
        XCTAssertTrue(r.capabilities.contains("tool:xcode"))
        XCTAssertTrue(TaskResourcePolicy.infer(prompt: "完成 TestFlight 发布和签名").claims.contains("device:apple-signing"))
    }
    func testInvalidWindowCannotProduceInventedPeak() {
        let buckets = [UsageBucket(start: Date(timeIntervalSince1970: 1_000), model: "fixture", requests: 2)]
        XCTAssertNil(QuotaEngine.peakInWindow(buckets, windowSeconds: -10, metric: .requests, pricing: nil, now: Date(timeIntervalSince1970: 2_000)))
    }
    func testPeakPreservesWindowBoundariesAndUnsortedUsage() {
        let now = Date(timeIntervalSince1970: 100_000)
        let buckets = (0..<150).reversed().map { i in
            UsageBucket(start: now.addingTimeInterval(Double(i * 137 - 30_000)), model: "fixture",
                prompts: i % 5, requests: i % 11, inputTokens: i * 7, outputTokens: i % 17)
        }
        for seconds in [600.0, 3600, 5400] {
            for metric in [QuotaMetric.prompts, .requests, .totalTokens, .outputTokens, .percent] {
                let earliest = buckets.map(\.start).min()!
                var end = earliest.addingTimeInterval(seconds), peak = 0.0
                while end <= now {
                    peak = max(peak, metric.value(from: buckets.filter { $0.start >= end.addingTimeInterval(-seconds) && $0.start < end }, pricing: nil))
                    end = end.addingTimeInterval(max(60, seconds / 12))
                }
                XCTAssertEqual(QuotaEngine.peakInWindow(buckets, windowSeconds: seconds, metric: metric, pricing: nil, now: now), peak > 0 ? peak : nil)
            }
        }
    }
    func testReleaseChannelSyncPrecedesBulkEvidenceAndSnapshotWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("control-priority-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        var reads: [String] = []
        _ = MirrorService.sync(local: local, cloud: cloud, selfMachineID: "isolated",
            cloudList: { url in reads.append(url.lastPathComponent); return .ok([]) })
        XCTAssertEqual(reads.first, "releases")
    }
    func testFullReleaseHashesCannotMatchOnlyByDisplayPrefix() {
        XCTAssertFalse(ReleaseFanout.matches(target: String(repeating: "a", count: 64),
            installed: String(repeating: "a", count: 12) + String(repeating: "b", count: 52)))
    }

    func testReleaseSyncLimitsTransferToReferencedPayloadAndPublishesManifestLast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-priority-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = ReleaseChannel.Manifest(sha256: String(repeating: "a", count: 64), file: "new.tar.gz",
            publishedAt: Date(), publishedBy: "fixture", notes: "isolated")
        try SnapshotCoding.encoder().encode(m).write(to: root.appendingPathComponent("current.json"))
        let names: Set<String> = ["current.json", "current.sig", "release-signer.crt", "new.tar.gz", "old.tar.gz"]
        let order = MirrorService.releaseSyncNames(names, localDir: root, cloudDir: root)
        XCTAssertFalse(order.contains("old.tar.gz"))
        XCTAssertTrue(order.contains("new.tar.gz"))
        XCTAssertEqual(order.last, "current.json")
        try FileManager.default.removeItem(at: root.appendingPathComponent("current.json"))
        XCTAssertFalse(MirrorService.releaseSyncNames(names, localDir: root, cloudDir: root).contains("old.tar.gz"))
    }
    func testReleaseVerificationRequiresAnExplicitFullTargetWhenSupplied() throws {
        let sha = String(repeating: "A", count: 64)
        XCTAssertEqual(try ReleaseFanout.verificationTarget(["verify", "--target", sha]), sha.lowercased())
        XCTAssertThrowsError(try ReleaseFanout.verificationTarget(["verify", "--target"]))
        XCTAssertThrowsError(try ReleaseFanout.verificationTarget(["verify", "--target", "old-release"]))
        XCTAssertNil(try ReleaseFanout.verificationTarget(["verify"]))
    }

    func testLegacyInferredSigningClaimIsRecomputedButExplicitExtraClaimsRemain() throws {
        var task = WorkTask(id: "isolated", prompt: "使用 Xcode 模拟器。禁止发布 TestFlight。", repo: "/tmp/isolated")
        task.resourceClaims = ["device:apple-signing", "device:ios-simulator", "tool:xcode"]
        func read(_ t: WorkTask) throws -> WorkTask {
            try SnapshotCoding.decoder().decode(WorkTask.self, from: SnapshotCoding.encoder().encode(t))
        }
        XCTAssertFalse(try read(task).resourceClaims.contains("device:apple-signing"))
        task.resourceClaims.append("explicit:exclusive-review")
        XCTAssertEqual(try read(task).resourceClaims, task.resourceClaims)
        XCTAssertTrue(TaskResourcePolicy.infer(prompt: "不要停止 Blender 渲染").claims.contains("tool:blender"))
        XCTAssertTrue(TaskResourcePolicy.infer(prompt: "不要使用 Blender，使用 Xcode 模拟器").claims.contains("device:ios-simulator"))
    }

}
