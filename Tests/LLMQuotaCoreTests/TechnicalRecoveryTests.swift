import XCTest
@testable import LLMQuotaCore

final class TechnicalRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
        Paths.appSupportOverride = root
        AskStore.rootOverride = root.appendingPathComponent("shared")
        TaskStore.resetWrittenRevForTests()
    }
    override func tearDown() {
        Paths.appSupportOverride = nil
        AskStore.rootOverride = nil
        TaskStore.resetWrittenRevForTests()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }
    private func failed() -> WorkTask {
        var t = WorkTask(id: "source", prompt: "修复产品", repo: root.path)
        t.state = .failed; t.terminalFailureKind = .timedOut
        t.ownerRunnerID = "kimi.code"; t.ownerPlatform = .kimi
        t.branch = "agent/kimi/source"
        t.startedAt = Date(timeIntervalSince1970: 1)
        t.endedAt = Date(timeIntervalSince1970: 100)
        return t
    }
    func testTechnicalTimeoutDoesNotBecomeSingleChoiceHumanQuestion() throws {
        let t = try TaskStore.create(failed(), actor: "fixture", reason: "isolated fixture")
        XCTAssertFalse(StuckAsk.raise(task: t, reason: "两轮超时"))
        XCTAssertNil(TaskStore.all().first?.pendingAsk)
    }
    func testTerminalTimeoutHasActualDiagnosticOwnerAndWork() throws {
        let t = failed()
        try WorkAttemptStore.append(WorkAttempt(attemptID: "failed-attempt", taskID: t.id,
            runnerID: "kimi.code", platform: .kimi, startedAt: t.startedAt!, endedAt: t.endedAt!,
            outcome: .failed, failureKind: "timedOut", timedOut: true))
        let changes = TaskGraph.reconcile([t])
        let source = try XCTUnwrap(changes.first { $0.id == t.id })
        let diagnostic = try XCTUnwrap(changes.first { $0.id != t.id })
        XCTAssertEqual(source.state, .blocked)
        XCTAssertEqual(source.waitReason, .architectureReview)
        XCTAssertEqual(source.ownerRunnerID, "kimi.code")
        XCTAssertEqual(diagnostic.preferredPlatform, .codex)
        XCTAssertTrue(TaskKind.isArchitectReview(diagnostic.prompt))
        XCTAssertTrue(source.note?.contains(diagnostic.id) == true)
    }
}

