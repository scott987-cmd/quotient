import Foundation

// MARK: - Claude Code

/// 解析 Claude Code 的会话日志。
///
/// 已用本机 4150 个文件、1.09GB 真实数据验证。
///
/// 去重是关键：同一个 requestId 会写出多行（正文一行、每个 tool_use 各一行），
/// 实测 300 个文件里就有 15515 组"多行 usage 完全一致"和 1191 组
/// "一行有值其余全零"，不去重会把用量放大一倍以上。
/// 另外续接会话时旧消息会被原样抄进新文件，所以去重必须跨文件全局做。
public struct ClaudeCodeAdapter: UsageAdapter {
    public let id: String
    public let displayName: String
    public let homePlatform: Platform
    public let roots: [String]
    public let verified: Bool

    public init(
        id: String = "claude-code",
        displayName: String = "Claude Code",
        homePlatform: Platform = .claude,
        roots: [String] = ["~/.claude"],
        verified: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.homePlatform = homePlatform
        self.roots = roots
        self.verified = verified
    }

    public func discoverFiles() -> [URL] {
        jsonlFiles(under: ["projects"])
    }

    public func parse(file: URL, data: Data) -> ParsedFile {
        let needle = Array("assistant".utf8)
        let promptNeedle = Array("promptId".utf8)
        var events: [UsageEvent] = []
        var prompts: [UsageEvent] = []
        var modelVotes: [String: Int] = [:]
        var last: Date?

        LineScanner.forEachLine(data) { line in
            // 人发的消息：套餐公布的「每 5 小时 X 次」数的就是这个。
            // 判据是实测出来的：真人输入的 content 是**字符串**，
            // 而工具结果回填的 content 是含 tool_result 块的数组 —— 后者不是人发的。
            // isMeta 是系统注入的，也要排除。promptId 正好可以拿来去重。
            if LineScanner.contains(line, promptNeedle),
               let obj = JSONHelp.object(line),
               obj["type"] as? String == "user",
               (obj["userType"] as? String) == "external",
               (obj["isMeta"] as? Bool) != true,
               let msg = obj["message"] as? [String: Any],
               msg["content"] is String,
               let pid = obj["promptId"] as? String,
               let ts = JSONHelp.date(obj["timestamp"]) {
                prompts.append(UsageEvent(
                    id: "prompt:\(pid)",
                    timestamp: ts,
                    platform: homePlatform,   // 稍后按本文件的主模型改写
                    model: "",
                    lane: LaneRouter.lane(forEntrypoint: obj["entrypoint"] as? String,
                                          cwd: obj["cwd"] as? String),
                    requests: 0, prompts: 1,
                    inputTokens: 0, outputTokens: 0,
                    cacheReadTokens: 0, cacheWriteTokens: 0
                ))
                if last == nil || ts > last! { last = ts }
            }

            guard LineScanner.contains(line, needle) else { return }
            guard let obj = JSONHelp.object(line),
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any]
            else { return }

            let model = (msg["model"] as? String) ?? ""
            guard ModelRouter.isRealAPICall(model: model) else { return }
            guard let ts = JSONHelp.date(obj["timestamp"]) else { return }
            guard let usage = msg["usage"] as? [String: Any] else { return }

            // requestId 才是"一次 API 调用"的身份；uuid 是"一行日志"的身份。
            let key = (obj["requestId"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
            modelVotes[model, default: 0] += 1

            events.append(UsageEvent(
                id: key,
                timestamp: ts,
                platform: ModelRouter.platform(forModel: model, fallback: homePlatform),
                model: model,
                // 优先按 cwd 判定：调度器总在自己的 worktree 里跑，这个信号比 entrypoint 可靠。
                lane: LaneRouter.lane(forEntrypoint: obj["entrypoint"] as? String,
                                      cwd: obj["cwd"] as? String),
                inputTokens: JSONHelp.int(usage["input_tokens"]),
                outputTokens: JSONHelp.int(usage["output_tokens"]),
                cacheReadTokens: JSONHelp.int(usage["cache_read_input_tokens"]),
                cacheWriteTokens: JSONHelp.int(usage["cache_creation_input_tokens"])
            ))
            if last == nil || ts > last! { last = ts }
        }

        // 人发的消息本身不带模型名，但它消耗的是这一轮实际用的那个平台的额度。
        // 按本文件出现最多的模型归属 —— 一个会话里换模型是少数情况，
        // 而这一步对「把 Claude Code 指到 GLM 端点」的用法是必需的：
        // 那种情况下 prompt 该记在 GLM 头上，不是 Claude。
        if let dominant = modelVotes.max(by: { $0.value < $1.value })?.key {
            let p = ModelRouter.platform(forModel: dominant, fallback: homePlatform)
            for i in prompts.indices {
                prompts[i].platform = p
                prompts[i].model = dominant
            }
        }
        events.append(contentsOf: prompts)

        return ParsedFile(events: events, quotas: [], lastEventAt: last)
    }
}

// MARK: - Codex

/// 解析 Codex 的 rollout 会话日志。
///
/// 已用本机 26 个 rollout 真实数据验证。
///
/// 两个要点：
/// 1. token 用量取 `total_token_usage` 的**单调增量**，不能累加 `last_token_usage`。
///    实测同一个会话里前者累加得 35733656（与最终值完全吻合），后者会多算 12 万
///    —— 因为同一轮会重复上报。
/// 2. `rate_limits` 里有平台官方回报的额度（used_percent / window_minutes /
///    resets_at），这是所有平台里唯一不用猜、不用用户填的真实额度来源。
public struct CodexAdapter: UsageAdapter {
    public let id = "codex"
    public let displayName = "Codex"
    public let homePlatform: Platform = .codex
    public let roots = ["~/.codex"]
    public let verified = true

