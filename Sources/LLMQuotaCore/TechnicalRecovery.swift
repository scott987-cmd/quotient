import Foundation
import CryptoKit

/// 状态使用字符串以保留未来版本的未知状态；未知状态只能保持阻塞。
public struct RecoveryIncident: Codable, Sendable {
    public var id: String
    public var sourceAttemptID: String
    public var ownerRunnerID: String
    public var branch: String?
    public var head: String?
    public var failureKind: String
    public var diagnosticTaskID: String
    public var createdAt: Date
    public var deadline: Date
    public var phase: String = "diagnosing"
    public var resumeCount: Int = 0
    public var legacyAsk: Ask?
}

extension RecoveryIncident {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        sourceAttemptID = try c.decodeIfPresent(String.self, forKey: .sourceAttemptID) ?? ""
        ownerRunnerID = try c.decodeIfPresent(String.self, forKey: .ownerRunnerID) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        failureKind = try c.decodeIfPresent(String.self, forKey: .failureKind) ?? ""
        diagnosticTaskID = try c.decodeIfPresent(String.self, forKey: .diagnosticTaskID) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline) ?? .distantPast
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "unresolved"
        // 缺预算的未知记录保守耗尽，不能因字段不全重新获得自动重排机会。
        resumeCount = try c.decodeIfPresent(Int.self, forKey: .resumeCount) ?? TechnicalRecovery.maximumResumes
        legacyAsk = try c.decodeIfPresent(Ask.self, forKey: .legacyAsk)
    }
}

/// 原任务是唯一状态源。诊断仅提交建议，不执行报告中的命令、不改变 Owner 或授权。
public enum TechnicalRecovery {
    public static let originPrefix = "technical-recovery:"
    public static let maximumResumes = 1
    public static let legacyMarker = "系统代发：卡死等确认，不是 agent 在提问"

    public struct Report: Codable, Sendable {
        public var incidentID: String
        public var sourceTaskID: String
        public var sourceAttemptID: String
        public var sourceHead: String?
        public var sourceBranch: String?
        public var sourceOwner: String
        public var failureKind: String
        public var diagnosticTaskID: String
        public var diagnosticAttemptID: String
        public var decision: String
        public var reason: String
        public var evidence: [String]
        public var steps: [String]
        public var humanBoundary: String?
    }

    public static func isDiagnostic(_ task: WorkTask) -> Bool {
        task.origin?.hasPrefix(originPrefix) == true
    }

    public static func isTechnicalFailure(_ task: WorkTask) -> Bool {
        switch task.terminalFailureKind {
        case .timedOut, .agentFailed, .sessionInvalid, .verificationFailed, .environmentBroken, .platformUnavailable: return true
        default: return false
        }
    }

    public static func legacyAsk(_ task: WorkTask) -> Ask? {
        guard task.state == .blocked, task.waitReason == .humanAnswer,
              task.transitionActor == "stuck-ask", task.answeredAsk == nil,
              let ask = task.pendingAsk, ask.taskID == task.id, ask.kind == .question,
              ask.progressNote == legacyMarker, ask.questions.count == 1,
              ask.questions[0].text.hasPrefix("这个任务卡死了："),
              ask.questions[0].options == [StuckAsk.recoveryOption(for: task).label]
        else { return nil }
        return ask
    }

    public static func holds(_ task: WorkTask) -> Bool {
        task.recoveryIncident != nil && task.state == .blocked
            && task.waitReason == .architectureReview
    }

    private static func permitted(_ task: WorkTask) -> Bool {
        !isDiagnostic(task) && !TaskKind.isSupportingTask(task)
            && task.pausedAt == nil && task.discardedAt == nil && task.landedAt == nil
            && task.frozenBy == nil && task.retryNotBefore == nil
            && task.architectureReviewRequestedAt == nil
            && task.production?.blockedReason == nil
            && (task.pendingAsk == nil || legacyAsk(task) != nil)
            && isTechnicalFailure(task)
            && (task.state == .failed || holds(task) || legacyAsk(task) != nil)
    }

    private static func head(_ task: WorkTask) -> String? {
        guard let branch = task.branch, branch.hasPrefix("agent/") else { return nil }
        let result = GitWorkspace.git(["rev-parse", "--verify", "refs/heads/" + branch],
                                      in: task.repo, timeout: 5)
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && sha.count == 40 ? sha : nil
    }

    public static func reportPath(_ incident: RecoveryIncident) -> String {
        "reviews/recovery-\(incident.id).json"
    }

