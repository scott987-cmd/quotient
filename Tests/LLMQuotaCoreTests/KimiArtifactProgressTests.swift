import XCTest
@testable import LLMQuotaCore

final class KimiArtifactProgressTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var home: URL!
    private var session: URL!
    private var outputs: URL!
    private var started: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-qa-\(UUID())")
        workspace = root.appendingPathComponent("repo")
        home = root.appendingPathComponent("kimi")
        session = home.appendingPathComponent("sessions/workspace/session-current")
        outputs = root.appendingPathComponent("outputs")
        for p in [workspace!, session!, outputs!] {
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        }
        try json(["cwd": workspace.path, "archived": false], to: session.appendingPathComponent("state.json"))
        try json(["workDir": workspace.path, "sessionDir": session.path], to: home.appendingPathComponent("session_index.jsonl"))
        started = Date().addingTimeInterval(-30)
    }

    override func tearDownWithError() throws {
        WorkProgressStore.dirOverride = nil
        try FileManager.default.removeItem(at: root)
    }

    private func json(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: path)
    }
    private func monitor() -> KimiArtifactProgress {
        KimiArtifactProgress(workspace: workspace.path, startedAt: started,
                             kimiHome: home, artifactRoots: [outputs], pollInterval: 0)
    }
    private func event(_ type: String, id: String = "tool-1", agent: String = "child",
                       time: Date = Date(), fields: [String: Any]) throws {
        let wire = session.appendingPathComponent("agents/\(agent)/wire.jsonl")
        try FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        var e: [String: Any] = ["type": type, "toolCallId": id]
        e.merge(fields) { _, new in new }
        var data = try JSONSerialization.data(withJSONObject: ["type": "context.append_loop_event",
            "time": time.timeIntervalSince1970 * 1_000, "event": e])
        data.append(10)
        if !FileManager.default.fileExists(atPath: wire.path) { try Data().write(to: wire) }
        let handle = try FileHandle(forWritingTo: wire)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func call(_ path: URL, id: String = "tool-1", agent: String = "child", time: Date = Date()) throws {
        try event("tool.call", id: id, agent: agent, time: time,
                  fields: ["name": "Bash", "args": ["command": "blender --report '\(path.path)'"]])
    }
    private func done(id: String = "tool-1", agent: String = "child", error: Bool = false) throws {
        try event("tool.result", id: id, agent: agent, fields: ["result": ["output": "finished", "isError": error]])
    }

    func testChildReportOutsideGitRenewsAndProjectsWithoutCompletingTask() throws {
        let m = monitor(), path = outputs.appendingPathComponent("candidate-report.json")
        try call(path)
        XCTAssertEqual(m.poll(), [])
        try json(["worstStretch": 40.5, "accepted": false], to: path)
        try done()
        let evidence = m.poll()
        XCTAssertEqual(evidence, [path.resolvingSymlinksInPath().path])
        XCTAssertEqual(m.poll(), [], "同一份报告只能消费一次")

        XCTAssertEqual(Proc.run("/usr/bin/git", ["init"], cwd: workspace.path, env: [:], timeout: 10).exitCode, 0)
        WorkProgressStore.dirOverride = root.appendingPathComponent("progress")
        let old = try WorkProgressStore.record(taskID: "task", phase: "制作", summary: "初始",
            nextStep: "继续修复", evidence: [], requestedMinutes: 20, repo: workspace.path)
        let lease = ExecutionLeaseGate(taskID: "task", baselineFingerprint: old.evidenceFingerprint, existing: old)
        let progress = try WorkProgressStore.record(taskID: "task", phase: "子任务产物已更新",
            summary: "候选未验收", nextStep: nil, evidence: evidence, requestedMinutes: 20,
            repo: workspace.path, automatic: true)
        XCTAssertNotNil(lease.renewal(progress: progress))
        XCTAssertNil(lease.renewal(progress: progress))
        XCTAssertEqual(progress.explicitNextStep, "继续修复")
        XCTAssertEqual(progress.checkpointAt, progress.updatedAt)
        var task = WorkTask(id: "task", prompt: "制作", repo: workspace.path)
        task.state = .running; task.startedAt = started; task.ownerRunnerID = "kimi.code"
        let brief = try XCTUnwrap(TaskBoard.build(from: [task], machineName: "QA",
            progressByTaskID: [task.id: progress]).tasks.first)
        XCTAssertEqual(brief.progressPhase, "子任务产物已更新")
        XCTAssertEqual(brief.ownerRunnerID, "kimi.code")
        XCTAssertNil(WorkProgressSentinel.finding(for: task, progress: progress))
        XCTAssertEqual(task.state, .running)
    }

    func testReadTouchAndWaitingAreNotProgressButContentChangeIs() throws {
        let path = outputs.appendingPathComponent("existing.json")
        try json(["version": 1], to: path)
        let m = monitor()
        try call(path); try done()
        XCTAssertEqual(m.poll(), [])
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        try event("step.end", fields: ["finishReason": "tool_use"])
        XCTAssertEqual(m.poll(), [], "mtime 和等待活动不能续期")
        try json(["version": 2], to: path)
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path])
        try json(["version": 1], to: path)
        XCTAssertEqual(m.poll(), [], "回到已经见过的内容也不能重复续期")
    }

    func testHistoricalEventsAndOldAttemptsAreIgnored() throws {
        let path = outputs.appendingPathComponent("old.json")
        try call(path); try json(["old": true], to: path); try done()
        let m = monitor()
        XCTAssertEqual(m.poll(), [])
        try call(path, id: "late", time: started.addingTimeInterval(-1))
        try json(["old": false], to: path); try done(id: "late")
        XCTAssertEqual(m.poll(), [], "上轮迟到事件不能恢复本轮租约")
    }

    func testFailedToolAndWrongAgentResultAreIgnored() throws {
        let m = monitor(), path = outputs.appendingPathComponent("bad.json")
        try call(path)
        XCTAssertEqual(m.poll(), [])
        try json(["partial": true], to: path)
        try done(agent: "other-child")
        XCTAssertEqual(m.poll(), [], "不同 agent 的同名 tool ID 不得配对")
        try done(error: true)
        XCTAssertEqual(m.poll(), [])
    }

    func testFailedRewriteOfPreviouslySuccessfulArtifactDoesNotRenew() throws {
        let m = monitor(), path = outputs.appendingPathComponent("rewrite.json")
        try call(path); try json(["revision": 1], to: path); try done()
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path])
        try call(path, id: "failed-rewrite")
        XCTAssertEqual(m.poll(), [])
        try json(["revision": 2, "partial": true], to: path)
        XCTAssertEqual(m.poll(), [], "工具尚未成功返回时，旧产物不能代替新结果续期")
        try done(id: "failed-rewrite", error: true)
        XCTAssertEqual(m.poll(), [], "先前成功过的文件再次写入失败，也不能当作进展")
        try call(path, id: "recovered")
        try json(["revision": 3], to: path); try done(id: "recovered")
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path])
    }

    func testOtherWorkspaceAndPathEscapeAreIgnored() throws {
        try json(["cwd": root.path, "archived": false], to: session.appendingPathComponent("state.json"))
        let m = monitor(), path = outputs.appendingPathComponent("other.json")
        try call(path); try json(["other": true], to: path); try done()
        XCTAssertEqual(m.poll(), [])
        try json(["cwd": workspace.path, "archived": false], to: session.appendingPathComponent("state.json"))
        let n = monitor()
        let outside = root.appendingPathComponent("outside.json")
        let escape = outputs.appendingPathComponent("escape.json")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        try call(escape, id: "escape"); try json(["private": true], to: outside); try done(id: "escape")
        XCTAssertEqual(n.poll(), [])
    }

    func testResultPathsDiscoverFastNewReportsAndIgnoreSameContentCopies() throws {
        let m = monitor()
        try event("tool.call", fields: ["name": "render_blend", "args": ["mesh": "Cloth"]])
        let path = outputs.appendingPathComponent("render.json")
        try json(["report": "new"], to: path)
        try event("tool.result", fields: ["result": ["report_path": path.path]])
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path])
        let copy = outputs.appendingPathComponent("copy.json")
        try call(copy, id: "copy"); try Data(contentsOf: path).write(to: copy); try done(id: "copy")
        XCTAssertEqual(m.poll(), [], "复制相同内容不算新进展")
    }

    func testCoordinatorTracksOnlyCurrentOwnerAttemptAndStopsAtTerminalState() throws {
        let coordinator = KimiArtifactProgressCoordinator(kimiHome: home, artifactRoots: [outputs], pollInterval: 0)
        var task = WorkTask(id: "task", prompt: "制作", repo: workspace.path)
        task.state = .running; task.platform = .kimi; task.ownerRunnerID = "kimi.code"; task.runnerPID = 123
        var attempt = WorkAttempt(attemptID: "attempt-A", taskID: task.id, runnerID: "kimi.code",
            platform: .kimi, startedAt: started, outcome: .running, timedOut: false)
        func poll() -> [KimiArtifactProgressCoordinator.Observation] {
            coordinator.poll(tasks: [task], attempts: [attempt]) { _ in self.workspace.path }
        }
        XCTAssertEqual(poll().count, 0)
        let path = outputs.appendingPathComponent("current.json")
        try call(path); try json(["new": 1], to: path); try done()
        let observation = try XCTUnwrap(poll().first)
        XCTAssertEqual(observation.attemptID, "attempt-A")
        XCTAssertEqual(observation.runnerPID, 123)
        XCTAssertEqual(observation.runnerID, "kimi.code")

        attempt.attemptID = "attempt-B"
        XCTAssertEqual(poll().count, 0, "切换轮次不能搬运 A 的已注册证据")
        try json(["new": 2], to: path)
        XCTAssertEqual(poll().count, 0)
        attempt.runnerID = "other-owner"
        try call(path, id: "wrong-owner"); try done(id: "wrong-owner")
        XCTAssertEqual(poll().count, 0)
        attempt.runnerID = "kimi.code"; task.state = .done
        XCTAssertEqual(poll().count, 0, "结束任务不得被观察器复活")
    }

    func testLongSessionContinuesAfterArtifactCacheFills() throws {
        let m = monitor()
        for i in 0..<130 {
            let path = outputs.appendingPathComponent("candidate-\(i).json")
            try call(path, id: "tool-\(i)")
            try json(["candidate": i], to: path)
            try done(id: "tool-\(i)")
            XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path], "第 \(i) 份新产物仍应可见")
        }
    }

    func testOversizedSessionStateIsIgnored() throws {
        try json(["cwd": workspace.path, "padding": String(repeating: "a", count: 300 * 1_024)],
                 to: session.appendingPathComponent("state.json"))
        let m = monitor(), path = outputs.appendingPathComponent("oversized-state.json")
        try call(path); try json(["new": true], to: path); try done()
        XCTAssertEqual(m.poll(), [])
    }

    func testAttemptBoundProgressCannotRenewDifferentAttemptAndOldPayloadStillDecodes() throws {
        let now = Date()
        let lease = ExecutionLeaseGate(taskID: "task", baselineFingerprint: "base", attemptID: "new")
        let old = WorkProgress(taskID: "task", sequence: 1, phase: "产物", summary: "真实报告",
            evidenceFingerprint: "changed", updatedAt: now, automatic: true, attemptID: "old")
        XCTAssertNil(lease.renewal(now: now, progress: old))
        var current = old; current.attemptID = "new"
        XCTAssertNotNil(lease.renewal(now: now, progress: current))
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        dictionary.removeValue(forKey: "attemptID")
        let decoded = try JSONDecoder().decode(WorkProgress.self, from: JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertNil(decoded.attemptID)
        XCTAssertEqual(decoded.summary, current.summary)
    }

    // Independent acceptance regression: interrupted calls must not saturate the monitor.
    func testAbandonedCallsDoNotPermanentlyDisableFutureProgress() throws {
        let m = monitor()
        for i in 0..<128 {
            let abandoned = outputs.appendingPathComponent("abandoned-\(i).json")
            try call(abandoned, id: "abandoned-\(i)")
        }
        let live = outputs.appendingPathComponent("live-after-abandoned.json")
        try call(live, id: "live")
        try json(["new": true], to: live)
        try done(id: "live")
        XCTAssertEqual(m.poll(), [live.resolvingSymlinksInPath().path],
                       "中断留下的未配对调用不能永久关闭本轮后续产物观察")
    }

    // Independent acceptance regression: one successful overlapping call cannot
    // authorize content written by a different call that eventually fails.
    func testOverlappingFailedRewriteCannotBorrowAnotherCallsSuccess() throws {
        let m = monitor()
        let path = outputs.appendingPathComponent("shared-output.json")
        try call(path, id: "seed")
        try json(["version": 1], to: path)
        try done(id: "seed")
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path])

        try call(path, id: "successful-overlap")
        try call(path, id: "failed-overlap")
        try done(id: "successful-overlap")
        try json(["version": 2, "partial": true], to: path)
        try done(id: "failed-overlap", error: true)
        XCTAssertEqual(m.poll(), [],
                       "失败调用写出的共享路径内容不能借另一个成功调用续租")

        try call(path, id: "successful-before-failure")
        try call(path, id: "failed-first")
        try json(["version": 3, "partial": true], to: path)
        try done(id: "failed-first", error: true)
        try done(id: "successful-before-failure")
        XCTAssertEqual(m.poll(), [],
                       "失败先返回时，较早开始的成功调用也不能授权失败内容")

        try call(path, id: "clean-recovery")
        try json(["version": 4, "complete": true], to: path)
        try done(id: "clean-recovery")
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path],
                       "失败之后新开始且成功的调用应恢复该路径的观察")
    }

    func testEvictedCallDoesNotBlockNewSuccessfulCallForSamePath() throws {
        let m = monitor()
        let shared = outputs.appendingPathComponent("evicted-then-retried.json")
        let base = Date().addingTimeInterval(-5)
        try call(shared, id: "old-shared", time: base)
        for i in 1..<128 {
            try call(outputs.appendingPathComponent("abandoned-\(i).json"),
                     id: "old-\(i)", time: base.addingTimeInterval(Double(i) / 1_000))
        }
        try call(shared, id: "new-shared", time: Date())
        try json(["complete": true], to: shared)
        try done(id: "new-shared")
        XCTAssertEqual(m.poll(), [shared.resolvingSymlinksInPath().path],
                       "淘汰旧调用不能连同随后成功的新调用一起封死同一路径")
    }

    func testSameMillisecondFailureThenNewSuccessRecoversByEventOrder() throws {
        let m = monitor()
        let path = outputs.appendingPathComponent("same-millisecond.json")
        try call(path, id: "seed")
        try json(["version": 1], to: path)
        try done(id: "seed")
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path])

        let sameTimestamp = Date()
        try call(path, id: "failed", time: sameTimestamp)
        try json(["version": 2, "partial": true], to: path)
        try event("tool.result", id: "failed", time: sameTimestamp,
                  fields: ["result": ["output": "failed", "isError": true]])
        XCTAssertEqual(m.poll(), [])

        try call(path, id: "recovery", time: sameTimestamp)
        try json(["version": 3, "complete": true], to: path)
        try event("tool.result", id: "recovery", time: sameTimestamp,
                  fields: ["result": ["output": "finished", "isError": false]])
        XCTAssertEqual(m.poll(), [path.resolvingSymlinksInPath().path],
                       "同一毫秒内按事件顺序更晚的新成功调用应恢复观察")
    }

}
