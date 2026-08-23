import XCTest
@testable import LLMQuotaCore

/// 每次 Proc.run 不许漏 fd。实锤 2026-08-23:常驻循环 66 分钟漏了 2555 个 PIPE fd,
/// fd 表一满,所有子进程「退出码 0、输出空」—— Kimi 结论丢、git 回空、分支被误删、待验收页空白。
final class ProcFdLeakTests: XCTestCase {
    private func fdCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    func test_连跑四十次_fd数不涨() {
        _ = Proc.run("/bin/sh", ["-c", "echo warm"], cwd: "/tmp", env: [:], timeout: 10)
        let before = fdCount()
        for i in 0..<40 {
            let r = Proc.run("/bin/sh", ["-c", "echo x\(i)"], cwd: "/tmp", env: [:], timeout: 10)
            XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "x\(i)")
        }
        let after = fdCount()
        XCTAssertLessThanOrEqual(after - before, 4, "40 次调用后 fd 从 \(before) 涨到 \(after):在漏")
    }

    func test_孙进程攥管道_也不漏() {
        let before = fdCount()
        for _ in 0..<5 {
            _ = Proc.run("/bin/sh", ["-c", "echo y; (sleep 20 &); exit 0"], cwd: "/tmp", env: [:], timeout: 15)
        }
        let after = fdCount()
        XCTAssertLessThanOrEqual(after - before, 4, "带孙进程的调用后 fd 从 \(before) 涨到 \(after):在漏")
    }
}
