import XCTest
@testable import LLMQuotaCore

/// GLM 现在由官方客户端 ZCode 跑,不再是「改 Claude Code 的 BASE_URL」。
/// 老板 2026-08-23:「MacBook 的 ZCode 还是没有在移动端展示」—— 数据其实到了手机,
/// 只是那一行一直叫「Claude Code · GLM」,他按名字找当然找不到。
final class ZcodeIdentityTests: XCTestCase {
    func test_GLM的干活人叫ZCode() {
        XCTAssertEqual(AgentIdentity.name(for: .glm), "ZCode · GLM")
        XCTAssertTrue(AgentIdentity.name(for: .glm).contains("ZCode"))
    }

    func test_GLM跑的是zcode不是claude() {
        XCTAssertEqual(AgentIdentity.binaryName(for: .glm), "zcode")
    }

    /// 有了官方客户端就不再算「借用别人的客户端」——它的用量就是 GLM 自己的套餐。
    func test_GLM不再算借用客户端() {
        XCTAssertFalse(AgentIdentity.isBorrowedClient(.glm))
        XCTAssertTrue(AgentIdentity.isBorrowedClient(.deepseek), "DeepSeek 还是借 Claude Code 跑的")
    }

    /// 执行器和身份表说的必须是同一件事(同一概念两处写,迟早对不上)。
    func test_执行器与身份表一致() {
        let runner = RunnerRegistry.all.first { $0.platform == .glm && $0 is ZcodeRunner }
        XCTAssertNotNil(runner, "GLM 的执行器应该是 ZcodeRunner")
        XCTAssertEqual(runner?.binaryName, AgentIdentity.binaryName(for: .glm))
    }
}
