import XCTest
@testable import LLMQuotaCore

final class LocalWorkerPoolTests: XCTestCase {
    private func task(_ id: String, repo: String,
                      state: WorkTask.State = .queued) -> WorkTask {
        var task = WorkTask(id: id, prompt: "task \(id)", repo: repo)
        task.state = state
        return task
    }

    func testMacMiniDefaultsToTwoSlotsAndOtherMacsStayAtOne() {
        XCTAssertEqual(LocalWorkerSlotPlanner.defaultSlots(
            machineName: "杜师兵的Mac mini"), 2)
        XCTAssertEqual(LocalWorkerSlotPlanner.defaultSlots(
            machineName: "杜师兵的MacBook Pro"), 1)
    }

    func testStandaloneUERequiresUnrealCapabilityAndExclusiveEditor() {
        let requirements = TaskResourcePolicy.infer(
            prompt: "在 M2 上用 UE 重新制作 Flint 场景")

        XCTAssertTrue(requirements.capabilities.contains("tool:unreal"))
        XCTAssertTrue(requirements.claims.contains("tool:unreal-editor"))
    }

    func testQueueTextDoesNotAccidentallyRequireUnreal() {
        let requirements = TaskResourcePolicy.infer(
            prompt: "修复任务队列 queue 卡住的问题")

        XCTAssertFalse(requirements.capabilities.contains("tool:unreal"))
        XCTAssertFalse(requirements.claims.contains("tool:unreal-editor"))
    }

    func testPublishedCapacityUsesActualLiveCoordinatorSlots() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-capacity-\(UUID().uuidString)")
        defer {
            WorkerCapacityStore.fileOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WorkerCapacityStore.fileOverride = root.appendingPathComponent("capacity.json")
        WorkerCapacityStore.publish(maxConcurrentTasks: 4, coordinatorPID: getpid())
        XCTAssertEqual(WorkerCapacityStore.current(), 4)
        let future = Date().addingTimeInterval(121)
        XCTAssertNil(WorkerCapacityStore.current(now: future),
                     "活着但已停止心跳的协调器不能继续发布执行容量")
        WorkerCapacityStore.publish(maxConcurrentTasks: 4, coordinatorPID: 999_999)
        XCTAssertNil(WorkerCapacityStore.current(), "死亡协调器留下的容量不能继续参与跨机选路")
    }

