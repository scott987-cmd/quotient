import XCTest
@testable import LLMQuotaCore

/// 非实现者的隔离验收。只访问每例自己的 temporaryDirectory，不使用生产工作循环。
final class IndependentMobileRoutingTests: XCTestCase {
    private var root: URL!
    private var savedRoot: URL?
    private var savedMachine: String?

    override func setUpWithError() throws {
        savedRoot = Paths.appSupportOverride
        savedMachine = Paths.machineIDOverride
        root = FileManager.default.temporaryDirectory.appendingPathComponent("independent-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root
        Paths.machineIDOverride = "acceptance-a"
    }

    override func tearDownWithError() throws {
        Paths.appSupportOverride = savedRoot
        Paths.machineIDOverride = savedMachine
        try? FileManager.default.removeItem(at: root)
    }

    private func invocation(_ action: String, request: String = UUID().uuidString,
                            machine: String = "acceptance-a") throws -> ViewFeed.Invocation {
        let id = try XCTUnwrap(MobileAction.scoped(action, machineID: machine))
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "invocationID": request,
            "at": "2026-09-03T00:00:00Z", "note": "独立验收隔离操作"])
        return try SnapshotCoding.decoder().decode(ViewFeed.Invocation.self, from: data)
    }

    private func repo() throws -> String {
        let path = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Isolated Acceptance"],
                     ["config", "user.email", "acceptance@example.invalid"],
                     ["commit", "--allow-empty", "-m", "isolated base"],
                     ["branch", "agent/codex/acceptance"]] {
            let result = GitWorkspace.git(args, in: path.path)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }
        return path.path
    }

    func testActualConsumerMissingRepositoryCannotProduceSuccessOrDecision() throws {
        let inv = try invocation("review:merge:" + root.appendingPathComponent("not-mounted").path + "|agent/codex/acceptance|head")
        for expected in ["retrying", "retrying", "failed"] {
            let receipt = MobileAction.process(inv) { MobileAction.execute(inv) }
            XCTAssertEqual(receipt?.state, expected, "缺仓库不是已经合入")
        }
        XCTAssertTrue(Review.decidedBranches().isEmpty)
        let receiptFile = Paths.sharedRoot.appendingPathComponent("action-receipts/" + MobileAction.receiptName(
            actionID: inv.id, invocationID: try XCTUnwrap(inv.invocationID)))
        XCTAssertEqual(SafeDecode.json(at: receiptFile, as: MobileAction.Receipt.self)?.state, "failed")
    }

    func testActualReviewConsumerRejectsWrongMachineAndStaleHeadBeforeDeletingBranch() throws {
        let path = try repo()
        let branch = "agent/codex/acceptance"
        let head = GitWorkspace.git(["rev-parse", branch], in: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stale = try invocation("review:discard:" + path + "|" + branch + "|" + String(repeating: "0", count: 40))
        XCTAssertEqual(MobileAction.execute(stale), false)
        XCTAssertTrue(GitWorkspace.branchExists(branch, in: path), "旧页面不能删除新提交")
        XCTAssertTrue(Review.decidedBranches().isEmpty)
        let current = try invocation("review:discard:" + path + "|" + branch + "|" + head)
        Paths.machineIDOverride = "acceptance-b"
        XCTAssertNil(MobileAction.execute(current))
        XCTAssertTrue(GitWorkspace.branchExists(branch, in: path))
        Paths.machineIDOverride = "acceptance-a"
        XCTAssertEqual(MobileAction.process(current) { MobileAction.execute(current) }?.state, "succeeded")
        XCTAssertFalse(GitWorkspace.branchExists(branch, in: path))
        XCTAssertTrue(Review.isDecided(repo: path, branch: branch, in: Review.decidedBranches()))
        XCTAssertEqual(MobileAction.process(current) { XCTFail("终态不得重执行"); return false }?.state, "succeeded")
    }

    func testInterruptedMergeRecognizesExpectedHeadAlreadyLandedAfterBranchDeletion() throws {
        let path = try repo(), branch = "agent/codex/acceptance"
        XCTAssertEqual(GitWorkspace.git(["checkout", branch], in: path).exitCode, 0)
        let artifact = URL(fileURLWithPath: path).appendingPathComponent("landed.txt")
        try "landed".write(to: artifact, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitWorkspace.git(["add", "landed.txt"], in: path).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["commit", "-m", "land isolated change"], in: path).exitCode, 0)
        let expectedHead = GitWorkspace.git(["rev-parse", "HEAD"], in: path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(GitWorkspace.git(["checkout", "main"], in: path).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["merge", "--no-ff", branch, "-m", "isolated merge"], in: path).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["branch", "-D", branch], in: path).exitCode, 0)

        let inv = try invocation("review:merge:" + path + "|" + branch + "|" + expectedHead)
        XCTAssertEqual(MobileAction.execute(inv), true,
                       "合入成功后若在写回执前中断，重启必须识别该版本已在 main")

        let unrelated = String(repeating: "0", count: 40)
        let stale = try invocation("review:merge:" + path + "|" + branch + "|" + unrelated)
        XCTAssertEqual(MobileAction.execute(stale), false,
                       "分支消失不能单独作为成功依据，必须核对指定提交已在 main")
    }

    func testInterruptedDiscardRecognizesUnlandedExpectedHeadAfterBranchDeletion() throws {
        let path = try repo(), branch = "agent/codex/acceptance"
        XCTAssertEqual(GitWorkspace.git(["checkout", branch], in: path).exitCode, 0)
        try "discarded".write(to: URL(fileURLWithPath: path).appendingPathComponent("discarded.txt"),
                              atomically: true, encoding: .utf8)
        XCTAssertEqual(GitWorkspace.git(["add", "discarded.txt"], in: path).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["commit", "-m", "discard isolated change"], in: path).exitCode, 0)
        let expectedHead = GitWorkspace.git(["rev-parse", "HEAD"], in: path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(GitWorkspace.git(["checkout", "main"], in: path).exitCode, 0)
        XCTAssertEqual(GitWorkspace.git(["branch", "-D", branch], in: path).exitCode, 0)

        let inv = try invocation("review:discard:" + path + "|" + branch + "|" + expectedHead)
        XCTAssertEqual(MobileAction.execute(inv), true,
                       "丢弃成功后若在写回执前中断，重启必须识别该版本未落入 main 且分支已消失")
    }

    func testActualApprovalFailurePreservesBlockedTaskAndCannotReportSuccess() throws {
        let path = try repo()
        var task = WorkTask(id: "missing-isolated-work", prompt: "只用于隔离验收", repo: path)
        task.state = .blocked
        task.note = "碰到高危路径，等你确认"
        // 故意不提供分支，复现 Approval.settle 的失败返回。
        try TaskStore.append(task)
        let current = try XCTUnwrap(TaskStore.all().last { $0.id == task.id })
        let inv = try invocation("task:approve:" + MobileAction.taskResource(current))
        XCTAssertEqual(MobileAction.process(inv) { MobileAction.execute(inv) }?.state, "retrying")
        XCTAssertEqual(TaskStore.all().last { $0.id == task.id }?.state, .blocked)
        XCTAssertTrue(Review.decidedBranches().isEmpty)
    }

    func testInterruptedTaskDiscardRecognizesAlreadyRemovedIsolatedBranch() throws {
        let path = try repo(), branch = "agent/codex/acceptance"
        var task = WorkTask(id: "discarded-isolated-work", prompt: "丢弃高危隔离改动", repo: path)
        task.state = .blocked
        task.waitReason = .humanApproval
        task.note = "碰到高危路径，等你确认"
        task.branch = branch
        try TaskStore.append(task)
        let current = try XCTUnwrap(TaskStore.all().last { $0.id == task.id })
        let inv = try invocation("task:discard:" + MobileAction.taskResource(current))

        // 模拟实际丢弃已经删掉分支，进程却在写任务状态和成功回执前退出。
        XCTAssertEqual(GitWorkspace.git(["branch", "-D", branch], in: path).exitCode, 0)
        XCTAssertFalse(GitWorkspace.branchExists(branch, in: path))
        XCTAssertNil(Review.worktreePath(repo: path, branch: branch))
        XCTAssertTrue(ViewFeed.awaitsBoss(current))
        XCTAssertEqual(MobileAction.execute(inv), true)
        let saved = try XCTUnwrap(TaskStore.all().last { $0.id == task.id })
        XCTAssertEqual(saved.state, .failed)
        XCTAssertNotNil(saved.discardedAt)
        XCTAssertNil(saved.branch)
    }

    func testInterruptedThirdAttemptStopsWithoutFourthExecution() throws {
        let inv = try invocation("playbook:approve:isolated", request: "crashed-three-times")
        let dir = MobileAction.ledger(machineID: "acceptance-a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let receipt = MobileAction.Receipt(actionID: inv.id, invocationID: "crashed-three-times",
            machineID: "acceptance-a", state: "running", message: "interrupted", attempts: 3)
        let name = MobileAction.receiptName(actionID: inv.id, invocationID: "crashed-three-times")
        try SnapshotCoding.prettyEncoder().encode(receipt).write(to: dir.appendingPathComponent(name))
        let result = MobileAction.process(inv) { XCTFail("已中断三次，不能第四次执行"); return true }
        XCTAssertEqual(result?.state, "failed")
        XCTAssertEqual(result?.attempts, 3)
    }

    func testReceiptTerminalContentReplacesSameMtimeRunningAndDoesNotRepush() throws {
        let local = Paths.sharedRoot.appendingPathComponent("action-receipts/isolated.json")
        let cloud = root.appendingPathComponent("isolated-cloud")
        let remote = cloud.appendingPathComponent("action-receipts/isolated.json")
        for url in [local, remote] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let stamp = Date(timeIntervalSince1970: 1000)
        var receipt = MobileAction.Receipt(actionID: "isolated", invocationID: "same-click", machineID: "acceptance-a",
            state: "running", message: "running", updatedAt: stamp, attempts: 1)
        try SnapshotCoding.prettyEncoder().encode(receipt).write(to: remote)
        receipt.state = "succeeded"; receipt.message = "succeeded"
        let final = try SnapshotCoding.prettyEncoder().encode(receipt)
        try final.write(to: local)
        for url in [local, remote] { try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path) }
        _ = MirrorService.sync(local: Paths.sharedRoot, cloud: cloud, selfMachineID: "acceptance-a")
        XCTAssertEqual(try Data(contentsOf: remote), final, "同mtime的执行终态必须替换running")
        let savedDate = try remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = MirrorService.sync(local: Paths.sharedRoot, cloud: cloud, selfMachineID: "acceptance-a")
        XCTAssertEqual(second.pushed, 0, "相同回执不能每轮重复推送")
        XCTAssertEqual(try remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, savedDate)
    }

    func testUnversionedLegacyRequestFailsWithoutExecutingAndLeavesReadableReceipt() throws {
        let inv = try invocation("task:approve:old-task")
        let receipt = MobileAction.process(inv) { XCTFail("无版本旧请求不可作用到新版任务"); return true }
        XCTAssertEqual(receipt?.state, "failed")
        XCTAssertTrue(receipt?.message.contains("版本") == true)
        XCTAssertEqual(MobileAction.execute(inv), false)
    }

    func testCompletedResourceRejectsOppositeDecisionButNewRevisionCanExecute() throws {
        let first = try invocation("review:merge:/tmp/isolated|same|old-head")
        XCTAssertEqual(MobileAction.process(first) { true }?.state, "succeeded")
        let opposite = try invocation("review:discard:/tmp/isolated|same|old-head")
        XCTAssertEqual(MobileAction.process(opposite) { XCTFail("同版本相反决定不能执行"); return true }?.state, "failed")
        let next = try invocation("review:discard:/tmp/isolated|same|new-head")
        XCTAssertEqual(MobileAction.process(next) { true }?.state, "succeeded")
    }

    func testNewRoutedRequestIgnoresOldSharedDoneLedger() throws {
        let inv = try invocation("review:merge:/tmp/isolated|same|head")
        let directory = Paths.sharedRoot.appendingPathComponent("actions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SnapshotCoding.prettyEncoder().encode(inv).write(to: directory.appendingPathComponent("request.json"))
        try inv.key.write(to: directory.appendingPathComponent(".done"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ViewFeed.pendingInvocations().map(\.id), [inv.id])
    }

    func testPendingInvocationsSkipsOtherMachinesAndLocallyTerminalRequests() throws {
        let ownPending = try invocation("playbook:approve:own|v1", request: "own-pending")
        let ownDone = try invocation("playbook:approve:done|v1", request: "own-done")
        let other = try invocation("playbook:approve:other|v1", request: "other", machine: "acceptance-b")
        let directory = Paths.sharedRoot.appendingPathComponent("actions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, inv) in [ownPending, ownDone, other].enumerated() {
            try SnapshotCoding.prettyEncoder().encode(inv)
                .write(to: directory.appendingPathComponent("request-\(index).json"))
        }
        let ledger = MobileAction.ledger(machineID: "acceptance-a")
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        let terminal = MobileAction.Receipt(
            actionID: ownDone.id, invocationID: try XCTUnwrap(ownDone.invocationID),
            machineID: "acceptance-a", state: "succeeded", message: "done", attempts: 1)
        let terminalName = MobileAction.receiptName(
            actionID: ownDone.id, invocationID: try XCTUnwrap(ownDone.invocationID))
        try SnapshotCoding.prettyEncoder().encode(terminal)
            .write(to: ledger.appendingPathComponent(terminalName))

        XCTAssertEqual(ViewFeed.pendingInvocations().map(\.id), [ownPending.id],
                       "每台 Mac 只应扫描自己的未完成动作，终态不能每轮重复发布")
    }

    func testActualDiscardFailureCannotMarkCheckedOutBranchDecided() throws {
        let path = try repo(), branch = "agent/codex/acceptance"
        XCTAssertEqual(GitWorkspace.git(["checkout", branch], in: path).exitCode, 0)
        let head = GitWorkspace.git(["rev-parse", "HEAD"], in: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let inv = try invocation("review:discard:" + path + "|" + branch + "|" + head)
        XCTAssertEqual(MobileAction.execute(inv), false)
        XCTAssertTrue(GitWorkspace.branchExists(branch, in: path))
        XCTAssertTrue(Review.decidedBranches().isEmpty)
    }

    func testActualProducerMirrorAndConsumerHonorRevisionAndMachine() throws {
        var project = Playbook.Project(id: "isolated-project", name: "独立验收方案", brief: "版本一")
        Playbook.save([project])
        XCTAssertTrue(ViewFeed.publish(ViewFeed.playbookPage()))
        let source = NotificationDetail.sourcePage("playbook", machineID: "acceptance-a")
        let cloud = root.appendingPathComponent("isolated-cloud")
        _ = MirrorService.sync(local: Paths.sharedRoot, cloud: cloud, selfMachineID: "acceptance-a")
        let page = try XCTUnwrap(SafeDecode.json(at: cloud.appendingPathComponent("views/" + source + ".json"), as: ViewFeed.Page.self))
        let action = try XCTUnwrap(page.sections.flatMap { $0.cards ?? [] }.flatMap(\.actions).first)
        let original = try XCTUnwrap(MobileAction.route(action.id))
        XCTAssertEqual(original.scope, MobileAction.digest("acceptance-a"))
        // 旧 CLI 的第一段 switch 不认识 machine，因此不能执行这个新版动作。
        XCTAssertFalse(["review", "task", "playbook", "milestone"].contains(String(action.id.split(separator: ":")[0])))
        let stale = try invocation(original.actionID)
        project.brief = "版本二"
        Playbook.save([project])
        XCTAssertEqual(MobileAction.execute(stale), false)
        XCTAssertNil(Playbook.all().first?.approvedAt)
        let current = try invocation("playbook:approve:" + MobileAction.playbookResource(project))
        Paths.machineIDOverride = "acceptance-b"
        XCTAssertNil(MobileAction.process(current) { MobileAction.execute(current) })
        XCTAssertNil(Playbook.all().first?.approvedAt)
        Paths.machineIDOverride = "acceptance-a"
        XCTAssertEqual(MobileAction.process(current) { MobileAction.execute(current) }?.state, "succeeded")
        XCTAssertNotNil(Playbook.all().first?.approvedAt)
        _ = MirrorService.sync(local: Paths.sharedRoot, cloud: cloud, selfMachineID: "acceptance-a")
        let name = MobileAction.receiptName(actionID: current.id, invocationID: try XCTUnwrap(current.invocationID))
        let receipt = try XCTUnwrap(SafeDecode.json(at: cloud.appendingPathComponent("action-receipts/" + name), as: MobileAction.Receipt.self))
        XCTAssertEqual(receipt.state, "succeeded")
        XCTAssertEqual(receipt.actionID, current.id)
        XCTAssertEqual(receipt.machineID, "acceptance-a")
    }
}
