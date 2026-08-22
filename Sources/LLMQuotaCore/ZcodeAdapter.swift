import Foundation

/// **zcode(智谱官方 GLM Coding CLI)的用量适配器。**
///
/// 老板 2026-08-22:「macbook 装了 zcode,以后 GLM 我主要用官方的 zcode 了」。
///
/// ## 为什么不能复用 ClaudeCodeAdapter
///
/// zcode 是 Anthropic 兼容的客户端(`~/.zcode/v2/config.json` 里
/// `"kind": "anthropic"`),但**日志布局和格式都不一样**:
/// - 位置:`~/.zcode/cli/rollout/model-io-sess_*.jsonl`,
///   不是 Claude Code 的 `projects/**/*.jsonl`
/// - 格式:一行一次完整调用,用量在 `response.usage`
///   (`inputTokens`/`outputTokens`/`cacheReadTokens`/`cacheWriteTokens`),
///   而不是 Claude Code 那种 `message.usage` 加多行同 requestId
///
/// 只把 `~/.zcode` 加进 GLM 那条 roots 是没用的 —— 路径和字段两头都对不上,
/// 结果是**一条都统计不到**:老板用 zcode 干的活,看板上等于没发生。
///
/// ## 「人发了几条消息」怎么数
///
/// 各家套餐公布的上限数的是人发的消息数,不是 API 调用数。zcode 的
/// 每行有 `turnId`:同一轮对话里工具循环的多次调用共用一个 turnId,
/// 所以**每个 turnId 记一条 prompt**,其余只记 requests。
/// 这和 ClaudeCodeAdapter 用 promptId 去重是同一个道理。
public struct ZcodeAdapter: UsageAdapter {
    public let id = "zcode"
    public let displayName = "GLM (zcode 官方 CLI)"
    public let homePlatform: Platform = .glm
    public let roots: [String]
    public var verified: Bool { false }

    public init(roots: [String] = ["~/.zcode"]) { self.roots = roots }

    public func discoverFiles() -> [URL] {
        jsonlFiles(under: ["cli/rollout"])
    }

    public func parse(file: URL, data: Data) -> ParsedFile {
        var events: [UsageEvent] = []
        var prompts: [UsageEvent] = []
        var seenTurns: Set<String> = []
        var modelVotes: [String: Int] = [:]
        var last: Date?

        LineScanner.forEachLine(data) { line in
            guard let obj = JSONHelp.object(line),
                  let resp = obj["response"] as? [String: Any],
                  let usage = resp["usage"] as? [String: Any] else { return }
            // 完成时刻优先；没有就退回开始时刻。
            let stamp = (obj["completedAt"] as? String) ?? (obj["startedAt"] as? String)
            guard let ts = stamp.flatMap(JSONHelp.date) else { return }
            let model = (resp["modelId"] as? String)
                ?? ((obj["model"] as? [String: Any])?["modelId"] as? String) ?? "glm"
            modelVotes[model, default: 0] += 1
            let rid = (obj["requestId"] as? String) ?? UUID().uuidString
            events.append(UsageEvent(
                id: "zcode:" + rid,
                timestamp: ts, platform: .glm, model: model,
                requests: 1, prompts: 0,
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int ?? 0,
                cacheWriteTokens: usage["cacheWriteTokens"] as? Int ?? 0))
            // 一轮对话记一条「人发的消息」。
            if let turn = obj["turnId"] as? String, seenTurns.insert(turn).inserted {
                prompts.append(UsageEvent(
                    id: "zcode-turn:" + turn,
                    timestamp: ts, platform: .glm, model: model,
                    requests: 0, prompts: 1,
                    inputTokens: 0, outputTokens: 0,
                    cacheReadTokens: 0, cacheWriteTokens: 0))
            }
            if last == nil || ts > last! { last = ts }
        }
        return ParsedFile(events: events + prompts, quotas: [], lastEventAt: last)
    }
}
