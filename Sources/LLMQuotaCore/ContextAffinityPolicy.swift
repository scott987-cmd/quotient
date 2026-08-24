import Foundation

/// owner 转移和实验开关的纯规则。主调度只负责提供事实，计数语义集中在这里。
public enum ContextAffinityPolicy {
    public enum AssignmentCause: Sendable {
        case initial
        case automaticFailure
        case manualDisable
    }

    public struct Snapshot: Sendable {
        var runnerID: String?
        var platform: Platform?
        var assignedAt: Date?
        var handoffCount: Int
        var automaticHandoffCount: Int
        public var changed: Bool
    }

    @discardableResult
    public static func assign(
        task: inout WorkTask,
        runnerID: String,
        platform: Platform,
        cause: AssignmentCause,
        now: Date = Date()
    ) -> Snapshot {
        let snapshot = Snapshot(
            runnerID: task.ownerRunnerID, platform: task.ownerPlatform,
            assignedAt: task.ownerAssignedAt, handoffCount: task.handoffCount,
            automaticHandoffCount: task.automaticHandoffCount,
            changed: task.ownerRunnerID != runnerID)
        guard snapshot.changed else { return snapshot }
        if task.ownerRunnerID != nil {
            task.handoffCount += 1
            if cause == .automaticFailure { task.automaticHandoffCount += 1 }
        }
        task.ownerRunnerID = runnerID
        task.ownerPlatform = platform
        task.ownerAssignedAt = now
        return snapshot
    }

    public static func restore(task: inout WorkTask, snapshot: Snapshot) {
        guard snapshot.changed else { return }
        task.ownerRunnerID = snapshot.runnerID
        task.ownerPlatform = snapshot.platform
        task.ownerAssignedAt = snapshot.assignedAt
        task.handoffCount = snapshot.handoffCount
        task.automaticHandoffCount = snapshot.automaticHandoffCount
    }

    public static func shouldRetryOwnerAfterTimeout(
        enabled: Bool, retryUsed: Bool,
        currentRunnerID: String, ownerRunnerID: String?
    ) -> Bool {
        enabled && !retryUsed && currentRunnerID == ownerRunnerID
    }

    public static func canProceedToNext(
        nextIsSameOwner: Bool, automaticHandoffCount: Int
    ) -> Bool {
        nextIsSameOwner || automaticHandoffCount < 1
    }

    /// 重试只能使用总预算里真正剩下的时间。
    ///
    /// 例如首轮上限 90 分钟、总预算 95 分钟，首轮跑满后同 owner 收尾最多
    /// 再拿 5 分钟，不能因为进入 retry 分支又重新获得完整 90 分钟。
    public static func cappedAttemptTimeout(
        requested: TimeInterval, totalBudget: TimeInterval, elapsed: TimeInterval
    ) -> TimeInterval {
        max(0, min(requested, totalBudget - max(0, elapsed)))
    }
}
