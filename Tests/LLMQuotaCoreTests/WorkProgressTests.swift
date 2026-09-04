import XCTest
@testable import LLMQuotaCore

final class WorkProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func progress(sequence: Int, fingerprint: String,
                          minutes: Int = 20, updatedAt: Date? = nil,
                          nextStep: String? = nil) -> WorkProgress {
        WorkProgress(taskID: "task", sequence: sequence, phase: "实现",
                     summary: "完成一项可核验改动", nextStep: nextStep,
                     evidence: ["test.log"],
                     evidenceFingerprint: fingerprint, requestedMinutes: minutes,
                     updatedAt: updatedAt ?? now)
    }

    func testFreshDeclaredNextStepPreventsWholeTaskCompletion() {
        func completedTask() -> WorkTask {
            var task = WorkTask(id: "task", prompt: "完成完整项目", repo: "/tmp/repo")
            task.state = .done
            task.endedAt = now
            task.runnerPID = 123
            task.branch = "agent/volcark/task"
            task.ownerRunnerID = "opencode.volcark.code"
            return task
        }
        let fresh = progress(sequence: 8, fingerprint: "new",
                             updatedAt: now, nextStep: "按原任务继续 M0 视觉复核")
        var task = completedTask()
        XCTAssertEqual(WorkContinuationGate.requeueIfNeeded(task: &task,
            startedAt: now.addingTimeInterval(-60), baselineSequence: 7,
            progress: fresh), "按原任务继续 M0 视觉复核")
        XCTAssertEqual(task.state, .queued)
        XCTAssertNil(task.endedAt)
        XCTAssertNil(task.runnerPID)
        XCTAssertEqual(task.branch, "agent/volcark/task")
        XCTAssertEqual(task.ownerRunnerID, "opencode.volcark.code")

        var sameSequence = completedTask()
        XCTAssertNil(WorkContinuationGate.requeueIfNeeded(task: &sameSequence,
            startedAt: now.addingTimeInterval(-60), baselineSequence: 8,
            progress: fresh), "上一轮的进度不能重开已经完成的新一轮")
        XCTAssertEqual(sameSequence.state, .done)

        var oldProgress = completedTask()
        XCTAssertNil(WorkContinuationGate.requeueIfNeeded(task: &oldProgress,
            startedAt: now.addingTimeInterval(1), baselineSequence: 7,
            progress: fresh), "开工前的旧进度不能影响本轮终态")
        XCTAssertEqual(oldProgress.state, .done)

        var noNextStep = completedTask()
        XCTAssertNil(WorkContinuationGate.requeueIfNeeded(task: &noNextStep,
            startedAt: now.addingTimeInterval(-60), baselineSequence: 7,
            progress: progress(sequence: 8, fingerprint: "done", updatedAt: now)),
            "本轮没有声明下一步时允许正常完成")
        XCTAssertEqual(noNextStep.state, .done)

        var automaticHeartbeat = completedTask()
        let automatic = WorkProgress(
            taskID: "task", sequence: 8, phase: "持续实现",
            summary: "检测到新提交 abcdef12，服务端自动保持当前会话",
            nextStep: "继续当前任务", evidenceFingerprint: "automatic",
            updatedAt: now, automatic: true)
        XCTAssertNil(WorkContinuationGate.requeueIfNeeded(task: &automaticHeartbeat,
            startedAt: now.addingTimeInterval(-60), baselineSequence: 7,
            progress: automatic), "worker 自动续期不是 Agent 声明的未完成事项")
        XCTAssertEqual(automaticHeartbeat.state, .done)
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
        let gate = ObjectiveProgressLeaseGate(
            baselineHead: "base", baselineFingerprint: "clean")

        XCTAssertNil(gate.renewal(currentHead: "base", currentFingerprint: "clean"),
                     "还停在开工提交时不能续期")
        XCTAssertEqual(gate.renewal(currentHead: "commit-1",
                                    currentFingerprint: "commit-1-clean")?.seconds, 20 * 60)
        XCTAssertNil(gate.renewal(currentHead: "commit-1",
                                  currentFingerprint: "commit-1-clean"),
                     "同一个提交和 diff 不能反复续命")
        XCTAssertEqual(gate.renewal(currentHead: "commit-2",
                                    currentFingerprint: "commit-2-clean")?.head, "commit-2",
                       "下一份真实提交应继续保持同一个执行会话")
    }

    func testUncommittedWorkspaceChangesRenewOnlyWhenFingerprintAdvances() {
        let gate = ObjectiveProgressLeaseGate(
            baselineHead: "base", baselineFingerprint: "clean", secondsPerChange: 600)

        XCTAssertEqual(gate.renewal(currentHead: "base",
                                    currentFingerprint: "dirty-1")?.seconds, 600)
        XCTAssertNil(gate.renewal(currentHead: "base", currentFingerprint: "dirty-1"),
                     "静止的 WIP 不能无限续命")
        XCTAssertEqual(gate.renewal(currentHead: "base",
                                    currentFingerprint: "dirty-2")?.seconds, 600)
    }

    func testAcceptedExplicitProgressIsNotConsumedAgainByFallback() {
        let gate = ObjectiveProgressLeaseGate(
            baselineHead: "base", baselineFingerprint: "clean")
        gate.observe(currentHead: "commit-1", currentFingerprint: "commit-1-clean")

        XCTAssertNil(gate.renewal(currentHead: "commit-1",
                                  currentFingerprint: "commit-1-clean"))
    }

    func testAutomaticObjectiveLeaseHasNoTotalCapWhileWorkspaceAdvances() {
        let gate = ObjectiveProgressLeaseGate(
            baselineHead: "base", baselineFingerprint: "clean", secondsPerChange: 600)
        for sequence in 1...20 {
            XCTAssertEqual(gate.renewal(
                currentHead: "commit-\(sequence)",
                currentFingerprint: "fingerprint-\(sequence)")?.seconds, 600,
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

    func testResumedAttemptDoesNotInheritHoursOfOldCheckpointAge() throws {
        var task = WorkTask(id: "task", prompt: "继续切片", repo: "/tmp/repo")
        task.state = .running
        task.startedAt = now.addingTimeInterval(-120)
        task.ownerRunnerID = "kimi.code"
        let old = progress(sequence: 4, fingerprint: "old", updatedAt: now.addingTimeInterval(-8 * 3600))
        XCTAssertNil(WorkProgressSentinel.finding(for: task, progress: old, now: now))
        let brief = try XCTUnwrap(TaskBoard.build(from: [task], machineName: "M2",
            progressByTaskID: [task.id: old], now: now).tasks.first)
        XCTAssertEqual(brief.progressPhase, "已恢复 · 等待本轮里程碑")
        XCTAssertTrue(brief.progressSummary?.hasPrefix("上轮进展") == true)
        XCTAssertEqual(brief.ownerRunnerID, "kimi.code")
        let late = WorkProgressSentinel.finding(for: task, progress: old,
                                               now: now.addingTimeInterval(1200))
        XCTAssertEqual(late?.minutesWithoutProgress, 22, "20 分钟后仍没增量必须告警，不能无限重置")
    }

    func testTwentyMinuteSentinelAlsoFindsStalledTechnicalDisposition() {
        var task = WorkTask(id: "task", prompt: "Flint 高危工程改动", repo: "/tmp/repo")
        task.state = .blocked
        task.endedAt = now.addingTimeInterval(-1_201)
        task.note = "技术处置任务 tabc1234：等待 Claude 领取；实现 Owner 保持 MiniMax"

        let finding = WorkProgressSentinel.finding(for: task, progress: nil, now: now)
        XCTAssertEqual(finding?.taskID, task.id)
        XCTAssertEqual(finding?.neverReported, true)
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

    func testAutomaticProgressDoesNotErasePreviouslyReportedEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-progress-evidence-\(UUID().uuidString)")
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
        try Data("image".utf8).write(to: repo.appendingPathComponent("evidence.png"))

        _ = try WorkProgressStore.record(
            taskID: "task", phase: "取证", summary: "已生成三机位截图", nextStep: "继续优化",
            evidence: ["evidence.png"], requestedMinutes: 20, repo: repo.path, now: now)
        let automatic = try WorkProgressStore.record(
            taskID: "task", phase: "持续实现", summary: "检测到工作区有新改动",
            nextStep: "继续当前任务", evidence: [], requestedMinutes: 20,
            repo: repo.path, now: now.addingTimeInterval(60), automatic: true)

        XCTAssertEqual(automatic.evidence, ["evidence.png"],
                       "自动续期只能更新进度，不能把已上报给人的证据清空")
        XCTAssertTrue(automatic.automatic)
        XCTAssertEqual(automatic.explicitNextStep, "继续优化",
                       "自动续期不能覆盖 Agent 已声明但尚未完成的下一步")
        XCTAssertEqual(automatic.explicitNextStepSequence, 1)
        XCTAssertEqual(automatic.explicitNextStepAt, now)

        var completed = WorkTask(id: "task", prompt: "完成完整项目", repo: repo.path)
        completed.state = .done
        completed.endedAt = now.addingTimeInterval(60)
        XCTAssertEqual(WorkContinuationGate.requeueIfNeeded(
            task: &completed,
            startedAt: now.addingTimeInterval(-1),
            baselineSequence: 0,
            progress: automatic), "继续优化",
            "显式下一步后的自动续期不能让整项任务被误报完成")
        XCTAssertEqual(completed.state, .queued)

        let nextAttemptStarted = now.addingTimeInterval(90)
        let nextAttemptAutomatic = try WorkProgressStore.record(
            taskID: "task", phase: "持续实现", summary: "检测到新提交 abcdef12",
            nextStep: "继续当前任务", evidence: [], requestedMinutes: 20,
            repo: repo.path, now: nextAttemptStarted.addingTimeInterval(30), automatic: true)
        var nextAttemptCompleted = WorkTask(
            id: "task", prompt: "完成完整项目", repo: repo.path)
        nextAttemptCompleted.state = .done
        nextAttemptCompleted.endedAt = nextAttemptStarted.addingTimeInterval(30)
        XCTAssertNil(WorkContinuationGate.requeueIfNeeded(
            task: &nextAttemptCompleted,
            startedAt: nextAttemptStarted,
            baselineSequence: automatic.sequence,
            progress: nextAttemptAutomatic),
            "上一轮声明不能被下一轮自动续期伪装成新声明，导致永久回队")
        XCTAssertEqual(nextAttemptCompleted.state, .done)

        let final = try WorkProgressStore.record(
            taskID: "task", phase: "任务完成", summary: "全部门槛已经通过",
            nextStep: nil, evidence: [], requestedMinutes: 20,
            repo: repo.path, now: now.addingTimeInterval(120))
        XCTAssertNil(final.explicitNextStep,
                     "Agent 最终上报不带 next 时必须清除旧的后续工作")
    }

    func testAutomaticWorkspaceChangesDoNotSilenceTwentyMinuteInspection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-progress-inspection-\(UUID().uuidString)")
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
        var task = WorkTask(id: "task", prompt: "长任务", repo: repo.path)
        task.state = .running
        task.startedAt = now

        try Data("wip".utf8).write(to: repo.appendingPathComponent("wip.txt"))
        let automatic = try WorkProgressStore.record(
            taskID: task.id, phase: "持续实现", summary: "检测到工作区有新改动",
            nextStep: "继续当前任务", evidence: [], requestedMinutes: 20,
            repo: repo.path, now: now.addingTimeInterval(1_200), automatic: true)

        XCTAssertNil(automatic.checkpointAt)
        XCTAssertNotNil(WorkProgressSentinel.finding(
            for: task, progress: automatic, now: now.addingTimeInterval(1_201)),
            "文件一直在变不等于 Agent 交了阶段成果；20 分钟巡检不能被自动心跳骗过")
    }

    func testCommittedVisualEvidenceCountsAsARealCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-progress-visual-\(UUID().uuidString)")
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
        try Data("image".utf8).write(to: repo.appendingPathComponent("evidence.png"))

        let checkpoint = try WorkProgressStore.record(
            taskID: "task", phase: "持续实现", summary: "检测到新提交",
            nextStep: "继续当前任务", evidence: ["evidence.png"],
            requestedMinutes: 20, repo: repo.path, now: now, automatic: true)

        XCTAssertEqual(checkpoint.checkpointAt, now,
                       "提交里真的新增了视觉证据时，自动检测也应算可核验 checkpoint")
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

    func testDenseProgressDoesNotAccumulateFutureLease() {
        var extensionCount = 0
        let result = Proc.run(
            "/bin/sleep", ["2.6"], cwd: "/tmp", env: [:], timeout: 1.1,
            deadlineExtension: { _ in
                guard extensionCount < 2 else { return nil }
                extensionCount += 1
                return Proc.DeadlineExtension(seconds: 1, reason: "dense file writes")
            })

        XCTAssertTrue(result.timedOut,
                      "密集进展只能把租约滑到最近进展之后，不能逐次叠加")
        XCTAssertEqual(extensionCount, 2)
    }

    func testLegacyProgressRecordDecodesWithSafeDefaults() throws {
        let data = Data(#"{"taskID":"task","phase":"分析","summary":"读完架构"}"#.utf8)
        let item = try SnapshotCoding.decoder().decode(WorkProgress.self, from: data)
        XCTAssertEqual(item.sequence, 0)
        XCTAssertEqual(item.evidence, [])
        XCTAssertEqual(item.requestedMinutes, 20)
        XCTAssertEqual(item.updatedAt, .distantPast)
        XCTAssertFalse(item.automatic)
        XCTAssertNil(item.explicitNextStep)
        XCTAssertNil(item.explicitNextStepSequence)
        XCTAssertNil(item.explicitNextStepAt)

        let oldAutomaticData = Data(
            #"{"taskID":"task","sequence":3,"phase":"持续实现","summary":"检测到工作区有新改动","nextStep":"继续当前任务"}"#.utf8)
        let oldAutomatic = try SnapshotCoding.decoder().decode(
            WorkProgress.self, from: oldAutomaticData)
        XCTAssertTrue(oldAutomatic.automatic)
        XCTAssertNil(oldAutomatic.explicitNextStep)
        XCTAssertNil(oldAutomatic.explicitNextStepSequence)
        XCTAssertNil(oldAutomatic.explicitNextStepAt)

        let oldExplicitData = Data(
            #"{"taskID":"task","sequence":4,"phase":"阶段收口","summary":"逻辑批完成","nextStep":"继续 M0"}"#.utf8)
        let oldExplicit = try SnapshotCoding.decoder().decode(
            WorkProgress.self, from: oldExplicitData)
        XCTAssertFalse(oldExplicit.automatic)
        XCTAssertEqual(oldExplicit.explicitNextStep, "继续 M0")
        XCTAssertEqual(oldExplicit.explicitNextStepSequence, 4)
        XCTAssertEqual(oldExplicit.explicitNextStepAt, .distantPast)
    }
}
