import Foundation

/// Context Pack 的发布保险丝（架构师决定，2026-08-26）。
///
/// 设计阶段 1 要求「先切换一个低风险仓库，确认后再扩面」，不允许全局
/// 一次性替换。这里给出最小可回滚的灰度机制：
///
/// - **默认影子**：没有配置、配置坏了、别名不认识、仓库没登记 —— 一律
///   影子模式。影子只构建新 pack 并记录 manifest，派发用的还是旧拼装，
///   绝不因新 pack 的 refusal 阻断任务。
/// - **白名单显式启用**：只有 `enabledAliases` 里点名的**已登记**仓库才
///   真正切换到新 pack；此时 refusal 才允许阻断派发。
/// - **独立配置文件**，不往 RepoAlias 塞字段 —— repos.json 会被旧版本
///   客户端按已知字段重写（pathByMachine 被洗掉的事故发生过一次），
///   新字段落进去就是等着被洗掉。
///
/// 每次派发现读配置，改名单不需要发版。
public enum ContextPackRollout {
    private static let document = "context-pack-rollout"
    private static var loadedRevision: Int?
    private static var loadedRevisionPath: String?

    public enum DispatchMode: String, Sendable, Codable {
        case shadow
        case active
    }

    /// 测试注入口。
    public static var fileOverride: URL? {
        didSet { loadedRevision = nil; loadedRevisionPath = nil }
    }

    /// 共享配置目录（本地暂存，由菜单栏 App 镜像进 iCloud），改一台机器、
    /// 全集群生效；iCloud 配置目录不可用时退回 appSupport。
    public static var file: URL {
        fileOverride
            ?? Paths.iCloudConfigDir?.appendingPathComponent("context-pack-rollout.json")
            ?? Paths.appSupport.appendingPathComponent("context-pack-rollout.json")
    }

    public struct Config: Codable, Sendable, Equatable {
        /// 启用新 Context Pack 的仓库别名（RepoRegistry 里登记的名字）。
        /// 名单之外的任何东西都是影子。
        public var enabledAliases: [String]

        public init(enabledAliases: [String] = []) {
            self.enabledAliases = enabledAliases
        }

        /// 旧格式/新格式互读都要安全 —— 缺键降级为空名单。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabledAliases = try c.decodeIfPresent([String].self,
                                                   forKey: .enabledAliases) ?? []
        }
    }

    // MARK: - 读写

    public static func load() -> Config {
        let snapshot = SharedConfigJournal.snapshot(
            document: document, compatibilityFile: file)
        loadedRevision = snapshot.revision
        loadedRevisionPath = file.standardizedFileURL.path
        guard let data = snapshot.data,
              let config = try? SnapshotCoding.decoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    public static func save(_ config: Config, expectedRevision: Int? = nil) throws {
        try Paths.ensureDirectories()
        let data = try SnapshotCoding.prettyEncoder().encode(config)
        let snapshot = SharedConfigJournal.snapshot(
            document: document, compatibilityFile: file)
        let committed = try SharedConfigJournal.commit(
            document: document, payload: data,
            expectedRevision: expectedRevision
                ?? (loadedRevisionPath == file.standardizedFileURL.path ? loadedRevision : nil)
                ?? snapshot.revision,
            compatibilityFile: file)
        loadedRevision = committed
        loadedRevisionPath = file.standardizedFileURL.path
    }

    // MARK: - 判定

    /// 这个仓库是否真正启用新 pack。任何不确定都倒向影子：
    /// 配置坏、仓库未登记、别名对不上，全部 fail-closed。
    public static func isActive(repo: String) -> Bool {
        let config = load()
        guard !config.enabledAliases.isEmpty else { return false }
        let normalized = CollaborationStore.normalizeProject(repo)
        guard let entry = RepoRegistry.all().first(where: {
            CollaborationStore.normalizeProject($0.localPath) == normalized
        }) else { return false }
        return config.enabledAliases.contains(entry.alias)
    }

    /// 把名单拆成「登记表里真实存在、可以叫已启用」和「配置里有但登记表
    /// 里查不到」两组。展示层必须只把 valid 叫已启用，ignored 单独提示 ——
    /// 调度虽然 fail-closed，但界面上把幽灵别名说成「已启用」会误导人。
    public static func partitionEnabled(
        _ aliases: [String], registry: [RepoAlias]
    ) -> (valid: [String], ignored: [String]) {
        let known = Set(registry.map(\.alias))
        var valid: [String] = []
        var ignored: [String] = []
        for alias in aliases {
            if known.contains(alias) { valid.append(alias) }
            else { ignored.append(alias) }
        }
        return (valid, ignored)
    }
}

