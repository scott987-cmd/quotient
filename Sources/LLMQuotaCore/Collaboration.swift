import Foundation

/// Agent 之间可以长期保存、跨机器合并的协作事实。
///
/// 这里只存结论、问题、证据和交接，不保存模型的隐藏推理。每台机器只追加
/// `<machineID>.jsonl`，读时合并所有机器的日志；这样不会出现两台机器覆盖同一
/// 个 JSON 的多写者问题，也不需要为了 MCP 再开放一个网络端口。
public struct CollaborationEvent: Codable, Sendable, Equatable {
    public static let maxArtifacts = 50
    public static let maxBriefingSummaryCharacters = 400

    /// 内部生产者把完整变更清单投影成协议允许的大小；存储层仍会拒绝外部
    /// 直接塞进来的超限事件，不能靠静默截断掩盖坏输入。
    public static func boundedArtifacts(_ artifacts: [String]) -> [String] {
        Array(artifacts.prefix(maxArtifacts))
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case claim, started, question, answer, decision, finding, checkpoint, result, handoff, ack

        public var needsResponse: Bool {
            switch self {
            case .question, .decision, .finding, .handoff: return true
            default: return false
            }
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var project: String
    public var taskID: String?
    public var graphID: String?
    public var lane: TaskCapabilityLane?
    public var senderRunnerID: String
    public var senderPlatform: Platform?
    public var senderMachineID: String
    /// nil 表示同项目内广播。
    public var recipientRunnerID: String?
    /// 定向消息实际归哪台机器处理。Runner ID 在多台机器上可以相同，不能靠名字猜。
    public var recipientMachineID: String?
    public var kind: Kind
    public var summary: String
    public var details: String?
    /// 回答、确认或补充所指向的事件。
    public var replyTo: String?
    public var branch: String?
    public var commitSHA: String?
    public var artifacts: [String]
    public var createdAt: Date

    public init(schemaVersion: Int = 1,
                id: String = UUID().uuidString.lowercased(),
                project: String, taskID: String? = nil, graphID: String? = nil,
                lane: TaskCapabilityLane? = nil,
                senderRunnerID: String, senderPlatform: Platform? = nil,
                senderMachineID: String = Paths.machineID(),
                recipientRunnerID: String? = nil,
                recipientMachineID: String? = nil,
                kind: Kind, summary: String, details: String? = nil,
                replyTo: String? = nil, branch: String? = nil,
                commitSHA: String? = nil, artifacts: [String] = [],
                createdAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.project = CollaborationStore.normalizeProject(project)
        self.taskID = taskID
        self.graphID = graphID
        self.lane = lane
        self.senderRunnerID = senderRunnerID
        self.senderPlatform = senderPlatform
        self.senderMachineID = senderMachineID
        self.recipientRunnerID = recipientRunnerID
        self.recipientMachineID = recipientMachineID
        self.kind = kind
        self.summary = summary
        self.details = details
        self.replyTo = replyTo
        self.branch = branch
        self.commitSHA = commitSHA
        self.artifacts = artifacts
        self.createdAt = createdAt
    }

    /// 共享数据会被不同版本的两台机器同时读取，缺字段必须安全降级。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        project = CollaborationStore.normalizeProject(
            try c.decodeIfPresent(String.self, forKey: .project) ?? "")
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        graphID = try c.decodeIfPresent(String.self, forKey: .graphID)
        lane = try c.decodeIfPresent(TaskCapabilityLane.self, forKey: .lane)
        senderRunnerID = try c.decodeIfPresent(String.self, forKey: .senderRunnerID) ?? "unknown"
        senderPlatform = try c.decodeIfPresent(Platform.self, forKey: .senderPlatform)
        senderMachineID = try c.decodeIfPresent(String.self, forKey: .senderMachineID) ?? "unknown"
        recipientRunnerID = try c.decodeIfPresent(String.self, forKey: .recipientRunnerID)
        recipientMachineID = try c.decodeIfPresent(String.self, forKey: .recipientMachineID)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .checkpoint
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA)
        artifacts = try c.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}

public enum CollaborationStore {
    /// 测试注入口；产品环境固定落在共享暂存的 collaboration/。
    public static var directoryOverride: URL?
    private static let processLock = NSLock()

    public static var directory: URL {
        directoryOverride
            ?? Paths.sharedRoot.appendingPathComponent("collaboration", isDirectory: true)
    }

    public static func normalizeProject(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.path
    }

    public static func journal(machineID: String = Paths.machineID()) -> URL {
        let safe = machineID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return directory.appendingPathComponent(String(safe) + ".jsonl")
    }

