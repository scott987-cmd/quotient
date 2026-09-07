import XCTest
@testable import LLMQuotaCore

final class WorkHandoffTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.path }
    private var oldHead: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "user.name", "Fixture"])
        try git(["commit", "--allow-empty", "-m", "old checkpoint"])
        oldHead = try git(["rev-parse", "HEAD"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ args: [String]) throws -> String {
        let r = GitWorkspace.git(args, in: repo, timeout: 10)
        guard r.exitCode == 0 else { throw NSError(domain: r.stderr, code: Int(r.exitCode)) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func addWork() throws -> String {
        try "accepted character".write(to: root.appendingPathComponent("character.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "new accepted asset"])
        return try git(["rev-parse", "HEAD"])
    }
    func testCleanCommittedWorkIsHandedOffAndOldDestinationAdvances() throws {
        try git(["branch", "agent/claude/task", oldHead])
        let latest = try addWork()
        let checkpoint = try WorkHandoff.checkpoint(in: repo, platform: .kimi, reason: "timeout")
        XCTAssertEqual(checkpoint, latest)
        let dest = try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: checkpoint)
        XCTAssertEqual(dest, latest)
        XCTAssertEqual(try git(["show", "agent/claude/task:character.txt"]), "accepted character")
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "2", "Clean checkpoint must not manufacture a commit")
    }
    func testOldDestinationCannotSilentlyIgnoreNewSource() throws {
        try git(["branch", "agent/claude/task", oldHead])
        let latest = try addWork()
        XCTAssertEqual(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: latest), latest)
    }
    func testDivergedDestinationIsPreservedAndRefused() throws {
        try git(["checkout", "-b", "agent/claude/task"])
        try git(["commit", "--allow-empty", "-m", "independent destination work"])
        let dest = try git(["rev-parse", "HEAD"])
        try git(["checkout", "main"]); let latest = try addWork()
        XCTAssertThrowsError(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: latest))
        XCTAssertEqual(try git(["rev-parse", "agent/claude/task"]), dest)
    }
    func testUncommittedChangesAreSavedAndInvalidBaseIsRejected() throws {
        try "pending".write(to: root.appendingPathComponent("pending.txt"), atomically: true, encoding: .utf8)
        let head = try WorkHandoff.checkpoint(in: repo, platform: .kimi, reason: "timeout")
        XCTAssertEqual(try git(["show", head + ":pending.txt"]), "pending")
        XCTAssertThrowsError(try WorkHandoff.advanceBranch(repo: repo, branch: "main", base: "missing-source"))
    }
    func testCheckedOutDirtyOrBusyDestinationIsNotChanged() throws {
        try git(["branch", "agent/claude/task", oldHead])
        let latest = try addWork()
        let target = root.appendingPathComponent("target").path
        try git(["worktree", "add", target, "agent/claude/task"])
        let probe = GitWorkspace.occupantsProbe
        defer { GitWorkspace.occupantsProbe = probe }
        GitWorkspace.occupantsProbe = { _ in [] }
        try "unsaved".write(toFile: target + "/pending.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: latest))
        XCTAssertEqual(try String(contentsOfFile: target + "/pending.txt", encoding: .utf8), "unsaved")
        XCTAssertEqual(try git(["rev-parse", "agent/claude/task"]), oldHead)
        try FileManager.default.removeItem(atPath: target + "/pending.txt")
        GitWorkspace.occupantsProbe = { _ in [Int32.max] }
        XCTAssertThrowsError(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: latest))
        XCTAssertEqual(try git(["rev-parse", "agent/claude/task"]), oldHead)
        GitWorkspace.occupantsProbe = { _ in [] }
        XCTAssertEqual(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: latest), latest)
        XCTAssertEqual(try String(contentsOfFile: target + "/character.txt", encoding: .utf8), "accepted character")
    }
    func testFailedCheckpointDoesNotTransferOlderCommittedTree() throws {
        // GitWorkspace deliberately disables hooks. An index lock is a real
        // commit failure that remains effective through its hardened git wrapper.
        try "fixture lock".write(to: root.appendingPathComponent(".git/index.lock"), atomically: true, encoding: .utf8)
        try "unsaved".write(to: root.appendingPathComponent("pending.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkHandoff.checkpoint(in: repo, platform: .kimi, reason: "failed save"))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), oldHead)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("pending.txt"), encoding: .utf8), "unsaved")
    }

    func testAlreadyCurrentOrLeadingDestinationStillProtectsUnsavedWork() throws {
        try git(["branch", "agent/claude/task", oldHead])
        let target = root.appendingPathComponent("target").path
        try git(["worktree", "add", target, "agent/claude/task"])
        let probe = GitWorkspace.occupantsProbe
        defer { GitWorkspace.occupantsProbe = probe }
        GitWorkspace.occupantsProbe = { _ in [] }
        try "unsaved".write(toFile: target + "/pending.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: oldHead))
        XCTAssertEqual(try String(contentsOfFile: target + "/pending.txt", encoding: .utf8), "unsaved")
        try FileManager.default.removeItem(atPath: target + "/pending.txt")
        let c = GitWorkspace.git(["commit", "--allow-empty", "-m", "ahead"], in: target)
        XCTAssertEqual(c.exitCode, 0)
        GitWorkspace.occupantsProbe = { _ in [Int32.max] }
        XCTAssertThrowsError(try WorkHandoff.advanceBranch(repo: repo, branch: "agent/claude/task", base: oldHead))
    }

}
