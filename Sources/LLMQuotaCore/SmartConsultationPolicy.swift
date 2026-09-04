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
        case consultationFailed
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

    /// CLI/MCP 的只读提示。绝不把状态机提示伪装成 Agent 事件写回账本。
    public static func currentInstruction(project: String, taskID: String?, runnerID: String,
                                          tasks: [WorkTask]? = nil) -> Instruction? {
        guard let taskID, let task = (tasks ?? TaskStore.all()).first(where: {
            $0.id == taskID && normalizedProject($0.repo) == normalizedProject(project)
                && $0.ownerRunnerID == runnerID && $0.pausedAt == nil && $0.discardedAt == nil
                && ($0.state == .running || $0.state == .queued || $0.state == .blocked)
        }) else { return nil }
        return instruction(task: task, runnerID: runnerID, events: CollaborationStore.all())
    }

    public static func instruction(
        task: WorkTask, runnerID: String, events: [CollaborationEvent],
        tier: TaskProfile.Tier? = nil, attempts: [WorkAttempt]? = nil
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
        let scoped = events.filter {
            $0.project == normalizedProject(task.repo)
                && $0.taskID == task.id
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        let prefix = "smart-consult:\(task.id):"
        let questions = scoped.filter {
            $0.id.hasPrefix(prefix) && $0.kind == .question
                && $0.senderRunnerID == runnerID
                && $0.recipientRunnerID == architectRunnerID
        }
        func answer(to question: CollaborationEvent) -> CollaborationEvent? {
            scoped.last {
                $0.kind == .answer && $0.replyTo == question.id
                    && $0.senderRunnerID == architectRunnerID
                    && $0.recipientRunnerID == runnerID
            }
        }
        func acknowledgement(of answer: CollaborationEvent?) -> CollaborationEvent? {
            guard let answer else { return nil }
            return scoped.last {
                $0.kind == .ack && $0.replyTo == answer.id && $0.senderRunnerID == runnerID
                    && $0.createdAt >= answer.createdAt
            }
        }
        // 先闭环正在处理的决策点，不能因为又失败一次而同时派出多个咨询。
        let openQuestion = questions.first { acknowledgement(of: answer(to: $0)) == nil }
        let lastClosedAt = questions.compactMap { acknowledgement(of: answer(to: $0))?.createdAt }.max()
        let failureKinds: Set<String> = ["timedOut", "agentFailed", "verificationFailed", "postRunGate", "qualityGate"]
        let failures = WorkAttemptStore.latestSnapshots(attempts ?? WorkAttemptStore.all()).filter {
            guard let endedAt = $0.endedAt else { return false }
            return $0.taskID == task.id && $0.runnerID == runnerID && $0.outcome == .failed
                && failureKinds.contains($0.failureKind ?? "")
                && endedAt > (lastClosedAt ?? .distantPast)
        }.sorted {
            $0.endedAt == $1.endedAt ? $0.attemptID < $1.attemptID
                : ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast)
        }
        let failure = failures.last
        let needsFailureDecision = failure != nil && (lastClosedAt != nil || failures.count >= 2)
        guard openQuestion != nil || needsFailureDecision
                || (questions.isEmpty && (architectureBoundary || repeatedFailure)) else { return nil }
        let question = openQuestion
        let questionID: String
        if let question { questionID = question.id }
        else if needsFailureDecision, let failure { questionID = prefix + "failure-" + failure.attemptID }
        else { questionID = prefix + "architecture-v1" }
        let reason: String
        if needsFailureDecision, let failure {
            reason = "失败尝试 \(failure.attemptID)（\(failure.failureKind ?? "unknown")）尚未裁决；先检查已有增量和失败证据，禁止继续盲改"
        } else {
            reason = repeatedFailure
                ? "同一任务已连续失败或自动接力，先裁决根因与边界，禁止继续盲改"
                : "任务触及重大架构、契约或跨模块边界，首次实现前需要架构裁决"
        }

        guard let question else {
            return Instruction(
                stage: .ask, reason: reason, questionID: questionID,
                recipientRunnerID: architectRunnerID,
                clause: askClause(task: task, runnerID: runnerID,
                                  questionID: questionID, reason: reason))
        }

        guard let answer = answer(to: question) else {
            if let failed = scoped.last(where: {
                $0.kind == .finding && $0.replyTo == question.id
                    && $0.id.hasPrefix("consultation-failure:") && $0.senderRunnerID == "consultation-executor"
            }) {
                return Instruction(stage: .consultationFailed, reason: failed.summary,
                    questionID: questionID, recipientRunnerID: architectRunnerID,
                    clause: "\n\n【智能咨询 · 执行失败】\(questionID)：\(failed.summary)。"
                        + "这不是架构师答复，禁止伪造 ack 或重新开同一问题。"
                        + "记录具体阻塞并请求处理接收方环境；不要循环等待。可继续不依赖该裁决的工作，Owner 不变。")
            }
            return Instruction(
                stage: .waitingForAnswer, reason: reason, questionID: questionID,
                recipientRunnerID: architectRunnerID,
                clause: "\n\n【智能咨询 · 等待答复】决策点 \(questionID) 已向 Codex 提问。"
                    + "不要重复提问；继续只做不依赖该裁决的读取、盘点和测试准备，"
                    + "在动架构边界前读取协作上下文。原任务 Owner 不变。")
        }

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
            + " --question '替换为检查现有增量后的具体疑问，不要原样发送模板'"
            + " --details '按事实填写：现有分支/提交、实际失败证据、已尝试方案和下一验收门槛；跨机器不可读的文件必须摘录关键证据，不能只给本机路径'"
        return "\n\n【智能咨询 · 强制决策点】\(reason)。在第一次实现性修改前，"
            + "必须先完成一次定向架构咨询；问题要包含你检查现有增量后发现的具体分歧。"
            + "同一决策点只问一次，提交后继续不依赖答案的工作，不暂停、不换 Owner。"
            + "收到答案后必须 ack 说明是否采用。\n" + command
    }

    private static func normalizedProject(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