/// 派发提示词的选择层：新 pack 始终构建并记录，实际派发哪份由灰度决定。
public enum ContextDispatchPrompt {

    public struct Outcome: Sendable {
        /// 真正发给 Runner 的提示词。
        public var prompt: String
        /// 新 pack 全文（影子模式下只作记录，不派发）。
        public var pack: ContextPack
        public var mode: ContextPackRollout.DispatchMode
        /// 记账用的 manifest：rolloutMode 已填，影子下也带新 pack 的
        /// 纳入/折叠/拒绝数据 —— P50/P95 和 miss 对比靠它。
        public var manifest: ContextPackManifest
        /// 只有 active 模式才可能为 true；调用方据此阻断该候选并换人。
        public var refused: Bool
    }

    /// `legacy` 闭包返回影子模式实际派发的旧拼装提示词，
    /// **恰好执行一次**（影子派发用它，记账也从它算）。
    /// 由调用方注入而不是在这里重新拼装 —— 旧逻辑收口在
    /// LegacyContextPromptBuilder，选择层只做选择。
    public static func build(request: ContextPackBuilder.Request,
                             legacy: () -> String) -> Outcome {
        let pack = ContextPackBuilder.build(request)
        let mode: ContextPackRollout.DispatchMode =
            ContextPackRollout.isActive(repo: request.task.repo) ? .active : .shadow
        var manifest = pack.manifest
        manifest.rolloutMode = mode.rawValue

        if mode == .active {
            // active 拒绝 = 什么都没派发，dispatchedSystemCharacters 记 nil；
            // 非拒绝时实际派发的就是新包，等于 totalCharacters。
            manifest.dispatchedSystemCharacters =
                pack.refused ? nil : pack.manifest.totalCharacters
            return Outcome(prompt: pack.text, pack: pack, mode: .active,
                           manifest: manifest, refused: pack.refused)
        }
        // 影子：legacy 恰好执行一次；派发它，并把它的系统注入量记下来。
        let legacyPrompt = legacy()
        let userMaterial: String
        if let answer = request.resumedAnswer, let ask = request.resumedAsk {
            userMaterial = answer.briefing(for: ask)
        } else {
            userMaterial = ""
        }
        manifest.dispatchedSystemCharacters = dispatchedSystemCharacters(
            legacyPrompt: legacyPrompt,
            taskBody: VisualQualityGate.compactRemediationPrompt(request.task.prompt),
            userMaterial: userMaterial)
        // 影子：新 pack 的拒绝只记账，绝不拦住真实派发。
        return Outcome(prompt: legacyPrompt, pack: pack, mode: .shadow,
                       manifest: manifest, refused: false)
    }

    /// 影子的系统注入字符数：旧拼装总长 − 任务正文 − 用户答复。
    /// handoff/地图/产品约束/条款/图位置/协作账/提问契约全算系统注入；
    /// 答复是用户提供的材料，不算。纯函数，异常输入钳到 0 不出负数。
    static func dispatchedSystemCharacters(
        legacyPrompt: String, taskBody: String, userMaterial: String
    ) -> Int {
        max(0, legacyPrompt.count - taskBody.count - userMaterial.count)
    }
}
