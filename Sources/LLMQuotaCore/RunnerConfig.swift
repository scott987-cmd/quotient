import Foundation

/// 每个平台用哪个模型。
///
/// 不写死在执行器里，是因为这属于**账号级偏好**而不是代码常量：
/// 同一个 CLI 往往能选好几个模型（实测 qwen CLI 里配了 15 个），
/// 选哪个取决于你买了什么档、更信任哪个模型 —— 这跟代码没关系。
///
/// 放 iCloud 共享配置目录，多台机器保持一致。
public struct RunnerConfig: Codable, Sendable {
    /// 平台 → 模型 ID。留空表示用该 CLI 自己的默认模型。
    public var models: [String: String]

    public init(models: [String: String] = [:]) {
        self.models = models
    }

    public func model(for platform: Platform) -> String? {
        let m = models[platform.rawValue]
        return (m?.isEmpty ?? true) ? nil : m
    }
}

public enum RunnerConfigStore {
    static var file: URL {
        Paths.iCloudConfigDir?.appendingPathComponent("runners.json")
            ?? Paths.appSupport.appendingPathComponent("runners.json")
    }

    /// 缓存住。执行器每次构造命令都要读，而这是个几乎不变的小文件 ——
    /// 每次派发都去碰一次 iCloud 目录没有意义。
    private static var cached: RunnerConfig?
    private static var cachedAt: Date?

    public static func load() -> RunnerConfig {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < 30 {
            return cached
        }
        let cfg: RunnerConfig
        if let data = try? Data(contentsOf: file),
           let c = try? SnapshotCoding.decoder().decode(RunnerConfig.self, from: data) {
            cfg = c
        } else {
            cfg = RunnerConfig()
        }
        cached = cfg
        cachedAt = Date()
        return cfg
    }

    public static func save(_ cfg: RunnerConfig) throws {
        try Paths.ensureDirectories()
        let data = try SnapshotCoding.prettyEncoder().encode(cfg)
        try data.write(to: file, options: .atomic)
        cached = cfg
        cachedAt = Date()
    }

    @discardableResult
    public static func setModel(_ model: String?, for platform: Platform) throws -> RunnerConfig {
        var cfg = load()
        if let model, !model.isEmpty {
            cfg.models[platform.rawValue] = model
        } else {
            cfg.models.removeValue(forKey: platform.rawValue)
        }
        try save(cfg)
        return cfg
    }

    /// 这个平台的 CLI 提供了哪些模型可选。
    ///
    /// 目前只有 Qwen 能问出来 —— 它把模型清单写在自己的 settings.json 里。
    /// 别家没有等价的东西，返回空表示"不知道，随你填"。
    public static func availableModels(for platform: Platform) -> [String] {
        guard platform == .qwen else { return [] }
        let path = NSString(string: "~/.qwen/settings.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = JSONHelp.object(data),
              let providers = root["modelProviders"] as? [String: Any]
        else { return [] }
        var out: [String] = []
        for (_, v) in providers {
            guard let models = v as? [[String: Any]] else { continue }
            out.append(contentsOf: models.compactMap { $0["id"] as? String })
        }
        return out.sorted()
    }
}
