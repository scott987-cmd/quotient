import XCTest
@testable import LLMQuotaCore

final class LifecycleIsolationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Watchdog.resetForTesting()
        PublicationGeneration.resetForTesting()
    }

    override func tearDown() {
        PublicationGeneration.resetForTesting()
        Paths.appSupportOverride = nil
        super.tearDown()
    }

    func testDetachedExecutorUsesOneShotIndependentLaunchdJob() throws {
        let spec = DetachedExecutorSpec(
            taskID: "task-1", repo: "/dev/Flint", leaseID: "lease-1",
            executable: "/opt/llmq", logPath: "/tmp/task-1.log")

        XCTAssertEqual(spec.label, "com.llmquotabar.executor.task-1.lease-1")
        let data = try DetachedExecutorLauncher.propertyListData(for: spec)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String], [
            "LLMQ_SLOT_CHILD": "1",
        ])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            "/opt/llmq", "work", "run", "task-1", "--slot-child",
            "--dispatch-lease", "lease-1",
        ])
        XCTAssertEqual(
            DetachedExecutorLauncher.bootstrapArguments(plistPath: "/tmp/job.plist"),
            ["bootstrap", "gui/\(getuid())", "/tmp/job.plist"])
    }

    func testFinishedExecutorJobIsBootedOutAndRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-executor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        Paths.appSupportOverride = root
        var calls: [[String]] = []
        let launcher = DetachedExecutorLauncher { arguments in
            calls.append(arguments)
            return 0
        }
        let spec = DetachedExecutorSpec(
            taskID: "task-1", repo: "/dev/Flint", leaseID: "lease-1",
            executable: "/opt/llmq", logPath: root.appendingPathComponent("task.log").path)
        XCTAssertTrue(try launcher.launch(spec))
        var task = WorkTask(id: "task-1", prompt: "done", repo: "/dev/Flint")
        task.state = .done

        XCTAssertEqual(launcher.cleanupFinished(tasks: [task]), 1)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].prefix(2), ["bootstrap", "gui/\(getuid())"])
        XCTAssertEqual(calls[1], ["bootout", "gui/\(getuid())/\(spec.label)"])
        let jobs = root.appendingPathComponent("executor-jobs")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: jobs.path)) ?? [], [])
    }

    func testRunningExecutorAndPendingDispatchSurviveCoordinatorGeneration() {
        var running = WorkTask(id: "running", prompt: "run", repo: "/dev/A")
        running.state = .running
        running.runnerPID = 42
        var pending = WorkTask(id: "pending", prompt: "pending", repo: "/dev/B")
        pending.dispatchLeaseID = "lease"
        pending.dispatchLeaseExpiresAt = Date(timeIntervalSince1970: 200)
        let active = DetachedExecutorRegistry.active(
            tasks: [running, pending], now: Date(timeIntervalSince1970: 100),
            processIsAlive: { $0 == 42 })

        XCTAssertEqual(Set(active.map(\.taskID)), ["running", "pending"])
        XCTAssertEqual(Set(active.map(\.repo)), ["/dev/A", "/dev/B"])
    }

    func testMigrationOnlyRestartsWorkerForLaunchdOwnedExecutor() {
        var task = WorkTask(id: "running", prompt: "run", repo: "/dev/A")
        task.state = .running
        task.runnerPID = 42
        XCTAssertTrue(DetachedExecutorRegistry.isIndependent(task, parentPID: { _ in 1 }))
        XCTAssertFalse(DetachedExecutorRegistry.isIndependent(task, parentPID: { _ in 900 }))
    }

    func testSupersededProjectorCannotPublish() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        Paths.appSupportOverride = root

        let old = try PublicationGeneration.activate(role: .projector, pid: 11)
        XCTAssertTrue(old.isCurrent)
        let current = try PublicationGeneration.activate(role: .projector, pid: 22)

        XCTAssertFalse(old.isCurrent)
        XCTAssertTrue(current.isCurrent)
        XCTAssertFalse(old.commitIfCurrent { XCTFail("旧投影器不得提交") })
        var committed = false
        XCTAssertTrue(current.commitIfCurrent { committed = true })
        XCTAssertTrue(committed)
    }

    func testTimedOutPreparationCannotCommitLateResult() {
        let committed = expectation(description: "late body returned")
        committed.isInverted = true
        let result = Watchdog.runLatest(
            "late", timeout: 0.05,
            prepare: {
                Thread.sleep(forTimeInterval: 0.2)
                return 7
            },
            commit: { _ in committed.fulfill() })

        guard case .timedOut = result else {
            return XCTFail("慢操作必须超时")
        }
        wait(for: [committed], timeout: 0.35)
    }

    func testControlPlaneSwapDoesNotWaitForDetachedExecutor() {
        XCTAssertTrue(BinarySwap.shouldExitCoordinator(changed: true))
        XCTAssertFalse(BinarySwap.shouldExitCoordinator(changed: false))
    }

    func testCoordinatorOwnsNeitherExecutorProcessNorProjectorTimer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent(
            "Sources/llmq/main.swift"), encoding: .utf8)
        let loopStart = try XCTUnwrap(main.range(of: "func cmdWorkLoop("))
        let projectorStart = try XCTUnwrap(main.range(of: "func cmdWorkProjector("))
        let loop = main[loopStart.lowerBound..<projectorStart.lowerBound]

        XCTAssertTrue(loop.contains("DetachedExecutorLauncher()"))
        XCTAssertFalse(loop.contains("LocalWorkerProcessPool()"))
        XCTAssertFalse(loop.contains("Showcase.trigger"))
        XCTAssertTrue(loop.contains("LLMQuota.collect(publishViews: false)"))
        XCTAssertTrue(main.contains("com.llmquotabar.projector"))
    }
}
