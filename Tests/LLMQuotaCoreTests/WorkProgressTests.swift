import XCTest
@testable import LLMQuotaCore

final class WorkProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func progress(sequence: Int, fingerprint: String,
                          minutes: Int = 20, updatedAt: Date? = nil) -> WorkProgress {
        WorkProgress(taskID: "task", sequence: sequence, phase: "实现",
                     summary: "完成一项可核验改动", evidence: ["test.log"],
                     evidenceFingerprint: fingerprint, requestedMinutes: minutes,
                     updatedAt: updatedAt ?? now)
    }

    func testLeaseRequiresFreshObjectiveProgress() {
        let gate = ExecutionLeaseGate(taskID: "task", baselineFingerprint: "baseline")

        XCTAssertNil(gate.renewal(now: now,
                                  progress: progress(sequence: 1, fingerprint: "baseline")),
                     "只改汇报文字、证据指纹没变，不能续期")
        let renewed = gate.renewal(now: now,
                                   progress: progress(sequence: 2, fingerprint: "changed"))
        XCTAssertEqual(renewed?.seconds, 20 * 60)
        XCTAssertEqual(renewed?.progress.sequence, 2)

        XCTAssertNil(gate.renewal(now: now,
                                  progress: progress(sequence: 2, fingerprint: "changed")),
                     "同一个里程碑不能反复消费")
        XCTAssertNil(gate.renewal(now: now,
                                  progress: progress(sequence: 3, fingerprint: "new",
                                                     updatedAt: now.addingTimeInterval(-301))),
                     "五分钟前的旧汇报不能在临近超时时突然续命")
    }

    func testLeaseHasNoTotalRenewalCapWhileEvidenceAdvances() {
        let gate = ExecutionLeaseGate(taskID: "task", baselineFingerprint: "baseline")
        for sequence in 1...12 {
            let point = now.addingTimeInterval(Double(sequence * 1_200))
            let item = progress(sequence: sequence, fingerprint: "change-\(sequence)",
                                minutes: 60, updatedAt: point)
            XCTAssertEqual(gate.renewal(now: point,
                                        progress: item)?.seconds, 60 * 60,
                           "第 \(sequence) 次真实推进仍应续期；总时长不设硬上限")
        }
    }

    func testNewCommitsRenewWhenAgentForgotToReportProgress() {
        let gate = CommitProgressLeaseGate(baselineHead: "base")

        XCTAssertNil(gate.renewal(currentHead: "base"),
                     "还停在开工提交时不能续期")
        XCTAssertEqual(gate.renewal(currentHead: "commit-1")?.seconds, 20 * 60)
        XCTAssertNil(gate.renewal(currentHead: "commit-1"),
                     "同一个提交不能反复续命")
        XCTAssertEqual(gate.renewal(currentHead: "commit-2")?.head, "commit-2",
                       "下一份真实提交应继续保持同一个执行会话")
    }

    func testAutomaticCommitLeaseHasNoTotalCapWhileCommitsAdvance() {
        let gate = CommitProgressLeaseGate(baselineHead: "base", secondsPerCommit: 600)
        for sequence in 1...20 {
            XCTAssertEqual(gate.renewal(currentHead: "commit-\(sequence)")?.seconds, 600,
                           "第 \(sequence) 个新提交仍应续期，不能重新引入总时长硬顶")
        }
    }

    func testTaskBoardCarriesLatestMilestoneToPhoneProjection() throws {
        var task = WorkTask(id: "task", prompt: "长任务", repo: "/tmp/repo")
        task.state = .running
        task.startedAt = now.addingTimeInterval(-600)
        let item = progress(sequence: 4, fingerprint: "changed")

        let board = TaskBoard.build(from: [task], machineName: "Mac mini",
                                    progressByTaskID: [task.id: item], now: now)
        let brief = try XCTUnwrap(board.tasks.first)
        XCTAssertEqual(brief.progressPhase, "实现")
        XCTAssertEqual(brief.progressSummary, "完成一项可核验改动")
        XCTAssertEqual(brief.progressUpdatedAt, now)
        XCTAssertEqual(brief.progressEvidenceCount, 1)
    }

    func testTwentyMinuteSentinelFindsMissingAndStaleProgress() {
        var task = WorkTask(id: "task", prompt: "长任务", repo: "/tmp/repo")
        task.state = .running
        task.startedAt = now.addingTimeInterval(-1_201)

        let missing = WorkProgressSentinel.finding(for: task, progress: nil, now: now)
        XCTAssertEqual(missing?.taskID, "task")
        XCTAssertEqual(missing?.neverReported, true)

        let stale = progress(sequence: 1, fingerprint: "changed",
                             updatedAt: now.addingTimeInterval(-1_201))
        XCTAssertNotNil(WorkProgressSentinel.finding(for: task, progress: stale, now: now))
        let fresh = progress(sequence: 2, fingerprint: "new",
                             updatedAt: now.addingTimeInterval(-60))
        XCTAssertNil(WorkProgressSentinel.finding(for: task, progress: fresh, now: now))
    }

    func testPhoneProjectionMarksTwentyMinutesWithoutMilestone() throws {
        var task = WorkTask(id: "task", prompt: "长任务", repo: "/tmp/repo")
        task.state = .running
        task.startedAt = now.addingTimeInterval(-1_201)

        let board = TaskBoard.build(from: [task], machineName: "Mac mini", now: now)
        let brief = try XCTUnwrap(board.tasks.first)
        XCTAssertEqual(brief.progressPhase, "无可证明进展")
        XCTAssertTrue(brief.progressSummary?.contains("20 分钟") == true)
    }

    func testTwentyMinuteInspectionNotifiesWithoutAddingUnreadBadge() {
        var task = WorkTask(id: "task", prompt: "Flint 人物黄金样板", repo: "/tmp/repo")
        task.state = .running
        task.startedAt = now.addingTimeInterval(-1_201)

        let item = Nudge.pending(now: now, tasks: [task], publishedAsks: [],
                                 progressByTaskID: [:])
            .first { $0.key.hasPrefix("progress-stalled-") }
        XCTAssertEqual(item?.kind, .trouble)
        XCTAssertEqual(item?.badge, 0)
        XCTAssertTrue(item?.body.contains("20 分钟巡检") == true)
    }

    func testProgressStoreAdvancesSequenceAndFingerprintWithWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-progress-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let progressDir = root.appendingPathComponent("progress")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer {
            WorkProgressStore.dirOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        WorkProgressStore.dirOverride = progressDir
        XCTAssertEqual(Proc.run("/usr/bin/git", ["init"], cwd: repo.path,
                                env: [:], timeout: 10).exitCode, 0)
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("value.txt"))
        let first = try WorkProgressStore.record(
            taskID: "task", phase: "分析", summary: "建立基线", nextStep: nil,
            evidence: [], requestedMinutes: 20, repo: repo.path, now: now)
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("value.txt"))
        let second = try WorkProgressStore.record(
            taskID: "task", phase: "实现", summary: "更新产物", nextStep: "测试",
            evidence: ["value.txt"], requestedMinutes: 30, repo: repo.path,
            now: now.addingTimeInterval(60))

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertNotEqual(first.evidenceFingerprint, second.evidenceFingerprint)
        XCTAssertEqual(WorkProgressStore.load(taskID: "task"), second)
    }

    func testProcAddsAnEarlyLeaseWithoutRestartingProcess() {
        var used = false
        let result = Proc.run(
            "/bin/sleep", ["1.5"], cwd: "/tmp", env: [:], timeout: 1,
            deadlineExtension: { _ in
                guard !used else { return nil }
                used = true
                return Proc.DeadlineExtension(seconds: 1, reason: "verified progress")
            })
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(used)
    }

    func testLegacyProgressRecordDecodesWithSafeDefaults() throws {
        let data = Data(#"{"taskID":"task","phase":"分析","summary":"读完架构"}"#.utf8)
        let item = try SnapshotCoding.decoder().decode(WorkProgress.self, from: data)
        XCTAssertEqual(item.sequence, 0)
        XCTAssertEqual(item.evidence, [])
        XCTAssertEqual(item.requestedMinutes, 20)
        XCTAssertEqual(item.updatedAt, .distantPast)
    }
}
