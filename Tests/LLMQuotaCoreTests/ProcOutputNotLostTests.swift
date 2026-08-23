import XCTest
@testable import LLMQuotaCore

/// 子进程退出了、但它留下的孙进程还攥着 stdout 管道 —— 以前 Proc.run 等 EOF 等不到,
/// 5 秒后把读端一关,已经读到的内容整个丢掉,stdout 返回空串。
/// 实锤 2026-08-23:Kimi(swarm 子 agent)跑完打印了最终结论、还 git commit 了报告,
/// 任务记录里 stdout 只有 2 字节;同一轮里 MacBook 上 Claude 的评审同样"没产出"。
/// 输出丢了 = 结论读不到 = 任务被记成「没产生改动」、分支被删。
final class ProcOutputNotLostTests: XCTestCase {
    func test_孙进程攥着管道_也要拿到已经打印的输出() {
        let t0 = Date()
        // 孙进程**继承**管道(不重定向),像 kimi 的 swarm 子 agent / 任何后台守护那样。
        let r = Proc.run("/bin/sh", ["-c", "echo hello-from-child; (sleep 20 &); exit 0"],
                         cwd: "/tmp", env: [:], timeout: 15)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.timedOut, "子进程自己 0 秒就退出了,不该算超时")
        XCTAssertTrue(r.stdout.contains("hello-from-child"), "已经打印的输出不能因为孙进程没关管道就丢:[\(r.stdout)]")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 12, "也不能跟着孙进程一起等")
    }

    func test_正常进程输出完整() {
        let r = Proc.run("/bin/sh", ["-c", "printf 'a%.0s' $(seq 1 200000); echo; echo err >&2"],
                         cwd: "/tmp", env: [:], timeout: 15)
        XCTAssertEqual(r.stdout.count, 200001, "大输出(超过管道缓冲 64K)必须完整读完")
        XCTAssertEqual(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }
}
