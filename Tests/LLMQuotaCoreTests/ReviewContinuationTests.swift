import XCTest
@testable import LLMQuotaCore

final class ReviewContinuationTests: XCTestCase {
    private var root: URL!
    private var previousRoot: URL?
    private var previousMachine: String?
    override func setUpWithError() throws {
        previousRoot = Paths.appSupportOverride; previousMachine = Paths.machineIDOverride
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root; Paths.machineIDOverride = "continuation-test"
    }
    override func tearDownWithError() throws {
        Paths.appSupportOverride = previousRoot; Paths.machineIDOverride = previousMachine
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture() throws -> (WorkTask, String) {
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"],
                     ["config", "user.email", "test@example.invalid"],
                     ["commit", "--allow-empty", "-m", "base"],
                     ["branch", "agent/kimi/continue-test"]] {
            XCTAssertEqual(GitWorkspace.git(args, in: repo).exitCode, 0)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "continue-test", "repo": repo, "prompt": "保留美术，完成可玩流程", "state": "failed",
            "branch": "agent/kimi/continue-test", "platform": "kimi", "ownerPlatform": "kimi",
            "createdAt": "2026-09-07T00:00:00Z", "ownerRunnerID": "kimi.code", "qualityRejectionCount": 1])
        let task = try SnapshotCoding.decoder().decode(WorkTask.self, from: data)
        try TaskStore.append(task)
        let current = try XCTUnwrap(TaskStore.all().first)
        let head = GitWorkspace.git(["rev-parse", current.branch!], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (current, head)
    }
    private func invocation(_ task: WorkTask, head: String) throws -> ViewFeed.Invocation {
        let action = "review-continuation:request:" + task.repo + "|" + task.branch! + "|" + head + "|" + MobileAction.taskResource(task)
        return try SnapshotCoding.decoder().decode(ViewFeed.Invocation.self, from: JSONSerialization.data(withJSONObject: [
            "id": MobileAction.scoped(action, machineID: "continuation-test")!, "invocationID": UUID().uuidString,
            "at": "2026-09-07T00:00:00Z"]))
    }
    func testContinuationKeepsOriginalWorkAndDoesNotApproveOrDiscard() throws {
        let (task, head) = try fixture()
        let inv = try invocation(task, head: head)
        XCTAssertEqual(MobileAction.execute(inv), true)
        let resumed = try XCTUnwrap(TaskStore.all().first)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertEqual(resumed.ownerRunnerID, task.ownerRunnerID)
        XCTAssertEqual(resumed.branch, task.branch)
        XCTAssertEqual(resumed.qualityRejectionCount, 1)
        XCTAssertTrue(resumed.prompt.hasPrefix(task.prompt))
        XCTAssertNil(resumed.landedAt); XCTAssertNil(resumed.discardedAt)
        XCTAssertTrue(Review.decidedBranches().isEmpty)
        XCTAssertEqual(GitWorkspace.git(["rev-parse", task.branch!], in: task.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines), head)
        XCTAssertEqual(MobileAction.execute(inv), true, "写任务后、写回执前退出仍须幂等")
        XCTAssertEqual(TaskStore.all().first?.rev, resumed.rev)
        XCTAssertEqual(GitWorkspace.git(["checkout", task.branch!], in: task.repo).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["commit", "--allow-empty", "-m", "continued work"], in: task.repo).exitCode, 0)
        XCTAssertEqual(MobileAction.execute(inv), true, "续作已经推进新提交后仍应确认原请求成功")
        XCTAssertEqual(TaskStore.all().first?.rev, resumed.rev)
    }
    func testProducerPublishesFullHeadAndUsableContinuation() throws {
        let (task, _) = try fixture()
        XCTAssertEqual(GitWorkspace.git(["checkout", task.branch!], in: task.repo).exitCode, 0)
        try "playable implementation".write(toFile: task.repo + "/game.txt", atomically: true, encoding: .utf8)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: URL(fileURLWithPath: task.repo + "/evidence.png"))
        XCTAssertEqual(GitWorkspace.git(["add", "game.txt", "evidence.png"], in: task.repo).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["commit", "-m", "game progress"], in: task.repo).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["checkout", "main"], in: task.repo).exitCode, 0)
        Review.invalidateListCache()
        let digest = try XCTUnwrap(Review.publishDigests(repos: [RepoAlias(alias: "game", path: task.repo)]).first)
        let head = GitWorkspace.git(["rev-parse", task.branch!], in: task.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(digest.head, head, "实际生产者必须与消费者要求的完整 SHA 一致")
        let action = try XCTUnwrap(digest.continuationActionID)
        XCTAssertTrue(action.contains("|" + head + "|"))
        let inv = try SnapshotCoding.decoder().decode(ViewFeed.Invocation.self, from: JSONSerialization.data(withJSONObject: [
            "id": MobileAction.scoped(action, machineID: "continuation-test")!,
            "invocationID": UUID().uuidString, "at": "2026-09-07T00:00:00Z"]))
        XCTAssertEqual(MobileAction.process(inv) { MobileAction.execute(inv) }?.state, "succeeded")
        XCTAssertEqual(TaskStore.all().first?.state, .queued)
    }
    func testContinuationSerializesWithDispositionWithoutPoisoningLaterDisposition() throws {
        let (task, head) = try fixture()
        let inv = try invocation(task, head: head)
        let discard = try SnapshotCoding.decoder().decode(ViewFeed.Invocation.self, from: JSONSerialization.data(withJSONObject: [
            "id": MobileAction.scoped("review:discard:" + task.repo + "|" + task.branch! + "|" + head, machineID: "continuation-test")!,
            "invocationID": UUID().uuidString, "at": "2026-09-07T00:00:00Z"]))
        let directory = MobileAction.ledger(machineID: "continuation-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(MobileAction.digest(MobileAction.resourceKey(discard.id)) + ".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertNil(MobileAction.process(inv) { XCTFail("同一成果正在处置，不能同时续作"); return true })
        flock(fd, LOCK_UN); close(fd)
        XCTAssertEqual(MobileAction.process(inv) { MobileAction.execute(inv) }?.state, "succeeded")
        XCTAssertEqual(MobileAction.execute(discard), false, "续作后旧成果页不能丢弃正在处理的分支")
        var completed = try XCTUnwrap(TaskStore.all().first)
        completed.state = .done
        _ = try TaskStore.transition(completed, actor: "test", reason: "本轮完成")
        XCTAssertEqual(MobileAction.process(discard) { MobileAction.execute(discard) }?.state, "succeeded",
                       "续作成功不能永久封死同 HEAD 的后续处置")
    }
    func testStaleVersionAndProtectedStateCannotBeRequeued() throws {
        let (task, head) = try fixture()
        XCTAssertEqual(MobileAction.execute(try invocation(task, head: String(repeating: "0", count: 40))), false)
        var protected = task
        protected.terminalFailureKind = .authenticationFailed
        protected = try TaskStore.transition(protected, actor: "test", reason: "账号仍需登录")
        XCTAssertEqual(MobileAction.execute(try invocation(task, head: head)), false)
        XCTAssertEqual(MobileAction.execute(try invocation(protected, head: head)), false)
        XCTAssertEqual(TaskStore.all().first?.state, .failed)
        protected.terminalFailureKind = nil; protected.pausedAt = Date()
        protected = try TaskStore.transition(protected, actor: "test", reason: "暂停")
        XCTAssertEqual(MobileAction.execute(try invocation(protected, head: head)), false)
    }
}