    /// 合并所有机器的追加日志。坏掉的一行不会让整本协作账无法读取。
    public static func all() -> [CollaborationEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let decoder = SnapshotCoding.decoder()
        var decoded: [CollaborationEvent] = []
        for file in files where file.pathExtension == "jsonl" {
            guard let data = ICloudSafe.read(file) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let event = try? decoder.decode(CollaborationEvent.self,
                                                       from: Data(line)) else { continue }
                decoded.append(event)
            }
        }
        // 文件枚举顺序没有保证；先按时间排，再以 ID 去重，冲突时才能稳定保留
        // 最早写下的事实，而不是两台机器每次读取随机赢一台。
        decoded.sort(by: timelineOrder)
        var byID: [String: CollaborationEvent] = [:]
        for event in decoded where byID[event.id] == nil { byID[event.id] = event }
        return byID.values.sorted(by: timelineOrder)
    }

    /// ISO-8601 落盘只保留到秒，同一秒内不能再拿字典序冒充时间顺序。
    /// 先尊重显式 replyTo，再按工作语义排；最后才用 ID 保证跨机确定性。
    private static func timelineOrder(_ lhs: CollaborationEvent,
                                      _ rhs: CollaborationEvent) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.replyTo == rhs.id { return false }
        if rhs.replyTo == lhs.id { return true }
        func rank(_ kind: CollaborationEvent.Kind) -> Int {
            switch kind {
            case .claim: return 0
            case .started: return 1
            case .question: return 2
            case .answer: return 3
            case .decision, .finding: return 4
            case .checkpoint: return 5
            case .result: return 6
            case .handoff: return 7
            case .ack: return 8
            }
        }
        let leftRank = rank(lhs.kind), rightRank = rank(rhs.kind)
        return leftRank == rightRank ? lhs.id < rhs.id : leftRank < rightRank
    }

    /// 同一个事件 ID 重试不会追加第二份。
    @discardableResult
    public static func publish(_ event: CollaborationEvent) throws -> CollaborationEvent {
        processLock.lock(); defer { processLock.unlock() }
        guard !event.id.isEmpty, !event.project.isEmpty,
              !event.senderRunnerID.isEmpty, !event.summary.isEmpty else {
            throw error(4, "协作事件缺少 id、project、senderRunnerID 或 summary")
        }
        guard event.id.count <= 512, event.project.count <= 4_096,
              event.senderRunnerID.count <= 256,
              (event.recipientRunnerID?.count ?? 0) <= 256,
              event.summary.count <= 2_000,
              (event.details?.count ?? 0) <= 20_000,
              event.artifacts.count <= CollaborationEvent.maxArtifacts,
              event.artifacts.allSatisfy({ $0.count <= 4_096 }) else {
            throw error(5, "协作事件过大（summary 2000、details 20000、artifacts 50）")
        }
        if let existing = all().first(where: { $0.id == event.id }) { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try SnapshotCoding.encoder().encode(event)
        data.append(UInt8(ascii: "\n"))
        let file = journal(machineID: event.senderMachineID)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw error(1, "协作日志打不开") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw error(2, "协作日志加锁失败") }
        defer { flock(fd, LOCK_UN) }
        // 进程锁只能管当前进程；拿到文件锁后再检查一次，挡住两个 CLI 同时重试。
        if let existingData = ICloudSafe.read(file) {
            let decoder = SnapshotCoding.decoder()
            let existing = existingData.split(separator: UInt8(ascii: "\n")).compactMap {
                try? decoder.decode(CollaborationEvent.self, from: Data($0))
            }.first { $0.id == event.id }
            if let existing { return existing }
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw error(3, "协作日志写入不完整") }
            offset += count
        }
        return event
    }

    /// 确认是独立事件，因此两台机器的确认也都能保留下来；同一 Runner 重试幂等。
    @discardableResult
    public static func acknowledge(eventID: String, project: String,
                                   taskID: String? = nil,
                                   senderRunnerID: String,
                                   senderPlatform: Platform? = nil,
                                   summary: String = "已收到并纳入后续工作") throws
        -> CollaborationEvent {
        let normalized = normalizeProject(project)
        guard all().contains(where: { $0.id == eventID && $0.project == normalized }) else {
            throw error(6, "要确认的协作事件不存在于这个项目")
        }
        if let existing = all().first(where: {
            $0.kind == .ack && $0.replyTo == eventID
                && $0.senderRunnerID == senderRunnerID
                && $0.project == normalized
        }) { return existing }
        return try publish(CollaborationEvent(
            id: "ack:" + eventID + ":" + senderRunnerID,
            project: normalized, taskID: taskID,
            senderRunnerID: senderRunnerID, senderPlatform: senderPlatform,
            kind: .ack, summary: summary, replyTo: eventID))
    }

    /// 当前仍需要接收方处理的事件。answer 和 ack 都会关闭它所引用的事件。
    public static func unresolved(project: String? = nil,
                                  recipientRunnerID: String? = nil) -> [CollaborationEvent] {
        let events = all()
        let resolved = resolvedIDs(in: events)
        let normalized = project.map(normalizeProject)
        return events.filter { event in
            event.kind.needsResponse && !resolved.contains(event.id)
                && (normalized == nil || event.project == normalized)
                && (recipientRunnerID == nil || event.recipientRunnerID == nil
                    || event.recipientRunnerID == recipientRunnerID)
        }
    }

    /// 给一个 Runner 的增量协作上下文。项目广播、明确发给它的消息，以及它自己
    /// 发起的线程会被带入；别的项目和发给别人的私有消息不会泄漏进提示词。
    public static func context(project: String, taskID: String? = nil,
                               graphID: String? = nil, runnerID: String,
                               limit: Int = 18) -> [CollaborationEvent] {
        let normalized = normalizeProject(project)
        return Array(all().filter { event in
            guard event.project == normalized else { return false }
            let sameScope = event.taskID == nil || event.taskID == taskID
                || (graphID != nil && event.graphID == graphID)
            let visible = event.recipientRunnerID == nil
                || event.recipientRunnerID == runnerID
                || event.senderRunnerID == runnerID
            // started 留在手机时间线里，但不占 Agent 的有限上下文；它不含可执行事实。
            return sameScope && visible && event.kind != .started
        }.suffix(max(1, min(limit, 50))))
    }

    public static func briefing(project: String, taskID: String? = nil,
                                graphID: String? = nil, runnerID: String) -> String {
        let events = context(project: project, taskID: taskID,
                             graphID: graphID, runnerID: runnerID)
        guard !events.isEmpty else { return "" }
        let resolved = resolvedIDs(in: events)
        var lines = [
            "【Agent 协作账（跨会话持久化）】",
            "以下是同项目已确认的显式事实，不是隐藏推理。先处理未确认项；引用事件 ID 回复或确认，避免重复讨论。"
        ]
        for event in events {
            let target = event.recipientRunnerID.map { " → \($0)" } ?? ""
            let pending = event.kind.needsResponse && !resolved.contains(event.id) ? " [待回应]" : ""
            let summary = String(event.summary.prefix(
                CollaborationEvent.maxBriefingSummaryCharacters))
            var line = "- [\(event.id)] \(event.kind.rawValue) · \(event.senderRunnerID)\(target)\(pending)：\(summary)"
            if let branch = event.branch { line += "；分支 \(branch)" }
            if let sha = event.commitSHA { line += "；提交 \(sha)" }
            if !event.artifacts.isEmpty { line += "；材料 " + event.artifacts.prefix(5).joined(separator: "、") }
            lines.append(line)
        }
        return "\n\n" + lines.joined(separator: "\n")
    }

    /// 即使当前还没有历史，也告诉 Agent 如何给下一棒留下结构化信息。
    /// 只给「怎么留下结构化事实」的固定条款。briefing 部分由
    /// ContextPackBuilder 按预算和优先级单独装配，两者在这里分家；
    /// `contract` 继续返回完整拼接，旧调用点行为不变。
    public static func conventionClause(project: String, taskID: String? = nil,
                                        graphID: String? = nil,
                                        runnerID: String) -> String {
        var command = "llmq collaboration publish --project "
            + shellQuote(normalizeProject(project))
            + " --sender " + shellQuote(runnerID)
        if let taskID { command += " --task " + shellQuote(taskID) }
        if let graphID { command += " --graph " + shellQuote(graphID) }
        command += " --kind finding --summary '替换成一句可执行结论'"
        var ask = "llmq collaboration ask --project "
            + shellQuote(normalizeProject(project))
            + " --sender " + shellQuote(runnerID)
        if let taskID { ask += " --task " + shellQuote(taskID) }
        if let graphID { ask += " --graph " + shellQuote(graphID) }
        ask += " --to <runner-id> --id <稳定问题ID> --question '一句具体问题'"
        var ack = "llmq collaboration ack <事件ID> --project "
            + shellQuote(normalizeProject(project))
            + " --sender " + shellQuote(runnerID)
        if let taskID { ack += " --task " + shellQuote(taskID) }
        let agents = "llmq collaboration agents"
        return "\n\n【协作约定】遇到会影响下一棒的发现、决定或检查点时，"
            + "用下面的 publish 留下结构化事实；不要写隐藏推理。遇到确实会造成返工、"
            + "而另一位 Agent 的岗位更适合回答的工作疑问时，先问再实现，不要自行假设。"
            + "先用 agents 列出当前可咨询的稳定 ID；架构、契约、技术边界或是否偏离目标的疑问，"
            + "若列表中存在 codex.code，优先向 codex.code 定向咨询一次。咨询会进入接收机器的"
            + "独立一次性进程异步回答；提交后继续处理不依赖答案的工作，不改变当前任务 owner，"
            + "不得广播拉群或循环互问。回答到达后必须 ack 表明是否采用。收到定向的发现、决定或交接后，"
            + "先明确确认并纳入后续工作，不能静默跳过。若 MCP 可用，优先调用 "
            + "collaboration_list_agents / collaboration_ask / collaboration_publish / "
            + "collaboration_ack。\n"
            + agents + "\n" + command + "\n" + ask + "\n" + ack
    }

    public static func contract(project: String, taskID: String? = nil,
                                graphID: String? = nil, runnerID: String) -> String {
        return briefing(project: project, taskID: taskID, graphID: graphID, runnerID: runnerID)
            + conventionClause(project: project, taskID: taskID,
                               graphID: graphID, runnerID: runnerID)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "CollaborationStore", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 显式 answer/ack 关闭所引用事件；接收方把同一任务继续交给下一棒时，
    /// 上一棒交接也已处理；同任务更晚的终态 result 会关闭此前的交接/发现。
    ///
    /// 「一个事件算不算已解决」只能有一套判据 —— ContextProjection 也用
    /// 这份；两处各写一份迟早分叉（这个形状本项目踩过不止一次）。
    static func resolvedIDs(in events: [CollaborationEvent]) -> Set<String> {
        var resolved = Set(events.compactMap { event -> String? in
            guard event.kind == .answer || event.kind == .ack else { return nil }
            return event.replyTo
        })
        let results = events.filter { $0.kind == .result && $0.taskID != nil }
        let handoffs = events.filter { $0.kind == .handoff && $0.taskID != nil }
        for event in events where event.kind.needsResponse {
            if results.contains(where: {
                $0.project == event.project && $0.taskID == event.taskID
                    && $0.createdAt >= event.createdAt
            }) { resolved.insert(event.id) }
            if event.kind == .handoff, let recipient = event.recipientRunnerID,
               handoffs.contains(where: {
                   $0.project == event.project && $0.taskID == event.taskID
                       && $0.senderRunnerID == recipient && $0.createdAt > event.createdAt
               }) { resolved.insert(event.id) }
        }
        return resolved
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 无监听端口的 MCP stdio 实现。既能被支持 MCP 的 Agent 直接调用，也便于
/// CLI/测试复用同一套协议处理逻辑。
public enum CollaborationMCP {
    public static func response(for request: [String: Any]) -> [String: Any]? {
        guard let method = request["method"] as? String else { return failure(id: request["id"], code: -32600, message: "Invalid Request") }
        let id = request["id"]
        if method.hasPrefix("notifications/") { return nil }
        switch method {
        case "initialize":
            return success(id: id, result: [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "llmq-collaboration", "version": "1"]
            ])
        case "ping":
            return success(id: id, result: [:])
        case "tools/list":
            return success(id: id, result: ["tools": tools])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return failure(id: id, code: -32602, message: "Missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try call(name: name, arguments: args)
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                let text = String(decoding: data, as: UTF8.self)
                return success(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                return success(id: id, result: [
                    "isError": true,
                    "content": [["type": "text", "text": error.localizedDescription]]
                ])
            }
        default:
            return failure(id: id, code: -32601, message: "Method not found")
        }
    }

    public static func runStdio() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = response(for: request),
                  let out = try? JSONSerialization.data(withJSONObject: response,
                                                         options: [.sortedKeys]) else { continue }
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static var tools: [[String: Any]] {[
        ["name": "collaboration_list_agents",
         "description": "列出本机可定向咨询的 Agent 稳定 ID；不调用模型、不消耗额度",
         "inputSchema": objectSchema(required: [], properties: [:])],
        ["name": "collaboration_get_context",
         "description": "读取同项目、当前任务和当前 Agent 可见的协作事实与待回应项",
         "inputSchema": objectSchema(required: ["project", "runnerID"], properties: [
            "project": stringSchema("仓库绝对路径"), "runnerID": stringSchema("当前 Runner ID"),
            "taskID": stringSchema("任务 ID"), "graphID": stringSchema("任务图 ID")])],
        ["name": "collaboration_publish",
         "description": "发布问题、结论、发现、检查点、结果或交接；不要发布隐藏推理",
         "inputSchema": objectSchema(required: ["project", "senderRunnerID", "kind", "summary"], properties: [
            "id": stringSchema("重试时复用的幂等 ID"), "project": stringSchema("仓库绝对路径"),
            "taskID": stringSchema("任务 ID"), "graphID": stringSchema("任务图 ID"),
            "senderRunnerID": stringSchema("发送 Runner ID"), "recipientRunnerID": stringSchema("接收 Runner ID；省略为广播"),
            "kind": ["type": "string", "enum": CollaborationEvent.Kind.allCases
                .filter { $0 != .ack }.map(\.rawValue)],
            "summary": stringSchema("一行可执行结论"), "details": stringSchema("必要的补充说明"),
            "replyTo": stringSchema("所回复事件 ID"), "branch": stringSchema("分支"),
            "commitSHA": stringSchema("提交 SHA"), "artifacts": ["type": "array", "items": ["type": "string"]]])],
        ["name": "collaboration_ack",
         "description": "幂等确认一个协作事件已被接收并纳入后续工作",
         "inputSchema": objectSchema(required: ["eventID", "project", "senderRunnerID"], properties: [
            "eventID": stringSchema("要确认的事件 ID"), "project": stringSchema("仓库绝对路径"),
            "taskID": stringSchema("任务 ID"), "senderRunnerID": stringSchema("确认者 Runner ID"),
            "summary": stringSchema("确认说明")])],
        ["name": "collaboration_ask",
         "description": "向指定机器上的 Agent 投递一次异步、只读、最小上下文咨询；原任务 owner 不变，禁止嵌套咨询",
         "inputSchema": objectSchema(required: ["id", "project", "senderRunnerID",
                                                  "recipientRunnerID", "question"], properties: [
            "id": stringSchema("稳定问题 ID；重试必须复用"),
            "project": stringSchema("仓库绝对路径"), "taskID": stringSchema("当前任务 ID"),
            "graphID": stringSchema("任务图 ID"),
            "senderRunnerID": stringSchema("提问 Runner ID"),
            "recipientRunnerID": stringSchema("回答 Runner ID"),
            "question": stringSchema("一个具体、可执行的问题，最多 1200 字符"),
            "details": stringSchema("必要背景，最多 4000 字符"),
            "artifacts": ["type": "array", "items": ["type": "string"]]])]
    ]}

    private static func call(name: String, arguments a: [String: Any]) throws -> Any {
        func required(_ key: String) throws -> String {
            guard let value = a[key] as? String, !value.isEmpty else {
                throw NSError(domain: "CollaborationMCP", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "缺少参数 " + key])
            }
            return value
        }
        switch name {
        case "collaboration_list_agents":
            return AgentConsultation.availableAgents().map {
                ["runnerID": $0.runnerID, "platform": $0.platform.displayName,
                 "machineID": $0.machineID, "machineName": $0.machineName]
            }
        case "collaboration_get_context":
            return CollaborationStore.context(
                project: try required("project"), taskID: a["taskID"] as? String,
                graphID: a["graphID"] as? String, runnerID: try required("runnerID"))
                .map(eventObject)
        case "collaboration_publish":
            let rawKind = try required("kind")
            guard let kind = CollaborationEvent.Kind(rawValue: rawKind), kind != .ack else {
                throw NSError(domain: "CollaborationMCP", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "未知 kind：" + rawKind])
            }
            let event = CollaborationEvent(
                id: (a["id"] as? String) ?? UUID().uuidString.lowercased(),
                project: try required("project"), taskID: a["taskID"] as? String,
                graphID: a["graphID"] as? String,
                senderRunnerID: try required("senderRunnerID"),
                recipientRunnerID: a["recipientRunnerID"] as? String,
                kind: kind, summary: try required("summary"), details: a["details"] as? String,
                replyTo: a["replyTo"] as? String, branch: a["branch"] as? String,
                commitSHA: a["commitSHA"] as? String, artifacts: a["artifacts"] as? [String] ?? [])
            return eventObject(try CollaborationStore.publish(event))
        case "collaboration_ack":
            return eventObject(try CollaborationStore.acknowledge(
                eventID: try required("eventID"), project: try required("project"),
                taskID: a["taskID"] as? String, senderRunnerID: try required("senderRunnerID"),
                summary: a["summary"] as? String ?? "已收到并纳入后续工作"))
        case "collaboration_ask":
            let question = try AgentConsultation.submit(.init(
                id: try required("id"), project: try required("project"),
                taskID: a["taskID"] as? String, graphID: a["graphID"] as? String,
                senderRunnerID: try required("senderRunnerID"),
                recipientRunnerID: try required("recipientRunnerID"),
                question: try required("question"), details: a["details"] as? String,
                artifacts: a["artifacts"] as? [String] ?? []))
            return eventObject(question)
        default:
            throw NSError(domain: "CollaborationMCP", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "未知工具：" + name])
        }
    }

    private static func eventObject(_ event: CollaborationEvent) -> [String: Any] {
        let data = try? SnapshotCoding.encoder().encode(event)
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]) ?? [:]
    }

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func objectSchema(required: [String], properties: [String: Any]) -> [String: Any] {
        ["type": "object", "required": required, "properties": properties,
         "additionalProperties": false]
    }

    private static func success(id: Any?, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private static func failure(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(),
         "error": ["code": code, "message": message]]
    }
}

