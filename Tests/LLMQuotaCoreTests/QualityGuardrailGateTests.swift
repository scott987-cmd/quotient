import XCTest
@testable import LLMQuotaCore

final class QualityGuardrailGateTests: XCTestCase {
    func testWeakenedMinimumIsBlockedButTightenedMinimumPasses() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("THUMB_MIN = -1.0\n", to: "gate.py", in: repo)
        git(["add", "gate.py"], in: repo)
        git(["commit", "-qm", "weaken"], in: repo)
        git(["branch", "weakened"], in: repo)

        let blocked = QualityGuardrailGate.violation(
            repo: repo.path, branch: "weakened")
        XCTAssertTrue(blocked?.contains("禁止放宽质量门槛") == true)
        XCTAssertTrue(blocked?.contains("45.0") == true)

        try write("THUMB_MIN = 50.0\n", to: "gate.py", in: repo)
        git(["add", "gate.py"], in: repo)
        git(["commit", "-qm", "tighten"], in: repo)
        git(["branch", "tightened"], in: repo)
        XCTAssertNil(QualityGuardrailGate.violation(
            repo: repo.path, branch: "tightened"))
    }

    func testMissingProtectedSymbolFailsClosed() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("OTHER = 45.0\n", to: "gate.py", in: repo)
        git(["add", "gate.py"], in: repo)
        git(["commit", "-qm", "remove gate"], in: repo)
        git(["branch", "missing"], in: repo)
        XCTAssertTrue(QualityGuardrailGate.violation(
            repo: repo.path, branch: "missing")?.contains("缺失或不可解析") == true)
    }

    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("guardrail-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".llmq"), withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repo)
        git(["config", "user.email", "test@example.com"], in: repo)
        git(["config", "user.name", "Test"], in: repo)
        let contract = ProjectContract(
            outcomeSummary: "test", qualityGuardrails: [
                .init(file: "gate.py", symbol: "THUMB_MIN",
                      bound: .minimum, value: 45)
            ])
        let data = try JSONEncoder().encode(contract)
        try data.write(to: repo.appendingPathComponent(ProjectContract.relativePath))
        try write("THUMB_MIN = 45.0\n", to: "gate.py", in: repo)
        git(["add", "-A"], in: repo)
        git(["commit", "-qm", "base"], in: repo)
        return repo
    }

    private func write(_ value: String, to path: String, in repo: URL) throws {
        try value.write(to: repo.appendingPathComponent(path),
                        atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String], in repo: URL) -> Proc.Result {
        let result = GitWorkspace.git(args, in: repo.path)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return result
    }
}
