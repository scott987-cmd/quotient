import XCTest
@testable import LLMQuotaCore

final class HumanBlockContractTests: XCTestCase {
    func testLoginBarrierHasAOneCommandHumanAskPath() {
        let clause = AskContract.clause(askFile: "/tmp/question.json")
        XCTAssertTrue(clause.contains("llmq work needs-human"))
        XCTAssertTrue(clause.contains("人工登录"))
        XCTAssertTrue(clause.contains("不要只在仓库里写 `BLOCKED.md`"))
    }

    func testProcessStopsPromptlyAfterStructuredQuestionAppears() {
        let started = Date()
        let result = Proc.run(
            "/bin/sleep", ["30"], cwd: "/tmp", env: [:], timeout: 20,
            stopWhen: { Date().timeIntervalSince(started) > 0.25 })

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(result.timedOut,
                       "人工提问是受控阻塞，不应被误记为模型超时")
    }

    func testWorkerExportsAskPathAndWatchesIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/llmq/main.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("executionEnv[\"LLMQ_ASK_FILE\"]"))
        XCTAssertTrue(source.contains("case \"needs-human\":"))
        XCTAssertTrue(source.contains("stopWhen:"))
    }
}