/// 一次有边界的 Agent → Agent 工作咨询。
///
/// 它不是第二个任务 owner，也不是让几个模型先开会。调用方保持在原生会话里，
/// 接收方使用自己在该项目上的稳定工作区和会话，只拿到一个问题、必要背景和
/// 协作账摘要。提问只追加问题事件并立即返回；接收方机器用独立进程真正开始处理时
/// 才发布 claim，回答随后异步写回。原任务 owner 始终不变。
public enum AgentConsultation {
    public struct Request: Sendable {
        public var id: String
        public var project: String
        public var taskID: String?
        public var graphID: String?
        public var senderRunnerID: String
        public var recipientRunnerID: String
        public var recipientMachineID: String?
        public var question: String
        public var details: String?
        public var artifacts: [String]

        public init(id: String, project: String, taskID: String? = nil,
                    graphID: String? = nil, senderRunnerID: String,
                    recipientRunnerID: String, recipientMachineID: String? = nil,
                    question: String,
                    details: String? = nil, artifacts: [String] = []) {
            self.id = id; self.project = project; self.taskID = taskID
            self.graphID = graphID; self.senderRunnerID = senderRunnerID
            self.recipientRunnerID = recipientRunnerID
            self.recipientMachineID = recipientMachineID; self.question = question
            self.details = details; self.artifacts = artifacts
        }
    }

