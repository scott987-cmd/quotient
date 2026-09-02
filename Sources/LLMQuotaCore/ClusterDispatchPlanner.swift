import Foundation

/// 在不共享绝对路径、不改变任务 Owner 的前提下选择一台执行机器。
///
/// 这里只做确定性选路，不创建任务、不重试、不合并。真正派发仍走 mTLS 的
/// `ClusterRequest.submitJob`；若选中本机也走同一个服务入口。执行机再用同一
/// 个仓库别名解析自己的本地路径，避免“本机兜底”和跨机走两套规则。
public enum ClusterDispatchPlanner {
    public struct Option: Equatable, Sendable {
        public var machineID: String
        public var machineName: String
        public var nodeName: String
        public var runnerID: String
        public var platform: Platform
        public var freeSlots: Int
        public var quotaAvailableFraction: Double?
        public var reason: String
    }

    public struct Rejection: Equatable, Sendable {
        public var machineID: String
        public var machineName: String
        public var reason: String
    }

    public struct Plan: Sendable {
        public var options: [Option]
        public var rejected: [Rejection]
        public var selected: Option? { options.first }
    }

    public static func plan(
        repoAlias: String,
        lane: TaskCapabilityLane,
        profile: TaskProfile?,
        requiredCapabilities: [String] = [],
        resourceClaims: [String] = [],
        preferredRunnerID: String? = nil,
        preferredPlatform: Platform? = nil,
        currentMachineID: String = Paths.machineID(),
        coordinatorMachineID: String?,
        presences: [ClusterPresence] = ClusterPresenceStore.all(),
        registrations: [AgentRegistration] = AgentRegistry.all(),
        now: Date = Date()
    ) -> Plan {
        let me = presences.first { $0.machineID == currentMachineID }
        var options: [Option] = []
        var rejected: [Rejection] = []

        // 自动跨机派发只有项目协调机一个写者。iCloud 快照不是分布式锁，
        // 若 Mac mini 和笔记本都能同时“自动决定”，相同项目仍会被双派。
        guard coordinatorMachineID == currentMachineID else {
            let reason = coordinatorMachineID == nil
                ? "项目未指定唯一协调机，自动跨机路由失败关闭"
                : "本机不是该项目的唯一协调机"
            return Plan(options: [], rejected: presences
                .filter { $0.machineID != currentMachineID }
                .map { Rejection(machineID: $0.machineID,
                                 machineName: $0.machineName, reason: reason) })
        }

        for machine in presences {
            func reject(_ reason: String) {
                rejected.append(Rejection(machineID: machine.machineID,
                                           machineName: machine.machineName,
                                           reason: reason))
            }

            let isLocal = machine.machineID == currentMachineID
            guard !machine.isStale(now: now) else {
                reject("节点状态已过期")
                continue
            }
            let node = machine.nodeName ?? (isLocal ? "local" : "")
            guard isLocal || (machine.serving && !node.isEmpty) else {
                reject("远端节点离线或未启用集群服务")
                continue
            }
            if !isLocal, let me, me.canReach[node] != true {
                reject("协调机到该节点的 mTLS 通道不可达")
                continue
            }
            guard machine.repoAliases.contains(repoAlias) else {
                reject("本机没有验证通过的仓库别名 \(repoAlias)")
                continue
            }
            guard machine.automaticRepoAliases.contains(repoAlias) else {
                reject("该机的项目执行作用域未允许 \(repoAlias)")
                continue
            }
            let missingCapabilities = Set(requiredCapabilities)
                .subtracting(machine.capabilities)
            guard missingCapabilities.isEmpty else {
                reject("缺少任务所需机器能力："
                    + missingCapabilities.sorted().joined(separator: "、"))
                continue
            }
            let resourceConflicts = Set(resourceClaims)
                .intersection(machine.runningResourceClaims)
            guard resourceConflicts.isEmpty else {
                reject("独占资源正在使用：" + resourceConflicts.sorted().joined(separator: "、"))
                continue
            }
            guard !machine.runningRepoAliases.contains(repoAlias) else {
                reject("同一项目已有任务执行中")
                continue
            }
            let free = machine.maxConcurrentTasks - machine.runningTaskCount
            guard machine.maxConcurrentTasks > 0, free > 0 else {
                reject("执行槽已满或目标机尚未发布容量")
                continue
            }

            let machineAgents = registrations.filter { $0.machineID == machine.machineID }
            let agents = machineAgents.filter {
                !$0.isMuted && !$0.isDispatcher
                    && (preferredRunnerID == nil || $0.runnerID == preferredRunnerID)
                    && (preferredPlatform == nil || $0.platform == preferredPlatform)
                    && $0.quotaBlockedReason == nil
                    && ($0.quotaAvailableFraction.map { $0 > 0 } ?? true)
                    && accepts($0, lane: lane, profile: profile)
            }
            guard !agents.isEmpty else {
                if let owner = preferredRunnerID,
                   let exact = machineAgents.first(where: { $0.runnerID == owner }) {
                    if let why = exact.quotaBlockedReason {
                        reject("Owner \(owner) 当前不可调度：\(why)")
                    } else if exact.isMuted {
                        reject("Owner \(owner) 在该机被静音")
                    } else if exact.isDispatcher {
                        reject("Owner \(owner) 是控制面，不接实现任务")
                    } else {
                        reject("Owner \(owner) 不满足能力、风险或复杂度边界")
                    }
                } else if let owner = preferredRunnerID {
                    reject("该机没有发布 Owner \(owner)")
                } else if let owner = preferredPlatform {
                    let ownerAgents = machineAgents.filter { $0.platform == owner }
                    if let blocked = ownerAgents.first(where: {
                        $0.quotaBlockedReason != nil
                    }), let why = blocked.quotaBlockedReason {
                        reject("项目负责人 \(owner.displayName) 当前不可调度：\(why)")
                    } else {
                        reject("该机没有满足能力边界的项目负责人 \(owner.displayName)")
                    }
                } else if let blocked = machineAgents.first(where: {
                    $0.quotaBlockedReason != nil
                }), let why = blocked.quotaBlockedReason {
                    reject("\(blocked.runnerID) 当前不可调度：\(why)")
                } else {
                    reject("该机没有满足任务能力与风险边界的 Agent")
                }
                continue
            }
            for agent in agents {
                let quotaText = agent.quotaAvailableFraction.map {
                    "，调度可用额度 \(Format.percent($0))"
                } ?? "，额度上限未配置（由目标机二次复核）"
                options.append(Option(
                    machineID: machine.machineID, machineName: machine.machineName,
                    nodeName: node, runnerID: agent.runnerID, platform: agent.platform,
                    freeSlots: free, quotaAvailableFraction: agent.quotaAvailableFraction,
                    reason: "仓库已就绪、项目作用域允许、同项目空闲，剩余 \(free) 个执行槽"
                        + quotaText))
            }
        }

        options.sort {
            let lhsQuota = $0.quotaAvailableFraction ?? 0.5
            let rhsQuota = $1.quotaAvailableFraction ?? 0.5
            if lhsQuota != rhsQuota { return lhsQuota > rhsQuota }
            if $0.freeSlots != $1.freeSlots { return $0.freeSlots > $1.freeSlots }
            if $0.runnerID != $1.runnerID { return $0.runnerID < $1.runnerID }
            return $0.machineID < $1.machineID
        }
        rejected.sort { $0.machineID < $1.machineID }
        return Plan(options: options, rejected: rejected)
    }

    private static func accepts(_ agent: AgentRegistration,
                                lane: TaskCapabilityLane,
                                profile: TaskProfile?) -> Bool {
        let laneOK: Bool
        switch lane {
        case .coding:
            laneOK = agent.canEdit && !agent.mediaOnly && !agent.reviewOnly
        case .media:
            laneOK = agent.canEdit && agent.mediaOnly && agent.canSeeMedia
        case .review:
            laneOK = agent.canEdit && agent.reviewOnly
        }
        guard laneOK else { return false }
        if let profile {
            guard profile.risk <= agent.maxRisk, profile.tier <= agent.maxTier else {
                return false
            }
        }
        return true
    }
}