extension TechnicalRecoveryTests {
    private func seed(_ task: WorkTask) throws {
        try WorkAttemptStore.append(WorkAttempt(attemptID: "failed-attempt", taskID: task.id,
            runnerID: task.ownerRunnerID!, platform: .kimi, startedAt: task.startedAt!,
            endedAt: task.endedAt!, outcome: .failed,
            failureKind: task.terminalFailureKind!.rawValue,
            headAfter: GitWorkspace.headSHA(in: root.path), timedOut: true))
    }
    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let r = GitWorkspace.git(args, in: root.path, timeout: 5)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func diagnosed() throws -> (WorkTask, WorkTask) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "user.name", "Isolated test"])
        try "source".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "source.txt"]); try git(["commit", "-m", "fixture"])
        try git(["branch", "agent/kimi/source"])
        let task = failed()
        try seed(task)
        let changes = TechnicalRecovery.reconcile([task])
        return (try XCTUnwrap(changes.first { $0.id == task.id }),
                try XCTUnwrap(changes.first { $0.id != task.id }))
    }
    private func finish(_ source: WorkTask, _ diagnostic: WorkTask,
                        edit: (inout TechnicalRecovery.Report) -> Void = { _ in }) throws -> WorkTask {
        let incident = try XCTUnwrap(source.recoveryIncident)
        var d = diagnostic
        d.branch = "agent/codex/diagnostic"
        d.state = .done
        d.ownerRunnerID = "codex"; d.ownerPlatform = .codex
        let before = try git(["rev-parse", "HEAD"])
        try git(["checkout", "-B", d.branch!])
        var report = TechnicalRecovery.Report(incidentID: incident.id, sourceTaskID: source.id,
            sourceAttemptID: incident.sourceAttemptID, sourceHead: incident.head,
            sourceBranch: incident.branch, sourceOwner: incident.ownerRunnerID,
            failureKind: incident.failureKind, diagnosticTaskID: d.id,
            diagnosticAttemptID: "diagnostic-attempt", decision: "resumeOriginal",
            reason: "超时后仍有已保存增量，可在原任务内完成下一步", evidence: ["已检查隔离分支 source.txt"],
            steps: ["沿用 source.txt 完成剩余实现并验证"], humanBoundary: nil)
        edit(&report)
        let path = TechnicalRecovery.reportPath(incident)
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: url)
        try git(["add", path]); try git(["commit", "-m", "diagnostic report"])
        try WorkAttemptStore.append(WorkAttempt(attemptID: "diagnostic-attempt", taskID: d.id,
            runnerID: "codex", platform: .codex, startedAt: Date(), endedAt: Date(),
            outcome: .done, headBefore: before, headAfter: try git(["rev-parse", "HEAD"]), timedOut: false))
        return d
    }
    func testValidReportResumesOriginalAndPersistsLifetimeBudget() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        let ready = try XCTUnwrap(TechnicalRecovery.reconcile([source, done]).first { $0.id == source.id })
        XCTAssertEqual(ready.state, .queued)
        XCTAssertEqual(ready.ownerRunnerID, source.ownerRunnerID)
        XCTAssertEqual(ready.branch, source.branch)
        XCTAssertEqual(ready.recoveryIncident?.resumeCount, 1)
        XCTAssertNil(ready.startedAt)
        XCTAssertNil(ready.terminalFailureKind)
        let restored = try SnapshotCoding.decoder().decode(WorkTask.self, from: SnapshotCoding.encoder().encode(ready))
        XCTAssertEqual(restored.recoveryIncident?.resumeCount, 1)
        XCTAssertTrue(TechnicalRecovery.reconcile([restored, done]).isEmpty)
    }
    func testNextFailureDoesNotResetBudgetOrAutoResume() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        var next = try XCTUnwrap(TechnicalRecovery.reconcile([source, done]).first { $0.id == source.id })
        next.state = .failed; next.terminalFailureKind = .timedOut
        next.startedAt = Date(); next.endedAt = Date()
        try WorkAttemptStore.append(WorkAttempt(attemptID: "second-failure", taskID: next.id,
            runnerID: "kimi.code", platform: .kimi, startedAt: next.startedAt!, endedAt: next.endedAt!,
            outcome: .failed, failureKind: "timedOut", headAfter: source.recoveryIncident?.head, timedOut: true))
        let changes = TechnicalRecovery.reconcile([next, done])
        let held = try XCTUnwrap(changes.first { $0.id == source.id })
        XCTAssertEqual(held.recoveryIncident?.resumeCount, 1)
        let second = try XCTUnwrap(changes.first { $0.id != source.id })
        let report = try finish(held, second)
        let unresolved = try XCTUnwrap(TechnicalRecovery.reconcile([held, report]).first { $0.id == source.id })
        XCTAssertEqual(unresolved.state, .blocked)
        XCTAssertEqual(unresolved.recoveryIncident?.phase, "unresolved")
        XCTAssertNil(unresolved.pendingAsk)
    }
    func testWrongDiagnosticAttemptCannotResumeAndOnlyOneSupplementAllowed() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic) { $0.diagnosticAttemptID = "older-attempt" }
        let changes = TechnicalRecovery.reconcile([source, done])
        let retry = try XCTUnwrap(changes.first { $0.id == done.id })
        XCTAssertEqual(retry.state, .queued)
        XCTAssertEqual(retry.interruptedCount, 1)
        XCTAssertFalse(changes.contains { $0.id == source.id && $0.state == .queued })
        var failedAgain = retry
        failedAgain.state = .failed; failedAgain.terminalFailureKind = .timedOut
        let final = TechnicalRecovery.reconcile([source, failedAgain])
        XCTAssertEqual(final.first { $0.id == source.id }?.recoveryIncident?.phase, "unresolved")
        XCTAssertFalse(final.contains { $0.id == done.id })
        XCTAssertFalse(StuckAsk.raise(task: failedAgain, reason: "诊断失败"))
    }
    func testLateReportCannotOverridePauseDiscardOrRealQuestion() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        var paused = source; paused.pausedAt = Date()
        var discarded = source; discarded.discardedAt = Date()
        var question = source; question.pendingAsk = realAsk(source)
        question.waitReason = .humanAnswer
        var ownerChanged = source; ownerChanged.ownerRunnerID = "another-owner"
        var approval = source; approval.waitReason = .humanApproval
        for t in [paused, discarded, question, ownerChanged, approval] {
            XCTAssertTrue(TechnicalRecovery.reconcile([t, done]).isEmpty)
        }
    }
    func testChangedSourceHeadRejectsPreviouslyValidReport() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        try git(["update-ref", "refs/heads/agent/kimi/source", "HEAD"])
        let changes = TechnicalRecovery.reconcile([source, done])
        XCTAssertEqual(changes.first { $0.id == source.id }?.state, .blocked)
        XCTAssertEqual(changes.first { $0.id == source.id }?.recoveryIncident?.phase, "unresolved")
    }
    func testInvalidReportBindingsNeverResume() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic) { $0.sourceHead = "wrong-head" }
        XCTAssertFalse(TechnicalRecovery.reconcile([source, done]).contains { $0.id == source.id && $0.state == .queued })
    }
    func testUnknownDecisionFailsClosed() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic) { $0.decision = "forceMergeAndResume" }
        let held = try XCTUnwrap(TechnicalRecovery.reconcile([source, done]).first { $0.id == source.id })
        XCTAssertEqual(held.recoveryIncident?.phase, "unresolved")
        XCTAssertEqual(held.state, .blocked)
    }
    func testExternalBlockerContainsActualActionAndPublishesWithoutContinueOption() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic) {
            $0.decision = "externalBlocker"; $0.humanBoundary = "login"
            $0.reason = "登录凭证失效，需要本人完成验证"
            $0.steps = ["在所属机器完成登录验证后回复"]
        }
        let held = try XCTUnwrap(TechnicalRecovery.reconcile([source, done]).first { $0.id == source.id })
        XCTAssertEqual(held.state, .blocked)
        XCTAssertEqual(held.waitReason, .humanAnswer)
        XCTAssertNil(held.pendingAsk?.questions.first?.options)
        TechnicalRecovery.syncAsks([held])
        XCTAssertEqual(AskStore.pending(machine: Paths.machineID()).first?.id, held.pendingAsk?.id)
    }
    private func realAsk(_ task: WorkTask) -> Ask {
        Ask(taskID: task.id, machineID: "isolated-machine", round: 1, platform: .kimi,
            taskPrompt: task.prompt, repoName: task.repo,
            questions: [Ask.Question(text: "是否选择方案 A？", options: ["采用方案 A"])])
    }
    func testOnlyExactLegacySystemAskMigratesAndRetractionPreservesNewQuestion() throws {
        let (source, diagnostic) = try diagnosed()
        var old = failed()
        old.state = .blocked; old.waitReason = .humanAnswer; old.transitionActor = "stuck-ask"
        var ask = realAsk(old)
        ask.progressNote = TechnicalRecovery.legacyMarker
        ask.questions = [Ask.Question(text: "这个任务卡死了：超时。怎么处理？", options: [StuckAsk.recoveryOption(for: old).label])]
        old.pendingAsk = ask
        try AskStore.publish(ask)
        let migration = TechnicalRecovery.reconcile([old], now: source.recoveryIncident!.createdAt)
        let moved = try XCTUnwrap(migration.first { $0.id == old.id })
        XCTAssertNil(moved.pendingAsk)
        XCTAssertEqual(moved.recoveryIncident?.legacyAsk?.id, ask.id)
        TechnicalRecovery.syncAsks([moved, diagnostic])
        XCTAssertTrue(AskStore.pending(machine: ask.machineID).isEmpty)
        var new = realAsk(old); new.machineID = ask.machineID
        try AskStore.publish(new)
        TechnicalRecovery.syncAsks([moved])
        XCTAssertEqual(AskStore.pending(machine: ask.machineID).first?.id, new.id)
        old.pendingAsk = new
        XCTAssertTrue(TechnicalRecovery.reconcile([old]).isEmpty)
    }
    func testExcludedFailureKindsDoNotEnterRecovery() throws {
        for kind: WorkTask.TerminalFailureKind in [.quotaExhausted, .authenticationFailed, .qualityGate, .postRunGate, .interrupted] {
            var task = failed(); task.terminalFailureKind = kind
            try seed(task)
            XCTAssertTrue(TechnicalRecovery.reconcile([task]).isEmpty, kind.rawValue)
        }
        var cooldown = failed(); cooldown.retryNotBefore = Date().addingTimeInterval(30)
        try seed(cooldown)
        XCTAssertTrue(TechnicalRecovery.reconcile([cooldown]).isEmpty)
    }
    func testPartialPersistenceRecreatesExactlySameDiagnostic() throws {
        let (source, diagnostic) = try diagnosed()
        let again = TechnicalRecovery.reconcile([source])
        XCTAssertEqual(again.filter { $0.id == diagnostic.id }.count, 1)
        let saved = try TaskStore.create(source, actor: "fixture", reason: "source persisted before crash")
        let result = try TaskGraph.persistReconciliation(actor: "fixture", reason: "recover interrupted reconciliation")
        XCTAssertTrue(result.contains { $0.id == diagnostic.id })
        XCTAssertEqual(TaskStore.all().filter { $0.id == diagnostic.id }.count, 1)
        XCTAssertEqual(TaskStore.all().first { $0.id == saved.id }?.state, .blocked)
        _ = try TaskGraph.persistReconciliation(actor: "fixture", reason: "idempotence")
        XCTAssertEqual(TaskStore.all().filter { $0.id == diagnostic.id }.count, 1)
    }
    func testDeadlineShowsUnresolvedAndLateReportDoesNotResume() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        var expired = source
        expired.recoveryIncident?.deadline = Date(timeIntervalSince1970: 150)
        let changes = TechnicalRecovery.reconcile([expired, done], now: source.recoveryIncident!.deadline.addingTimeInterval(1))
        let held = try XCTUnwrap(changes.first { $0.id == source.id })
        XCTAssertEqual(held.recoveryIncident?.phase, "unresolved")
        XCTAssertEqual(held.state, .blocked)
        XCTAssertTrue(TechnicalRecovery.reconcile([held, done]).isEmpty)
    }
    func testBoardReplacesHistoricalSummaryAndHidesSupportingDiagnostic() throws {
        let (source, diagnostic) = try diagnosed()
        let board = TaskBoard.build(from: [source, diagnostic], machineName: "isolated")
        XCTAssertEqual(board.tasks.count, 1)
        let brief = try XCTUnwrap(board.tasks.first)
        XCTAssertEqual(brief.progressPhase, "系统诊断中")
        XCTAssertTrue(brief.progressSummary?.contains(diagnostic.id) == true)
        XCTAssertTrue(brief.progressNextStep?.contains("无需点击继续") == true)
    }
    func testOldTaskStillDecodesWithoutRecoveryField() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotCoding.encoder().encode(failed())) as? [String: Any])
        json.removeValue(forKey: "recoveryIncident")
        let decoded = try SnapshotCoding.decoder().decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.recoveryIncident)
        XCTAssertEqual(decoded.ownerRunnerID, "kimi.code")
    }
}

