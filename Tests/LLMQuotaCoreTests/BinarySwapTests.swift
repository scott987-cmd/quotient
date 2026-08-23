import XCTest
@testable import LLMQuotaCore

/// 「新二进制等它干完自然生效」必须是机制,不是安慰。
///
/// 两个反向的坑同时防:
///  - 循环不自己换 → MacBook 停在旧版几小时(2026-08-22);
///  - 更新路径无条件 kickstart → 正在跑的 agent 被杀(fa4e5eeb 2026-08-23 两次)。
final class BinarySwapTests: XCTestCase {
    private func tmp(_ name: String) -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("binswap-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(name).path
    }

    func test_换了二进制才算变_同一份不算() throws {
        let p = tmp("llmq")
        try Data("v1".utf8).write(to: URL(fileURLWithPath: p))
        let w = BinarySwap.watch(path: p)
        XCTAssertNotNil(w.startedWith)
        XCTAssertFalse(w.changed(), "没动过就不该报变")

        // 像 build-app.sh / ReleaseChannel.install 那样:写新文件再 mv 覆盖(新 inode)。
        let fresh = p + ".new"
        try Data("v2-longer".utf8).write(to: URL(fileURLWithPath: fresh))
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: p), withItemAt: URL(fileURLWithPath: fresh))
        XCTAssertTrue(w.changed(), "mv 覆盖后 inode/大小都变了,必须报变")
    }

    func test_文件暂时没了按没变处理_不在中间态退出() throws {
        let p = tmp("llmq")
        try Data("v1".utf8).write(to: URL(fileURLWithPath: p))
        let w = BinarySwap.watch(path: p)
        try FileManager.default.removeItem(atPath: p)
        XCTAssertFalse(w.changed(), "替换中的一瞬间文件可能不在,别据此退出")
    }

    func test_没指纹的watch永远不报变() {
        let w = BinarySwap.watch(path: "/nonexistent/llmq")
        XCTAssertNil(w.startedWith)
        XCTAssertFalse(w.changed())
    }

    func test_只有换了且没活才退出() {
        XCTAssertTrue(BinarySwap.shouldExit(changed: true, inFlight: false))
        XCTAssertFalse(BinarySwap.shouldExit(changed: true, inFlight: true), "有活在跑,再等一轮")
        XCTAssertFalse(BinarySwap.shouldExit(changed: false, inFlight: false))
        XCTAssertFalse(BinarySwap.shouldExit(changed: false, inFlight: true))
    }

    /// 契约:`ReleaseChannel.install` 不准自己踢 worker。
    /// 踢不踢由调用方的 `restartResidentServices()` 按在飞守卫决定;install 里再来一句
    /// 无条件 kickstart,守卫就被绕过 —— 同一件事两处判,正是这次出事的形状。
    func test_install不再自己kickstart() throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LLMQuotaCore/ReleaseChannel.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        guard let start = text.range(of: "public static func install(") else {
            return XCTFail("找不到 install")
        }
        let body = text[start.lowerBound...]
        let end = body.range(of: "\n    // MARK: - 工具")?.lowerBound ?? body.endIndex
        let installBody = body[..<end]
        // 只认代码里的字面量参数 "kickstart"(带引号),注释里提一嘴不算。
        XCTAssertFalse(installBody.contains("\"kickstart\""),
                       "install 里不准 kickstart:会绕过在飞守卫杀掉正在跑的 agent")
    }
}