    /// 测试注入口。产品环境为 nil，真正调用目标 Runner。
    public static var responseOverride: ((Request) throws -> String)?

    public static func availableAgents(
        runners: [AgentRunner] = RunnerRegistry.all
    ) -> [AgentRegistration] {
        let local = runners.filter {
            $0.isAvailable && $0.canReadFiles && !$0.mediaOnly
                && supportsReadOnlyConsultation($0)
        }.map {
            AgentRegistration(machineID: Paths.machineID(), machineName: Paths.machineName(),
                              runnerID: $0.runnerID, platform: $0.platform,
                              canConsult: true)
        }
        var byIdentity = Dictionary(uniqueKeysWithValues: AgentRegistry.all().map {
            ($0.machineID + "|" + $0.runnerID, $0)
        })
        for item in local { byIdentity[item.machineID + "|" + item.runnerID] = item }
        return byIdentity.values.filter(\.canConsult).sorted {
            if $0.runnerID != $1.runnerID { return $0.runnerID < $1.runnerID }
            return $0.machineID < $1.machineID
        }
    }

    /// 发现结果必须和真正可执行的只读咨询命令一致；否则 Agent 会看到一个
    /// 能选择、但提交后才报“不支持”的虚假目标。
    static func supportsReadOnlyConsultation(_ runner: AgentRunner) -> Bool {
        runner.runnerID == CodexRunner().runnerID
            || runner.runnerID == ClaudeRunner().runnerID
            || runner is MiniMaxCodeRunner
            || runner is OpenCodeRunner
    }