extension TechnicalRecoveryTests {
    func testLegacyMigrationRejectsEachNearMatchBindingVariant() throws {
        let (source, _) = try diagnosed()
        var exact = failed()
        exact.state = .blocked
        exact.waitReason = .humanAnswer
        exact.transitionActor = "stuck-ask"
        var ask = realAsk(exact)
        ask.progressNote = TechnicalRecovery.legacyMarker
        ask.questions = [Ask.Question(
            text: "这个任务卡死了：超时。怎么处理？",
            options: [StuckAsk.recoveryOption(for: exact).label])]
        exact.pendingAsk = ask

        var wrongProgress = exact
        wrongProgress.pendingAsk?.progressNote = TechnicalRecovery.legacyMarker + "（人工补充）"

        var wrongActor = exact
        wrongActor.transitionActor = "human"

        var wrongOnlyOption = exact
        wrongOnlyOption.pendingAsk?.questions[0].options = [
            StuckAsk.recoveryOption(for: exact).label + "（稍后）"
        ]

        for candidate in [wrongProgress, wrongActor, wrongOnlyOption] {
            let changes = TechnicalRecovery.reconcile(
                [candidate],
                now: source.recoveryIncident!.createdAt)
            XCTAssertTrue(changes.isEmpty)
            XCTAssertNil(candidate.recoveryIncident)
            XCTAssertNotNil(candidate.pendingAsk)
        }
    }

