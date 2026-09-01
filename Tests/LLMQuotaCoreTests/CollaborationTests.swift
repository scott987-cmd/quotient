import XCTest
@testable import LLMQuotaCore

final class CollaborationTests: XCTestCase {
    func testInternalArtifactProjectionFitsProtocolWithoutChangingOrder() {
        let files = (0..<52).map { "file-\($0).swift" }
        let projected = CollaborationEvent.boundedArtifacts(files)
        XCTAssertEqual(projected.count, CollaborationEvent.maxArtifacts)
        XCTAssertEqual(projected.first, "file-0.swift")
        XCTAssertEqual(projected.last, "file-49.swift")
    }

    func testBriefingTruncatesHistoricalOutputInsteadOfReplayingLogs() throws {
        try publish(summary: String(repeating: "x", count: 2_000))
        let briefing = CollaborationStore.briefing(
            project: "/tmp/project-a", taskID: "task-a", runnerID: "kimi.code")
        XCTAssertLessThan(briefing.count, 1_000)
        XCTAssertTrue(briefing.contains(String(repeating: "x", count: 400)))
        XCTAssertFalse(briefing.contains(String(repeating: "x", count: 401)))
    }

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collaboration-" + UUID().uuidString)
        CollaborationStore.directoryOverride = scratch
        // Agent 发现会合并跨机注册表；测试必须使用自己的空注册目录，不能
        // 把开发机此刻真实在线的 Claude/MiniMax 等 Agent 当成夹具。
        AgentRegistry.directoryOverride = scratch.appendingPathComponent("agent-registry")
    }

    override func tearDown() {
        AgentConsultation.responseOverride = nil
        AgentRegistry.directoryOverride = nil
        CollaborationStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    @discardableResult
    private func publish(id: String = UUID().uuidString, project: String = "/tmp/project-a",
                         task: String? = "task-a", sender: String = "kimi.code",
                         to: String? = nil, kind: CollaborationEvent.Kind = .finding,
                         summary: String = "发现一个可复查的问题",
                         replyTo: String? = nil, machine: String = "machine-A",
                         at: Date = Date()) throws -> CollaborationEvent {
        try CollaborationStore.publish(CollaborationEvent(
            id: id, project: project, taskID: task,
            senderRunnerID: sender, senderMachineID: machine,
            recipientRunnerID: to, kind: kind, summary: summary,
            replyTo: replyTo, createdAt: at))
    }

    private func task(id: String, owner: String, platform: Platform,
                      origin: String? = nil) -> WorkTask {
        var task = WorkTask(id: id, prompt: "测试任务 " + id, repo: "/tmp/project-a")
        task.ownerRunnerID = owner
        task.ownerPlatform = platform
        task.platform = platform
        task.origin = origin
        return task
    }

    func testPerMachineAppendOnlyJournalsMergeWithoutOverwrite() throws {
        try publish(id: "a", summary: "A 的结论", machine: "machine-A")
        try publish(id: "b", sender: "claude.code", summary: "B 的结论",
                    machine: "machine-B")

        XCTAssertEqual(Set(CollaborationStore.all().map(\.id)), ["a", "b"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("machine-A.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("machine-B.jsonl").path))
    }

    func testDuplicateIDAcrossMachinesDeterministicallyKeepsEarliestFact() throws {
        let start = Date()
        let first = CollaborationEvent(
            id: "same", project: "/tmp/project-a", senderRunnerID: "kimi.code",
            senderMachineID: "machine-B", kind: .finding, summary: "最早的事实",
            createdAt: start)
        let later = CollaborationEvent(
            id: "same", project: "/tmp/project-a", senderRunnerID: "claude.code",
            senderMachineID: "machine-A", kind: .finding, summary: "较晚的重试",
            createdAt: start.addingTimeInterval(1))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for (machine, event) in [("machine-B", first), ("machine-A", later)] {
            var data = try SnapshotCoding.encoder().encode(event)
            data.append(UInt8(ascii: "\n"))
            try data.write(to: scratch.appendingPathComponent(machine + ".jsonl"))
        }
        XCTAssertEqual(CollaborationStore.all().map(\.summary), ["最早的事实"])
    }

    func testPublishAndAcknowledgeAreIdempotent() throws {
        let event = CollaborationEvent(
            id: "stable-id", project: "/tmp/project-a", taskID: "task-a",
            senderRunnerID: "kimi.code", senderMachineID: "machine-A",
            kind: .decision, summary: "统一采用方案 A")
        _ = try CollaborationStore.publish(event)
        _ = try CollaborationStore.publish(event)
        _ = try CollaborationStore.acknowledge(
            eventID: event.id, project: event.project, taskID: event.taskID,
            senderRunnerID: "claude.code")
        _ = try CollaborationStore.acknowledge(
            eventID: event.id, project: event.project, taskID: event.taskID,
            senderRunnerID: "claude.code")

        XCTAssertEqual(CollaborationStore.all().filter { $0.id == event.id }.count, 1)
        XCTAssertEqual(CollaborationStore.all().filter {
            $0.kind == .ack && $0.replyTo == event.id
        }.count, 1)
        XCTAssertTrue(CollaborationStore.unresolved(project: event.project).isEmpty)
    }

    func testContextDoesNotLeakOtherProjectTaskOrRecipient() throws {
        try publish(id: "broadcast", task: nil, summary: "项目广播")
        try publish(id: "mine", to: "kimi.code", summary: "给 Kimi")
        try publish(id: "other-runner", sender: "claude.code", to: "claude.code",
                    summary: "给 Claude")
        try publish(id: "other-task", task: "task-b", summary: "另一个任务")
        try publish(id: "other-project", project: "/tmp/project-b", summary: "另一个项目")
        try publish(id: "started", kind: .started, summary: "只是开工轨迹")

        let ids = Set(CollaborationStore.context(
            project: "/tmp/project-a", taskID: "task-a", runnerID: "kimi.code").map(\.id))
        XCTAssertEqual(ids, ["broadcast", "mine"])
    }

    func testAnswerClosesQuestionAndBriefingMarksOnlyPending() throws {
        try publish(id: "q1", kind: .question, summary: "接口返回值怎么定？")
        XCTAssertTrue(CollaborationStore.briefing(
            project: "/tmp/project-a", taskID: "task-a",
            runnerID: "kimi.code").contains("[待回应]"))

        try publish(id: "answer", sender: "claude.code", kind: .answer,
                    summary: "沿用兼容字段", replyTo: "q1")
        XCTAssertTrue(CollaborationStore.unresolved(project: "/tmp/project-a").isEmpty)
        XCTAssertFalse(CollaborationStore.briefing(
            project: "/tmp/project-a", taskID: "task-a",
            runnerID: "kimi.code").contains("[待回应]"))
    }

    func testLaterTaskResultClosesHandoff() throws {
        let start = Date()
        try publish(id: "handoff", kind: .handoff, summary: "前一棒超时", at: start)
        try publish(id: "result", sender: "claude.code", kind: .result,
                    summary: "接手后已完成", at: start.addingTimeInterval(1))
        XCTAssertTrue(CollaborationStore.unresolved(project: "/tmp/project-a").isEmpty)
    }

    func testRecipientForwardingSameTaskClosesPreviousHandoff() throws {
        let start = Date()
        try publish(id: "runner-to-scheduler", sender: "opencode.openrouter.code",
                    to: "orchestrator", kind: .handoff, summary: "模型已下线",
                    at: start)
        try publish(id: "scheduler-to-kimi", sender: "orchestrator", to: "kimi.code",
                    kind: .handoff, summary: "改由 Kimi 延续同一任务",
                    at: start.addingTimeInterval(1))

        XCTAssertEqual(CollaborationStore.unresolved(project: "/tmp/project-a").map(\.id),
                       ["scheduler-to-kimi"])
    }

    func testMalformedLineDoesNotLoseValidEventsAndOldSchemaDecodes() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = #"{"project":"/tmp/project-a","senderRunnerID":"old","senderMachineID":"machine-A","kind":"checkpoint","summary":"old"}"#
        try (Data("not-json\n".utf8) + Data(old.utf8) + Data("\n".utf8))
            .write(to: scratch.appendingPathComponent("machine-A.jsonl"))

        let events = CollaborationStore.all()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].schemaVersion, 1)
        XCTAssertEqual(events[0].artifacts, [])
    }

    func testMCPListsToolsAndPublishesUsingSameStore() throws {
        let list = try XCTUnwrap(CollaborationMCP.response(for: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        ]))
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), [
            "collaboration_list_agents", "collaboration_get_context",
            "collaboration_publish", "collaboration_ack", "collaboration_ask"
        ])

        let response = try XCTUnwrap(CollaborationMCP.response(for: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "collaboration_publish", "arguments": [
                "id": "via-mcp", "project": "/tmp/project-a",
                "senderRunnerID": "kimi.code", "kind": "checkpoint",
                "summary": "已完成第一阶段"
            ]]
        ]))
        let result = response["result"] as? [String: Any]
        XCTAssertNil(result?["isError"])
        XCTAssertEqual(CollaborationStore.all().map(\.id), ["via-mcp"])
    }

    func testDynamicMobilePageAndMenuExposeCollaboration() throws {
        try publish(id: "pending", kind: .finding, summary: "需要另一位 Agent 复核")
        let page = ViewFeed.collaborationPage(tasks: [])
        XCTAssertEqual(page.page, "collaboration")
        let cards: [ViewFeed.Card] = page.sections.flatMap { $0.cards ?? [] }
        let pending = cards.first { $0.id == "pending" }
        XCTAssertNotNil(pending)
        XCTAssertTrue(pending?.title.contains("待回应") == true)
        XCTAssertEqual(pending?.eventKind, "finding")
        XCTAssertEqual(pending?.taskID, "task-a")
        let entry = ViewFeed.menu().entries.first { $0.page == "collaboration" }
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.badge, "Agent 待回应不是人的未读消息，不能制造幽灵角标")
    }

    func testDynamicPageShowsWhoClaimedWhoseWorkAsReadableChains() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try publish(id: "task-claim", task: "74726e09", sender: "minimax.code",
                    kind: .claim, summary: "主动认领：修复 Flint 手势",
                    at: start)
        try publish(id: "task-start", task: "74726e09", sender: "minimax.code",
                    kind: .started, summary: "开始执行：修复 Flint 手势",
                    at: start.addingTimeInterval(1))
        try publish(id: "question", task: "other-task", sender: "codex.architect",
                    to: "claude.code", kind: .question, summary: "骨骼约束应该放在哪一层？",
                    at: start.addingTimeInterval(10))
        try publish(id: "question-claim", task: "other-task", sender: "claude.code",
                    kind: .claim, summary: "我来检查骨骼约束", replyTo: "question",
                    at: start.addingTimeInterval(11))
        try publish(id: "answer", task: "other-task", sender: "claude.code",
                    kind: .answer, summary: "约束放在绑定层", replyTo: "question",
                    at: start.addingTimeInterval(12))

        let page = ViewFeed.collaborationPage(
            now: start.addingTimeInterval(20),
            tasks: [
                task(id: "74726e09", owner: "minimax.code", platform: .minimax),
                task(id: "other-task", owner: "claude.code", platform: .claude),
            ])
        let section = try XCTUnwrap(page.sections.first { $0.title == "交互关系" })
        let cards = try XCTUnwrap(section.cards)
        XCTAssertEqual(cards.count, 2, "手机应按工作链聚合，不能把五个动作摊成五张任务卡")
        XCTAssertTrue(cards[0].title.contains("Codex ⇄ Claude"))
        XCTAssertTrue(cards[0].body?.contains("提问　Codex → Claude") == true)
        XCTAssertTrue(cards[0].body?.contains("认领　Codex → Claude") == true)
        XCTAssertTrue(cards[0].body?.contains("回复　Claude → Codex") == true)
        XCTAssertTrue(cards[1].title.contains("调度器 → MiniMax"))
        XCTAssertTrue(cards[1].body?.contains("认领　调度器 → MiniMax") == true)
        XCTAssertTrue(cards[1].body?.contains("执行　MiniMax") == true)

        let recent = try XCTUnwrap(page.sections.first { $0.title == "最近记录" }?.cards)
        XCTAssertEqual(recent.map(\.id),
                       ["answer", "question-claim", "question", "task-start", "task-claim"],
                       "最近记录必须按全局时间倒序，不能受工作链分组顺序影响")
    }

    func testCurrentPageDoesNotLetTerminalMiniMaxNoiseReplaceRunningWork() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try publish(id: "old-handoff", task: "old-minimax", sender: "minimax.media",
                    to: "orchestrator", kind: .handoff, summary: "历史媒体任务失败",
                    at: start)
        try publish(id: "current-claim", task: "current-kimi", sender: "kimi.code",
                    kind: .claim, summary: "认领当前功能任务",
                    at: start.addingTimeInterval(10))
        var old = task(id: "old-minimax", owner: "minimax.media", platform: .minimax)
        old.state = .failed
        old.endedAt = start.addingTimeInterval(2)
        var current = task(id: "current-kimi", owner: "kimi.code", platform: .kimi)
        current.state = .running

        let page = ViewFeed.collaborationPage(
            now: start.addingTimeInterval(20), tasks: [old, current])
        let relationships = try XCTUnwrap(
            page.sections.first { $0.title == "交互关系" }?.cards)
        XCTAssertEqual(relationships.count, 1)
        XCTAssertTrue(relationships[0].title.contains("Kimi"))
        XCTAssertFalse(relationships[0].title.contains("MiniMax"))
        let facts = try XCTUnwrap(page.sections.first { $0.title == "协作状态" }?.facts)
        XCTAssertEqual(facts.first { $0.key == "待回应" }?.value, "0",
                       "终态任务的旧 handoff 不能继续冒充当前待回应")
    }

    func testProductionShapedBroadcastEventsStillExposeReviewRelationship() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, kind, summary) in [
            (0.0, CollaborationEvent.Kind.claim, "主动认领：架构复核"),
            (1.0, .started, "开始执行：架构复核"),
            (2.0, .finding, "评审结论需要推翻"),
            (3.0, .result, "复核完成")
        ] {
            try publish(id: "event-\(Int(offset))", task: "a3c3b538",
                        sender: "claude.code", kind: kind, summary: summary,
                        at: start.addingTimeInterval(offset))
        }
        let source = task(id: "3c3b538d", owner: "minimax.review", platform: .minimax)
        let review = task(id: "a3c3b538", owner: "claude.code", platform: .claude,
                          origin: "architect-review:3c3b538d")

        let page = ViewFeed.collaborationPage(
            now: start.addingTimeInterval(10), tasks: [source, review])
        let section = try XCTUnwrap(page.sections.first { $0.title == "交互关系" })
        let card = try XCTUnwrap(section.cards?.first)
        XCTAssertTrue(card.title.contains("MiniMax → Claude"))
        XCTAssertTrue(card.title.contains("架构复核 3c3b538d"))
        XCTAssertTrue(card.body?.contains("认领　MiniMax → Claude") == true)
        XCTAssertTrue(card.body?.contains("发现　Claude → MiniMax") == true)
        XCTAssertTrue(card.body?.contains("交付　Claude → MiniMax") == true)
        XCTAssertFalse(card.body?.contains("项目广播") == true,
                       "缺接收方的历史记录也必须投影成真实任务关系")

        let recent = try XCTUnwrap(page.sections.first { $0.title == "最近记录" }?.cards)
        XCTAssertTrue(recent.allSatisfy { $0.body?.contains("项目广播") != true })
        XCTAssertTrue(recent.first?.body?.contains("交付　Claude → MiniMax") == true)
    }

    func testCollaborationContractRequiresExplicitAcknowledgement() {
        let clause = CollaborationStore.conventionClause(
            project: "/tmp/project-a", taskID: "task-a", runnerID: "minimax.code")
        XCTAssertTrue(clause.contains("collaboration_ack"))
        XCTAssertTrue(clause.contains("llmq collaboration ack <事件ID>"))
        XCTAssertTrue(clause.contains("不能静默跳过"))
        XCTAssertTrue(clause.contains("llmq collaboration agents"),
                      "Agent 必须先能发现稳定 ID，不能让它猜 --to 参数")
        XCTAssertTrue(clause.contains("codex.code"))
        XCTAssertTrue(clause.contains("架构"),
                      "架构疑问必须明确路由给 Codex，而不是只给一条泛化命令")
    }

    func testAvailableConsultationAgentsDoNotAdvertiseUnsupportedTargets() {
        struct Stub: AgentRunner {
            let platform: Platform
            let runnerID: String
            let binaryName = "true"
            let binaryPath: String? = "/usr/bin/true"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/usr/bin/true", [], [:])
            }
        }
        let runners: [AgentRunner] = [
            Stub(platform: .codex, runnerID: "codex.code"),
            Stub(platform: .kimi, runnerID: "kimi.code"),
            Stub(platform: .qwen, runnerID: "qwen.code"),
            Stub(platform: .minimax, runnerID: "minimax.code"),
        ]

        XCTAssertEqual(
            AgentConsultation.availableAgents(runners: runners).map(\.runnerID),
            ["codex.code"],
            "发现接口不能把尚无只读执行器的目标展示为可咨询 Agent")
    }

    func testEventSizeIsBounded() throws {
        XCTAssertThrowsError(try publish(summary: String(repeating: "x", count: 2_001)))
        XCTAssertTrue(CollaborationStore.all().isEmpty)
    }

    func testTargetedConsultationPublishesQuestionClaimAndAnswer() throws {
        struct Stub: AgentRunner {
            let platform: Platform = .claude
            let runnerID = "claude.test"
            let binaryName = "true"
            let binaryPath: String? = "/usr/bin/true"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/usr/bin/true", [], [:])
            }
        }
        AgentConsultation.responseOverride = { request in
            XCTAssertEqual(request.recipientRunnerID, "claude.test")
            return "结论：保留 owner，只回传最小答案。"
        }

        let answer = try AgentConsultation.ask(.init(
            id: "q-stable", project: "/tmp/project-a", taskID: "task-a",
            senderRunnerID: "opencode.openrouter.code",
            recipientRunnerID: "claude.test", question: "这个边界是否正确？"),
            runners: [Stub()])

        XCTAssertEqual(answer.kind, .answer)
        XCTAssertEqual(answer.replyTo, "q-stable")
        let events = CollaborationStore.all()
        XCTAssertEqual(events.map(\.kind), [.question, .claim, .answer])
        XCTAssertEqual(events[1].replyTo, "q-stable")
        XCTAssertEqual(events[1].senderRunnerID, "claude.test")
        XCTAssertTrue(CollaborationStore.unresolved(project: "/tmp/project-a").isEmpty)

        let retried = try AgentConsultation.ask(.init(
            id: "q-stable", project: "/tmp/project-a", taskID: "task-a",
            senderRunnerID: "opencode.openrouter.code",
            recipientRunnerID: "claude.test", question: "这个边界是否正确？"),
            runners: [Stub()])
        XCTAssertEqual(retried.id, answer.id)
        XCTAssertEqual(CollaborationStore.all().count, 3, "重试复用答案，不能再耗一次 token")
    }

    func testKimiCanConsultCodexArchitectThroughReadOnlyRunner() throws {
        struct CodexStub: AgentRunner {
            let platform: Platform = .codex
            let runnerID = "codex.code"
            let binaryName = "echo"
            let binaryPath: String? = "/bin/echo"
            func command(prompt: String, cwd: String)
                -> (launchPath: String, args: [String], env: [String: String]) {
                ("/bin/echo", ["unused"], [:])
            }
        }
        let repo = scratch.appendingPathComponent("consult-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(Proc.run("/usr/bin/git", ["init", "-b", "main"],
                                cwd: repo.path, env: [:], timeout: 10).exitCode, 0)
        try "# consultation fixture\n".write(
            to: repo.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        XCTAssertEqual(Proc.run("/usr/bin/git", ["add", "README.md"],
                                cwd: repo.path, env: [:], timeout: 10).exitCode, 0)
        XCTAssertEqual(Proc.run("/usr/bin/git", [
            "-c", "user.name=LLMQ Test", "-c", "user.email=test@localhost",
            "commit", "-m", "fixture"
        ], cwd: repo.path, env: [:], timeout: 10).exitCode, 0)

        let answer = try AgentConsultation.ask(.init(
            id: "kimi-to-codex", project: repo.path, taskID: "task-a",
            senderRunnerID: "kimi.code", recipientRunnerID: "codex.code",
            question: "这个技术边界是否应由架构层裁决？"),
            runners: [CodexStub()])

        XCTAssertEqual(answer.kind, .answer)
        XCTAssertEqual(answer.senderRunnerID, "codex.code")
        XCTAssertEqual(answer.recipientRunnerID, "kimi.code")
        XCTAssertEqual(CollaborationStore.all().map(\.kind), [.question, .claim, .answer])
    }

    func testOpenCodeMCPInstallPreservesExistingConfiguration() throws {
        let config = scratch.appendingPathComponent("opencode.json")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let original: [String: Any] = [
            "provider": ["openrouter": ["options": ["apiKey": "keep-me"]]],
            "mcp": ["existing": ["type": "remote", "url": "https://example.test"]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: config)

        _ = try CollaborationMCPInstaller.installOpenCode(
            executable: "/tmp/llmq", config: config)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: config)) as? [String: Any])
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        XCTAssertNotNil(providers["openrouter"], "不得覆盖用户现有 provider 与凭据")
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        XCTAssertNotNil(mcp["existing"], "不得覆盖已有 MCP")
        let installed = try XCTUnwrap(mcp[CollaborationMCPInstaller.serverName]
                                      as? [String: Any])
        XCTAssertEqual(installed["command"] as? [String],
                       ["/tmp/llmq", "collaboration", "mcp"])
    }
}