    public init() {}

    public func discoverFiles() -> [URL] {
        jsonlFiles(under: ["sessions"])
    }

    public func parse(file: URL, data: Data) -> ParsedFile {
        let tokenNeedle = Array("token_count".utf8)
        let ctxNeedle = Array("turn_context".utf8)

        var events: [UsageEvent] = []
        var quotas: [OfficialQuota] = []
        var last: Date?

        var currentModel = ""
        var sessionID = file.deletingPathExtension().lastPathComponent
        var prevTotals = Totals()
        var seq = 0

        LineScanner.forEachLine(data) { line in
            let isToken = LineScanner.contains(line, tokenNeedle)
            let isCtx = LineScanner.contains(line, ctxNeedle)
            guard isToken || isCtx else { return }
            guard let obj = JSONHelp.object(line) else { return }
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let type = obj["type"] as? String

            if type == "session_meta" {
                if let sid = payload["session_id"] as? String { sessionID = sid }
                // 同一个 rollout 文件里可能有多段会话（续接 / 分叉），计数要重新起头。
                prevTotals = Totals()
                return
            }
            if type == "turn_context" {
                if let m = payload["model"] as? String, !m.isEmpty { currentModel = m }
                return
            }
            guard payload["type"] as? String == "token_count" else { return }
            guard let ts = JSONHelp.date(obj["timestamp"]) else { return }

            if let rl = payload["rate_limits"] as? [String: Any] {
                let planType = rl["plan_type"] as? String
                for (key, label) in [("primary", "主额度"), ("secondary", "次额度")] {
                    guard let w = rl[key] as? [String: Any],
                          let used = JSONHelp.double(w["used_percent"])
                    else { continue }
                    let minutes = JSONHelp.int(w["window_minutes"])
                    var resets: Date?
                    if let epoch = JSONHelp.double(w["resets_at"]) {
                        resets = Date(timeIntervalSince1970: epoch)
                    }
                    quotas.append(OfficialQuota(
                        id: key,
                        label: Self.windowLabel(minutes: minutes, fallback: label),
                        usedPercent: used,
                        windowMinutes: minutes,
                        resetsAt: resets,
                        planType: planType,
                        observedAt: ts
                    ))
                }
            }

            guard let info = payload["info"] as? [String: Any],
                  let totalDict = info["total_token_usage"] as? [String: Any]
            else { return }

            let totals = Totals(totalDict)
            let delta = totals.delta(from: prevTotals)
            prevTotals = totals

            guard delta.hasUsage else { return }
            seq += 1

            let model = currentModel.isEmpty ? "unknown" : currentModel
            events.append(UsageEvent(
                id: "\(sessionID)#\(seq)",
                timestamp: ts,
                platform: ModelRouter.platform(forModel: model, fallback: homePlatform),
                model: model,
                // Codex 的 input_tokens 是含缓存命中的总量，cached 是其中的子集。
                // 实测 total = input + output 成立，所以这里把缓存拆出来单列。
                inputTokens: max(0, delta.input - delta.cachedInput),
                outputTokens: delta.output,
                cacheReadTokens: delta.cachedInput,
                cacheWriteTokens: delta.cacheWrite
            ))
            if last == nil || ts > last! { last = ts }
        }

        return ParsedFile(events: events, quotas: quotas, lastEventAt: last)
    }