    /// 只发布问题，不替接收方认领，也不在提问进程里同步消耗另一模型的额度。
    @discardableResult
    public static func submit(
        _ request: Request,
        registrations: [AgentRegistration] = availableAgents()
    ) throws -> CollaborationEvent {
        guard ProcessInfo.processInfo.environment["LLMQ_CONSULTATION_DEPTH"] != "1" else {
            throw error(1, "咨询回答过程中不能再发起咨询，避免 Agent 循环互问")
        }
        guard request.senderRunnerID != request.recipientRunnerID else {
            throw error(2, "不能向自己发起 Agent 咨询")
        }
        guard !request.id.isEmpty, request.question.count <= 1_200,
              (request.details?.count ?? 0) <= 4_000,
              request.artifacts.count <= 5 else {
            throw error(3, "咨询必须有稳定 ID；问题最多 1200 字、背景最多 4000 字、材料最多 5 个")
        }
        let project = CollaborationStore.normalizeProject(request.project)
        let events = CollaborationStore.all()
        if let existing = events.first(where: { $0.id == request.id && $0.kind == .question }) {
            return existing
        }
        if CollaborationStore.unresolved(project: project).contains(where: {
            $0.id != request.id && $0.kind == .question
                && $0.taskID == request.taskID
                && $0.senderRunnerID == request.senderRunnerID
                && $0.recipientRunnerID != nil
        }) {
            throw error(4, "当前任务已有一条 Agent 咨询待回答；先处理它，不能广播拉群")
        }
        let candidates = registrations.filter {
            $0.runnerID == request.recipientRunnerID && $0.canConsult
                && (request.recipientMachineID == nil
                    || $0.machineID == request.recipientMachineID)
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.machineID < $1.machineID
        }
        guard let target = candidates.first else {
            throw error(5, "目标 Agent 未注册或不具备只读咨询能力："
                        + request.recipientRunnerID)
        }
        let question = try CollaborationStore.publish(CollaborationEvent(
            id: request.id, project: project, taskID: request.taskID,
            graphID: request.graphID, senderRunnerID: request.senderRunnerID,
            recipientRunnerID: request.recipientRunnerID,
            recipientMachineID: target.machineID, kind: .question,
            summary: request.question, details: request.details,
            artifacts: CollaborationEvent.boundedArtifacts(request.artifacts)))
        _ = ViewFeed.publish(ViewFeed.collaborationPage())
        return question
    }