    func testTwoDifferentReposCanFillTwoSlots() {
        let a = task("a", repo: "/dev/A")
        let b = task("b", repo: "/dev/B")
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [a, b], allTasks: [a, b], active: [],
            maxConcurrentTasks: 2).map(\.id), ["a", "b"])
    }

    func testDifferentReposStillSerializeWhenTheyClaimSameExclusiveTool() {
        var a = task("a", repo: "/dev/A")
        var b = task("b", repo: "/dev/B")
        a.resourceClaims = ["tool:unreal-editor"]
        b.resourceClaims = ["tool:unreal-editor"]
        let plan = LocalWorkerSlotPlanner.plan(
            ready: [a, b], allTasks: [a, b], active: [], maxConcurrentTasks: 2)

        XCTAssertEqual(plan.selected.map(\.id), ["a"])
        XCTAssertTrue(plan.decisions.first { $0.taskID == "b" }?.reason
            .contains("资源") == true)
    }

    func testSameRepoStillUsesOnlyOneSlot() {
        let a = task("a", repo: "/dev/A")
        let b = task("b", repo: "/dev/A/")
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [a, b], allTasks: [a, b], active: [],
            maxConcurrentTasks: 2).map(\.id), ["a"])
    }

    func testManualRunningTaskConsumesCapacityAndItsRepo() {
        let running = task("running", repo: "/dev/A", state: .running)
        let same = task("same", repo: "/dev/A")
        let other = task("other", repo: "/dev/B")
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [same, other], allTasks: [running, same, other], active: [],
            maxConcurrentTasks: 2).map(\.id), ["other"])
    }

    func testJustLaunchedChildReservesSlotBeforeTaskStoreCatchesUp() {
        let a = task("a", repo: "/dev/A")
        let b = task("b", repo: "/dev/B")
        let active = [LocalWorkerSlotPlanner.Active(taskID: "a", repo: "/dev/A")]
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [a, b], allTasks: [a, b], active: active,
            maxConcurrentTasks: 2).map(\.id), ["b"])
    }

    func testTaskWaitsForItsBusyOwnerInsteadOfChangingAgent() {
        var running = task("running", repo: "/dev/A", state: .running)
        running.ownerRunnerID = "minimax.code"
        var sameOwner = task("same-owner", repo: "/dev/B")
        sameOwner.ownerRunnerID = "minimax.code"
        let independent = task("independent", repo: "/dev/C")
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [sameOwner, independent],
            allTasks: [running, sameOwner, independent], active: [],
            maxConcurrentTasks: 2).map(\.id), ["independent"])
    }

    func testTwoQueuedTasksWithSameOwnerDoNotStartTogether() {
        var first = task("first", repo: "/dev/A")
        first.ownerRunnerID = "minimax.code"
        var second = task("second", repo: "/dev/B")
        second.ownerRunnerID = "minimax.code"
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [first, second], allTasks: [first, second], active: [],
            maxConcurrentTasks: 2).map(\.id), ["first"])
    }

    func testPlanPersistsReasonsForSelectedAndRejectedCandidates() {
        var running = task("running", repo: "/dev/A", state: .running)
        running.ownerRunnerID = "kimi.code"
        var busyOwner = task("owner", repo: "/dev/B")
        busyOwner.ownerRunnerID = "kimi.code"
        let busyRepo = task("repo", repo: "/dev/A")
        let selected = task("selected", repo: "/dev/C")
        let plan = LocalWorkerSlotPlanner.plan(
            ready: [busyOwner, busyRepo, selected],
            allTasks: [running, busyOwner, busyRepo, selected], active: [],
            maxConcurrentTasks: 2)

        XCTAssertEqual(plan.selected.map(\.id), ["selected"])
        XCTAssertEqual(plan.decisions.map(\.taskID), ["owner", "repo", "selected"])
        XCTAssertTrue(plan.decisions.first { $0.taskID == "owner" }!.reason
            .contains("原 Owner"))
        XCTAssertTrue(plan.decisions.first { $0.taskID == "repo" }!.reason
            .contains("同项目"))
        XCTAssertEqual(plan.decisions.first { $0.taskID == "selected" }?.selected, true)
    }

    func testSchedulerSnapshotRoundTripsSelectionAndConfigVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-snapshot-\(UUID().uuidString)")
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        Paths.appSupportOverride = root
        let ready = [task("a", repo: "/dev/A"), task("b", repo: "/dev/B")]
        let plan = LocalWorkerSlotPlanner.plan(
            ready: ready, allTasks: ready, active: [], maxConcurrentTasks: 1)
        let snapshot = SchedulerSnapshot(
            scope: ProjectExecutionScope(allowedRepo: "/dev/A"),
            ready: ready, active: [], plan: plan, maxConcurrentTasks: 1,
            machineID: "machine", createdAt: Date(timeIntervalSince1970: 42))
        try SchedulerSnapshotStore.save(snapshot)

        let restored = try XCTUnwrap(SchedulerSnapshotStore.latest())
        XCTAssertEqual(restored.id, snapshot.id)
        XCTAssertEqual(restored.configVersion, snapshot.configVersion)
        XCTAssertEqual(restored.executionMode, .focused)
        XCTAssertEqual(restored.decisions, plan.decisions)
        XCTAssertEqual(restored.ready.map(\.rev), [0, 0])
    }

    func testSchedulerSnapshotExplainsIdleAndWaitingStates() {
        let scope = ProjectExecutionScope(allowedRepo: "/dev/A")
        let emptyPlan = LocalWorkerSlotPlanner.Plan(selected: [], decisions: [])
        let idle = SchedulerSnapshot(
            scope: scope, ready: [], active: [], plan: emptyPlan,
            maxConcurrentTasks: 2, allTasks: [])
        XCTAssertEqual(idle.state, .idle)
        XCTAssertTrue(idle.summary.contains("没有待执行任务"))

        var blocked = task("blocked", repo: "/dev/A", state: .blocked)
        blocked.waitReason = .dependency
        let waiting = SchedulerSnapshot(
            scope: scope, ready: [], active: [], plan: emptyPlan,
            maxConcurrentTasks: 2, allTasks: [blocked])
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertTrue(waiting.summary.contains("门禁") || waiting.summary.contains("依赖"))
    }

    func testSchedulerSnapshotDoesNotCountPausedTasksAsPending() {
        let scope = ProjectExecutionScope(allowedRepo: "/dev/A")
        let emptyPlan = LocalWorkerSlotPlanner.Plan(selected: [], decisions: [])
        var paused = task("paused", repo: "/dev/A", state: .blocked)
        paused.pausedAt = Date(timeIntervalSince1970: 42)

        let snapshot = SchedulerSnapshot(
            scope: scope, ready: [], active: [], plan: emptyPlan,
            maxConcurrentTasks: 2, allTasks: [paused])

        XCTAssertEqual(snapshot.pendingTaskCount, 0)
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertTrue(snapshot.summary.contains("没有待执行任务"))
    }

    func testSchedulerSnapshotJournalOnlyAppendsMeaningfulTransitions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-snapshot-transitions-\(UUID().uuidString)")
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        Paths.appSupportOverride = root
        let scope = ProjectExecutionScope(allowedRepo: "/dev/A")
        let plan = LocalWorkerSlotPlanner.Plan(selected: [], decisions: [])
        let first = SchedulerSnapshot(
            scope: scope, ready: [], active: [], plan: plan,
            maxConcurrentTasks: 1, allTasks: [],
            createdAt: Date(timeIntervalSince1970: 10))
        let heartbeat = SchedulerSnapshot(
            scope: scope, ready: [], active: [], plan: plan,
            maxConcurrentTasks: 1, allTasks: [],
            createdAt: Date(timeIntervalSince1970: 20))
        try SchedulerSnapshotStore.save(first)
        try SchedulerSnapshotStore.save(heartbeat)

        XCTAssertEqual(SchedulerSnapshotStore.latest()?.createdAt,
                       Date(timeIntervalSince1970: 20),
                       "current 快照仍要每轮刷新心跳")
        let unchangedLines = try Data(contentsOf: SchedulerSnapshotStore.file)
            .split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(unchangedLines.count, 1,
                       "状态没变不能每几秒向审计账本追加一行")

        let changed = SchedulerSnapshot(
            scope: scope, ready: [task("next", repo: "/dev/A")], active: [],
            plan: LocalWorkerSlotPlanner.Plan(
                selected: [], decisions: [.init(
                    taskID: "next", selected: false, reason: "执行槽已满")]),
            maxConcurrentTasks: 1, allTasks: [task("next", repo: "/dev/A")],
            createdAt: Date(timeIntervalSince1970: 30))
        try SchedulerSnapshotStore.save(changed)
        let changedLines = try Data(contentsOf: SchedulerSnapshotStore.file)
            .split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(changedLines.count, 2)
    }

    func testJustLaunchedChildReservesItsOwnerBeforeRunningStateIsWritten() {
        var first = task("first", repo: "/dev/A")
        first.ownerRunnerID = "minimax.code"
        var second = task("second", repo: "/dev/B")
        second.ownerRunnerID = "minimax.code"
        let active = [LocalWorkerSlotPlanner.Active(taskID: "first", repo: "/dev/A")]
        XCTAssertTrue(LocalWorkerSlotPlanner.select(
            ready: [first, second], allTasks: [first, second], active: active,
            maxConcurrentTasks: 2).isEmpty)
    }

    func testKernelLeaseRejectsSameKeyButAllowsDifferentKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalExecutionLease(scope: .runner, key: "minimax.code", root: root)
        let duplicate = LocalExecutionLease(scope: .runner, key: "minimax.code", root: root)
        let other = LocalExecutionLease(scope: .runner, key: "qwen.code", root: root)
        XCTAssertTrue(first.acquire())
        XCTAssertFalse(duplicate.acquire(), "同一个 Agent 不能同时跑两个任务")
        XCTAssertTrue(other.acquire(), "不同 Agent 可以各占一个执行槽")
        first.release()
        XCTAssertTrue(duplicate.acquire(), "上一任务结束后同 Agent 应立即可用")
    }

    func testKernelResourceLeasePreventsPlannerRaceAndManualBypass() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-resource-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let unreal = LocalExecutionLease(
            scope: .resource, key: "tool:unreal-editor", root: root)
        let duplicate = LocalExecutionLease(
            scope: .resource, key: "tool:unreal-editor", root: root)
        let blender = LocalExecutionLease(
            scope: .resource, key: "tool:blender", root: root)

        XCTAssertTrue(unreal.acquire())
        XCTAssertFalse(duplicate.acquire(),
                       "即使绕过调度快照，同一独占工具也不能并发启动")
        XCTAssertTrue(blender.acquire(), "不同独占工具可以并行")
        unreal.release()
        XCTAssertTrue(duplicate.acquire())
    }

    func testProcessPoolRunsChildrenConcurrentlyAndIsolatesFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-pool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = LocalWorkerProcessPool()
        let env = ProcessInfo.processInfo.environment
        try pool.launch(
            taskID: "ok", repo: "/dev/A", executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.15; exit 0"], environment: env,
            logURL: root.appendingPathComponent("ok.log"))
        try pool.launch(
            taskID: "bad", repo: "/dev/B", executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.15; exit 7"], environment: env,
            logURL: root.appendingPathComponent("bad.log"))
        XCTAssertEqual(pool.count, 2)

        let deadline = Date().addingTimeInterval(3)
        var completions: [LocalWorkerProcessPool.Completion] = []
        while completions.count < 2, Date() < deadline {
            completions.append(contentsOf: pool.reap())
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: completions.map {
            ($0.taskID, $0.exitCode)
        }), ["ok": 0, "bad": 7])
        XCTAssertTrue(pool.isEmpty)
    }
}