    static func windowLabel(minutes: Int, fallback: String) -> String {
        switch minutes {
        case 0: return fallback
        case ..<60: return "\(minutes) 分钟"
        case ..<1440: return "\(minutes / 60) 小时"
        case 10080: return "每周"
        case 43200: return "每月"
        default: return "\(minutes / 1440) 天"
        }
    }

    struct Totals {
        var input = 0
        var cachedInput = 0
        var cacheWrite = 0
        var output = 0

        init() {}

        init(_ d: [String: Any]) {
            input = JSONHelp.int(d["input_tokens"])
            cachedInput = JSONHelp.int(d["cached_input_tokens"])
            cacheWrite = JSONHelp.int(d["cache_write_input_tokens"])
            output = JSONHelp.int(d["output_tokens"])
        }

        var hasUsage: Bool { input > 0 || output > 0 || cacheWrite > 0 }

        /// 累计值回退说明会话被压缩或重开了，这一段从头算。
        func delta(from prev: Totals) -> Totals {
            guard input >= prev.input, output >= prev.output else { return self }
            var d = Totals()
            d.input = input - prev.input
            d.cachedInput = max(0, cachedInput - prev.cachedInput)
            d.cacheWrite = max(0, cacheWrite - prev.cacheWrite)
            d.output = output - prev.output
            return d
        }
    }
}

// MARK: - Gemini CLI family

/// 解析 Gemini CLI 及其分叉（Qwen Code、iFlow 等）的会话日志。
///
/// 已用本机 ~/.gemini 真实数据验证格式。
///
/// 注意：这一家的 `logs.json` **只记录用户消息，不记录 token**。
/// 所以这个适配器只能统计"请求次数"，token 恒为 0。
/// 这不是缺陷 —— Gemini CLI 和 Qwen Code 的免费额度本来就是按每日请求次数限的，
/// 次数正好是对口的计量单位。
public struct GeminiFamilyAdapter: UsageAdapter {
    public let id: String
    public let displayName: String
    public let homePlatform: Platform
    public let roots: [String]
    public let verified: Bool

    public init(
        id: String,
        displayName: String,
        homePlatform: Platform,
        roots: [String],
        verified: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.homePlatform = homePlatform
        self.roots = roots
        self.verified = verified
    }

    public static let gemini = GeminiFamilyAdapter(
        id: "gemini-cli", displayName: "Gemini CLI",
        homePlatform: .gemini, roots: ["~/.gemini"], verified: true
    )

    /// iFlow 同属这一家族。本机没装，未用真实数据验证。
    public static let iflow = GeminiFamilyAdapter(
        id: "iflow", displayName: "iFlow",
        homePlatform: .qwen, roots: ["~/.iflow"], verified: false
    )

    public func discoverFiles() -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in expandedRoots {
            let tmp = root.appendingPathComponent("tmp", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for dir in entries {
                let logs = dir.appendingPathComponent("logs.json")
                if fm.fileExists(atPath: logs.path) { out.append(logs) }
            }
        }
        return out
    }