    /// 由事件中指定的接收机器执行。claim 的 senderMachineID 因而是真实处理者，
    /// 不是提问方代写的 UI 轨迹。
    @discardableResult
    public static func respond(
        questionID: String, machineID: String = Paths.machineID(),
        runners: [AgentRunner] = RunnerRegistry.all
    ) throws -> CollaborationEvent {
        let events = CollaborationStore.all()
        if let existing = events.first(where: { $0.kind == .answer && $0.replyTo == questionID }) {
            return existing
        }
        guard let question = events.first(where: { $0.id == questionID && $0.kind == .question })
        else { throw error(10, "找不到要回答的问题：" + questionID) }
        guard question.recipientMachineID == nil || question.recipientMachineID == machineID else {
            throw error(11, "这个问题属于另一台机器：" + (question.recipientMachineID ?? "unknown"))
        }
        guard let target = runners.first(where: {
            $0.runnerID == question.recipientRunnerID && $0.isAvailable
                && $0.canReadFiles && !$0.mediaOnly
                && (responseOverride != nil || supportsReadOnlyConsultation($0))
        }) else {
            throw error(5, "本机没有可回答问题的 Agent：" + (question.recipientRunnerID ?? "unknown"))
        }
        let request = Request(
            id: question.id, project: question.project, taskID: question.taskID,
            graphID: question.graphID, senderRunnerID: question.senderRunnerID,
            recipientRunnerID: target.runnerID, recipientMachineID: machineID,
            question: question.summary, details: question.details,
            artifacts: question.artifacts)
        _ = try CollaborationStore.publish(CollaborationEvent(
            id: question.id + ":claim:" + machineID,
            project: question.project, taskID: question.taskID,
            graphID: question.graphID, senderRunnerID: target.runnerID,
            senderPlatform: target.platform, senderMachineID: machineID,
            recipientRunnerID: question.senderRunnerID,
            kind: .claim, summary: "认领咨询：" + String(question.summary.prefix(120)),
            replyTo: question.id))
        _ = ViewFeed.publish(ViewFeed.collaborationPage())
        let started = Date()
        let rawAnswer: String
        if let responseOverride {
            rawAnswer = try responseOverride(request)
        } else {
            rawAnswer = try runTarget(target, request: request, project: question.project)
        }
        let cleaned = rawAnswer.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
            options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw error(6, "目标 Agent 没有返回可用答复") }
        let answer = try CollaborationStore.publish(CollaborationEvent(
            id: "answer:" + request.id + ":" + request.recipientRunnerID,
            project: question.project, taskID: request.taskID, graphID: request.graphID,
            senderRunnerID: request.recipientRunnerID, senderPlatform: target.platform,
            senderMachineID: machineID,
            recipientRunnerID: request.senderRunnerID, kind: .answer,
            summary: String(cleaned.prefix(2_000)),
            details: "咨询耗时 " + Format.duration(Date().timeIntervalSince(started)),
            replyTo: request.id))
        _ = ViewFeed.publish(ViewFeed.collaborationPage())
        return answer
    }

    /// 兼容旧调用者的本机同步入口；生产 CLI/MCP 已改走 submit + 独立 responder。
    @discardableResult
    public static func ask(_ request: Request,
                           runners: [AgentRunner] = RunnerRegistry.all) throws
        -> CollaborationEvent {
        let local = runners.filter { $0.isAvailable }.map {
            AgentRegistration(machineID: Paths.machineID(), machineName: Paths.machineName(),
                              runnerID: $0.runnerID, platform: $0.platform,
                              canConsult: responseOverride != nil
                                || supportsReadOnlyConsultation($0))
        }
        let question = try submit(request, registrations: local)
        return try respond(questionID: question.id, machineID: Paths.machineID(), runners: runners)
    }

    private static func runTarget(_ target: AgentRunner, request: Request,
                                  project: String) throws -> String {
        let safeID = request.id.map { $0.isLetter || $0.isNumber ? $0 : Character("-") }
        let consultID = "consult-" + String(safeID.prefix(20))
        let workspace = try GitWorkspace.prepare(
            repo: project, taskID: consultID, platform: target.platform, base: "main")
        let lane = TaskCapabilityLane.review
        let context = GraphSession.Context(
            taskID: request.taskID ?? consultID, graphID: request.graphID,
            capability: lane, runnerID: target.runnerID, machineID: Paths.machineID())
        let session = GraphSession.mode(
            context: context, support: target.sessionSupport, workspace: workspace.path)
        let briefing = CollaborationStore.briefing(
            project: project, taskID: request.taskID, graphID: request.graphID,
            runnerID: target.runnerID)
        let prompt = """
        【Agent 定向咨询｜只读】
        你正在回答另一位 Agent 的一个具体工作疑问，不是接管它的实现任务。
        只读取仓库并给出可执行结论；不要编辑、创建或删除任何文件，不要提交，
        不要再咨询第三位 Agent。回答控制在 1200 字以内，先给结论，再给依据和建议动作。

        提问者：\(request.senderRunnerID)
        问题：\(request.question)
        \(request.details.map { "必要背景：" + $0 } ?? "")
        \(request.artifacts.isEmpty ? "" : "材料：" + request.artifacts.joined(separator: "、"))
        \(briefing)
        """
        let command = try readOnlyCommand(
            for: target, prompt: prompt, cwd: workspace.path, session: session)
        var env = command.env
        env["LLMQ_CONSULTATION_DEPTH"] = "1"
        let result = Proc.run(command.launchPath, command.args, cwd: workspace.path,
                              env: env, timeout: 480)
        GraphSession.markLaunched(
            context: context, support: target.sessionSupport, workspace: workspace.path)
        guard result.exitCode == 0, !result.timedOut else {
            let why = result.timedOut ? "咨询超时" : "咨询退出码 \(result.exitCode)"
            throw error(7, why + "：" + String((result.stderr + result.stdout).suffix(600)))
        }
        guard GitWorkspace.touchedFiles(in: workspace.path).isEmpty else {
            throw error(8, "咨询 Agent 违反只读边界并改动了工作区，答复未采纳")
        }
        return result.stdout
    }

    private static func readOnlyCommand(
        for target: AgentRunner, prompt: String, cwd: String, session: GraphSession.Mode
    ) throws -> (launchPath: String, args: [String], env: [String: String]) {
        if target.runnerID == CodexRunner().runnerID {
            // `--approve-for-me` 会把沙箱提升为 workspace-write，不适合咨询。
            // Codex 的 exec 级选项必须位于 resume 子命令之前。
            var args = ["exec", "--sandbox", "read-only", "--color", "never"]
            if case .projectResume = session {
                args += ["resume", "--last", prompt]
            } else {
                args.append(prompt)
            }
            return (target.binaryPath ?? "codex", args, [:])
        }
        if target.runnerID == ClaudeRunner().runnerID {
            var args = ["-p", prompt, "--add-dir", cwd,
                        "--tools", "Read,Glob,Grep", "--permission-mode", "default"]
            if let model = RunnerConfigStore.load().model(for: target.platform) {
                args += ["--model", model]
            }
            switch session {
            case .create(let id): args += ["--session-id", id]
            case .resume(let id): args += ["--resume", id]
            case .fresh, .projectResume: break
            }
            return (target.binaryPath ?? "claude", args, [:])
        }
        if let minimax = target as? MiniMaxCodeRunner {
            return minimax.readOnlyCommand(
                prompt: prompt, cwd: cwd, session: session)
        }
        if target is OpenCodeRunner {
            var args = ["run", "--dir", cwd, "--agent", "plan"]
            if case .projectResume = session { args.append("-c") }
            let configured = RunnerConfigStore.load().model(for: target.platform)
            let model = configured ?? (target.platform == .openrouter
                ? "openrouter/stealth/ox-alpha" : nil)
            if let model { args += ["-m", model] }
            args.append(prompt)
            return (target.binaryPath ?? "opencode", args, [:])
        }
        throw error(9, "目标 Runner 尚未实现只读咨询命令：" + target.runnerID)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "AgentConsultation", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
