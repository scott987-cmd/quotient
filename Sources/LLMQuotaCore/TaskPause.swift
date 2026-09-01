import Foundation

/// 停止自动执行，但保留任务现场。`.blocked` 负责让现有调度器跳过任务，
/// 这两个字段负责说明它不是在等答复，也不能被普通对账逻辑自动解冻。
public enum TaskPause {
    public static let qualityRejectionLimit = 2

    /// 架构重审可阻止自动恢复，但用户明确要求继续时必须有一条可审计的解锁路径。
    public static func canResume(_ task: WorkTask, userOverride: Bool = false) -> Bool {
        task.pausedAt != nil
            && (task.architectureReviewRequestedAt == nil || userOverride)
    }

    public static func pause(_ task: WorkTask, reason: String,
                             now: Date = Date()) -> WorkTask {
        var out = task
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        out.state = .blocked
        out.waitReason = .paused
        out.endedAt = now
        out.runnerPID = nil
        out.pausedAt = now
        out.pauseReason = why.isEmpty ? "人工暂停" : why
        out.note = "已暂停（保留分支、Owner、工作区和会话）：" + (out.pauseReason ?? "人工暂停")
        return out
    }

    public static func resume(_ task: WorkTask, reason: String? = nil,
                              preserveQualityHistory: Bool = false,
                              now: Date = Date()) -> WorkTask {
        var out = task
        guard out.pausedAt != nil else { return out }
        out.pausedAt = nil
        out.pauseReason = nil
        if !preserveQualityHistory {
            out.architectureReviewRequestedAt = nil
            out.qualityRejectionCount = 0
        }
        out.createdAt = now
        out.startedAt = nil
        out.endedAt = nil
        out.exitCode = nil
        out.changedFiles = nil
        out.runnerPID = nil
        out.terminalFailureKind = nil
        out.retryNotBefore = nil
        if out.pendingAsk != nil {
            out.state = .blocked
            out.waitReason = .humanAnswer
            out.note = reason ?? "已解除暂停，继续等待原问题答复"
        } else {
            out.state = .queued
            out.waitReason = nil
            out.note = reason ?? "已解除暂停，沿用原分支、Owner 和会话重新排队"
        }
        return out
    }

    /// 把普通“停止执行”升级为可见、可调度的架构重审闭环。
    public static func requestArchitectureReview(_ task: WorkTask, reason: String,
                                                 now: Date = Date()) -> WorkTask {
        var out = pause(task, reason: reason, now: now)
        out.architectureReviewRequestedAt = now
        out.waitReason = .architectureReview
        out.note = "架构重审待创建；实现 Owner、分支、工作区和会话保持不变"
        return out
    }

    /// 返回 true 表示已经达到收敛上限，调用方必须保持暂停，不能自动重开。
    @discardableResult
    public static func registerQualityRejection(_ task: inout WorkTask,
                                                reason: String,
                                                now: Date = Date()) -> Bool {
        task.qualityRejectionCount += 1
        guard task.qualityRejectionCount >= qualityRejectionLimit else { return false }
        task = requestArchitectureReview(task,
            reason: "黄金样板连续 \(task.qualityRejectionCount) 轮未收敛；先做架构评审。\(reason)",
            now: now)
        return true
    }
}
