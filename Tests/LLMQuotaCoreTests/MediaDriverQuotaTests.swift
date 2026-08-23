import XCTest
import Foundation
@testable import LLMQuotaCore

/// 媒体驱动(MiniMaxMediaRunner 内联的 zsh)对视频额度撞顶的处理:
/// 第一条 VIDEO 报「用量上限」之后,本轮余下的 VIDEO 一条都不再发请求。
///
/// 实测 2026-08-22:一条任务排了 6 条 VIDEO,第一条就撞顶,后面 5 条照样发、照样被拒,
/// 日志里六个 FAIL 看不出是同一个原因,agent 还以为是提示词不对去改词重试。
final class MediaDriverQuotaTests: XCTestCase {
    private func makeDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediadrv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 假 mmx:每次被调都往计数文件追加一行,然后按 MiniMax 的真实措辞报额度错。
    private func fakeMMX(in dir: URL, counter: URL) throws -> URL {
        let mmx = dir.appendingPathComponent("mmx")
        let body = """
        #!/bin/zsh
        echo "called $*" >> "\(counter.path)"
        echo "Error: 已达到 Token Plan 用量上限,请明日再试" >&2
        exit 1
        """
        try body.write(to: mmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mmx.path)
        return mmx
    }

    private func runDriver(spec: String, cwd: URL, mmx: URL) throws -> (out: String, status: Int32) {
        let cmd = MiniMaxMediaRunner().command(prompt: spec, cwd: cwd.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.launchPath)
        p.arguments = cmd.args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in cmd.env { env[k] = v }
        env["LLMQ_MMX"] = mmx.path     // 指到假 mmx
        env["LLMQ_NODE"] = ""          // 空 = 直接执行 LLMQ_MMX,不经 node
        p.environment = env
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    func test_视频额度撞顶后_余下VIDEO不再发请求() throws {
        let dir = try makeDir()
        let counter = dir.appendingPathComponent("calls.txt")
        let mmx = try fakeMMX(in: dir, counter: counter)
        let spec = """
        【媒体】测试
        VIDEO out/a.mp4 :: 画面一
        VIDEO out/b.mp4 :: 画面二
        VIDEO out/c.mp4 :: 画面三
        """
        let r = try runDriver(spec: spec, cwd: dir, mmx: mmx)
        let calls = (try? String(contentsOf: counter, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        XCTAssertEqual(calls, 1, "撞顶之后不该再调 mmx;实际调了 \(calls) 次\n\(r.out)")
        XCTAssertTrue(r.out.contains("NOTE 视频额度已达上限"), "要把原因说明白\n\(r.out)")
        XCTAssertEqual(r.out.components(separatedBy: "SKIP out/").count - 1, 2,
                       "后两条应当是 SKIP(额度),不是 FAIL\n\(r.out)")
        XCTAssertEqual(r.out.components(separatedBy: "FAIL out/").count - 1, 1,
                       "只有第一条是真正发了请求的 FAIL\n\(r.out)")
        XCTAssertNotEqual(r.status, 0, "一个都没生成,整体仍然算失败")
    }

    func test_普通失败不触发跳过() throws {
        let dir = try makeDir()
        let counter = dir.appendingPathComponent("calls.txt")
        let mmx = dir.appendingPathComponent("mmx")
        try """
        #!/bin/zsh
        echo "called $*" >> "\(counter.path)"
        echo "Error: prompt rejected by content filter" >&2
        exit 1
        """.write(to: mmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mmx.path)
        let spec = """
        VIDEO out/a.mp4 :: 画面一
        VIDEO out/b.mp4 :: 画面二
        """
        let r = try runDriver(spec: spec, cwd: dir, mmx: mmx)
        let calls = (try? String(contentsOf: counter, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        XCTAssertEqual(calls, 2, "不是额度问题就该每条都试\n\(r.out)")
        XCTAssertFalse(r.out.contains("视频额度已达上限"))
    }
}
