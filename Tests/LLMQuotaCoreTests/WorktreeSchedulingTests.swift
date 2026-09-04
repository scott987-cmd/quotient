import XCTest
@testable import LLMQuotaCore

/// 回放 M2：实现任务属于主仓，阶段评审却登记在它的 linked worktree。
/// 必须在专注过滤、手机投影、并发互斥和新任务摄入中保持同一项目身份。
final class WorktreeSchedulingTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!
    private var workspace: String!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-scheduling-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox.appendingPathComponent("state")
        repo = sandbox.appendingPathComponent("Flint").path
        workspace = sandbox.appendingPathComponent("worktrees/flint-kimi").path
        try git(["init", repo], in: sandbox.path)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-m", "baseline"], in: repo)
        try git(["worktree", "add", "-b", "agent/kimi/sample", workspace], in: repo)
    }

    override func tearDownWithError() throws {
        Paths.appSupportOverride = nil
        try FileManager.default.removeItem(at: sandbox)
    }

    private func git(_ arguments: [String], in directory: String) throws {
        let result = GitWorkspace.git(arguments, in: directory, timeout: 10)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        guard result.exitCode == 0 else { throw CocoaError(.fileReadUnknown) }
    }

    func testFocusedScopeAcceptsLinkedWorktreeButNotCloneOrNestedRepo() throws {
        let scope = ProjectExecutionScope(allowedRepo: repo)
        XCTAssertTrue(scope.allows(workspace))
        XCTAssertTrue(scope.includesForDisplay(workspace))
        XCTAssertTrue(ProjectExecutionScope(allowedRepo: workspace).allows(repo))
        let alias = sandbox.appendingPathComponent("flint-link").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: workspace)
        XCTAssertTrue(scope.allows(alias))

        let clone = sandbox.appendingPathComponent("other/Flint").path
        try git(["clone", "--no-hardlinks", repo, clone], in: sandbox.path)
        XCTAssertFalse(scope.allows(clone), "相同历史/同名 clone 不是同一个本机仓库")
        let nested = repo + "/nested"
        try git(["init", nested], in: repo)
        XCTAssertFalse(scope.allows(nested), "不能按父目录前缀放行其他仓库")
        XCTAssertFalse(scope.allows(repo + "-old"))
        XCTAssertFalse(ProjectExecutionScope(mode: .manualOnly).allows(workspace))
    }

    func testLegacyQueuedReviewsRemainVisibleAndScheduleOnlyOnePerRepo() {
        let scope = ProjectExecutionScope(allowedRepo: repo)
        let tasks = (1...3).map {
            WorkTask(id: "review\($0)", prompt: "【看效果】阶段证据", repo: workspace)
        }
        let ready = scope.filter(tasks)
        let plan = LocalWorkerSlotPlanner.plan(
            ready: ready, allTasks: tasks, active: [], maxConcurrentTasks: 2)
        let snapshot = SchedulerSnapshot(
            scope: scope, ready: ready, active: [], plan: plan,
            maxConcurrentTasks: 2, allTasks: scope.filter(tasks))
        XCTAssertEqual(snapshot.pendingTaskCount, 3, "不得把排队评审投影成空闲零任务")
        XCTAssertEqual(snapshot.state, .dispatching)
        XCTAssertEqual(plan.selected.map(\.id), ["review1"])
        XCTAssertEqual(plan.decisions.filter { !$0.selected }.count, 2)
    }

    func testWorktreeAndMainShareBusyRepoAndExecutionLock() {
        var implementation = WorkTask(id: "implementation", prompt: "制作样板", repo: repo)
        implementation.state = .running
        let review = WorkTask(id: "review", prompt: "【看效果】", repo: workspace)
        XCTAssertEqual(RepoLease.holder(repo: workspace, tasks: [implementation])?.id,
                       implementation.id)
        let plan = LocalWorkerSlotPlanner.plan(
            ready: [review], allTasks: [implementation, review], active: [],
            maxConcurrentTasks: 2)
        XCTAssertTrue(plan.selected.isEmpty, "允许专注匹配后不能绕过同仓库互斥")
        XCTAssertEqual(plan.decisions.first?.reason, "同项目已有任务执行中")
        let root = sandbox.appendingPathComponent("leases")
        let first = LocalExecutionLease(scope: .repo, key: RepoLease.normalize(repo), root: root)
        let second = LocalExecutionLease(scope: .repo, key: RepoLease.normalize(workspace), root: root)
        XCTAssertTrue(first.acquire())
        defer { first.release(); second.release() }
        XCTAssertFalse(second.acquire(), "不同路径写法必须竞争同一把跨进程锁")
    }

    func testNewVisualReviewUsesMainRepoAndRetainsIdempotency() throws {
        let item = Milestone.Item(repo: workspace, repoName: "flint-kimi",
                                  branch: "agent/kimi/sample", mergeSHA: "abc123",
                                  subject: "样板", landedAt: Date(), evidenceFiles: ["front.png"])
        let id = try XCTUnwrap(Milestone.dispatchVisualCheck(item, repoPath: workspace))
        let review = try XCTUnwrap(TaskStore.all().first { $0.id == id })
        XCTAssertEqual(review.repo, RepoLease.normalize(repo))
        XCTAssertEqual(Milestone.dispatchVisualCheck(item, repoPath: workspace), id)
        XCTAssertEqual(TaskStore.all().count, 1)

        var prepared = WorkTask(id: "prepared", prompt: "【审查】", repo: workspace)
        prepared.ownerRunnerID = "kimi.code"
        _ = try TaskIntake.enqueuePrepared(prepared, idempotencyKey: "prepared", source: "test")
        let saved = try XCTUnwrap(TaskStore.all().first { $0.id == "prepared" })
        XCTAssertEqual(saved.repo, RepoLease.normalize(repo))
        XCTAssertEqual(saved.ownerRunnerID, "kimi.code")
    }

    func testCheckpointKeepsTaskProjectWhileReadingWorktreeEvidence() throws {
        let evidence = URL(fileURLWithPath: workspace).appendingPathComponent("docs/evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: evidence.appendingPathComponent("front.png"))
        try git(["add", "."], in: workspace)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-m", "evidence"], in: workspace)
        var task = WorkTask(id: "source", prompt: "制作样板", repo: repo)
        task.state = .running
        task.branch = "agent/kimi/sample"
        let progress = WorkProgress(taskID: task.id, sequence: 1, phase: "M0",
            summary: "三机位", evidence: ["docs/evidence/front.png"], evidenceFingerprint: "fp",
            requestedMinutes: 20, updatedAt: Date())
        let item = try XCTUnwrap(Milestone.recordCheckpoint(task: task, progress: progress, repo: workspace))
        XCTAssertEqual(item.repo, RepoLease.normalize(repo))
        XCTAssertEqual(item.repoName, "Flint")
        XCTAssertEqual(item.taskID, task.id)
        XCTAssertEqual(item.phase, "M0")
        XCTAssertEqual(item.evidenceFiles.count, 1)
    }

    func testBrokenWorktreeMetadataDoesNotMatchFocusedRepo() throws {
        let broken = sandbox.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("gitdir: /missing/repository\n".utf8).write(to: broken.appendingPathComponent(".git"))
        XCTAssertFalse(ProjectExecutionScope(allowedRepo: repo).allows(broken.path))
    }

    func testQueuedIdentityRepairPreservesOwnerAndSkipsClaimedOrFrozenTasks() throws {
        let scope = ProjectExecutionScope(allowedRepo: repo)
        var legacy = WorkTask(id: "legacy", prompt: "【看效果】当前证据", repo: workspace)
        legacy.ownerRunnerID = "minimax.code"
        legacy.branch = "agent/minimax/legacy"
        legacy.intakeKey = "milestone-eyes:abc"
        _ = try TaskStore.create(legacy, actor: "test", reason: "旧版记录")
        var claimed = WorkTask(id: "claimed", prompt: "已领取", repo: workspace)
        claimed.dispatchLeaseID = "lease"
        var running = WorkTask(id: "running", prompt: "执行中", repo: workspace)
        running.state = .running
        var frozen = WorkTask(id: "frozen", prompt: "冻结历史", repo: workspace)
        frozen.state = .blocked
        frozen.pausedAt = Date()
        let outside = WorkTask(id: "outside", prompt: "另一项目", repo: repo + "-other/")
        for task in [claimed, running, frozen, outside] {
            _ = try TaskStore.create(task, actor: "test", reason: "不该改动")
        }
        XCTAssertEqual(try TaskIntake.reconcileQueuedRepos(scope: scope), 1)
        let saved = try XCTUnwrap(TaskStore.all().first { $0.id == legacy.id })
        XCTAssertEqual(saved.repo, RepoLease.normalize(repo))
        XCTAssertEqual(saved.rev, 1)
        XCTAssertEqual(saved.state, .queued)
        XCTAssertEqual(saved.ownerRunnerID, legacy.ownerRunnerID)
        XCTAssertEqual(saved.branch, legacy.branch)
        XCTAssertEqual(saved.prompt, legacy.prompt)
        XCTAssertEqual(saved.intakeKey, legacy.intakeKey)
        XCTAssertTrue(saved.transitionReason?.contains("归一工作副本项目身份") == true)
        for original in [claimed, running, frozen, outside] {
            let untouched = try XCTUnwrap(TaskStore.all().first { $0.id == original.id })
            XCTAssertEqual(untouched.rev, 0)
            XCTAssertEqual(untouched.repo, original.repo)
        }
        XCTAssertEqual(try TaskIntake.reconcileQueuedRepos(scope: scope), 0,
                       "下一轮不可重复写账或消耗模型额度")
    }

    func testEvidenceCacheRefreshPreservesQueuedReviewReferencesIncludingSpaces() throws {
        let dir = Review.evidenceDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = "/Application Support/worktrees/flint-kimi|agent/kimi/sample"
        let name = Review.evidencePrefix(digestID: digest, revision: "old") + "front.jpg"
        let file = dir.appendingPathComponent(name)
        try Data("old review fixture".utf8).write(to: file)
        let task = WorkTask(id: "old-review", prompt: """
        【看效果】阶段证据
        文件（都在 \(dir.path) 下）：
          - \(name)
        """, repo: repo)
        _ = try TaskStore.create(task, actor: "test", reason: "等待消费旧图")
        XCTAssertEqual(MiniMaxMediaRunner.visualFiles(in: task.prompt), [file.path])
        // 后续纯文档提交没有新图片：空 expected 也不能清掉前一轮排队证据。
        _ = Review.extractEvidence(repo: workspace, branch: "HEAD", files: [],
                                   digestID: digest, revision: "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // 非缓存路径（转换失败）也必须保护已有引用。
        _ = Review.extractEvidence(repo: workspace, branch: "HEAD", files: ["missing.png"],
                                   digestID: digest, revision: "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
