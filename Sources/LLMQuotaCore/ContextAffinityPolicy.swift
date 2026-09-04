import Foundation

/// owner 转移和实验开关的纯规则。主调度只负责提供事实，计数语义集中在这里。
public enum ContextAffinityPolicy {
    public enum AssignmentCause: Sendable {
        case initial
        case automaticFailure
        case automaticRecovery
        case manualDisable
    }

    public struct Snapshot: Sendable {
        var runnerID: String?
        var platform: Platform?
        var assignedAt: Date?
        var recoveryRunnerID: String?
        var recoveryPlatform: Platform?
        var preferredPlatform: Platform?
        var handoffCount: Int
        var automaticHandoffCount: Int
        public var changed: Bool
    }

    /// 人工要求“原平台重试”时，为没有持久化 owner 的旧任务补上唯一 owner。
    /// 找不到或同平台有歧义就返回 nil，调用方必须拒绝猜测。
    public static func samePlatformRetryOwner(
        for task: WorkTask,
        runners: [AgentRunner] = RunnerRegistry.all
    ) -> AgentRunner? {
        guard let platform = task.ownerPlatform ?? task.platform else { return nil }
        if let runnerID = task.ownerRunnerID {
            return RunnerRegistry.resolve(
                ownerRunnerID: runnerID, platform: platform,
                prompt: task.prompt, runners: runners)
        }
        let lane = TaskCapabilityLane.classify(task.prompt)
        let matches = runners.filter {
            $0.platform == platform && $0.canEdit
                && TaskCapabilityLane.accepts($0, lane: lane)
        }
        return matches.count == 1 ? matches[0] : nil
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
            assignedAt: task.ownerAssignedAt,
            recoveryRunnerID: task.recoveryOwnerRunnerID,
            recoveryPlatform: task.recoveryOwnerPlatform,
            preferredPlatform: task.preferredPlatform,
            handoffCount: task.handoffCount,
            automaticHandoffCount: task.automaticHandoffCount,
            changed: task.ownerRunnerID != runnerID)
        guard snapshot.changed else {
            // 人工明确保留当前 Owner 也代表接受新的负责人基线；不能让更早一次
            // 自动接力的恢复目标在后台把它偷偷换回去。
            if cause == .manualDisable {
                task.recoveryOwnerRunnerID = nil
                task.recoveryOwnerPlatform = nil
                task.automaticHandoffCount = 0
            }
            return snapshot
        }
        if task.ownerRunnerID != nil {
            task.handoffCount += 1
            switch cause {
            case .automaticFailure:
                if task.recoveryOwnerRunnerID == nil,
                   let previousRunner = task.ownerRunnerID,
                   let previousPlatform = task.ownerPlatform {
                    task.recoveryOwnerRunnerID = previousRunner
                    task.recoveryOwnerPlatform = previousPlatform
                }
                task.automaticHandoffCount += 1
            case .automaticRecovery:
                task.recoveryOwnerRunnerID = nil
                task.recoveryOwnerPlatform = nil
                task.automaticHandoffCount = 0
                task.preferredPlatform = platform
            case .manualDisable:
                task.recoveryOwnerRunnerID = nil
                task.recoveryOwnerPlatform = nil
                task.automaticHandoffCount = 0
            case .initial:
                break
            }
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
        task.recoveryOwnerRunnerID = snapshot.recoveryRunnerID
        task.recoveryOwnerPlatform = snapshot.recoveryPlatform
        task.preferredPlatform = snapshot.preferredPlatform
        task.handoffCount = snapshot.handoffCount
        task.automaticHandoffCount = snapshot.automaticHandoffCount
    }

    /// 人工选择“换人重试”时，必须把所有会把任务吸回旧执行者的亲和字段
    /// 一次清空。把这条规则集中起来，避免 CLI、移动端和后续入口各漏一项。
    public static func prepareForDifferentOwner(task: inout WorkTask) {
        task.triedPlatforms = []
        task.ownerPlatform = nil
        task.ownerRunnerID = nil
        task.ownerAssignedAt = nil
        task.recoveryOwnerPlatform = nil
        task.recoveryOwnerRunnerID = nil
        task.automaticHandoffCount = 0
        task.platform = nil
        task.preferredPlatform = nil
    }

    /// 找到自动接力前的 Owner。新版任务直接使用持久字段；旧任务从不可覆盖的
    /// attempt 账本迁移，取当前 Owner 最后一段尝试之前最近的不同 Runner。
    public static func recoveryOwner(
        for task: WorkTask,
        attempts: [WorkAttempt],
        runners: [AgentRunner] = RunnerRegistry.all
    ) -> AgentRunner? {
        guard task.automaticHandoffCount > 0,
              let currentRunnerID = task.ownerRunnerID else { return nil }

        let runnerID: String
        let platform: Platform
        if let storedRunnerID = task.recoveryOwnerRunnerID,
           let storedPlatform = task.recoveryOwnerPlatform {
            runnerID = storedRunnerID
            platform = storedPlatform
        } else {
            let history = WorkAttemptStore.latestSnapshots(attempts.filter {
                $0.taskID == task.id
            }).sorted { $0.startedAt < $1.startedAt }
            guard let lastCurrent = history.lastIndex(where: {
                $0.runnerID == currentRunnerID
            }), lastCurrent > history.startIndex,
            let previous = history[..<lastCurrent].last(where: {
                $0.runnerID != currentRunnerID
            }) else { return nil }
            runnerID = previous.runnerID
            platform = previous.platform
        }
        guard runnerID != currentRunnerID else { return nil }
        return RunnerRegistry.resolve(
            ownerRunnerID: runnerID, platform: platform,
            prompt: task.prompt, runners: runners)
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
