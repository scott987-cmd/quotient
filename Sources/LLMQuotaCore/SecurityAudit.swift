import Foundation

/// 本机暴露面审计。
///
/// 存在的理由：这套工具最终要跨设备调度、要无人值守地跑 agent 改代码。
/// 那意味着一旦哪里开了个没鉴权的口子，别人就能让你的机器执行任意代码、
/// 花你的额度、读你的仓库。所以「有没有裸奔的服务」必须是可复查的，
/// 而不是靠某次人工检查记在脑子里。
///
/// 设计上的硬规矩（见 SECURITY.md）：**本工具只允许开一个端口** ——
/// `llmq cluster serve` 的双向 mTLS 口，而且认证过的对端只能投任务，
/// 不能执行任意命令。
///
/// 这条规矩比原来的"一个端口都不开"弱，所以审计不能只对着白名单点头：
/// 它会真的拿一个不带证书的连接去敲那个口，拿到服务就报严重。
public enum SecurityAudit {

    public enum Severity: String, Sendable {
        case critical, warning, info, ok

        public var rank: Int {
            switch self {
            case .critical: return 3
            case .warning: return 2
            case .info: return 1
            case .ok: return 0
            }
        }
    }

    public struct Finding: Sendable {
        public var severity: Severity
        public var area: String
        public var detail: String
        public var fix: String?

        public init(_ severity: Severity, _ area: String, _ detail: String, fix: String? = nil) {
            self.severity = severity
            self.area = area
            self.detail = detail
            self.fix = fix
        }
    }

    public struct Listener: Sendable {
        public var command: String
        public var pid: String
        public var address: String
        /// 绑在 127.0.0.1 / ::1 之外，也就是局域网可达。
        public var isExposed: Bool
    }

    // MARK: - 入口

    public static func run() -> [Finding] {
        var findings: [Finding] = []
        findings.append(contentsOf: auditOwnSurface())
        findings.append(contentsOf: auditListeners())
        findings.append(contentsOf: auditFirewall())
        findings.append(contentsOf: auditSecretFiles())
        return findings.sorted { $0.severity.rank > $1.severity.rank }
    }

    // MARK: - 自身暴露面

    /// 这套工具只允许开**一个**端口：`llmq cluster serve` 的那个。
    /// 除它之外任何监听都是回归。
    ///
    /// 而且光认出端口号不算数 —— 白名单只能证明"这个端口是我们开的"，
    /// 证明不了"它真的在拦人"。所以这里会**实际去敲一次门**：
    /// 用一个不带客户端证书的连接去请求服务，拿到回应就是严重问题。
    /// 这是唯一能发现"双向认证被改坏了"的办法，光读配置读不出来。
    static func auditOwnSurface() -> [Finding] {
        let mine = listeners().filter {
            $0.command.localizedCaseInsensitiveContains("llmq")
                || $0.command.localizedCaseInsensitiveContains("LLMQuota")
        }
        guard !mine.isEmpty else {
            return [Finding(.ok, "自身暴露面", "LLMQuotaBar 没有监听任何端口")]
        }

        let expectedPort = ClusterConfigStore.load()?.port
        var out: [Finding] = []
        for l in mine {
            // 探针必须连它**实际绑的那个地址**。服务端只绑内网 IP，
            // 冲 127.0.0.1 敲永远敲不通，那样就会把"没验出来"当成常态。
            let bits = l.address.split(separator: ":")
            let host = bits.count >= 2 ? String(bits[bits.count - 2]) : "127.0.0.1"
            let port = bits.last.flatMap { UInt16($0) }
            guard let port, port == expectedPort else {
                out.append(Finding(.critical, "自身暴露面",
                    "LLMQuotaBar 组件 \(l.command)(\(l.pid)) 在监听 \(l.address)",
                    fix: "这不是集群端口（配置里是 \(expectedPort.map(String.init) ?? "未配置")）。"
                       + "本工具除了 cluster serve 不该开任何端口，这是回归。"))
                continue
            }
            switch probeAnonymous(port: port, host: host) {
            case .rejected:
                out.append(Finding(.ok, "自身暴露面",
                    "集群端口 \(l.address) 在听，实测拒绝了不带客户端证书的连接"))
            case .served:
                out.append(Finding(.critical, "自身暴露面",
                    "集群端口 \(l.address) 对**不带证书**的连接提供了服务",
                    fix: "双向认证失效了 —— 局域网内任何设备都能给这台机器派任务。"
                       + "立刻停掉 serve，检查 ClusterNet.parameters 里的 "
                       + "peer_authentication_required 和 verify block。"))
            case .unknown(let why):
                out.append(Finding(.warning, "自身暴露面",
                    "集群端口 \(l.address) 在听，但没验出它拒不拒匿名连接（\(why)）",
                    fix: "手动验一次：llmq cluster ping <对方名> 应该通，"
                       + "不带证书的 openssl s_client 应该被拒。"))
            }
        }
        return out
    }

    enum ProbeResult {
        case rejected           // 敲了，被拒 —— 正常
        case served             // 敲了，拿到回应 —— 严重
        case unknown(String)    // 敲不成，说不清
    }