    public static func isReportOnlyChange(_ task: WorkTask, files: [String]) -> Bool {
        guard isDiagnostic(task), let id = task.origin?.split(separator: ":").last,
              id.count == 24, id.allSatisfy({ $0.isHexDigit }), !files.isEmpty else { return false }
        return files.allSatisfy { $0 == "reviews/recovery-\(id).json" }
    }

    private static func diagnostic(for task: WorkTask, incident: RecoveryIncident) -> WorkTask {
        var diagnostic = WorkTask(id: incident.diagnosticTaskID, prompt: """
        【架构复核】故障诊断：原任务 \(task.id)
        你负责查明故障并给出具体处置，原任务仍由 \(incident.ownerRunnerID) 负责。
        只读取现有代码、该任务 work-attempts.jsonl、work-progress、handoff 和运行日志。
        分支：\(incident.branch ?? "缺失")；快照：\(incident.head ?? "缺失")。
        故障：\(incident.failureKind)；原执行：\(incident.sourceAttemptID)。
        禁止修改业务代码、停止真实 Agent、更换 Owner、合入或发布。
        唯一允许新增的产物为 \(reportPath(incident))，提交到你的隔离分支。
        严格 JSON 字段：incidentID="\(incident.id)", sourceTaskID="\(task.id)",
        sourceAttemptID="\(incident.sourceAttemptID)", diagnosticTaskID="\(incident.diagnosticTaskID)",
        sourceHead=上述快照（缺失时 null），sourceBranch=上述分支（缺失时 null），
        sourceOwner="\(incident.ownerRunnerID)", failureKind="\(incident.failureKind)",
        diagnosticAttemptID=本进程环境变量 LLMQ_ATTEMPT_ID 的真实值，
        decision=resumeOriginal/externalBlocker/unresolved 之一，reason=实际原因，
        evidence=非空证据字符串数组，steps=非空且具体的原 Owner 下一步数组。
        只有证据支持原 Owner 可在现有权限内修复/续作时选择 resumeOriginal；不要只写重试。
        externalBlocker 必须另含 humanBoundary=login/unlock/authorization/payment/productChoice
        之一，reason 解释为什么必须由用户操作，steps 写明用户最小操作。
        缺少证据、快照或可行处置时写 unresolved。不得声称已经恢复或已经完成产品。
        已使用任务级自动恢复预算：\(incident.resumeCount)/\(maximumResumes)。
        """, repo: task.repo)
        diagnostic.createdAt = incident.createdAt
        diagnostic.origin = originPrefix + task.id + ":" + incident.id
        diagnostic.preferredPlatform = AgentRoles.architectPlatform()
        diagnostic.requiredCapabilities = []
        diagnostic.resourceClaims = []
        diagnostic.profile = TaskProfile(tier: .standard, risk: .safe, estimatedMinutes: 8,
            isSelfContained: true, rationale: "技术故障取证及原 Owner 恢复方案")
        diagnostic.note = "系统诊断原任务 \(task.id)，不接管实现"
        return diagnostic
    }

    private static func report(_ diagnostic: WorkTask, sourceTaskID: String, incident: RecoveryIncident,
                               attempts: [WorkAttempt]) -> Report? {
        guard diagnostic.state == .done, let branch = diagnostic.branch,
              branch.hasPrefix("agent/"),
              let attempt = attempts.last(where: { $0.taskID == diagnostic.id }),
              attempt.outcome == .done,
              let ended = attempt.endedAt, ended <= incident.deadline,
              diagnostic.terminalAttemptID == nil || diagnostic.terminalAttemptID == attempt.attemptID,
              diagnostic.ownerRunnerID == attempt.runnerID,
              diagnostic.ownerPlatform == attempt.platform,
              attempt.startedAt.timeIntervalSince(diagnostic.createdAt) >= -1 else { return nil }
        guard let before = attempt.headBefore, let after = attempt.headAfter,
              before.count == 40, after.count == 40,
              before.allSatisfy({ $0.isHexDigit }), after.allSatisfy({ $0.isHexDigit }) else { return nil }
        let changed = GitWorkspace.git(["diff", "--name-only", before, after], in: diagnostic.repo, timeout: 5)
        guard changed.exitCode == 0,
              isReportOnlyChange(diagnostic, files: changed.stdout.split(separator: "\n").map(String.init)) else { return nil }
        let path = "\(after):\(reportPath(incident))"
        let size = GitWorkspace.git(["cat-file", "-s", path], in: diagnostic.repo, timeout: 5)
        guard size.exitCode == 0, let bytes = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              bytes > 0, bytes <= 16_384 else { return nil }
        let shown = GitWorkspace.git(["show", path], in: diagnostic.repo, timeout: 5)
        guard shown.exitCode == 0,
              let report = try? JSONDecoder().decode(Report.self, from: Data(shown.stdout.utf8)),
              report.incidentID == incident.id, report.sourceTaskID == sourceTaskID,
              report.sourceAttemptID == incident.sourceAttemptID,
              report.sourceHead == incident.head, report.sourceBranch == incident.branch,
              report.sourceOwner == incident.ownerRunnerID, report.failureKind == incident.failureKind,
              report.diagnosticTaskID == diagnostic.id, report.diagnosticAttemptID == attempt.attemptID,
              !report.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !report.evidence.isEmpty, !report.steps.isEmpty,
              (report.evidence + report.steps).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        return report
    }

