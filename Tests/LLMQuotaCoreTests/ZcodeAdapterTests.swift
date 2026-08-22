import XCTest
@testable import LLMQuotaCore

/// **zcode 的用量要能被看见。**
///
/// 老板 2026-08-22:「macbook 装了 zcode,以后 GLM 我主要用官方的 zcode 了」。
/// 它是 Anthropic 兼容客户端,但日志在 `cli/rollout/model-io-*.jsonl`、
/// 用量在 `response.usage` —— 和 Claude Code 的 `projects/**` + `message.usage`
/// 两头都对不上。只加一条 roots 的话一条都统计不到,
/// 他用 zcode 干的活在看板上等于没发生。
final class ZcodeAdapterTests: XCTestCase {
    private func sample() -> Data {
        let line1 = """
        {"requestId":"req-1","turnId":"turn-a","completedAt":"2026-08-22T02:54:08.809Z",\
        "model":{"modelId":"glm-5.3","providerId":"builtin:bigmodel-coding-plan"},\
        "response":{"modelId":"glm-5.3","usage":{"inputTokens":13834,"outputTokens":121,\
        "totalTokens":13955,"cacheReadTokens":11712,"cacheWriteTokens":0}}}
        """
        // 同一轮里的第二次调用(工具循环)——算 requests,不算第二条「人发的消息」
        let line2 = """
        {"requestId":"req-2","turnId":"turn-a","completedAt":"2026-08-22T02:54:20.000Z",\
        "model":{"modelId":"glm-5.3","providerId":"builtin:bigmodel-coding-plan"},\
        "response":{"modelId":"glm-5.3","usage":{"inputTokens":900,"outputTokens":40,\
        "cacheReadTokens":0,"cacheWriteTokens":0}}}
        """
        return Data((line1 + "\n" + line2 + "\n").utf8)
    }

    func testParsesTokensFromResponseUsage() {
        let r = ZcodeAdapter().parse(file: URL(fileURLWithPath: "/tmp/x.jsonl"), data: sample())
        let calls = r.events.filter { $0.requests > 0 }
        XCTAssertEqual(calls.count, 2, "两次调用都要记")
        XCTAssertEqual(calls.reduce(0) { $0 + $1.inputTokens }, 14734)
        XCTAssertEqual(calls.reduce(0) { $0 + $1.cacheReadTokens }, 11712,
                       "缓存读也要记 —— 它照样计费")
        XCTAssertTrue(calls.allSatisfy { $0.platform == .glm })
    }

    /// 一轮对话只算一条「人发的消息」——套餐公布的上限数的是这个,
    /// 混进工具循环的几十次调用会让已用百分比偏出十几倍。
    func testOnePromptPerTurn() {
        let r = ZcodeAdapter().parse(file: URL(fileURLWithPath: "/tmp/x.jsonl"), data: sample())
        XCTAssertEqual(r.events.filter { $0.prompts > 0 }.count, 1,
                       "同一个 turnId 的多次调用只算一条人发消息")
    }

    /// 找的是 zcode 自己的目录结构,不是 Claude Code 的 projects/。
    func testLooksInRolloutNotProjects() {
        XCTAssertEqual(ZcodeAdapter().roots, ["~/.zcode"])
        XCTAssertEqual(ZcodeAdapter().homePlatform, .glm)
    }
}
