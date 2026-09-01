import Foundation

/// 主实现 Agent 把一小块低价值、只读、非关键路径工作交给当前最合适的空闲 Agent。
///
/// 它刻意不是 WorkTask：同仓库两个写入任务并发会造成过期基线和合并冲突。
/// 辅助 Agent 只返回盘点/草稿/测试矩阵，主 Owner 决定是否落实，因此不切断
/// 主会话，也不把一个大任务重新拆成许多小任务。
public enum LowValueDelegationPolicy {
    public enum Stage: String, Sendable {
        case delegate
        case waitingForAnswer
        case acknowledgeAnswer
    }

    public struct Instruction: Sendable {
        public var stage: Stage
        public var questionID: String
        public var recipientRunnerID: String
        public var clause: String
    }

    public static func instruction(
        task: WorkTask, runnerID: String, events: [CollaborationEvent],
        tier: TaskProfile.Tier? = nil,
        candidates: [AgentRegistration] = AgentConsultation.availableAgents(),
        headroom: [Platform: Double] = [:]
    ) -> Instruction? {
        guard TaskCapabilityLane.classify(task.prompt) == .coding else { return nil }
        let effectiveTier = tier ?? task.profile?.tier ?? .standard
        let minutes = task.profile?.estimatedMinutes ?? 5
        guard effectiveTier == .complex || minutes >= 20 else { return nil }

        let questionID = "sidecar:\(task.id):helper-v1"
        let project = normalizedProject(task.repo)
        let scoped = events.filter { $0.project == project && $0.taskID == task.id }
        let question = scoped.first {
            $0.id == questionID && $0.kind == .question
                && $0.senderRunnerID == runnerID
        }
        guard let question else {
            guard let helper = selectHelper(senderRunnerID: runnerID,
                                            candidates: candidates,
                                            headroom: headroom) else { return nil }
            let helperRunnerID = helper.runnerID
            let details = String(task.prompt.prefix(1_000))
            let command = "llmq collaboration ask --project " + shellQuote(project)
                + " --sender " + shellQuote(runnerID)
                + " --task " + shellQuote(task.id)
                + " --to " + shellQuote(helperRunnerID)
                + " --id " + shellQuote(questionID)
                + " --question '请只读仓库，为当前任务完成一个低价值辅助产出："
                + "从测试矩阵、日志归因、文档差异、验收清单中选最有价值的一项，"
                + "给不超过 5 条可执行结论；不要改文件、不要接管实现'"
                + " --details " + shellQuote(details)
            let clause = "\n\n【只读辅助委派 · \(helperRunnerID)】这是一个较大的编码任务。"
                + "先检查现有增量；若确实存在不阻塞主线、可独立回答的测试清单、"
                + "日志归因、文档差异或验收矩阵工作，并且 collaboration agents 中"
                + "仍存在该目标，就在开始主实现后尽早委派一次。目标由系统按只读能力、"
                + "可用额度和岗位边界选择，不绑定厂商。每个主任务最多一次；"
                + "不得委派架构决策、写代码、改文件、最终验收或关键路径。提交后继续主线，"
                + "主任务 Owner 不变，不等待、不拆 WorkTask。若没有合适支线或目标不可用，"
                + "直接继续，不要为了展示协作而提问。收到答复后必须 ack 说明采用情况。\n"
                + command
            return Instruction(stage: .delegate, questionID: questionID,
                               recipientRunnerID: helperRunnerID, clause: clause)
        }

        guard let helperRunnerID = question.recipientRunnerID else { return nil }

        guard let answer = scoped.last(where: {
            $0.kind == .answer && $0.replyTo == question.id
                && $0.senderRunnerID == helperRunnerID
                && $0.recipientRunnerID == runnerID
        }) else {
            return Instruction(
                stage: .waitingForAnswer, questionID: questionID,
                recipientRunnerID: helperRunnerID,
                clause: "\n\n【只读辅助委派 · 等待结果】\(questionID) 已交给 \(helperRunnerID)。"
                    + "不要重复委派、不要停下主线；只在结果到达后读取并判断是否采用。")
        }

        let acknowledged = scoped.contains {
            $0.kind == .ack && $0.replyTo == answer.id && $0.senderRunnerID == runnerID
        }
        guard !acknowledged else { return nil }
        let command = "llmq collaboration ack " + shellQuote(answer.id)
            + " --project " + shellQuote(project)
            + " --sender " + shellQuote(runnerID)
            + " --task " + shellQuote(task.id)
            + " --summary '说明采用了哪些结论，或说明不采用的原因'"
        return Instruction(
            stage: .acknowledgeAnswer, questionID: questionID,
            recipientRunnerID: helperRunnerID,
            clause: "\n\n【只读辅助委派 · 必须闭环】\(helperRunnerID) 已返回辅助结果。"
                + "继续收尾前必须确认采用情况；它只提供建议，主任务 Owner 仍对实现负责。\n"
                + command)
    }

    /// 额度以最紧的有效窗口为准；一个平台短窗还很多、周窗已快满时不能冒充富余。
    public static func currentHeadroom(
        dashboard: Dashboard = LLMQuota.dashboard(), now: Date = Date()
    ) -> [Platform: Double] {
        var result: [Platform: Double] = [:]
        for report in dashboard.reports {
            if report.cooldownUntil.map({ $0 > now }) == true {
                result[report.platform] = 0
                continue
            }
            let known = report.statuses.compactMap { status -> Double? in
                guard status.isFresh(now: now), let used = status.usedFraction else { return nil }
                return max(0, min(1, 1 - used))
            }
            if let tightest = known.min() { result[report.platform] = tightest }
        }
        return result
    }

    static func selectHelper(
        senderRunnerID: String, candidates: [AgentRegistration],
        headroom: [Platform: Double]
    ) -> AgentRegistration? {
        let eligible = candidates.filter {
            $0.canConsult && $0.runnerID != senderRunnerID
                && $0.platform != AgentRoles.architectPlatform()
                && !AgentRoles.isMuted($0.platform, machine: $0.machineName)
                && !AgentRoles.isDispatcher($0.platform, machine: $0.machineName)
                && (headroom[$0.platform]
                    ?? (1 - AgentRoles.reserve(for: $0.platform, default: 0.25))) > 0.05
        }
        return eligible.sorted {
            // 调度器若已有额度事实就用；没有时只按岗位留白排序，绝不为了
            // 选辅助 Agent 同步重算整张看板、反过来卡住主任务。
            let lhs = headroom[$0.platform]
                ?? (1 - AgentRoles.reserve(for: $0.platform, default: 0.25))
            let rhs = headroom[$1.platform]
                ?? (1 - AgentRoles.reserve(for: $1.platform, default: 0.25))
            if lhs != rhs { return lhs > rhs }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.runnerID != $1.runnerID { return $0.runnerID < $1.runnerID }
            return $0.machineID < $1.machineID
        }.first
    }

    private static func normalizedProject(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
