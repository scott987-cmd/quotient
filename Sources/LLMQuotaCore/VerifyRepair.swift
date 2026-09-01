import Foundation

/// **验证没过 → 派人去修,而不是「留给人工审」。**
///
/// 老板 2026-08-22 定的分工:「让别的 agent 做检查和测试,你做架构和审核」,
/// 以及「总不能跑一步卡一步就需要你介入」。
///
/// ## 原来是条死路
///
/// `autoLand` 验证失败就记否决、写一句「留给人工审」,然后**再也不动它**。
/// 那个「人」就是老板 —— 而他要的恰恰是不用管。一条分支挂在那儿,
/// 后面同仓库的活被基线闸挡着,产线看起来就停了。
///
/// ## 为什么不让 agent 自己「跑测试并汇报」
///
/// 因为 agent 会**总结**。评审 agent 今天就干过:通篇「截断看不到」却给了
/// 「不合入」的结论(见 VerdictQuality)。测试结果必须是**退出码**说了算,
/// 不能是谁的读后感。
///
/// 所以分工是:**机器跑测试(退出码为准),agent 负责把挂掉的修好**。
/// 这才是 agent 比一条命令多出来的价值。
public enum VerifyRepair {
    /// 同一条分支最多派几次修复 —— 修不动就是真该人看了。
    public static let maxAttempts = 2

    public static func isRepairPrompt(_ prompt: String, of branch: String) -> Bool {
        prompt.hasPrefix("【修验证】分支 " + branch + " ")
    }

    static func attempts(branch: String, tasks: [WorkTask]) -> Int {
        tasks.filter { isRepairPrompt($0.prompt, of: branch) }.count
    }

    static func prompt(branch: String, repo: String, failure: String, command: String) -> String {
        """
        【修验证】分支 \(branch) 合进 main 之后验证没过,把它修到过。

        失败信息:\(failure.prefix(400))

        怎么做:
        1. 开一个临时工作区,把 main 合进这条分支(或把分支合进 main 的副本),
           在那里跑仓库的验证命令:
               \(command)
        2. **看退出码,不看输出好不好看** —— 非零就是没过。
        3. 修到它退出码为 0。改动提交到 `\(branch)` 这条分支上,不要新开分支。
        4. 如果失败根本不是这条分支引起的(比如 main 自己就是坏的),
           **不要硬改**:如实说清楚是什么情况,然后停下。

        注意:这是别人的产出,你的任务是让它能落地,不是重写它。
        能不动业务代码就不动 —— 优先修测试、依赖、工程配置这类。
        """
    }

    public struct Outcome: Sendable {
        public var branch: String
        public var enqueued: Bool
        public var note: String
    }

    /// 验证失败时叫一次修复。
    ///
    /// - Returns: 派出去了就返回 outcome;不该派(次数到顶/已在队/仓库没配
    ///   验证命令)返回 nil,调用方照旧记否决。
    public static func dispatch(repo: String, branch: String, failure: String,
                                tasks: [WorkTask] = TaskStore.all()) -> Outcome? {
        guard let reg = RepoRegistry.all().first(where: {
            NSString(string: $0.localPath).expandingTildeInPath
                == NSString(string: repo).expandingTildeInPath
        }), let cmd = reg.verifyCommand, !cmd.isEmpty else { return nil }

        // 只修「验证没过」,不碰冲突这类机械问题(那条归 StaleBranch 刷新)。
        guard failure.contains("验证没过") else { return nil }

        let tried = attempts(branch: branch, tasks: tasks)
        guard tried < maxAttempts else {
            return Outcome(branch: branch, enqueued: false,
                           note: "修了 \(tried) 次还没过 —— 不再派,这次真该人看了")
        }
        // 已经在排/在跑就别重复派(精确判重,见 TaskKind.hasPendingDerived)。
        if tasks.contains(where: {
            ($0.state == .queued || $0.state == .running) && isRepairPrompt($0.prompt, of: branch)
        }) {
            return Outcome(branch: branch, enqueued: false, note: "修复任务还在排/跑")
        }

        do {
            let r = try TaskIntake.enqueue(
                prompt: prompt(branch: branch, repo: repo, failure: failure, command: cmd),
                repo: repo, classify: false, split: false, force: true,
                origin: "verify-repair",
                idempotencyKey: "verify-repair:\(branch):\(tried + 1)",
                source: "verify-repair")
            if case .single = r {
                return Outcome(branch: branch, enqueued: true,
                               note: "验证没过,已派 agent 去修(第 \(tried + 1)/\(maxAttempts) 次)")
            }
            return Outcome(branch: branch, enqueued: false, note: "入队没成")
        } catch {
            return Outcome(branch: branch, enqueued: false,
                           note: "派修复失败:\(error.localizedDescription)")
        }
    }
}