    public func parse(file: URL, data: Data) -> ParsedFile {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return ParsedFile()
        }
        var events: [UsageEvent] = []
        var last: Date?

        for entry in arr {
            guard entry["type"] as? String == "user",
                  let ts = JSONHelp.date(entry["timestamp"])
            else { continue }
            let session = (entry["sessionId"] as? String) ?? file.path
            let mid = JSONHelp.int(entry["messageId"])
            events.append(UsageEvent(
                id: "\(session)#\(mid)",
                timestamp: ts,
                platform: homePlatform,
                model: "unknown",
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0
            ))
            if last == nil || ts > last! { last = ts }
        }
        return ParsedFile(events: events, quotas: [], lastEventAt: last)
    }
}

/// 从 CLI 自己的配置里读出「模型 → 实际端点」的映射。
///
/// 为什么必须做这一步：**模型名不等于付钱的平台。**
///
/// 实测本机 `~/.qwen/settings.json` 里配了 15 个模型 —— Qwen、DeepSeek、Kimi、
/// GLM、MiniMax 全都有 —— 但它们的 baseUrl 指向同一个地方：
/// `token-plan.cn-beijing.maas.aliyuncs.com`（阿里百炼 Token Plan）。
/// 阿里在转售这些模型，账全记在百炼头上。
///
/// 只看模型名的话，`qwen -m glm-5.2` 会被记到 GLM 的额度里，
/// 而真实消耗的是百炼。这种错账会让作废预警和调度决策同时失真：
/// 一边以为 GLM 在被消耗（其实没有），一边以为百炼还很闲（其实在烧）。
enum EndpointRouter {
    /// 端点主机 → 真正付钱的平台。
    private static let hostRules: [(String, Platform)] = [
        ("token-plan.cn-beijing.maas.aliyuncs.com", .qwen),   // 阿里百炼 Token Plan
        ("dashscope.aliyuncs.com", .qwen),
        ("api.moonshot", .kimi),
        ("api.minimax", .minimax),
        ("open.bigmodel.cn", .glm),
        ("api.z.ai", .glm),
        ("api.deepseek.com", .deepseek),
        ("ark.cn-beijing.volces.com", .volcark),
        ("api.anthropic.com", .claude),
        ("api.openai.com", .codex),
    ]

    static func platform(forHost host: String) -> Platform? {
        let h = host.lowercased()
        return hostRules.first { h.contains($0.0) }?.1
    }

    /// 解析 Qwen Code 的配置，得到 模型名 → 平台。
    static func qwenModelMap() -> [String: Platform] {
        let path = NSString(string: "~/.qwen/settings.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = JSONHelp.object(data),
              let providers = root["modelProviders"] as? [String: Any]
        else { return [:] }

        var map: [String: Platform] = [:]
        for (_, value) in providers {
            guard let models = value as? [[String: Any]] else { continue }
            for m in models {
                guard let id = m["id"] as? String,
                      let base = m["baseUrl"] as? String,
                      let host = URL(string: base)?.host,
                      let platform = platform(forHost: host)
                else { continue }
                map[id] = platform
            }
        }
        return map
    }
}

// MARK: - Qwen Code

/// 解析 Qwen Code 的 token 用量日志。
///
/// 已用本机 ~/.qwen/usage/token-usage-2026-08.jsonl 真实数据验证。
///
/// Qwen Code 比 Gemini CLI 强的地方在于它专门落了一份用量流水，每次 API 调用一条，
/// 带 model / inputTokens / outputTokens / cachedTokens，还自带 uuid 可以去重。
/// 所以这里不走 Gemini 那套只能数次数的路子。
///
/// 注意别同时启用 GeminiFamilyAdapter 扫 ~/.qwen —— 那会把同样的调用按
/// tmp/*/logs.json 再数一遍，造成重复计数。
public struct QwenCodeAdapter: UsageAdapter {
    public let id = "qwen-code"
    public let displayName = "Qwen Code"
    public let homePlatform: Platform = .qwen
    public let roots = ["~/.qwen"]
    public let verified = true

