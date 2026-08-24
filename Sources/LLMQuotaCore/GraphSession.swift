import Foundation

/// 原生 CLI 会话的本机映射。
///
/// 执行会话只跟随一条任务，或一张图里的一个能力泳道。仓库长期知识应写进
/// AGENTS.md / STATUS / briefing，不能靠把不相关任务串进一段无限增长的聊天。
public enum GraphSession {
    public static var fileOverride: URL?
    private static let lock = NSLock()

    static var file: URL {
        fileOverride ?? Paths.appSupport.appendingPathComponent("graph-sessions.json")
    }

    public enum Mode: Sendable, Equatable {
        case fresh
        case create(String)
        case resume(String)
        /// CLI 没有显式 ID，只能恢复这个工作目录最近一次会话。
        case projectResume
    }

    public struct Context: Sendable, Equatable, Hashable {
        public var taskID: String
        public var graphID: String?
        public var capability: TaskCapabilityLane
        public var runnerID: String
        public var machineID: String

        public init(taskID: String, graphID: String?, capability: TaskCapabilityLane,
                    runnerID: String, machineID: String) {
            self.taskID = taskID
            self.graphID = graphID
            self.capability = capability
            self.runnerID = runnerID
            self.machineID = machineID
        }

        static func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "|", with: "%7C")
        }

        var storageKey: String {
            let scope = graphID.map {
                "graph:\(Self.escaped($0))|lane:\(capability.rawValue)"
            } ?? "task:\(Self.escaped(taskID))"
            return "v2|machine:\(Self.escaped(machineID))|runner:"
                + Self.escaped(runnerID) + "|" + scope
        }
    }

    static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode([String: String].self, from: d)
        else { return [:] }
        return m
    }

    static func save(_ m: [String: String]) {
        try? Paths.ensureDirectories()
        if let d = try? JSONEncoder().encode(m) { ICloudSafe.write(d, to: file) }
    }

    private static func workspaceKey(_ workspace: String, _ context: Context) -> String {
        let path = URL(fileURLWithPath: NSString(string: workspace).expandingTildeInPath)
            .standardizedFileURL.path
        return "workspace|machine:\(Context.escaped(context.machineID))|runner:"
            + Context.escaped(context.runnerID) + "|path:" + Context.escaped(path)
    }

    /// 决定本轮会话方式。stableID 的新 ID 在启动前落盘：进程被杀后仍知道该恢复谁。
    public static func mode(context: Context, support: SessionSupport,
                            workspace: String) -> Mode {
        switch support {
        case .none:
            return .fresh
        case .stableID:
            lock.lock(); defer { lock.unlock() }
            var m = load()
            if let existing = m[context.storageKey] { return .resume(existing) }
            let id = UUID().uuidString.lowercased()
            m[context.storageKey] = id
            save(m)
            return .create(id)
        case .projectLatest:
            lock.lock(); defer { lock.unlock() }
            let m = load()
            return m[workspaceKey(workspace, context)] == context.storageKey
                ? .projectResume : .fresh
        case .reportedID:
            lock.lock(); defer { lock.unlock() }
            return load()[context.storageKey].map(Mode.resume) ?? .fresh
        }
    }

    /// 记录 CLI 在真实输出中报告的 ID。调用方必须先按 Runner 自己的语法解析，
    /// 这里不接受调度器生成的替代值。
    public static func rememberReportedID(context: Context, id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load(); m[context.storageKey] = id; save(m)
    }

    /// 子进程确实启动后，当前 cwd 的“最近会话”才可以归给这条任务。
    public static func markLaunched(context: Context, support: SessionSupport,
                                    workspace: String) {
        guard support == .projectLatest else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load()
        m[context.storageKey] = "project"
        m[workspaceKey(workspace, context)] = context.storageKey
        save(m)
    }

    /// 只删除这条任务/能力泳道的映射，不再根据 nil graphID 猜命名空间。
    public static func forget(context: Context) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        m.removeValue(forKey: context.storageKey)
        for key in Array(m.keys) where key.hasPrefix("workspace|")
            && m[key] == context.storageKey {
            m.removeValue(forKey: key)
        }
        save(m)
    }

    /// 只有明确的会话错误才允许删映射；普通任务失败和超时不算。
    public static func isSessionFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        guard text.contains("session") || text.contains("conversation") else { return false }
        return text.contains("not found") || text.contains("no conversation")
            || text.contains("already in use") || text.contains("expired")
            || text.contains("invalid session")
    }

    public static func forgetGraph(_ graphID: String) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        let escaped = Context.escaped(graphID)
        let newMarker = "|graph:\(escaped)|"
        for key in Array(m.keys) where key.contains(newMarker)
            || key.hasPrefix(graphID + "|") {
            m.removeValue(forKey: key)
        }
        let live = Set(m.keys.filter { $0.hasPrefix("v2|") })
        for key in Array(m.keys) where key.hasPrefix("workspace|")
            && !live.contains(m[key] ?? "") {
            m.removeValue(forKey: key)
        }
        save(m)
    }

    // MARK: - 旧调用兼容

    static func legacyKey(_ graph: String, _ platform: Platform) -> String {
        graph + "|" + platform.rawValue
    }

    /// 旧测试和旧调用使用；新调度必须走 Context API。
    public static func mode(graphID: String?, platform: Platform) -> Mode {
        guard let graphID else { return .fresh }
        let m = load()
        if let id = m[legacyKey(graphID, platform)] { return .resume(id) }
        return .create(UUID().uuidString.lowercased())
    }

    public static func remember(graphID: String?, platform: Platform, id: String) {
        guard let graphID else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load(); m[legacyKey(graphID, platform)] = id; save(m)
    }

    public static func forget(graphID: String?, platform: Platform) {
        guard let graphID else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load(); m.removeValue(forKey: legacyKey(graphID, platform)); save(m)
    }

    public static func mode(repo: String, platform: Platform, graphID: String?) -> Mode {
        if graphID != nil { return mode(graphID: graphID, platform: platform) }
        let key = "repo:" + NSString(string: repo).expandingTildeInPath
            + "|" + platform.rawValue
        lock.lock(); defer { lock.unlock() }
        var m = load()
        if let id = m[key] { return .resume(id) }
        let id = UUID().uuidString; m[key] = id; save(m); return .create(id)
    }

    public static func forget(repo: String, platform: Platform) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        m.removeValue(forKey: "repo:" + NSString(string: repo).expandingTildeInPath
                      + "|" + platform.rawValue)
        save(m)
    }
}
