import XCTest
@testable import LLMQuotaCore

/// 「被杀」和「没通过」必须分开。
///
/// 实况（2026-08-17）：
///
/// ```
/// 3f68707cs2  failed   改了 3 个文件但 验证没过（退出码 15），没有提交
/// 3f68707cs3  blocked  上游失败了，这一步先冻住。上游恢复后会自动解冻。
/// 3f68707cs4  blocked  同上
/// ```
///
/// 退出码 15 是 SIGTERM —— 验证进程被杀，不是跑出了失败。那天为了装新
/// 二进制重启了八次工作循环，每次都会杀掉正在跑的子进程。这个失败是
/// 基础设施造成的，跟 agent 改的代码毫无关系。
///
/// 后果：任务判 failed → 下游三步永久冻住（上游是 failed，「上游恢复后
/// 自动解冻」永远不会发生）→ 整条图搁浅 → **唯一会发现的是人**。
final class ExitClassifyTests: XCTestCase {

    /// 裸信号号（15/9/2）必须认成被杀。
    ///
    /// 这是实测踩到的那一种：Proc.run 在这条路径上回传的是原始信号号，
    /// 不是 shell 折算过的 143。只判 `> 128` 会漏掉它 ——
    /// 而漏掉的后果就是上面那三行。
    func testBareSignalIsKilledNotFailed() {
        for code in [Int32(15), 9, 2] {
            let k = ExitClassify.classify(exitCode: code)
            guard case .killed = k else {
                return XCTFail("退出码 \(code) 该判成被杀，判成了 \(k)")
            }
            XCTAssertTrue(k.shouldRequeue, "被杀该重排")
            XCTAssertFalse(k.blamesOutput,
                           "被杀不能算到产出账上 —— 一次发布重启就能让好产出背失败")
        }
    }

    /// shell 折算过的 128+signo 也要认。
    func testShellEncodedSignalIsKilled() {
        guard case .killed(let s) = ExitClassify.classify(exitCode: 143) else {
            return XCTFail("143 该是 SIGTERM")
        }
        XCTAssertEqual(s, 15)
        guard case .killed = ExitClassify.classify(exitCode: 137) else {
            return XCTFail("137 该是 SIGKILL")
        }
    }

    /// 真正的失败退出码还得是失败 —— 别把分类做成「什么都不算失败」。
    func testRealFailuresStillFail() {
        for code in [Int32(1), 3, 65, 70] {
            let k = ExitClassify.classify(exitCode: code)
            XCTAssertEqual(k, .failed, "退出码 \(code) 是真失败")
            XCTAssertTrue(k.blamesOutput)
            XCTAssertFalse(k.shouldRequeue, "真失败不该无限重排")
        }
    }

    func testZeroIsPassed() {
        XCTAssertEqual(ExitClassify.classify(exitCode: 0), .passed)
    }

    /// 超时按可重排处理，但不算产出的错。
    ///
    /// 超时是灰的：可能是活太大，也可能是机器卡了。倾向重排一次 ——
    /// 判错成「产出不行」的代价（永久钉死一份好产出）比多跑一次贵。
    func testTimeoutIsRequeuableButNotBlamed() {
        let k = ExitClassify.classify(exitCode: 1, timedOut: true)
        XCTAssertEqual(k, .timedOut)
        XCTAssertTrue(k.shouldRequeue)
        XCTAssertFalse(k.blamesOutput)
    }

    /// 措辞里必须写明「不是产出的问题」。
    ///
    /// 不写的话，人和评审 agent 看到「退出码 15」还是会当成验证失败 ——
    /// 分类做了但没传达出去，等于没做。
    func testDescriptionSaysItIsNotTheOutputsFault() {
        let d = ExitClassify.describe(.killed(signal: 15))
        XCTAssertTrue(d.contains("不是产出的问题"))
        XCTAssertTrue(d.contains("SIGTERM"), "得说清是哪个信号，否则没法排查来源")
        XCTAssertTrue(d.contains("重排"))
    }
}
