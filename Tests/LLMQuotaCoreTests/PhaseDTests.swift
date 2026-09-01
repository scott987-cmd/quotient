import XCTest
@testable import LLMQuotaCore

final class PhaseDTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase-d-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Paths.appSupportOverride = scratch.appendingPathComponent("app-support")
        SharedConfigJournal.directoryOverride = scratch.appendingPathComponent("config-journal")
        AgentRegistry.directoryOverride = scratch.appendingPathComponent("agent-registry")
        CollaborationStore.directoryOverride = scratch.appendingPathComponent("collaboration")
        AgentConsultation.responseOverride = nil
        ContextPackRollout.fileOverride = nil
    }

    override func tearDown() {
        AgentConsultation.responseOverride = nil
        CollaborationStore.directoryOverride = nil
        AgentRegistry.directoryOverride = nil
        SharedConfigJournal.directoryOverride = nil
        ContextPackRollout.fileOverride = nil
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func snapshot(_ id: String, name: String, at: Date) -> MachineSnapshot {
        MachineSnapshot(
            machineID: id, machineName: name, generatedAt: at,
            retentionStart: .distantPast, platforms: [])
    }

    func testSameNamedMachinesRemainDistinctByStableMachineID() {
        let now = Date()
        let dashboard = QuotaEngine(config: PlansConfig(plans: [])).buildDashboard(
            snapshots: [
                snapshot("hardware-A", name: "Mac mini", at: now),
                snapshot("hardware-B", name: "Mac mini", at: now),
            ], now: now)

        XCTAssertEqual(Set(dashboard.machines.map(\.machineID)), ["hardware-A", "hardware-B"])
    }

    func testOnlyExplicitProjectCoordinatorMayAutoRefill() {
        var repo = RepoAlias(alias: "flint", path: "/tmp/Flint")
        repo.coordinatorMachineID = "machine-A"

        XCTAssertTrue(AutoRefill.isDesignatedCoordinator(repo: repo, machineID: "machine-A"))
        XCTAssertFalse(AutoRefill.isDesignatedCoordinator(repo: repo, machineID: "machine-B"))
        repo.coordinatorMachineID = nil
        XCTAssertFalse(AutoRefill.isDesignatedCoordinator(repo: repo, machineID: "machine-A"),
                       "没有明确协调节点必须失败关闭，不能让每台机器都补同一份活")
    }

    func testSharedConfigurationRejectsStaleRevisionAndKeepsConflictVisible() throws {
        let compatibility = scratch.appendingPathComponent("roles.json")
        let initial = SharedConfigJournal.snapshot(
            document: "roles", compatibilityFile: compatibility)
        XCTAssertEqual(initial.revision, 0)

        _ = try SharedConfigJournal.commit(
            document: "roles", payload: Data("first".utf8),
            expectedRevision: initial.revision, compatibilityFile: compatibility,
            writerMachineID: "machine-A")

        XCTAssertThrowsError(try SharedConfigJournal.commit(
            document: "roles", payload: Data("stale".utf8),
            expectedRevision: initial.revision, compatibilityFile: compatibility,
            writerMachineID: "machine-B"))
        XCTAssertEqual(SharedConfigJournal.snapshot(
            document: "roles", compatibilityFile: compatibility).data,
                       Data("first".utf8))
        XCTAssertEqual(SharedConfigJournal.conflicts(document: "roles").count, 1)
    }

    func testOfflineSiblingConfigWritesRemainVisibleAsConflictAfterUnion() throws {
        let a = scratch.appendingPathComponent("journal-a", isDirectory: true)
        let b = scratch.appendingPathComponent("journal-b", isDirectory: true)
        let merged = scratch.appendingPathComponent("journal-merged", isDirectory: true)
        let configA = scratch.appendingPathComponent("a.json")
        let configB = scratch.appendingPathComponent("b.json")
        try FileManager.default.createDirectory(at: merged, withIntermediateDirectories: true)

        SharedConfigJournal.directoryOverride = a
        _ = try SharedConfigJournal.commit(
            document: "roles", payload: Data("A".utf8), expectedRevision: 0,
            compatibilityFile: configA, writerMachineID: "machine-a")
        SharedConfigJournal.directoryOverride = b
        _ = try SharedConfigJournal.commit(
            document: "roles", payload: Data("B".utf8), expectedRevision: 0,
            compatibilityFile: configB, writerMachineID: "machine-b")
        for directory in [a, b] {
            for file in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                try FileManager.default.copyItem(
                    at: file, to: merged.appendingPathComponent(file.lastPathComponent))
            }
        }

        SharedConfigJournal.directoryOverride = merged
        let snapshot = SharedConfigJournal.snapshot(
            document: "roles", compatibilityFile: configA)
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(SharedConfigJournal.conflicts(document: "roles").count, 1)
    }

    func testPlansAndContextRolloutUseRevisionCAS() throws {
        var plans = PlansConfig.template()
        plans.plans[0].planName = "revision-one"
        try PlansStore.save(plans, force: true, expectedRevision: 0)
        var stale = plans
        stale.plans[0].planName = "stale-write"
        XCTAssertThrowsError(try PlansStore.save(
            stale, force: true, expectedRevision: 0))
        XCTAssertEqual(PlansStore.load().plans[0].planName, "revision-one")
        var external = plans
        external.plans[0].planName = "other-machine"
        let externalData = try SnapshotCoding.prettyEncoder().encode(external)
        _ = try SharedConfigJournal.commit(
            document: "plans", payload: externalData, expectedRevision: 1,
            compatibilityFile: PlansStore.canonicalFile,
            writerMachineID: "other-machine")
        XCTAssertThrowsError(try PlansStore.save(plans, force: true),
                             "读后修改必须携带旧 revision，不能在保存瞬间偷换成最新 revision")

        ContextPackRollout.fileOverride = scratch.appendingPathComponent("rollout.json")
        try ContextPackRollout.save(.init(enabledAliases: ["flint"]), expectedRevision: 0)
        XCTAssertThrowsError(try ContextPackRollout.save(
            .init(enabledAliases: ["maw"]), expectedRevision: 0))
        XCTAssertEqual(ContextPackRollout.load().enabledAliases, ["flint"])
    }

    func testAgentRegistryKeepsSameRunnerOnTwoMachinesDistinct() throws {
        try AgentRegistry.publish([
            .init(machineID: "machine-A", machineName: "Mac mini",
                  runnerID: "codex.code", platform: .codex, canConsult: true),
        ], machineID: "machine-A")
        try AgentRegistry.publish([
            .init(machineID: "machine-B", machineName: "Mac mini",
                  runnerID: "codex.code", platform: .codex, canConsult: true),
        ], machineID: "machine-B")

        let registrations = AgentRegistry.all(now: Date())
        XCTAssertEqual(registrations.count, 2)
        XCTAssertEqual(Set(registrations.map(\.machineID)), ["machine-A", "machine-B"])
    }

    func testSubmittingConsultationDoesNotForgeRecipientClaim() throws {
        let registrations = [AgentRegistration(
            machineID: "architect-machine", machineName: "MacBook",
            runnerID: "codex.code", platform: .codex, canConsult: true)]
        let question = try AgentConsultation.submit(.init(
            id: "kimi-asks-codex", project: "/tmp/Flint", taskID: "flint-task",
            senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            question: "状态机边界应该放在哪一层？"), registrations: registrations)

        XCTAssertEqual(question.kind, .question)
        XCTAssertEqual(question.recipientMachineID, "architect-machine")
        XCTAssertEqual(CollaborationStore.all().map(\.kind), [.question],
                       "认领必须由接收方真正开始处理时发布，提问方不能代写")
    }

    func testRecipientProcessPublishesRealClaimThenAnswer() throws {
        struct CodexStub: AgentRunner {
            let platform: Platform = .codex
            let runnerID = "codex.code"
            let binaryName = "true"
            let binaryPath: String? = "/usr/bin/true"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/usr/bin/true", [], [:])
            }
        }
        let registration = AgentRegistration(
            machineID: "architect-machine", machineName: "MacBook",
            runnerID: "codex.code", platform: .codex, canConsult: true)
        _ = try AgentConsultation.submit(.init(
            id: "async-question", project: "/tmp/Flint", taskID: "flint-task",
            senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            question: "是否保留当前 owner？"), registrations: [registration])
        AgentConsultation.responseOverride = { _ in "保留 Kimi owner，只返回架构结论。" }

        let answer = try AgentConsultation.respond(
            questionID: "async-question", machineID: "architect-machine",
            runners: [CodexStub()])

        XCTAssertEqual(answer.kind, .answer)
        XCTAssertEqual(answer.senderMachineID, "architect-machine")
        XCTAssertEqual(CollaborationStore.all().map(\.kind), [.question, .claim, .answer])
        XCTAssertEqual(CollaborationStore.all()[1].senderMachineID, "architect-machine")
    }

    func testMobileRelationshipExposesAnswerAdoptionState() throws {
        let question = try CollaborationStore.publish(CollaborationEvent(
            id: "q", project: "/tmp/Flint", taskID: "task",
            senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            kind: .question, summary: "架构怎么定？"))
        let answer = try CollaborationStore.publish(CollaborationEvent(
            id: "a", project: "/tmp/Flint", taskID: "task",
            senderRunnerID: "codex.code", recipientRunnerID: "kimi.code",
            kind: .answer, summary: "采用单写者", replyTo: question.id))

        var page = ViewFeed.collaborationPage(tasks: [])
        var card = try XCTUnwrap(page.sections.first { $0.title == "交互关系" }?.cards?.first)
        XCTAssertTrue(card.body?.contains("采用　待 Kimi 确认") == true)

        _ = try CollaborationStore.acknowledge(
            eventID: answer.id, project: answer.project, taskID: answer.taskID,
            senderRunnerID: "kimi.code", summary: "已采用到实现")
        page = ViewFeed.collaborationPage(tasks: [])
        card = try XCTUnwrap(page.sections.first { $0.title == "交互关系" }?.cards?.first)
        XCTAssertTrue(card.body?.contains("采用　Kimi 已确认") == true)
    }

    func testMobileCollaborationListsConsultableAgentsByMachineIdentity() throws {
        try AgentRegistry.publish([
            .init(machineID: "machine-A", machineName: "Mac mini",
                  runnerID: "codex.code", platform: .codex, canConsult: true),
        ], machineID: "machine-A")
        try AgentRegistry.publish([
            .init(machineID: "machine-B", machineName: "Mac mini",
                  runnerID: "codex.code", platform: .codex, canConsult: false),
        ], machineID: "machine-B")

        let page = ViewFeed.collaborationPage(tasks: [])
        let section = try XCTUnwrap(page.sections.first { $0.title == "可用 Agent" })
        XCTAssertEqual(section.cards?.count, 2)
        XCTAssertEqual(Set(section.cards?.compactMap(\.body) ?? []), [
            "Mac mini\nmachine-A", "Mac mini\nmachine-B",
        ])
        XCTAssertEqual(Set(section.cards?.compactMap(\.detail) ?? []), [
            "Codex · 可接收咨询", "Codex · 仅执行任务",
        ])
    }

    func testConsultationRunsAsOneShotIndependentJob() throws {
        let spec = ConsultationJobSpec(
            questionID: "q-1", machineID: "machine-a",
            executable: "/usr/local/bin/llmq", logPath: "/tmp/consultation.log")
        let data = try ConsultationJobLauncher.propertyListData(for: spec)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            "/usr/local/bin/llmq", "collaboration", "respond", "q-1",
        ])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?[
            "LLMQ_CONSULTATION_WORKER"], "1")
    }
}
