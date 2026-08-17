import Foundation

/// 退出码分类：**「被杀」和「没通过」是两件完全不同的事。**
///
/// ## 这东西为什么存在
///
/// 2026-08-17 排查一条搁浅的任务图，实况是这样的：
///
/// ```
/// 3f68707cs2  failed   改了 3 个文件但 验证没过（退出码 15），没有提交
/// 3f68707cs3  blocked  上游失败了，这一步先冻住。上游恢复后会自动解冻。
/// 3f68707cs4  blocked  同上
/// ```
///
/// 退出码 15 是 SIGTERM —— **验证进程是被杀死的，不是跑出了失败**。
/// 那天我为了装新二进制重启了八次工作循环，每次都会杀掉正在跑的子进程。
/// 也就是说：这个失败是我自己造成的，跟 agent 改的代码毫无关系。
///
/// 后果一点都不轻：任务被判 failed → 下游三步永久冻住（上游是 failed，
/// 「上游恢复后自动解冻」永远不会发生）→ 整条图搁浅 →
/// 而唯一会发现这件事的是人。
///
/// 任务被打断这条路径本来是有恢复逻辑的（`interruptedCount`，上限两次），
/// 但那条只管**任务进程**被杀；**验证进程**被杀走的是另一条路，
/// 一路当成「验证不通过」记下来。同一个原因，两条路，只修了一条。
///
/// ## 为什么不能靠「下次小心点」
///
/// 杀进程的来源至少有四个：`launchctl kickstart -k`、launchd 的 KeepAlive、
/// 发布时重启 worker、机器休眠。每一个都绕得过在飞守卫。
/// 判据必须做在**读退出码的地方**，而不是做在杀进程的地方。
public enum ExitClassify {

    /// 一次进程退出到底是什么情况。
    public enum Kind: Sendable, Equatable {
        /// 跑完了，通过。
        case passed
        /// 跑完了，没通过 —— 这是**产出的问题**，该记账、该给评审看。
        case failed
        /// 被信号杀死（SIGTERM / SIGKILL / SIGINT 等）—— 这是
        /// **基础设施的问题**，不该记成产出失败，该重排。
        case killed(signal: Int32)
        /// 超时 —— 介于两者之间：可能是活太大，也可能是机器卡了。
        /// 按可重排处理，但要记次数。
        case timedOut

        /// 该不该重排。被杀和超时都该，真失败不该。
        public var shouldRequeue: Bool {
            switch self {
            case .killed, .timedOut: return true
            case .passed, .failed: return false
            }
        }

        /// 该不该算到「这个产出有问题」的账上。
        ///
        /// 被杀不算 —— 否则一次发布重启就能让一份好产出背上失败记录，
        /// 而且这个记录会一路传染：平台被拉黑、分支进否决名单、下游冻住。
        public var blamesOutput: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// 按 shell 约定，被信号杀死的退出码是 128 + 信号号。
    ///
    /// 直接列出常见的几个而不是只判 `> 128`：`Proc.run` 在某些路径上
    /// 回传的是原始信号号（15）而不是 shell 折算过的（143），两种都得认。
    /// 实测踩的就是 15 这一种。
    static let bareSignals: Set<Int32> = [
        2,   // SIGINT   Ctrl-C
        9,   // SIGKILL  kill -9 / OOM killer
        15,  // SIGTERM  launchctl kickstart -k、发布重启 worker
    ]

    /// 判一次退出。
    ///
    /// - Parameters:
    ///   - exitCode: 进程退出码。
    ///   - timedOut: 跑超时了没有（`Proc.run` 会给这个标志）。
    public static func classify(exitCode: Int32, timedOut: Bool = false) -> Kind {
        if timedOut { return .timedOut }
        if exitCode == 0 { return .passed }
        // shell 折算过的：128 + signo
        if exitCode > 128, exitCode < 128 + 64 {
            return .killed(signal: exitCode - 128)
        }
        if bareSignals.contains(exitCode) {
            return .killed(signal: exitCode)
        }
        return .failed
    }

    /// 给人看的一句话。
    ///
    /// 措辞上要明确写出「不是产出的问题」—— 不写的话，人（和评审 agent）
    /// 看到「退出码 15」还是会当成验证失败，等于没分类。
    public static func describe(_ k: Kind) -> String {
        switch k {
        case .passed: return "验证通过"
        case .failed: return "验证没过"
        case .timedOut: return "验证超时"
        case .killed(let s):
            let name = s == 15 ? "SIGTERM" : s == 9 ? "SIGKILL"
                : s == 2 ? "SIGINT" : "信号 \(s)"
            return "验证进程被杀（\(name)）—— 基础设施打断，不是产出的问题，会重排"
        }
    }
}
