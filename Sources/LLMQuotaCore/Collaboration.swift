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
        case started, question, answer, decision, finding, checkpoint, result, handoff, ack

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
        decoded.sort {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        var byID: [String: CollaborationEvent] = [:]
        for event in decoded where byID[event.id] == nil { byID[event.id] = event }
        return byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
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
    public static func contract(project: String, taskID: String? = nil,
                                graphID: String? = nil, runnerID: String) -> String {
        var command = "llmq collaboration publish --project "
            + shellQuote(normalizeProject(project))
            + " --sender " + shellQuote(runnerID)
        if let taskID { command += " --task " + shellQuote(taskID) }
        if let graphID { command += " --graph " + shellQuote(graphID) }
        command += " --kind finding --summary '替换成一句可执行结论'"
        return briefing(project: project, taskID: taskID, graphID: graphID, runnerID: runnerID)
            + "\n\n【协作约定】遇到会影响下一棒的发现、决定、问题或检查点时，"
            + "请用以下命令留下结构化事实；不要写隐藏推理。若环境已配置 MCP，"
            + "也可调用 collaboration_publish。\n" + command
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "CollaborationStore", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 显式 answer/ack 关闭所引用事件；同任务更晚的终态 result 也会关闭此前
    /// 的交接/发现，避免任务已经收工，协作页还永久挂着“待回应”。
    private static func resolvedIDs(in events: [CollaborationEvent]) -> Set<String> {
        var resolved = Set(events.compactMap { event -> String? in
            guard event.kind == .answer || event.kind == .ack else { return nil }
            return event.replyTo
        })
        let results = events.filter { $0.kind == .result && $0.taskID != nil }
        for event in events where event.kind.needsResponse {
            if results.contains(where: {
                $0.project == event.project && $0.taskID == event.taskID
                    && $0.createdAt >= event.createdAt
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
            "summary": stringSchema("确认说明")])]
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
