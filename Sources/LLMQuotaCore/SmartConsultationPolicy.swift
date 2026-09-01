import Foundation

/// 把 Agent 咨询从“想起来可以问”收敛为可重放的决策点状态机。
///
/// 这里只决定何时必须问、当前该问/等/确认哪一步；真正的问题仍由任务 Owner
/// 发出，接收方真正开始处理时才发布 claim，调度器不冒充任何 Agent 写事件。
public enum SmartConsultationPolicy {
    public enum Stage: String, Sendable {
        case ask
        case waitingForAnswer
        case acknowledgeAnswer
    }

    public struct Instruction: Sendable {
        public var stage: Stage
        public var reason: String
        public var questionID: String
        public var recipientRunnerID: String
        public var clause: String
    }

    private static let architectRunnerID = "codex.code"
    private static let architectureMarkers = [
        "架构", "architecture", "接口契约", "数据契约", "状态契约",
        "api contract", "interface contract", "state contract", "状态机", "state machine",
        "数据模型", "data model", "schema", "持久化", "persistence", "迁移",
        "migration", "并发", "concurrency", "跨模块", "cross-module", "单写者",
        "single writer", "权限模型", "authorization model",
    ]
    private static let derivedReviewOrigins = [
        "architect-review:", "visual-quality-review", "technical-disposition:",
        "consultation:",
    ]

    public static func instruction(
        task: WorkTask, runnerID: String, events: [CollaborationEvent],
        tier: TaskProfile.Tier? = nil
    ) -> Instruction? {
        guard runnerID != architectRunnerID else { return nil }
        if let origin = task.origin?.lowercased(),
           derivedReviewOrigins.contains(where: { origin.hasPrefix($0) }) {
            return nil
        }

        let effectiveTier = tier ?? task.profile?.tier ?? .standard
        let prompt = task.prompt.lowercased()
        let architectureBoundary = effectiveTier != .trivial
            && architectureMarkers.contains(where: prompt.contains)
        let repeatedFailure = (task.interruptedCount ?? 0) >= 2
            || task.automaticHandoffCount >= 1
            || task.qualityRejectionCount >= 2
        guard architectureBoundary || repeatedFailure else { return nil }

        let reason = repeatedFailure
            ? "同一任务已连续失败或自动接力，先裁决根因与边界，禁止继续盲改"
            : "任务触及重大架构、契约或跨模块边界，首次实现前需要架构裁决"
        let questionID = "smart-consult:\(task.id):architecture-v1"
        let scoped = events.filter {
            $0.project == normalizedProject(task.repo)
                && $0.taskID == task.id
        }
        let question = scoped.first {
            $0.id == questionID && $0.kind == .question
                && $0.senderRunnerID == runnerID
                && $0.recipientRunnerID == architectRunnerID
        }

        guard let question else {
            return Instruction(
                stage: .ask, reason: reason, questionID: questionID,
                recipientRunnerID: architectRunnerID,
                clause: askClause(task: task, runnerID: runnerID,
                                  questionID: questionID, reason: reason))
        }

        guard let answer = scoped.last(where: {
            $0.kind == .answer && $0.replyTo == question.id
                && $0.senderRunnerID == architectRunnerID
                && $0.recipientRunnerID == runnerID
        }) else {
            return Instruction(
                stage: .waitingForAnswer, reason: reason, questionID: questionID,
                recipientRunnerID: architectRunnerID,
                clause: "\n\n【智能咨询 · 等待答复】决策点 \(questionID) 已向 Codex 提问。"
                    + "不要重复提问；继续只做不依赖该裁决的读取、盘点和测试准备，"
                    + "在动架构边界前读取协作上下文。原任务 Owner 不变。")
        }

        let acknowledged = scoped.contains {
            $0.kind == .ack && $0.replyTo == answer.id
                && $0.senderRunnerID == runnerID
        }
        guard !acknowledged else { return nil }
        let ack = "llmq collaboration ack " + shellQuote(answer.id)
            + " --project " + shellQuote(normalizedProject(task.repo))
            + " --sender " + shellQuote(runnerID)
            + " --task " + shellQuote(task.id)
            + " --summary '说明已采用、部分采用或拒绝，并写明落实位置'"
        return Instruction(
            stage: .acknowledgeAnswer, reason: reason, questionID: questionID,
            recipientRunnerID: architectRunnerID,
            clause: "\n\n【智能咨询 · 必须闭环】Codex 已回答决策点 \(questionID)。"
                + "继续修改前必须用 ack 明确说明采用、部分采用或拒绝及理由；"
                + "不能静默略过，也不能再开同一问题。\n" + ack)
    }

    private static func askClause(task: WorkTask, runnerID: String,
                                  questionID: String, reason: String) -> String {
        var command = "llmq collaboration ask --project "
            + shellQuote(normalizedProject(task.repo))
            + " --sender " + shellQuote(runnerID)
            + " --task " + shellQuote(task.id)
        if let graphID = task.graphID {
            command += " --graph " + shellQuote(graphID)
        }
        command += " --to " + shellQuote(architectRunnerID)
            + " --id " + shellQuote(questionID)
            + " --question '请裁决本任务的架构/契约边界、最小正确方案和验收门槛'"
        return "\n\n【智能咨询 · 强制决策点】\(reason)。在第一次实现性修改前，"
            + "必须先完成一次定向架构咨询；问题要包含你检查现有增量后发现的具体分歧。"
            + "只问这一次，提交后继续不依赖答案的工作，不暂停、不换 Owner。"
            + "收到答案后必须 ack 说明是否采用。\n" + command
    }

    private static func normalizedProject(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