    func testSameRunnerWithChangedOwnerPlatformCannotResume() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        var changed = source
        changed.ownerPlatform = .codex

        let changes = TechnicalRecovery.reconcile([changed, done])
        XCTAssertFalse(changes.contains {
            $0.id == source.id && $0.state == .queued
        })
        XCTAssertTrue(changes.isEmpty)
    }
}

extension TechnicalRecoveryTests {
    func testStaleFailureCannotBeMisattributedToNewerTaskTermination() throws {
        var task = failed()
        try seed(task)
        task.endedAt = task.endedAt!.addingTimeInterval(3600)
        XCTAssertTrue(TechnicalRecovery.reconcile([task]).isEmpty)
        task.terminalAttemptID = "another-attempt"
        task.endedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(TechnicalRecovery.reconcile([task]).isEmpty)
    }
    func testIncidentUsesAttemptSnapshotEvenIfBranchMovedBeforeReconciliation() throws {
        let (source, _) = try diagnosed()
        let old = source.recoveryIncident!.head
        try "new".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "source.txt"]); try git(["commit", "-m", "another writer"])
        try git(["update-ref", "refs/heads/agent/kimi/source", "HEAD"])
        let task = failed()
        let incident = TechnicalRecovery.reconcile([task]).first { $0.id == task.id }?.recoveryIncident
        XCTAssertEqual(incident?.head, old)
        XCTAssertNotEqual(incident?.head, try git(["rev-parse", "agent/kimi/source"]))
    }
    func testOnTimeReportRemainsValidWhenConsumedAfterDeadline() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        let later = source.recoveryIncident!.deadline.addingTimeInterval(60)
        let ready = TechnicalRecovery.reconcile([source, done], now: later).first { $0.id == source.id }
        XCTAssertEqual(ready?.state, .queued)
    }
    func testDiagnosticOriginRepositoryAndOwnerMustMatch() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        var wrongOrigin = done; wrongOrigin.origin = "unrelated-task"
        var wrongRepo = done; wrongRepo.repo = root.appendingPathComponent("another").path
        var wrongOwner = done; wrongOwner.ownerRunnerID = "someone-else"
        for invalid in [wrongOrigin, wrongRepo, wrongOwner] {
            XCTAssertFalse(TechnicalRecovery.reconcile([source, invalid]).contains { $0.id == source.id && $0.state == .queued })
        }
    }
    func testAvailabilityCheckIsScheduledAndNeverAsksForBlindContinue() throws {
        var task = failed()
        task.state = .blocked; task.waitReason = .ownerUnavailable
        task.terminalFailureKind = nil
        task.retryNotBefore = Date().addingTimeInterval(600)
        XCTAssertFalse(StuckAsk.raise(task: task, reason: "没有平台能接"))
        XCTAssertFalse(TaskGraph.reconcile([task]).contains { $0.id == task.id && $0.state == .queued })
        let ready = TaskGraph.reconcile([task], now: task.retryNotBefore!.addingTimeInterval(1)).first { $0.id == task.id }
        XCTAssertEqual(ready?.state, .queued)
        XCTAssertEqual(ready?.ownerRunnerID, task.ownerRunnerID)
        var paused = task; paused.pausedAt = Date()
        XCTAssertTrue(TaskGraph.reconcile([paused], now: task.retryNotBefore!.addingTimeInterval(1)).isEmpty)
    }
    func testAuthenticationAsksForActualLoginAndPreservesRecoveryBudget() throws {
        var task = failed(); task.terminalFailureKind = .authenticationFailed
        task.askRounds = 1
        task = try TaskStore.create(task, actor: "fixture", reason: "isolated auth failure")
        XCTAssertTrue(StuckAsk.raise(task: task, reason: "token expired"))
        let held = try XCTUnwrap(TaskStore.all().first { $0.id == task.id })
        XCTAssertEqual(held.pendingAsk?.round, 2)
        XCTAssertEqual(held.askRounds, 2)
        XCTAssertNil(held.pendingAsk?.questions.first?.options)
        XCTAssertTrue(held.pendingAsk?.questions.first?.text.contains("登录") == true)
        XCTAssertEqual(held.ownerRunnerID, task.ownerRunnerID)
    }
    func testEnvironmentFaultCreatesDiagnosisWithoutBlindRetry() throws {
        var task = failed(); task.terminalFailureKind = .environmentBroken
        try seed(task)
        XCTAssertFalse(StuckAsk.raise(task: task, reason: "command not found"))
        let changes = TechnicalRecovery.reconcile([task])
        XCTAssertEqual(changes.first { $0.id == task.id }?.state, .blocked)
        XCTAssertEqual(changes.filter { TechnicalRecovery.isDiagnostic($0) }.count, 1)
    }
    func testSupplementaryAskPublicationNeverOverwritesNewerQuestion() throws {
        let task = failed()
        var first = realAsk(task); first.machineID = "isolated"
        var newer = realAsk(task); newer.machineID = "isolated"
        try AskStore.publish(newer)
        try AskStore.publish(first, onlyIfMissing: true)
        XCTAssertEqual(AskStore.pending(machine: "isolated").first?.id, newer.id)
    }
    func testMissingRecoveryFieldsFailClosedWithoutDroppingTask() throws {
        let (source, _) = try diagnosed()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotCoding.encoder().encode(source)) as? [String: Any])
        var incident = try XCTUnwrap(json["recoveryIncident"] as? [String: Any])
        incident.removeValue(forKey: "resumeCount"); incident.removeValue(forKey: "phase")
        json["recoveryIncident"] = incident
        let decoded = try SnapshotCoding.decoder().decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.recoveryIncident?.resumeCount, TechnicalRecovery.maximumResumes)
        XCTAssertEqual(decoded.recoveryIncident?.phase, "unresolved")
        XCTAssertTrue(TechnicalRecovery.reconcile([decoded]).isEmpty)
    }
}

