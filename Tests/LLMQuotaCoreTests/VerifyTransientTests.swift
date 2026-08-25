import XCTest
@testable import LLMQuotaCore

/// **验证的瞬时失败(超时/被杀)不记否决 —— 「下一轮会重试」必须是真的。**
///
/// 控制流 review §6 实锤:verifyMerge 超时返回的字符串写着「（下一轮会重试）」,
/// 但 autoLand 拿到后照样 setAutoLandVeto,veto 只在 head 变化时失效 ——
/// 文字承诺重试,控制流永久否决。一份正常产出因为一次 15 分钟构建超时,
/// 就再也合不进去。现在 transient 是结构化标志,autoLand 按它分流。
final class VerifyTransientTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-evidence-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox,
                                                  withIntermediateDirectories: true)
        CollaborationStore.directoryOverride = sandbox
            .appendingPathComponent("collaboration")
    }

    override func tearDown() {
        CollaborationStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func repo() throws -> (String, String) {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        func g(_ a: [String]) { _ = GitWorkspace.git(a, in: d) }
        g(["init", "-q", "--initial-branch=main"])
        g(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"])
        g(["branch", "agent/x/1"])
        try "x".write(toFile: d + "/f.txt", atomically: true, encoding: .utf8)
        g(["checkout", "-q", "agent/x/1"]); g(["add", "."])
        g(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "work"])
        g(["checkout", "-q", "main"])
        return (d, "agent/x/1")
    }

    func testTimeoutIsTransient() throws {
        let (d, b) = try repo()
        let f = Review.verifyMerge(repo: d, branch: b, base: "main",
                                   command: "sleep 5", timeout: 1)
        XCTAssertNotNil(f)
        XCTAssertTrue(f?.transient == true, "超时不是这份产出的错,必须标瞬时 —— 否则被永久否决")
    }

    func testRealTestFailureIsNotTransient() throws {
        let (d, b) = try repo()
        let f = Review.verifyMerge(repo: d, branch: b, base: "main",
                                   command: "exit 1", timeout: 30)
        XCTAssertNotNil(f)
        XCTAssertTrue(f?.transient == false, "测试真挂了才是产出的问题,该走修复/否决")
    }

    func testPassReturnsNil() throws {
        let (d, b) = try repo()
        XCTAssertNil(Review.verifyMerge(repo: d, branch: b, base: "main",
                                        command: "printf '42 tests passed\\n'", timeout: 30))
        let evidence = CollaborationStore.all().last
        XCTAssertEqual(evidence?.senderRunnerID, "orchestrator.verify")
        XCTAssertEqual(evidence?.branch, b)
        XCTAssertTrue(evidence?.summary.contains("退出码 0") == true)
        XCTAssertTrue(evidence?.details?.contains("42 tests passed") == true)
    }
}