    public static func reconcile(_ tasks: [WorkTask], now: Date = Date(),
                                  attempts supplied: [WorkAttempt]? = nil) -> [WorkTask] {
        let attempts = WorkAttemptStore.latestSnapshots(supplied ?? WorkAttemptStore.all())
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var updates: [WorkTask] = []
        for original in tasks where permitted(original) {
            guard let owner = original.ownerRunnerID,
                  let attempt = attempts.last(where: { $0.taskID == original.id }),
                  attempt.runnerID == owner, attempt.platform == original.ownerPlatform,
                  attempt.outcome == .failed,
                  attempt.failureKind == original.terminalFailureKind?.rawValue,
                  let started = original.startedAt, let ended = original.endedAt,
                  let attemptEnd = attempt.endedAt,
                  attempt.startedAt.timeIntervalSince(started) >= -1,
                  original.terminalAttemptID.map({ $0 == attempt.attemptID })
                    ?? (abs(attemptEnd.timeIntervalSince(ended)) <= 30) else { continue }
            var task = original
            var incident: RecoveryIncident
            if let existing = task.recoveryIncident, existing.sourceAttemptID == attempt.attemptID {
                incident = existing
                guard existing.ownerRunnerID == owner, existing.branch == task.branch,
                      existing.failureKind == task.terminalFailureKind?.rawValue,
                      existing.phase == "diagnosing" else { continue }
            } else {
                let digest = SHA256.hash(data: Data((task.id + ":" + attempt.attemptID).utf8))
                    .prefix(12).map { String(format: "%02x", $0) }.joined()
                incident = RecoveryIncident(id: digest, sourceAttemptID: attempt.attemptID,
                    ownerRunnerID: owner, branch: task.branch, head: attempt.headAfter,
                    failureKind: attempt.failureKind!, diagnosticTaskID: "r" + digest,
                    createdAt: now, deadline: now.addingTimeInterval(30 * 60),
                    resumeCount: task.recoveryIncident?.resumeCount ?? 0, legacyAsk: legacyAsk(task))
                task.pendingAsk = nil
                task.state = .blocked
                task.waitReason = .architectureReview
                task.runnerPID = nil
                task.clearDispatchLease()
            }
            task.recoveryIncident = incident
            let diagnostic = byID[incident.diagnosticTaskID]
            if let diagnostic, diagnostic.origin != originPrefix + task.id + ":" + incident.id
                || URL(fileURLWithPath: diagnostic.repo).standardizedFileURL != URL(fileURLWithPath: task.repo).standardizedFileURL
                || !TaskKind.isArchitectReview(diagnostic.prompt) {
                incident.phase = "unresolved"
                task.recoveryIncident = incident
                task.note = "技术诊断身份冲突，保持原任务阻塞；系统尚未解决"
                updates.append(task)
                continue
            }
            let validReport = diagnostic.flatMap {
                report($0, sourceTaskID: task.id, incident: incident, attempts: attempts)
            }
            if now > incident.deadline && validReport == nil {
                incident.phase = "unresolved"
                task.note = "技术诊断 \(incident.diagnosticTaskID) 超过 30 分钟仍未形成可用处置；系统尚未解决，保留原 Owner 与现场"
                if var expired = diagnostic, expired.state == .queued {
                    expired.state = .failed
                    expired.terminalFailureKind = .interrupted
                    expired.endedAt = now
                    expired.clearDispatchLease()
                    expired.note = "技术诊断时限已过，停止未领取的诊断排队；原任务现场保留"
                    updates.append(expired)
                }
            } else if let diagnostic, let report = validReport,
                      report.sourceTaskID == task.id {
                if report.decision == "resumeOriginal", incident.resumeCount < maximumResumes,
                   incident.head != nil, head(task) == incident.head {
                    incident.resumeCount += 1
                    incident.phase = "resuming"
                    task.state = .queued
                    task.waitReason = nil
                    task.createdAt = now
                    task.startedAt = nil; task.endedAt = nil; task.exitCode = nil
                    task.runnerPID = nil; task.terminalFailureKind = nil
                    task.terminalAttemptID = nil
                    task.clearDispatchLease()
                    task.preferredPlatform = task.ownerPlatform ?? task.platform
                    task.prompt += "\n\n【已验证绑定的故障诊断 \(incident.id)】\n"
                        + report.reason + "\n" + report.steps.joined(separator: "\n")
                        + "\n沿用原分支与会话，原任务授权和质量要求全部继续有效。"
                    task.note = "架构师已诊断，原 Owner \(owner) 等待续作（自动恢复 \(incident.resumeCount)/\(maximumResumes)）；尚未证明恢复产出"
                } else if report.decision == "externalBlocker",
                          ["login", "unlock", "authorization", "payment", "productChoice"].contains(report.humanBoundary ?? "") {
                    incident.phase = "externalBlocker"
                    task.askRounds += 1
                    task.pendingAsk = Ask(taskID: task.id, machineID: Paths.machineID(), round: task.askRounds,
                        platform: task.ownerPlatform, taskPrompt: String(task.prompt.prefix(200)), repoName: task.repo,
                        questions: [Ask.Question(text: report.reason + "\n" + report.steps.joined(separator: "\n"))],
                        progressNote: "技术诊断确认需要用户操作：" + (report.humanBoundary ?? ""))
                    task.waitReason = .humanAnswer
                    task.note = report.reason
                } else {
                    incident.phase = "unresolved"
                    task.note = "技术诊断 \(diagnostic.id) 未解决：\(report.reason)；"
                        + (incident.resumeCount >= maximumResumes ? "自动恢复预算已用尽，禁止重复空转" : "缺少可验证的恢复条件")
                }
            } else if let diagnostic {
                if (diagnostic.state == .failed && isTechnicalFailure(diagnostic)
                    || diagnostic.state == .done), diagnostic.pausedAt == nil,
                   diagnostic.pendingAsk == nil, diagnostic.retryNotBefore == nil,
                   diagnostic.discardedAt == nil, (diagnostic.interruptedCount ?? 0) < 1 {
                    var retry = diagnostic
                    retry.state = .queued; retry.waitReason = nil
                    retry.createdAt = now; retry.startedAt = nil; retry.endedAt = nil
                    retry.exitCode = nil; retry.runnerPID = nil; retry.terminalFailureKind = nil
                    retry.clearDispatchLease()
                    retry.interruptedCount = 1
                    retry.note = "系统诊断缺少有效报告，保留同一票补跑一次；必须绑定新的 LLMQ_ATTEMPT_ID"
                    updates.append(retry)
                } else if diagnostic.state == .failed || diagnostic.state == .done || diagnostic.discardedAt != nil {
                    incident.phase = "unresolved"
                }
                task.note = "技术诊断 \(diagnostic.id)："
                    + (incident.phase == "unresolved" ? "系统尚未解决，诊断补跑已结束" : "架构师处理中，无需点击继续")
                    + "；原 Owner \(owner) 与会话保留"
            } else {
                updates.append(self.diagnostic(for: task, incident: incident))
                task.note = "技术诊断 \(incident.diagnosticTaskID) 已排给架构师；无需点击继续，原 Owner \(owner) 与会话保留"
            }
            task.recoveryIncident = incident
            if task.note != original.note || task.state != original.state
                || original.recoveryIncident?.id != incident.id
                || original.recoveryIncident?.phase != incident.phase { updates.append(task) }
        }
        return updates
    }

    /// 对账成功后同步问题投影。只撤掉 incident 记录的那个旧问题，保留后来真实提问。
    public static func syncAsks(_ tasks: [WorkTask]) {
        for task in tasks {
            if let old = task.recoveryIncident?.legacyAsk,
               task.pendingAsk?.id != old.id {
                AskStore.retract(taskID: task.id, machine: old.machineID, matchingAskID: old.id)
            }
            if task.recoveryIncident?.phase == "externalBlocker", task.state == .blocked,
               let ask = task.pendingAsk, task.answeredAsk == nil {
                try? AskStore.publish(ask, onlyIfMissing: true)
            }
        }
    }
}