    public init() {}

    public func discoverFiles() -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in expandedRoots {
            let dir = root.appendingPathComponent("usage", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries
            where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("token-usage-") {
                out.append(url)
            }
        }
        return out
    }

    public func parse(file: URL, data: Data) -> ParsedFile {
        var events: [UsageEvent] = []
        var last: Date?
        // 按配置里的真实端点归类，而不是按模型名 —— 见 EndpointRouter 的说明。
        let endpointMap = EndpointRouter.qwenModelMap()

        LineScanner.forEachLine(data) { line in
            guard let obj = JSONHelp.object(line),
                  let ts = JSONHelp.date(obj["timestamp"])
            else { return }

            let model = (obj["model"] as? String) ?? "unknown"
            let input = JSONHelp.int(obj["inputTokens"])
            let output = JSONHelp.int(obj["outputTokens"])
            let cached = JSONHelp.int(obj["cachedTokens"])
            let total = JSONHelp.int(obj["totalTokens"])

            // cachedTokens 到底是 inputTokens 的子集还是并列项，日志里没写死。
            // 用 total == input + output 这个恒等式反推：成立就说明缓存已经算在
            // input 里了，要拆出来；不成立说明是并列的，原样保留。
            let cachedIsSubset = (total == input + output) && cached > 0
            let uncachedInput = cachedIsSubset ? max(0, input - cached) : input

            let key = (obj["id"] as? String)
                ?? "\((obj["sessionId"] as? String) ?? file.path)#\(ts.timeIntervalSince1970)"

            events.append(UsageEvent(
                id: key,
                timestamp: ts,
                // 端点映射优先。配置里查不到这个模型时才退回按模型名猜。
                platform: endpointMap[model]
                    ?? ModelRouter.platform(forModel: model, fallback: homePlatform),
                model: model,
                inputTokens: uncachedInput,
                outputTokens: output,
                cacheReadTokens: cached,
                cacheWriteTokens: 0
            ))
            if last == nil || ts > last! { last = ts }
        }

        return ParsedFile(events: events, quotas: [], lastEventAt: last)
    }
}

// MARK: - Kimi Code

/// 解析 Kimi Code 客户端的 wire 日志。
///
/// 已用本机 ~/.kimi-code 的 8 个 wire.jsonl、941 条记录真实验证。
///
/// 数据长这样（一次 API 调用一条）：
/// ```
/// {"type":"usage.record","model":"kimi-code/k3","usageScope":"turn",
///  "usage":{"inputOther":6909,"output":230,"inputCacheRead":13824,"inputCacheCreation":0},
///  "time":1786071333912}
/// ```
///
/// **关键：必须只取 `usageScope == "turn"`。**
/// 实测 941 条记录里有 940 条 turn 加 1 条 `session` —— 后者是整个会话的汇总，
/// 混进去会把那个会话的用量算两遍。
public struct KimiCodeAdapter: UsageAdapter {
    public let id = "kimi-code"
    public let displayName = "Kimi Code"
    public let homePlatform: Platform = .kimi
    public let roots = ["~/.kimi-code"]
    public let verified = true

    public init() {}

    public func discoverFiles() -> [URL] {
        // sessions 下还有别的 jsonl，只认 wire.jsonl。
        jsonlFiles(under: ["sessions"]).filter { $0.lastPathComponent == "wire.jsonl" }
    }