extension TechnicalRecoveryTests {
    func testOnlyExactDiagnosticArtifactCanSkipProductBuild() throws {
        let (source, diagnostic) = try diagnosed()
        let path = TechnicalRecovery.reportPath(source.recoveryIncident!)
        XCTAssertTrue(TechnicalRecovery.isReportOnlyChange(diagnostic, files: [path]))
        XCTAssertFalse(TechnicalRecovery.isReportOnlyChange(diagnostic, files: []))
        XCTAssertFalse(TechnicalRecovery.isReportOnlyChange(diagnostic, files: [path, "Game.swift"]))
        XCTAssertFalse(TechnicalRecovery.isReportOnlyChange(source, files: [path]))
        XCTAssertFalse(TechnicalRecovery.isReportOnlyChange(diagnostic, files: ["reviews/another.json"]))
    }
    func testReportReadsImmutableCompletedAttemptCommit() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        let path = TechnicalRecovery.reportPath(source.recoveryIncident!)
        try "invalid later report".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try git(["add", path]); try git(["commit", "-m", "later branch change"])
        let ready = TechnicalRecovery.reconcile([source, done]).first { $0.id == source.id }
        XCTAssertEqual(ready?.state, .queued)
    }
    func testDiagnosticBusinessChangeCannotAuthorizeRecovery() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic)
        var attempt = try XCTUnwrap(WorkAttemptStore.latestSnapshots().last { $0.taskID == done.id })
        try "unexpected".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "source.txt"]); try git(["commit", "-m", "unauthorized business change"])
        attempt.headAfter = try git(["rev-parse", "HEAD"])
        try WorkAttemptStore.append(attempt)
        XCTAssertFalse(TechnicalRecovery.reconcile([source, done]).contains { $0.id == source.id && $0.state == .queued })
    }
}

