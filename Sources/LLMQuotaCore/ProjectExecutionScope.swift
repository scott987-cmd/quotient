import Foundation

/// 本机允许自动执行哪个项目。
///
/// `RepoAlias.autoRefill` 是历史上的共享配置，只回答“队列空时给谁补活”，
/// 不能表达 Mac mini 与 MacBook 各自跑不同项目。执行作用域必须是本机状态，
/// 并且要同时约束后台派发和人工恢复入口。
public struct ProjectExecutionScope: Sendable {
    public enum ExecutionMode: String, Codable, Sendable {
        /// 只自动执行本机选中的一个项目。
        case focused
        /// 不自动执行任何项目；人工点名仍可启动。
        case manualOnly
        /// 明确允许本机自动执行所有项目。
        case automaticAll
    }

    private struct Snapshot: Codable {
        var version: Int
        var mode: ExecutionMode
        var allowedRepo: String?

        init(mode: ExecutionMode, allowedRepo: String?) {
            version = 2
            self.mode = mode
            self.allowedRepo = allowedRepo
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            allowedRepo = try c.decodeIfPresent(String.self, forKey: .allowedRepo)
            // v1 用 allowedRepo=nil 表示“关闭专注”。它从未代表“自动跑全部”，
            // 升级时必须保持失败关闭，不能把旧机器突然变成跨项目调度器。
            mode = try c.decodeIfPresent(ExecutionMode.self, forKey: .mode)
                ?? (allowedRepo == nil ? .manualOnly : .focused)
        }
    }

    public let mode: ExecutionMode
    public let allowedRepo: String?
    public let isConfigured: Bool
    public let configurationError: Bool

    public init(allowedRepo: String?) {
        self.init(mode: allowedRepo == nil ? .manualOnly : .focused,
                  allowedRepo: allowedRepo, isConfigured: true,
                  configurationError: false)
    }

    public init(mode: ExecutionMode, allowedRepo: String? = nil) {
        self.init(mode: mode, allowedRepo: allowedRepo, isConfigured: true,
                  configurationError: false)
    }

    private init(mode: ExecutionMode, allowedRepo: String?, isConfigured: Bool,
                 configurationError: Bool) {
        self.mode = mode
        self.allowedRepo = allowedRepo.map(Self.normalize)
        self.isConfigured = isConfigured
        self.configurationError = configurationError
    }

    private static var file: URL {
        Paths.appSupport.appendingPathComponent("project-execution-scope.json")
    }

    private static func normalize(_ path: String) -> String {
        RepoLease.normalize(path)
    }

    /// 新版优先读本机作用域；尚未配置的机器只读兼容旧的共享 focus。
    public static func current(repos: [RepoAlias] = RepoRegistry.all()) -> Self {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? SnapshotCoding.decoder()
                    .decode(Snapshot.self, from: data) else {
                // 作用域损坏时必须失败关闭。退回“允许所有项目”会让一处坏 JSON
                // 直接变成跨项目误执行。
                return Self(mode: .manualOnly, allowedRepo: nil, isConfigured: true,
                            configurationError: true)
            }
            return Self(mode: snapshot.mode, allowedRepo: snapshot.allowedRepo,
                        isConfigured: true,
                        configurationError: false)
        }
        let legacy = repos.first(where: { $0.autoRefill })?.localPath
        return Self(mode: legacy == nil ? .manualOnly : .focused,
                    allowedRepo: legacy, isConfigured: false,
                    configurationError: false)
    }

    /// nil 表示明确关闭专注：已排队任务可手工执行，但不会自动补活。
    public static func setFocusedRepo(_ repo: String?) throws {
        try setExecutionMode(repo == nil ? .manualOnly : .focused,
                             focusedRepo: repo)
    }

    public static func setExecutionMode(
        _ mode: ExecutionMode,
        focusedRepo: String? = nil
    ) throws {
        try Paths.ensureDirectories()
        guard mode != .focused || focusedRepo != nil else {
            throw NSError(
                domain: "ProjectExecutionScope", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "focused 模式必须指定项目"])
        }
        let snapshot = Snapshot(
            mode: mode,
            allowedRepo: mode == .focused ? focusedRepo.map(normalize) : nil)
        let data = try SnapshotCoding.prettyEncoder().encode(snapshot)
        guard ICloudSafe.write(data, to: file) else {
            throw NSError(
                domain: "ProjectExecutionScope",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法保存本机项目执行范围"]
            )
        }
    }

    public func allows(_ repo: String) -> Bool {
        guard !configurationError else { return false }
        switch mode {
        case .focused:
            guard let allowedRepo else { return false }
            return Self.normalize(repo) == allowedRepo
        case .manualOnly:
            return false
        case .automaticAll:
            return true
        }
    }

    /// 看板可见范围和自动执行范围不是一回事。manualOnly 仍要展示任务，
    /// 否则用户一关自动调度，手机上的排队任务也会凭空消失。
    public func includesForDisplay(_ repo: String) -> Bool {
        guard !configurationError else { return false }
        switch mode {
        case .focused: return allows(repo)
        case .manualOnly, .automaticAll: return true
        }
    }

    public func filter(_ tasks: [WorkTask]) -> [WorkTask] {
        tasks.filter { allows($0.repo) }
    }

    public func canStart(_ task: WorkTask, explicitOverride: Bool) -> Bool {
        explicitOverride || allows(task.repo)
    }

    public func shouldAutoRefill(_ repo: String) -> Bool {
        guard !configurationError else { return false }
        switch mode {
        case .focused: return allows(repo)
        case .manualOnly: return false
        case .automaticAll: return true
        }
    }
}
