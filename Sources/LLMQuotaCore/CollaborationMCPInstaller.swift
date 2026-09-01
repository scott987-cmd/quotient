import Foundation

/// 把同一个本地协作 MCP 暴露给 Claude Code 和 OpenCode（Ox）。
///
/// MCP 进程仍由各 Agent 按需拉起，没有常驻服务、没有额外模型调用；配置只做
/// 工具发现。OpenCode 没有非交互 add 命令，因此仅合并自己的键，保留用户已有配置。
public enum CollaborationMCPInstaller {
    public static let serverName = "llmq-collaboration"

    public struct Report: Sendable {
        public var claude: String
        public var openCode: String
    }

    @discardableResult
    public static func install(executable: String? = nil) throws -> Report {
        let invoked = CommandLine.arguments[0]
        let invokedURL = URL(fileURLWithPath: invoked,
                             relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
        let binary = executable
            ?? (FileManager.default.isExecutableFile(atPath: invokedURL) ? invokedURL : nil)
            ?? Proc.which("llmq") ?? invokedURL
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw error(1, "找不到可执行的 llmq，不能配置协作 MCP：" + binary)
        }
        let openCode = try installOpenCode(
            executable: binary,
            config: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/opencode.json"))
        let claude = try installClaude(executable: binary)
        return Report(claude: claude, openCode: openCode)
    }

    /// 公开纯合并入口，方便契约测试证明不会覆盖 provider、插件或密钥配置。
    @discardableResult
    public static func installOpenCode(executable: String, config: URL) throws -> String {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: config.path) {
            let data = try Data(contentsOf: config)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw error(2, "OpenCode 配置不是 JSON 对象，拒绝覆盖：" + config.path)
            }
            root = decoded
        }
        var servers = root["mcp"] as? [String: Any] ?? [:]
        let desired: [String: Any] = [
            "type": "local",
            "command": [executable, "collaboration", "mcp"],
            "enabled": true,
            // 定向咨询允许一次只读模型调用；OpenCode 默认 5 秒会误判超时。
            "timeout": 600_000,
        ]
        if let current = servers[serverName] as? [String: Any],
           NSDictionary(dictionary: current).isEqual(to: desired) {
            return "已配置"
        }
        servers[serverName] = desired
        root["mcp"] = servers
        try fm.createDirectory(at: config.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        guard ICloudSafe.write(data, to: config) else {
            throw error(5, "OpenCode MCP 配置写入超时或失败：" + config.path)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        return "已安装"
    }

    private static func installClaude(executable: String) throws -> String {
        guard let claude = Proc.which("claude") else { return "未安装 Claude CLI，已跳过" }
        let existing = Proc.run(claude, ["mcp", "get", serverName],
                                cwd: NSTemporaryDirectory(), env: [:], timeout: 20)
        if existing.exitCode == 0 {
            let text = existing.stdout + existing.stderr
            if text.contains(executable), text.contains("collaboration"), text.contains("mcp") {
                return "已配置"
            }
            guard text.contains("collaboration"), text.contains("mcp") else {
                throw error(3, "Claude 已有同名 MCP，但不是 llmq 协作服务；为避免覆盖用户配置，请先检查")
            }
            let removed = Proc.run(claude, ["mcp", "remove", "--scope", "user", serverName],
                                   cwd: NSTemporaryDirectory(), env: [:], timeout: 20)
            guard removed.exitCode == 0 else {
                throw error(3, "Claude 旧协作 MCP 无法升级："
                            + String((removed.stderr + removed.stdout).suffix(300)))
            }
        }
        let added = Proc.run(claude, ["mcp", "add", "--scope", "user", serverName,
                                      "--", executable, "collaboration", "mcp"],
                             cwd: NSTemporaryDirectory(), env: [:], timeout: 30)
        guard added.exitCode == 0 else {
            throw error(4, "Claude MCP 安装失败：" + String((added.stderr + added.stdout).suffix(500)))
        }
        return "已安装"
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "CollaborationMCPInstaller", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