extension TechnicalRecoveryTests {
    func testDiagnosticNextStepDoesNotStartUnboundedImplementationContinuation() throws {
        let (_, diagnostic) = try diagnosed()
        var done = diagnostic; done.state = .done
        let now = Date()
        let progress = WorkProgress(taskID: done.id, sequence: 2, phase: "诊断", summary: "完成诊断",
            nextStep: "原 Owner 修复代码", evidence: ["report.json"], evidenceFingerprint: "new",
            requestedMinutes: 5, updatedAt: now)
        XCTAssertNil(WorkContinuationGate.requeueIfNeeded(task: &done, startedAt: now.addingTimeInterval(-60),
            baselineSequence: 1, progress: progress))
        XCTAssertEqual(done.state, .done)
    }
    func testExpiredQueuedDiagnosisCannotConsumeAnotherExecutionSlot() throws {
        let (source, diagnostic) = try diagnosed()
        var leased = diagnostic
        leased.dispatchLeaseID = "not-started"
        leased.dispatchLeaseExpiresAt = source.recoveryIncident!.deadline.addingTimeInterval(60)
        let changes = TechnicalRecovery.reconcile([source, leased], now: source.recoveryIncident!.deadline.addingTimeInterval(1))
        let expired = try XCTUnwrap(changes.first { $0.id == diagnostic.id })
        XCTAssertEqual(expired.state, .failed)
        XCTAssertNil(expired.dispatchLeaseID)
        var running = diagnostic; running.state = .running
        XCTAssertFalse(TechnicalRecovery.reconcile([source, running], now: source.recoveryIncident!.deadline.addingTimeInterval(1))
            .contains { $0.id == diagnostic.id })
    }
}

extension TechnicalRecoveryTests {
    func testWrongSourceReportCannotExtendExpiredDiagnosticBudget() throws {
        let (source, diagnostic) = try diagnosed()
        let done = try finish(source, diagnostic) { $0.sourceTaskID = "another-task" }
        let changes = TechnicalRecovery.reconcile([source, done], now: source.recoveryIncident!.deadline.addingTimeInterval(1))
        XCTAssertEqual(changes.first { $0.id == source.id }?.recoveryIncident?.phase, "unresolved")
        XCTAssertFalse(changes.contains { $0.id == diagnostic.id && $0.state == .queued })
    }
}
