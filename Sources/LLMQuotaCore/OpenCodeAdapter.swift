import Foundation

/// opencode 的用量采集。
///
/// ## 它和别的 CLI 不一样的地方
///
/// 别家都是往磁盘写 JSONL 会话日志，逐行解析就行。opencode 用的是
/// **SQLite**（`~/.local/share/opencode/opencode.db`），而且 `session` 表上
/// 直接挂着这次会话的 token 和费用汇总：
///
///     tokens_input / tokens_output / tokens_reasoning
///     tokens_cache_read / tokens_cache_write / cost
///
/// 这比从日志里逐条累加靠谱得多 —— 那是它自己记的账，不是我们推的。
///
/// ## 读一个正在被写的库
///
/// opencode 可能正开着（WAL 模式，旁边有 -wal 和 -shm）。用只读 URI
/// `file:...?mode=ro` 打开，实测在它运行时照样读得到，也不会干扰它。
///
/// ## 归属
///
/// opencode 是**多 provider** 的，模型字段存的是一段 JSON：
///
///     {"id":"volc-coding","providerID":"gateway","variant":"default"}
///
/// 实测这台机器上它指向一个本地 LiteLLM 网关，网关再转发到火山方舟。
/// 所以归属看的是 `id`（`volc-*` → 火山方舟），不是 `providerID`
/// —— 后者只是「哪个网关」，说明不了钱花在谁头上。这和 ModelRouter
/// 里那个教训是同一条：一个通用客户端指向哪儿，得看它实际打的那个后端。
public struct OpenCodeAdapter: UsageAdapter {
    public let id = "opencode"
    public let displayName = "opencode"
    public let homePlatform: Platform
    public let roots = ["~/.local/share/opencode"]
    /// 用真实数据验证过：4 个会话、token 数与 `opencode stats` 的汇总对得上。
    public let verified = true

    public init(homePlatform: Platform = .volcark) {
        self.homePlatform = homePlatform
    }

    var dbPath: String {
        NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath
    }

    public func discoverFiles() -> [URL] {
        // 把整个库当成一个「文件」交给采集框架。
        //
        // 这样能白蹭它那套 (size, mtime) 缓存：库没动过就直接复用上次解析的
        // 结果，不必每次都 fork 一个 sqlite3。库一被写过 mtime 就变，
        // 下次自然重新读 —— 而采集器每轮都是从头重算快照、不做累加，
        // 所以重读全部会话不会重复计数。
        let u = URL(fileURLWithPath: dbPath)
        return FileManager.default.fileExists(atPath: u.path) ? [u] : []
    }

    /// `data` 用不上 —— SQLite 的字节没法直接解析，走 sqlite3 命令行。
    ///
    /// 这是这个适配器唯一「不按套路」的地方，值得说明：为了这个不引第三方
    /// SQLite 依赖（整个项目零第三方依赖），而 /usr/bin/sqlite3 是 macOS 自带的。
    public func parse(file: URL, data: Data) -> ParsedFile {
        let sql = """
        SELECT id, model, agent,
               COALESCE(tokens_input,0), COALESCE(tokens_output,0),
               COALESCE(tokens_reasoning,0), COALESCE(tokens_cache_read,0),
               COALESCE(tokens_cache_write,0), COALESCE(cost,0),
               COALESCE(time_updated, time_created), directory
        FROM session
        WHERE COALESCE(time_updated, time_created) IS NOT NULL;
        """
        let r = Proc.run("/usr/bin/sqlite3", [
            "-readonly", "-separator", "\u{1}", "file:\(file.path)?mode=ro", sql,
        ], cwd: "/tmp", env: [:], timeout: 30)
        guard r.exitCode == 0 else {
            return ParsedFile(events: [], quotas: [], lastEventAt: nil)
        }

        var events: [UsageEvent] = []
        var last: Date?
        for line in r.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: "\u{1}")
            guard f.count >= 11 else { continue }
            let modelID = Self.modelID(from: f[1])
            // time_updated 是毫秒。
            guard let ms = Double(f[9]), ms > 0 else { continue }
            let ts = Date(timeIntervalSince1970: ms / 1000)

            let input = Int(f[3]) ?? 0
            let output = Int(f[4]) ?? 0
            let reasoning = Int(f[5]) ?? 0
            let cacheRead = Int(f[6]) ?? 0
            let cacheWrite = Int(f[7]) ?? 0

            // 一个会话记一条。session 表给的就是整段会话的汇总，
            // 拆不出逐次调用 —— 这一点要如实反映：requests 记 1，
            // 而不是凭 token 数去猜它调了多少次。猜出来的次数会污染
            // 「按次数计费」那类额度的判断。
            events.append(UsageEvent(
                // 会话 id 天然就是去重键：同一个会话每轮采集都读到，
                // 但采集器每次从头重算快照，同 id 只会算一次。
                id: "opencode:" + f[0],
                timestamp: ts,
                platform: ModelRouter.platform(forModel: modelID, fallback: homePlatform),
                model: modelID,
                lane: LaneRouter.lane(forEntrypoint: nil, cwd: f[10]),
                requests: 1,
                prompts: 0,
                inputTokens: input,
                outputTokens: output + reasoning,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite
            ))
            if last == nil || ts > last! { last = ts }
        }
        return ParsedFile(events: events, quotas: [], lastEventAt: last)
    }

    /// 从 `{"id":"volc-coding","providerID":"gateway",...}` 里取出 id。
    ///
    /// 取 `id` 不取 `providerID`：后者只说明经过哪个网关，
    /// 而钱是花在网关背后那个平台上的。
    static func modelID(from raw: String) -> String {
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = o["id"] as? String
        else {
            // 不是 JSON 就当成裸模型名，旧版本可能这么存。
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return id
    }
}

// MARK: - 执行器

/// 用 opencode 跑任务。
public struct OpenCodeRunner: AgentRunner {
    public let platform: Platform
    public var runnerID: String { "opencode.\(platform.rawValue).code" }
    public let binaryName = "opencode"
    public let sessionSupport: SessionSupport = .projectLatest
    /// 它能改文件。
    public let canEdit = true

    public init(platform: Platform = .volcark) {
        self.platform = platform
    }

    public func command(prompt: String, cwd: String)
        -> (launchPath: String, args: [String], env: [String: String]) {
        command(prompt: prompt, cwd: cwd, session: .fresh)
    }

    public func command(prompt: String, cwd: String, session: GraphSession.Mode)
        -> (launchPath: String, args: [String], env: [String: String]) {
        var args = ["run", "--auto", "--dir", cwd]
        if case .projectResume = session { args.append("-c") }
        // `--auto` 是它的 yolo：自动批准没有被显式拒绝的权限请求。
        // 无头跑必须要它 —— 否则会停在权限提示上直到超时，
        // 这个坑在 Qwen 上踩过一次（consecutive_identical_tool_calls
        // 的根因就是编辑被审批拦住）。
        if let m = RunnerConfigStore.load().model(for: platform), !m.isEmpty {
            args += ["-m", m]
        }
        args.append(prompt)
        return (Proc.which("opencode") ?? "/opt/homebrew/bin/opencode", args, [:])
    }
}
