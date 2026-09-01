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

    func testTwoDifferentReposCanFillTwoSlots() {
        let a = task("a", repo: "/dev/A")
        let b = task("b", repo: "/dev/B")
        XCTAssertEqual(LocalWorkerSlotPlanner.select(
            ready: [a, b], allTasks: [a, b], active: [],
            maxConcurrentTasks: 2).map(\.id), ["a", "b"])
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
