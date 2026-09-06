import XCTest
import CryptoKit
@testable import LLMQuotaCore

final class StageFindingLoopTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var source: WorkTask!
    private var observation: WorkTask!
    private var observedHead: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("finding-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        Paths.appSupportOverride = root.appendingPathComponent("support")
        AskStore.rootOverride = root.appendingPathComponent("shared")
        CollaborationStore.directoryOverride = root.appendingPathComponent("events")
        AgentRegistry.directoryOverride = root.appendingPathComponent("agents")
        TaskStore.resetWrittenRevForTests()
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "test@example.invalid"])
        try git(["config", "user.name", "Isolated fixture"])
        try "source".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); observedHead = try git(["commit", "-m", "source"])
        observedHead = try git(["rev-parse", "HEAD"])
        try git(["branch", "agent/kimi/source"])
        source = WorkTask(id: "source", prompt: "只修复角色手臂蒙皮，不制作 HUD", repo: repo.path)
        source.state = .running; source.branch = "agent/kimi/source"
        source.ownerRunnerID = "kimi.code"; source.ownerPlatform = .kimi
        observation = WorkTask(id: "observation", prompt: """
        【看效果】阶段观察
        【阶段观察 v1】
        来源任务：source
        来源分支：agent/kimi/source
        证据提交：\(observedHead!)
        """, repo: repo.path)
        observation.origin = "milestone-eyes"; observation.state = .done
        observation.ownerRunnerID = "minimax"; observation.ownerPlatform = .minimax
        observation.branch = "agent/minimax/observation"
        try git(["checkout", "-b", observation.branch!])
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("reviews"), withIntermediateDirectories: true)
        try "**阶段观察**：发现可见问题\n持枪画面右臂拉伸。截图 frame.png；本次蒙皮目标适用。".write(
            to: repo.appendingPathComponent("reviews/EVAL-视觉-observation.md"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "observation report"])
        try WorkAttemptStore.append(WorkAttempt(attemptID: "eyes-attempt", taskID: observation.id,
            runnerID: observation.ownerRunnerID!, platform: .minimax, startedAt: Date(),
            endedAt: Date(), outcome: .done, headBefore: observedHead,
            headAfter: try git(["rev-parse", "HEAD"]), timedOut: false))
        try AgentRegistry.publish([.init(machineID: Paths.machineID(), machineName: "Fixture",
            runnerID: CodexRunner().runnerID, platform: .codex, canConsult: true,
            canReadFiles: true, canSeeMedia: CodexRunner().canSeeMedia)])
        source = try TaskStore.create(source, actor: "fixture", reason: "isolated")
        observation = try TaskStore.create(observation, actor: "fixture", reason: "isolated")
        try FileManager.default.createDirectory(at: Review.evidenceDir, withIntermediateDirectories: true)
        try Data("initial visual fixture".utf8).write(to: Review.evidenceDir.appendingPathComponent("frame.png"))
        XCTAssertTrue(Milestone.save([.init(repo: repo.path, repoName: "Fixture",
            branch: source.branch!, mergeSHA: observedHead, subject: "蒙皮", landedAt: Date(),
            evidenceFiles: ["frame.png"], taskID: source.id, isCheckpoint: true)]))
    }
    override func tearDown() {
        Paths.appSupportOverride = nil; AskStore.rootOverride = nil
        CollaborationStore.directoryOverride = nil; AgentRegistry.directoryOverride = nil
        TaskStore.resetWrittenRevForTests()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }
    @discardableResult private func git(_ args: [String]) throws -> String {
        let r = GitWorkspace.git(args, in: repo.path, timeout: 5)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testLateArchitectAnswerCannotOrderRepairOfAnOldCommit() throws {
        StageFindingLoop.synchronize(TaskStore.all())
        let q = try XCTUnwrap(CollaborationStore.all().first { $0.kind == .question })
        try git(["checkout", source.branch!])
        try "new progress".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "owner advanced before answer"])
        try answer(q, decision: "fixNow")
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertFalse(CollaborationStore.all().contains { $0.kind == .finding })
    }

    func testLateObservationCannotTriageAfterSourceCommitHasAdvanced() throws {
        try git(["checkout", source.branch!])
        try "already repaired".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "new owner progress"])
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertFalse(CollaborationStore.all().contains { $0.kind == .question })
    }

    func testCompletedObservationCreatesDirectedScopeTriageWithoutInterruptingOwner() throws {
        try TaskGraph.persistReconciliation(actor: "fixture", reason: "isolated")
        let question = try XCTUnwrap(CollaborationStore.all().first {
            $0.kind == .question && $0.taskID == source.id
        })
        XCTAssertEqual(question.recipientRunnerID, CodexRunner().runnerID)
        XCTAssertEqual(question.recipientMachineID, Paths.machineID())
        XCTAssertTrue(question.details?.contains(observedHead) == true)
        let current = try XCTUnwrap(TaskStore.all().first { $0.id == source.id })
        XCTAssertEqual(current.state, .running)
        XCTAssertEqual(current.ownerRunnerID, source.ownerRunnerID)
        XCTAssertNil(current.pendingAsk)
        try TaskGraph.persistReconciliation(actor: "fixture", reason: "repeat")
        XCTAssertEqual(CollaborationStore.all().filter { $0.kind == .question }.count, 1)
    }

    private func triage(_ decision: String = "fixNow") throws -> CollaborationEvent {
        StageFindingLoop.synchronize(TaskStore.all())
        let q = try XCTUnwrap(CollaborationStore.all().first { $0.kind == .question })
        try answer(q, decision: decision)
        StageFindingLoop.synchronize(TaskStore.all())
        return q
    }
    private func answer(_ q: CollaborationEvent, decision: String,
                        edit: (inout StageFindingLoop.Assessment) -> Void = { _ in }) throws {
        let c = try XCTUnwrap(StageFindingLoop.context(q))
        var a = StageFindingLoop.Assessment(questionID: q.id, sourceTaskID: source.id,
            sourceHead: c.sourceHead, decision: decision, reason: "右臂拉伸", criterion: "当前蒙皮目标",
            evidence: ["实际画面右臂顶点拉伸"], steps: ["修正上臂权重后拍摄同动作"])
        edit(&a)
        let raw = String(data: try JSONEncoder().encode(a), encoding: .utf8)!
        let details = try StageFindingLoop.answerDetails(raw, question: q)
        try CollaborationStore.publish(.init(project: repo.path, taskID: source.id,
            senderRunnerID: q.recipientRunnerID!, senderMachineID: q.recipientMachineID!,
            kind: .answer, summary: "范围复核", details: details, replyTo: q.id))
    }
    func testOnlyConfirmedApplicableFindingRequiresRepairAndAckDoesNotCloseIt() throws {
        let q = try triage()
        let finding = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        XCTAssertFalse(finding.acknowledged); XCTAssertFalse(finding.resolved)
        try CollaborationStore.acknowledge(eventID: finding.event.id, project: repo.path,
            taskID: source.id, senderRunnerID: source.ownerRunnerID!)
        try CollaborationStore.publish(.init(project: repo.path, taskID: source.id,
            senderRunnerID: source.ownerRunnerID!, kind: .result, summary: "声称完成", replyTo: q.id))
        let acked = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        XCTAssertTrue(acked.acknowledged); XCTAssertFalse(acked.resolved)
        XCTAssertNotNil(Review.qualityLandingBlock(repo: repo.path, branch: source.branch!, tasks: [source]))
        XCTAssertTrue(StageFindingLoop.reconcile([source]).isEmpty, "不能打断实际运行者")
        var done = source!; done.state = .done
        let queued = try XCTUnwrap(StageFindingLoop.reconcile([done]).first)
        XCTAssertEqual(queued.state, .queued); XCTAssertEqual(queued.ownerRunnerID, source.ownerRunnerID)
        XCTAssertEqual(queued.branch, source.branch)
        XCTAssertEqual(queued.findingRequeueIDs, [finding.event.id])
        let decoded = try SnapshotCoding.decoder().decode(WorkTask.self, from: SnapshotCoding.encoder().encode(queued))
        var ended = decoded; ended.state = .done
        let held = try XCTUnwrap(StageFindingLoop.reconcile([ended]).first)
        XCTAssertEqual(held.state, .blocked, "同一问题不能无限自动续作")
    }
    func testDeferredObservationDoesNotBecomeOwnerRework() throws {
        _ = try triage("notApplicable")
        XCTAssertTrue(StageFindingLoop.findings(for: source).isEmpty)
        var done = source!; done.state = .done
        XCTAssertTrue(StageFindingLoop.reconcile([done]).isEmpty)
        XCTAssertNil(Review.qualityLandingBlock(repo: repo.path, branch: source.branch!, tasks: [source]))
    }
    func testWrongSnapshotUnknownDecisionAndNoEvidenceAreRejected() throws {
        StageFindingLoop.synchronize(TaskStore.all())
        let q = try XCTUnwrap(CollaborationStore.all().first { $0.kind == .question })
        XCTAssertThrowsError(try answer(q, decision: "fixNow") { $0.sourceHead = String(repeating: "a", count: 40) })
        XCTAssertThrowsError(try answer(q, decision: "looksGood"))
        XCTAssertThrowsError(try answer(q, decision: "fixNow") { $0.evidence = [] })
        XCTAssertThrowsError(try answer(q, decision: "fixNow") { $0.criterion = "" })
        XCTAssertThrowsError(try answer(q, decision: "fixNow") { $0.sourceTaskID = "another" })
        XCTAssertTrue(StageFindingLoop.findings(for: source).isEmpty)
    }
    func testIndependentNewEvidenceClosesOnlyAfterOwnerAcknowledgement() throws {
        _ = try triage()
        let f = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        try git(["checkout", source.branch!])
        try "fixed".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "repair"])
        let fixedHead = try git(["rev-parse", "HEAD"])
        var item = try XCTUnwrap(Milestone.all().first)
        item.mergeSHA = fixedHead; item.landedAt = Date().addingTimeInterval(1)
        XCTAssertTrue(Milestone.save(Milestone.all() + [item]))
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertFalse(CollaborationStore.all().contains { $0.id.hasPrefix("stage-recheck:") })
        try CollaborationStore.acknowledge(eventID: f.event.id, project: repo.path,
            taskID: source.id, senderRunnerID: source.ownerRunnerID!)
        try freshObservation(head: fixedHead, id: "old-proof", files: ["frame.png"])
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertFalse(CollaborationStore.all().contains { $0.id.hasPrefix("stage-recheck:") }, "旧图换提交号仍不是新证据")
        try Data("new visual fixture".utf8).write(to: Review.evidenceDir.appendingPathComponent("fixed.png"))
        item.evidenceFiles = ["fixed.png"]
        XCTAssertTrue(Milestone.save([item]))
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertFalse(CollaborationStore.all().contains { $0.id.hasPrefix("stage-recheck:") }, "新图没有被该视觉报告看过，不能借相同代码 SHA 复用报告")
        try freshObservation(head: fixedHead, id: "fresh-proof", files: ["fixed.png"])
        StageFindingLoop.synchronize(TaskStore.all())
        let q = try XCTUnwrap(CollaborationStore.all().first { $0.id.hasPrefix("stage-recheck:") })
        XCTAssertNotEqual(q.recipientRunnerID, source.ownerRunnerID)
        try answer(q, decision: "resolved")
        XCTAssertTrue(StageFindingLoop.findings(for: source).first?.resolved == true)
        XCTAssertNil(Review.qualityLandingBlock(repo: repo.path, branch: source.branch!, tasks: [source]))
    }
    private func freshObservation(head: String, id: String, files: [String]) throws {
        var fresh = observation!
        fresh.id = id; fresh.rev = 0; fresh.createdAt = Date()
        fresh.prompt = fresh.prompt.replacingOccurrences(of: observedHead, with: head)
        let hashes = try files.map { name in
            let data = try Data(contentsOf: Review.evidenceDir.appendingPathComponent(name))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.sorted()
        fresh.prompt += "\n证据摘要：" + hashes.joined(separator: ",")
        fresh.branch = "agent/minimax/" + id
        try git(["checkout", "-b", fresh.branch!, head])
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("reviews"), withIntermediateDirectories: true)
        try "**阶段观察**：未见明显问题\n新画面右臂权重正常，无拉伸；只判断当前持枪姿势。".write(
            to: repo.appendingPathComponent("reviews/EVAL-视觉-\(id).md"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "fresh independent observation"])
        try WorkAttemptStore.append(WorkAttempt(attemptID: "eyes-" + id, taskID: fresh.id,
            runnerID: fresh.ownerRunnerID!, platform: .minimax, startedAt: Date(), endedAt: Date(),
            outcome: .done, headBefore: head, headAfter: try git(["rev-parse", "HEAD"]), timedOut: false))
        _ = try TaskStore.create(fresh, actor: "fixture", reason: "fresh independent observation")
    }

    func testNewImageAndCommitAloneCannotTriggerArchitectSignoffWithoutVisualObserver() throws {
        _ = try triage()
        let f = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        try CollaborationStore.acknowledge(eventID: f.event.id, project: repo.path,
            taskID: source.id, senderRunnerID: source.ownerRunnerID!)
        try git(["checkout", source.branch!])
        try "fixed".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "repair"])
        let head = try git(["rev-parse", "HEAD"])
        try Data("fresh image fixture".utf8).write(to: Review.evidenceDir.appendingPathComponent("new.png"))
        var item = try XCTUnwrap(Milestone.all().first)
        item.mergeSHA = head; item.evidenceFiles = ["new.png"]; item.landedAt = Date().addingTimeInterval(1)
        XCTAssertTrue(Milestone.save([item]))
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertFalse(CollaborationStore.all().contains { $0.id.hasPrefix("stage-recheck:") })
        XCTAssertFalse(StageFindingLoop.findings(for: source).first?.resolved == true)
    }
    func testStaleOrAmbiguousObservationCannotCreateTriage() throws {
        var duplicate = source!; duplicate.id = "other-source"
        var legacy = observation!; legacy.prompt = legacy.prompt.replacingOccurrences(of: "来源任务：source\n", with: "")
        StageFindingLoop.synchronize([source, duplicate, legacy])
        XCTAssertTrue(CollaborationStore.all().isEmpty)
        var stale = observation!; stale.terminalAttemptID = "new-unfinished-attempt"
        StageFindingLoop.synchronize([source, stale])
        XCTAssertTrue(CollaborationStore.all().isEmpty)
    }

    func testOwnerCannotSignOffOwnFindingAndRealQuestionIsPreserved() throws {
        StageFindingLoop.synchronize(TaskStore.all())
        let q = try XCTUnwrap(CollaborationStore.all().first { $0.kind == .question })
        let a = StageFindingLoop.Assessment(questionID: q.id, sourceTaskID: source.id,
            sourceHead: observedHead, decision: "fixNow", reason: "蒙皮拉伸", criterion: "蒙皮目标",
            evidence: ["frame.png"], steps: ["修复权重"])
        let details = try StageFindingLoop.answerDetails(String(data: JSONEncoder().encode(a), encoding: .utf8)!, question: q)
        try CollaborationStore.publish(.init(project: repo.path, taskID: source.id,
            senderRunnerID: source.ownerRunnerID!, kind: .answer, summary: "自签", details: details, replyTo: q.id))
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertTrue(StageFindingLoop.findings(for: source).isEmpty)
        // 隔离日志里清除伪答复，再让指定架构师真实签发一个适用问题。
        try FileManager.default.removeItem(at: CollaborationStore.directory)
        _ = try triage()
        var blocked = source!; blocked.state = .blocked; blocked.waitReason = .humanAnswer
        blocked.pendingAsk = Ask(taskID: source.id, machineID: "fixture", round: 1,
            platform: .kimi, taskPrompt: source.prompt, repoName: repo.path,
            questions: [Ask.Question(text: "授权素材选择？")])
        XCTAssertTrue(StageFindingLoop.reconcile([blocked]).isEmpty)
    }
    func testSameRunnerOnAnotherMachineCannotAcknowledgeOwnerFinding() throws {
        _ = try triage()
        let f = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        try CollaborationStore.publish(.init(project: repo.path, taskID: source.id,
            senderRunnerID: source.ownerRunnerID!, senderMachineID: "another-machine",
            kind: .ack, summary: "另一台机器的同名执行器", replyTo: f.event.id))
        XCTAssertFalse(StageFindingLoop.findings(for: source).first?.acknowledged == true)
        XCTAssertEqual(f.event.recipientMachineID, Paths.machineID())
    }
    func testOwnerOrBranchDriftPreservesLandingBlockWithoutAutomaticReassignment() throws {
        _ = try triage()
        for change in 0..<3 {
            var drifted = source!; drifted.state = .done
            if change == 0 { drifted.ownerRunnerID = "qwen.code" }
            if change == 1 { drifted.ownerPlatform = .qwen }
            if change == 2 { drifted.branch = "agent/kimi/other" }
            XCTAssertEqual(StageFindingLoop.findings(for: drifted).filter { !$0.resolved }.count, 1)
            XCTAssertNotNil(Review.qualityLandingBlock(repo: repo.path, branch: drifted.branch!, tasks: [drifted]))
            XCTAssertNotNil(Review.qualityLandingBlock(repo: repo.path, branch: source.branch!, tasks: [drifted]))
            XCTAssertFalse(StageFindingLoop.reconcile([drifted]).contains { $0.state == .queued })
        }
        var moved = source!; moved.state = .done
        XCTAssertFalse(StageFindingLoop.reconcile([moved], machineID: "another-machine").contains { $0.state == .queued })
    }
    func testNewObservationCannotTriageOverwrittenEvidence() throws {
        var bound = observation!
        bound.prompt += "\n证据摘要：" + StageFindingLoop.evidenceDigests(["frame.png"]).joined(separator: ",")
        try Data("replaced after observation".utf8).write(to: Review.evidenceDir.appendingPathComponent("frame.png"))
        StageFindingLoop.synchronize([source, bound])
        XCTAssertTrue(CollaborationStore.all().isEmpty)
    }
    private func failQuestion(_ q: CollaborationEvent) throws {
        try CollaborationStore.publish(.init(id: "consultation-failure:" + q.id + ":" + Paths.machineID(),
            project: repo.path, taskID: source.id, senderRunnerID: "consultation-executor",
            kind: .finding, summary: "隔离夹具：响应未形成有效 JSON", replyTo: q.id))
    }
    func testFailedTriageRetriesOnceWithoutHumanAskOrPendingDuplication() throws {
        StageFindingLoop.synchronize(TaskStore.all())
        let q = try XCTUnwrap(CollaborationStore.all().first { $0.kind == .question })
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertEqual(CollaborationStore.all().filter { $0.kind == .question }.count, 1)
        try failQuestion(q)
        StageFindingLoop.synchronize(TaskStore.all())
        let questions = CollaborationStore.all().filter { $0.kind == .question }
        XCTAssertEqual(questions.count, 2)
        if let retry = questions.first(where: { $0.id != q.id }) { try failQuestion(retry) }
        StageFindingLoop.synchronize(TaskStore.all())
        XCTAssertEqual(CollaborationStore.all().filter { $0.kind == .question }.count, 2)
        XCTAssertNil(TaskStore.all().first { $0.id == source.id }?.pendingAsk)
    }
    func testTrackedFindingCannotDisappearWhenJournalOrContextIsMissing() throws {
        _ = try triage()
        var done = source!; done.state = .done
        var queued = try XCTUnwrap(StageFindingLoop.reconcile([done]).first)
        queued.state = .done
        try FileManager.default.removeItem(at: CollaborationStore.directory)
        XCTAssertNotNil(Review.qualityLandingBlock(repo: repo.path, branch: queued.branch!, tasks: [queued]))
        XCTAssertEqual(StageFindingLoop.reconcile([queued]).first?.state, .blocked)
    }
    func testDirectedAcknowledgementAndInboxRespectMachineIdentity() throws {
        _ = try triage()
        let f = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        try CollaborationStore.publish(.init(project: repo.path, taskID: source.id,
            senderRunnerID: source.ownerRunnerID!, senderMachineID: "another-machine",
            kind: .ack, summary: "另一台同名执行器", replyTo: f.event.id))
        XCTAssertTrue(CollaborationStore.unresolved(project: repo.path, recipientRunnerID: source.ownerRunnerID).contains { $0.id == f.event.id })
        let remote = try CollaborationStore.publish(.init(project: repo.path, taskID: source.id,
            senderRunnerID: "architect", recipientRunnerID: source.ownerRunnerID!, recipientMachineID: "another-machine",
            kind: .finding, summary: "仅属于另一台机器"))
        XCTAssertFalse(CollaborationStore.context(project: repo.path, taskID: source.id, runnerID: source.ownerRunnerID!).contains { $0.id == remote.id })
        XCTAssertThrowsError(try CollaborationStore.acknowledge(eventID: remote.id, project: repo.path,
            taskID: source.id, senderRunnerID: source.ownerRunnerID!))
    }
    func testSameCommitDifferentEvidenceSelectsMatchingMilestone() throws {
        var bound = observation!
        try Data("second evidence".utf8).write(to: Review.evidenceDir.appendingPathComponent("second.png"))
        bound.prompt += "\n证据摘要：" + StageFindingLoop.evidenceDigests(["second.png"]).joined(separator: ",")
        var second = try XCTUnwrap(Milestone.all().first); second.evidenceFiles = ["second.png"]
        XCTAssertTrue(Milestone.save(Milestone.all() + [second]))
        StageFindingLoop.synchronize([source, bound])
        XCTAssertEqual(CollaborationStore.all().filter { $0.kind == .question }.count, 1)
    }
    func testKnownFindingWithMissingContextStillBlocksBeforeFirstRequeue() throws {
        _ = try triage()
        let f = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        try FileManager.default.removeItem(at: CollaborationStore.directory)
        try CollaborationStore.publish(f.event)
        var done = source!; done.state = .done
        XCTAssertNotNil(Review.qualityLandingBlock(repo: repo.path, branch: done.branch!, tasks: [done]))
        XCTAssertEqual(StageFindingLoop.reconcile([done]).first?.state, .blocked)
    }
    func testSameHeadNewEvidenceCanRecheckAfterNeedsEvidenceWithoutRepeatingOldProof() throws {
        _ = try triage()
        let f = try XCTUnwrap(StageFindingLoop.findings(for: source).first)
        try CollaborationStore.acknowledge(eventID: f.event.id, project: repo.path,
            taskID: source.id, senderRunnerID: source.ownerRunnerID!)
        try git(["checkout", source.branch!])
        try "fixed".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "repair"])
        let head = try git(["rev-parse", "HEAD"])
        var item = try XCTUnwrap(Milestone.all().first)
        item.mergeSHA = head; item.landedAt = Date().addingTimeInterval(1)
        for i in 1...2 {
            let file = "proof-\(i).png"
            try Data("fresh visual \(i)".utf8).write(to: Review.evidenceDir.appendingPathComponent(file))
            item.evidenceFiles = [file]
            XCTAssertTrue(Milestone.save([item]))
            try freshObservation(head: head, id: "eyes-\(i)", files: [file])
            StageFindingLoop.synchronize(TaskStore.all())
            let qs = CollaborationStore.all().filter { $0.id.hasPrefix("stage-recheck:") }
            XCTAssertEqual(qs.count, i)
            if let q = qs.last { try answer(q, decision: i == 1 ? "needsEvidence" : "resolved") }
            StageFindingLoop.synchronize(TaskStore.all())
            XCTAssertEqual(CollaborationStore.all().filter { $0.id.hasPrefix("stage-recheck:") }.count, i)
        }
        XCTAssertTrue(StageFindingLoop.findings(for: source).first?.resolved == true)
    }

}