    /// 不带客户端证书去请求一次服务，看拿不拿得到回应。
    ///
    /// 判据是**有没有被服务**，不是退出码：TLS 1.3 下客户端在收到服务端的
    /// 告警之前就认为握手完成了，openssl 可以以 0 退出却什么也没拿到。
    static func probeAnonymous(port: UInt16, host: String = "127.0.0.1") -> ProbeResult {
        guard let frame = try? Frame.encode(ClusterRequest.ping) else {
            return .unknown("构造探测请求失败")
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmq-probe-\(UUID().uuidString).bin")
        guard (try? frame.write(to: tmp)) != nil else { return .unknown("写临时文件失败") }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = Proc.run("/bin/sh", ["-c",
            // sleep 是必须的：stdin 一关 s_client 就收摊，等不到回应，
            // 那样什么都探不出来还会误报"安全"。
            "{ cat \(tmp.path); sleep 2; } | /usr/bin/openssl s_client "
            + "-connect \(host):\(port) -verify 0 -tls1_3 2>&1"],
            cwd: NSTemporaryDirectory(), env: [:], timeout: 15)

        let out = r.stdout + r.stderr
        if out.contains("pong") { return .served }
        if out.contains("CONNECTED") { return .rejected }
        return .unknown("连不上")
    }

    // MARK: - 全机监听

    static func auditListeners() -> [Finding] {
        let exposed = listeners().filter(\.isExposed)
        guard !exposed.isEmpty else {
            return [Finding(.ok, "对外监听", "没有服务绑在局域网可达的地址上")]
        }

        // macOS 自带的这几个是系统功能（隔空播放、接力），不是用户装的服务，
        // 单独归类，免得淹没真正需要处理的那几条。
        let systemOwned: Set<String> = ["rapportd", "ControlCe", "sharingd", "AirPlayXPCH"]
        var out: [Finding] = []

        for l in exposed where !systemOwned.contains(l.command) {
            out.append(Finding(.warning, "对外监听",
                "\(l.command)(\(l.pid)) 绑在 \(l.address)，局域网内任何设备可达",
                fix: "确认它有鉴权；没有的话把绑定地址改成 127.0.0.1，需要远程访问就走 SSH 隧道。"))
        }
        let sys = exposed.filter { systemOwned.contains($0.command) }
        if !sys.isEmpty {
            out.append(Finding(.info, "对外监听",
                "另有 \(sys.count) 个 macOS 系统服务对外监听（"
                + Set(sys.map(\.command)).sorted().joined(separator: "、") + "）",
                fix: "隔空播放接收器和接力功能。用不到可在「系统设置 → 通用 → 隔空播放与接力」关掉。"))
        }
        return out
    }

    static func listeners() -> [Listener] {
        let out = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])
        var result: [Listener] = []
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 9 else { continue }
            let addr = f[8]
            let local = addr.hasPrefix("127.0.0.1:") || addr.hasPrefix("[::1]:")
            result.append(Listener(command: f[0], pid: f[1], address: addr, isExposed: !local))
        }
        return result
    }

    // MARK: - 防火墙

    static func auditFirewall() -> [Finding] {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.fileExists(atPath: fw) else { return [] }
        let state = shell(fw, ["--getglobalstate"])
        if state.contains("disabled") || state.contains("State = 0") {
            return [Finding(.warning, "防火墙",
                "macOS 应用防火墙处于关闭状态 —— 任何进程一旦监听就直接对局域网可达",
                fix: "系统设置 → 网络 → 防火墙 打开。开启后新监听会弹窗询问，等于多一道确认。")]
        }
        return [Finding(.ok, "防火墙", "macOS 应用防火墙已启用")]
    }

    // MARK: - 密钥文件权限

    /// 这些目录里放着各平台的凭据。
    static let secretRoots = [
        "~/.qwen", "~/.kimi-code", "~/.codex", "~/.hermes", "~/.claude", "~/.gemini"
    ]

    /// 只认长得像真凭据的东西，而且必须是**完整形态**。
    ///
    /// 第一版用 "sk-" 做子串匹配，结果 risk- / task- / disk- 全命中，
    /// package-lock.json 和模型缓存被报成"含明文凭据"——4 条严重全是误报。
    /// 会喊狼来了的安全工具等于没有，所以这里一律用带边界和长度约束的正则。
    static let credentialPatterns: [String] = [
        // 字符类必须含点号：有的平台（如阿里百炼）key 形如 sk-sp-A.BBBBB.CCCC.DDDD…，
        // 不含点的话长度约束在第一个点就断了，真 key 反而漏检。
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_.\-]{20,}"#,
        #"(?<![A-Za-z0-9])sk_live_[A-Za-z0-9]{16,}"#,
        #"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"#,
        #"(?<![A-Za-z0-9])ghp_[A-Za-z0-9]{30,}"#,
        #"(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9\-]{15,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ]

    static let credentialRegexes: [NSRegularExpression] = credentialPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    static func looksLikeCredential(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return credentialRegexes.contains {
            $0.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    static func auditSecretFiles() -> [Finding] {
        let fm = FileManager.default
        var bad: [String] = []

        for root in secretRoots {
            let dir = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
            guard let en = fm.enumerator(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var depth = 0
            for case let url as URL in en {
                depth += 1
                if depth > 4000 { break }        // 会话日志目录可能极大，别扫穿
                if en.level > 2 { en.skipDescendants(); continue }
                let ext = url.pathExtension
                guard ["json", "toml", "yaml", "yml", "env", ""].contains(ext) else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      (attrs[.type] as? FileAttributeType) == .typeRegular,
                      let posix = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
                else { continue }
                // 组或其他有读权限
                guard (posix & 0o044) != 0 else { continue }
                guard let size = (attrs[.size] as? NSNumber)?.intValue, size < 2_000_000 else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard looksLikeCredential(text) else { continue }

                bad.append(url.path.replacingOccurrences(
                    of: fm.homeDirectoryForCurrentUser.path, with: "~"))
            }
        }

        guard !bad.isEmpty else {
            return [Finding(.ok, "凭据文件", "没有发现组/其他可读的凭据文件")]
        }
        return bad.map {
            Finding(.critical, "凭据文件",
                    "\($0) 含明文凭据且组/其他可读",
                    fix: "chmod 600 \($0)")
        }
    }

    // MARK: - shell

    static func shell(_ path: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
