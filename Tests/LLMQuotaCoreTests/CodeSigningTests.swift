import XCTest
@testable import LLMQuotaCore

final class CodeSigningTests: XCTestCase {

    /// 没配身份时必须**什么都不做**、也不算失败。
    ///
    /// 这个项目要开源，别人拿去用不会有你的证书。签名是可选增强，
    /// 不能变成「不配就发不出去」。
    func testNoIdentityIsNotAFailure() throws {
        let saved = CodeSigning.identity()
        CodeSigning.clearIdentity()
        defer { if let s = saved { try? CodeSigning.setIdentity(s) } }

        // 环境变量也可能配着，配了就跳过这条（本地跑 vs CI 跑行为不同）。
        guard ProcessInfo.processInfo.environment["LLMQ_CODESIGN_IDENTITY"] == nil else {
            throw XCTSkip("环境变量里配了签名身份，这条用例不适用")
        }
        let r = CodeSigning.sign("/bin/ls")
        XCTAssertFalse(r.signed)
        XCTAssertTrue(r.detail.contains("没配签名身份"), "要说清楚为什么没签：\(r.detail)")
        XCTAssertTrue(r.detail.contains("失效"), "要点明代价，否则人不知道这条警告重不重要")
    }

    func testIdentityRoundTrips() throws {
        let saved = CodeSigning.identity()
        defer {
            if let s = saved { try? CodeSigning.setIdentity(s) } else { CodeSigning.clearIdentity() }
        }
        try CodeSigning.setIdentity("Some Identity (ABC123)")
        XCTAssertEqual(CodeSigning.identity(), "Some Identity (ABC123)")
        CodeSigning.clearIdentity()
        // 环境变量优先，没配环境变量时清掉就是 nil。
        if ProcessInfo.processInfo.environment["LLMQ_CODESIGN_IDENTITY"] == nil {
            XCTAssertNil(CodeSigning.identity())
        }
    }

    /// 签名身份**不能**存到 iCloud 共享配置里 —— 证书名带邮箱和 Team ID，
    /// 而那份配置是多机共享的、也是要开源的项目会读的位置。
    func testIdentityIsStoredLocallyNotInICloud() {
        XCTAssertFalse(ICloudSafe.isICloud(CodeSigning.configFile),
                       "签名身份存到了 iCloud：\(CodeSigning.configFile.path)")
        XCTAssertTrue(CodeSigning.configFile.path.contains("Application Support"))
    }

    /// `describe` 要能认出 adhoc（TeamIdentifier=not set）并报成 nil，
    /// 因为「有签名」和「有稳定身份」是两回事 —— adhoc 也是签名，但每次重建都变。
    func testAdhocReportsNoTeam() throws {
        let src = URL(fileURLWithPath: "/bin/ls")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adhoc-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = Proc.run("/usr/bin/codesign", ["--force", "--sign", "-", tmp.path],
                     cwd: NSTemporaryDirectory(), env: [:], timeout: 60)
        let d = CodeSigning.describe(tmp.path)
        XCTAssertNil(d.team, "adhoc 没有 team，必须报 nil 而不是字符串 \"not set\"")
    }
}
