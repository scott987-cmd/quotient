import Foundation

/// 原生 CLI 会话的本机映射。
///
/// 原生会话跟随「机器 × Runner × 稳定工作区 × 能力泳道」。
///
/// 稳定工作区本身已经是「仓库 × Agent」隔离的，因此同一个 Agent 在同一项目
/// 接到新任务时应继续项目会话，而不是因为 taskID 变化就从零开始。不同 Runner、
/// 不同仓库和不同能力泳道仍然隔离；长期且需要跨工具保存的事实继续写进
/// AGENTS.md / STATUS / briefing，不能只押在聊天记录上。
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

    private static func legacyWorkspaceKey(_ workspace: String, _ context: Context) -> String {
        let path = URL(fileURLWithPath: NSString(string: workspace).expandingTildeInPath)
            .standardizedFileURL.path
        return "workspace|machine:\(Context.escaped(context.machineID))|runner:"
            + Context.escaped(context.runnerID) + "|path:" + Context.escaped(path)
    }

    private static func projectKey(_ workspace: String, _ context: Context) -> String {
        let path = URL(fileURLWithPath: NSString(string: workspace).expandingTildeInPath)
            .standardizedFileURL.path
        return "v3|machine:\(Context.escaped(context.machineID))|runner:"
            + Context.escaped(context.runnerID) + "|lane:"
            + context.capability.rawValue + "|workspace:" + Context.escaped(path)
    }

    /// 阶段 3a 之前使用 `repo:<主仓库>|<平台>` 保存项目会话。升级到稳定
    /// Agent 工作区后路径变了，但上下文没有失效：精确 ID 执行器沿用旧 ID，
    /// `-c/--last` 型执行器把它当成“这个项目已有历史”的可信启动标记。
    public static func migrateLegacyProject(
        context: Context, support: SessionSupport, workspace: String,
        repo: String, platform: Platform
    ) {
        guard support != .none else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load()
        let target = projectKey(workspace, context)
        guard m[target] == nil else { return }
        let source = "repo:" + NSString(string: repo).expandingTildeInPath
            + "|" + platform.rawValue
        guard let legacy = m[source] else { return }
        m[target] = support == .projectLatest ? "project" : legacy
        save(m)
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
            let key = projectKey(workspace, context)
            if let existing = m[key] { return .resume(existing) }
            // 从任务级旧映射迁移：同一条任务升级后不应平白丢一次上下文。
            if let legacy = m[context.storageKey] {
                m[key] = legacy; save(m)
                return .resume(legacy)
            }
            let id = UUID().uuidString.lowercased()
            m[key] = id
            save(m)
            return .create(id)
        case .projectLatest:
            lock.lock(); defer { lock.unlock() }
            var m = load()
            let key = projectKey(workspace, context)
            if m[key] != nil { return .projectResume }
            // 兼容阶段 3a 的任务级工作区标记。
            if m[legacyWorkspaceKey(workspace, context)] == context.storageKey {
                m[key] = "project"; save(m)
                return .projectResume
            }
            return .fresh
        case .reportedID:
            lock.lock(); defer { lock.unlock() }
            var m = load()
            let key = projectKey(workspace, context)
            if let id = m[key] { return .resume(id) }
            if let legacy = m[context.storageKey] {
                m[key] = legacy; save(m)
                return .resume(legacy)
            }
            return .fresh
        }
    }

    /// 记录 CLI 在真实输出中报告的 ID。调用方必须先按 Runner 自己的语法解析，
    /// 这里不接受调度器生成的替代值。
    public static func rememberReportedID(context: Context, id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load(); m[context.storageKey] = id; save(m)
    }

    public static func rememberReportedID(context: Context, workspace: String, id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load(); m[projectKey(workspace, context)] = id; save(m)
    }

    /// 子进程确实启动后，当前 cwd 的“最近会话”才可以归给这条任务。
    public static func markLaunched(context: Context, support: SessionSupport,
                                    workspace: String) {
        guard support == .projectLatest else { return }
        lock.lock(); defer { lock.unlock() }
        var m = load()
        m[projectKey(workspace, context)] = "project"
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


    /// 只清掉这个 Agent 在这个项目/泳道上的坏会话，不影响它在其他项目的上下文。
    public static func forget(context: Context, workspace: String) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        m.removeValue(forKey: projectKey(workspace, context))
        m.removeValue(forKey: context.storageKey)
        m.removeValue(forKey: legacyWorkspaceKey(workspace, context))
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
        let live = Set(m.keys.filter { $0.hasPrefix("v2|") || $0.hasPrefix("v3|") })
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