    public func parse(file: URL, data: Data) -> ParsedFile {
        let needle = Array("usage.record".utf8)
        var events: [UsageEvent] = []
        var last: Date?
        var index = 0

        LineScanner.forEachLine(data) { line in
            guard LineScanner.contains(line, needle) else { return }
            guard let obj = JSONHelp.object(line),
                  obj["type"] as? String == "usage.record",
                  // session 口径是会话汇总，会和它自己的 turn 记录重复。
                  (obj["usageScope"] as? String) == "turn",
                  let usage = obj["usage"] as? [String: Any]
            else { return }

            // time 是毫秒时间戳，不是 ISO 字符串。
            guard let ms = JSONHelp.double(obj["time"]) else { return }
            let ts = Date(timeIntervalSince1970: ms / 1000)

            let model = (obj["model"] as? String) ?? "unknown"
            index += 1

            events.append(UsageEvent(
                // 记录本身没有唯一 id。文件路径 + 行序号是稳定的：
                // 这个采集器每次都整文件重解析，序号不会漂。
                id: "\(file.path)#\(index)",
                timestamp: ts,
                platform: ModelRouter.platform(forModel: model, fallback: homePlatform),
                model: model,
                inputTokens: JSONHelp.int(usage["inputOther"]),
                outputTokens: JSONHelp.int(usage["output"]),
                cacheReadTokens: JSONHelp.int(usage["inputCacheRead"]),
                cacheWriteTokens: JSONHelp.int(usage["inputCacheCreation"])
            ))
            if last == nil || ts > last! { last = ts }
        }

        return ParsedFile(events: events, quotas: [], lastEventAt: last)
    }
}

// MARK: - Registry

public enum AdapterRegistry {
    /// 采集器清单。
    ///
    /// GLM / Kimi / MiniMax / DeepSeek / 火山 这几家的编码套餐，主流用法是把
    /// Claude Code 或 Codex 的 BASE_URL 指到对方的兼容端点。那种情况下用量会
    /// 落在 ~/.claude 或 ~/.codex 里，靠 ModelRouter 按模型名认出来归类，
    /// 不需要单独的适配器。下面这些额外条目是为"用了独立配置目录"的情况准备的
    /// （比如设了 CLAUDE_CONFIG_DIR 给每家分开放）。
    public static let all: [UsageAdapter] = [
        ClaudeCodeAdapter(),
        // 调度器跑 agent 时会用独立的 CLAUDE_CONFIG_DIR 来隔离平台。
        // **这条必须存在**：不采集它，调度器自己烧掉的额度对快照完全不可见，
        // 快照里的 usedFraction 只含人类手动用的那部分，
        // 于是所有基于用量的闸门（尤其是"给人类留多少额度"）全部被静默绕过。
        // 缓存文件按 adapter id 分开，所以和主目录互不干扰；
        // 事件按 requestId 全局去重，同一次调用不会被计两遍。
        ClaudeCodeAdapter(
            id: "claude-bot", displayName: "Claude（调度器专用目录）",
            homePlatform: .claude, roots: ["~/.claude-bot"], verified: true
        ),
        CodexAdapter(),
        GeminiFamilyAdapter.gemini,
        QwenCodeAdapter(),
        GeminiFamilyAdapter.iflow,
        KimiCodeAdapter(),
        OpenCodeAdapter(),
        ClaudeCodeAdapter(
            id: "kimi-cc", displayName: "Kimi (Claude Code 兼容目录)",
            // ~/.kimi-code 归 KimiCodeAdapter 管，这里只认 BASE_URL 转接时的独立配置目录。
            homePlatform: .kimi, roots: ["~/.claude-kimi"], verified: false
        ),
        ClaudeCodeAdapter(
            id: "glm-cc", displayName: "GLM (Claude Code 兼容目录)",
            homePlatform: .glm, roots: ["~/.glm", "~/.claude-glm", "~/.zai"], verified: false
        ),
        ClaudeCodeAdapter(
            id: "minimax-cc", displayName: "MiniMax (Claude Code 兼容目录)",
            homePlatform: .minimax, roots: ["~/.minimax", "~/.claude-minimax"], verified: false
        ),
        ClaudeCodeAdapter(
            id: "deepseek-cc", displayName: "DeepSeek (Claude Code 兼容目录)",
            homePlatform: .deepseek, roots: ["~/.deepseek", "~/.claude-deepseek"], verified: false
        ),
        ClaudeCodeAdapter(
            id: "volcark-cc", displayName: "火山方舟 (Claude Code 兼容目录)",
            homePlatform: .volcark, roots: ["~/.volcark", "~/.claude-ark", "~/.doubao"],
            verified: false
        ),
    ]
}
