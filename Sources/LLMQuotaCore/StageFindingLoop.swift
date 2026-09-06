import Foundation
import CryptoKit

/// 阶段观察只触发范围复核。确认、收到、改过和复验通过是不同事实；
/// 生命周期由既有协作事件推导，不用 unresolved（它只表示消息未回复）。
public enum StageFindingLoop {
    public static let sender = "stage-finding-controller"
    public struct Context: Codable, Equatable, Sendable {
        public var observationID: String
        public var sourceTaskID: String
        public var sourceOwner: String
        public var sourceOwnerMachineID: String
        public var sourceOwnerPlatform: String
        public var sourceBranch: String
        public var sourceHead: String
        public var reportRef: String
        public var scope: String
        public var report: String
        public var stage: String
        public var findingID: String
        public var evidenceDigests: [String]
    }
    public struct Assessment: Codable, Equatable, Sendable {
        public var questionID: String
        public var sourceTaskID: String
        public var sourceHead: String
        public var decision: String
        public var reason: String
        public var criterion: String
        public var evidence: [String]
        public var steps: [String]
    }
    public struct Finding: Sendable {
        public var event: CollaborationEvent
        public var context: Context
        public var assessment: Assessment
        public var acknowledged: Bool
        public var resolved: Bool
    }
    public static func holds(_ task: WorkTask) -> Bool {
        task.state == .blocked && task.waitReason == .productionGate
            && task.note?.hasPrefix("阶段问题待复验：") == true
    }
    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: String?) -> T? {
        guard let value, value.utf8.count <= 20_000 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(value.utf8))
    }
    private static func sha(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit }
    }
    private static func field(_ name: String, in prompt: String) -> String? {
        let matches = prompt.components(separatedBy: .newlines).filter { $0.hasPrefix(name + "：") }
        guard matches.count == 1 else { return nil }
        let value = String(matches[0].dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    public static func context(_ question: CollaborationEvent) -> Context? {
        guard question.kind == .question, question.senderRunnerID == sender,
              question.id.hasPrefix("stage-triage:") || question.id.hasPrefix("stage-recheck:"),
              let c = decode(Context.self, question.details),
              c.sourceTaskID == question.taskID, !c.sourceOwner.isEmpty,
              !c.sourceOwnerMachineID.isEmpty, !c.sourceOwnerPlatform.isEmpty,
              c.sourceBranch.hasPrefix("agent/"), sha(c.sourceHead),
              ["triage", "recheck"].contains(c.stage) else { return nil }
        return c
    }
    /// 特殊咨询保存完整、已校验 JSON，不能把 2000 字截断的普通 summary 当决策。
    public static func answerDetails(_ raw: String, question: CollaborationEvent) throws -> String? {
        guard let c = context(question) else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json\n"), text.hasSuffix("```") {
            text = String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let a = decode(Assessment.self, text), valid(a, question: question, context: c) else {
            throw NSError(domain: "StageFindingLoop", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "阶段问题复核缺少匹配的范围、证据或结构化结论，未采纳"])
        }
        return encode(a)
    }
    private static func valid(_ a: Assessment, question: CollaborationEvent, context c: Context) -> Bool {
        let allowed = c.stage == "triage"
            ? ["fixNow", "defer", "notApplicable", "needsEvidence", "noIssue"]
            : ["resolved", "stillOpen", "needsEvidence"]
        return a.questionID == question.id && a.sourceTaskID == c.sourceTaskID
            && a.sourceHead == c.sourceHead && allowed.contains(a.decision)
            && !a.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && a.reason.count <= 1_000 && !a.evidence.isEmpty && a.evidence.count <= 10
            && a.evidence.allSatisfy { !$0.isEmpty && $0.count <= 1_000 }
            && a.steps.count <= 10 && a.steps.allSatisfy { !$0.isEmpty && $0.count <= 1_000 }
            && (!["fixNow", "resolved"].contains(a.decision) || !a.criterion.isEmpty)
            && (a.decision != "fixNow" || !a.steps.isEmpty)
            && (!["resolved", "fixNow"].contains(a.decision) || !c.evidenceDigests.isEmpty)
    }
    private static func assessment(_ question: CollaborationEvent, events: [CollaborationEvent]) -> Assessment? {
        guard !AgentConsultation.failed(question, events: events) else { return nil }
        guard let c = context(question), let answer = events.first(where: {
            $0.kind == .answer && $0.replyTo == question.id && $0.project == question.project
                && $0.taskID == question.taskID && $0.senderRunnerID == question.recipientRunnerID
                && $0.senderMachineID == question.recipientMachineID
        }), let a = decode(Assessment.self, answer.details), valid(a, question: question, context: c)
        else { return nil }
        return a
    }
    private static func nextQuestionID(_ base: String, events: [CollaborationEvent]) -> String? {
        guard let first = events.first(where: { $0.id == base }) else { return base }
        guard AgentConsultation.failed(first, events: events),
              !events.contains(where: { $0.id == base + ":retry1" }) else { return nil }
        return base + ":retry1"
    }
    public static func hasUnverifiedTrackedFinding(_ task: WorkTask, events: [CollaborationEvent] = CollaborationStore.all()) -> Bool {
        let closed = Set(findings(for: task, events: events).filter { $0.resolved }.map { $0.event.id })
        let known = events.filter {
            $0.kind == .finding && $0.senderRunnerID == sender
                && $0.taskID == task.id && $0.project == CollaborationStore.normalizeProject(task.repo)
                && $0.id.hasPrefix("stage-finding:")
        }.map { $0.id }
        return (known + (task.findingRequeueIDs ?? [])).contains { !closed.contains($0) }
    }
    public static func findings(for task: WorkTask, events: [CollaborationEvent] = CollaborationStore.all()) -> [Finding] {
        let project = CollaborationStore.normalizeProject(task.repo)
        return events.compactMap { event in
            guard event.kind == .finding, event.senderRunnerID == sender,
                  event.project == project, event.taskID == task.id,
                  let q = events.first(where: { $0.id == event.replyTo }),
                  let c = context(q), c.stage == "triage",
                  event.senderMachineID == c.sourceOwnerMachineID,
                  event.id == "stage-finding:" + q.id,
                  let a = assessment(q, events: events), a.decision == "fixNow" else { return nil }
            let ack = events.contains {
                $0.kind == .ack && $0.replyTo == event.id && $0.project == project
                    && $0.senderRunnerID == c.sourceOwner && $0.taskID == task.id
                    && $0.senderMachineID == c.sourceOwnerMachineID
                    && ($0.senderPlatform == nil || $0.senderPlatform?.rawValue == c.sourceOwnerPlatform)
            }
            let resolved = events.contains { recheck in
                guard recheck.project == project, let rc = context(recheck),
                      rc.stage == "recheck", rc.findingID == event.id,
                      rc.sourceOwner == c.sourceOwner, rc.sourceTaskID == c.sourceTaskID,
                      rc.sourceOwnerMachineID == c.sourceOwnerMachineID,
                      rc.sourceOwnerPlatform == c.sourceOwnerPlatform,
                      rc.sourceHead != c.sourceHead,
                      !Set(rc.evidenceDigests).isSubset(of: Set(c.evidenceDigests)),
                      recheck.recipientRunnerID != c.sourceOwner else { return false }
                return assessment(recheck, events: events)?.decision == "resolved"
            }
            return Finding(event: event, context: c, assessment: a, acknowledged: ack, resolved: ack && resolved)
        }
    }
    private static func evidence(_ files: [String]) -> (paths: [String], digests: [String]) {
        var paths: [String] = [], hashes: [String] = []
        for name in files.prefix(5) {
            guard !name.contains("/"), name != ".", name != "..",
                  Review.isImageName(name) || Review.isVideoName(name) else { continue }
            let url = Review.evidenceDir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 20_000_000,
                  let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            paths.append(url.path)
            hashes.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return (paths, hashes)
    }
    public static func evidenceDigests(_ files: [String]) -> [String] {
        evidence(files).digests.sorted()
    }
    private static func submit(_ c: Context, id: String, source: WorkTask,
                               artifacts: [String], registrations: [AgentRegistration]) throws {
        guard let target = registrations.filter({
            $0.machineID == Paths.machineID() && $0.platform == AgentRoles.architectPlatform()
                && $0.runnerID != source.ownerRunnerID && $0.canConsult && $0.canReadFiles
                && !$0.isMuted && $0.quotaBlockedReason == nil
                && ($0.quotaAvailableFraction ?? 1) > 0
        }).sorted(by: { $0.runnerID < $1.runnerID }).first, let details = encode(c), details.count <= 4_000 else { return }
        _ = try AgentConsultation.submit(.init(id: id, project: source.repo,
            taskID: source.id, senderRunnerID: sender, recipientRunnerID: target.runnerID,
            recipientMachineID: target.machineID,
            question: c.stage == "triage"
                ? "复核阶段观察是否属于原任务本阶段的真实问题；不得按整项目标准扩张范围。"
                : "根据独立视觉 Agent 对新画面的已完成观察和修复代码，复核原具体问题是否消失。",
            details: details, artifacts: artifacts), registrations: registrations)
    }
    private static func report(_ observation: WorkTask, source: WorkTask) -> (ref: String, text: String)? {
        guard observation.origin == "milestone-eyes", observation.state == .done,
              observation.discardedAt == nil, observation.ownerPlatform == .minimax,
              observation.ownerRunnerID != source.ownerRunnerID,
              let attempt = WorkAttemptStore.all().filter({ $0.taskID == observation.id })
                .max(by: { $0.startedAt < $1.startedAt }), attempt.outcome == .done,
              attempt.runnerID == observation.ownerRunnerID, attempt.platform == observation.ownerPlatform,
              observation.terminalAttemptID == nil || observation.terminalAttemptID == attempt.attemptID,
              let head = attempt.headAfter, sha(head) else { return nil }
        let ref = head + ":reviews/EVAL-视觉-\(observation.id).md"
        let size = GitWorkspace.git(["cat-file", "-s", ref], in: source.repo, timeout: 5)
        guard size.exitCode == 0,
              let bytes = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              bytes > 0 && bytes <= 20_000 else { return nil }
        let value = GitWorkspace.git(["show", ref], in: source.repo, timeout: 5)
        guard value.exitCode == 0, VisualReviewScope.observation.acceptsReportHeading(value.stdout) else { return nil }
        return (ref, value.stdout)
    }
    /// 只发布真实任务对应的 Agent 内部咨询。无可用架构师时保持等待，不造人工问题。
    public static func synchronize(_ tasks: [WorkTask], registrations: [AgentRegistration] = AgentRegistry.all()) {
        var events = CollaborationStore.all()
        let milestones = Milestone.all()
        // 每个原任务仅复核最新阶段；旧证据不批量回灌，不盖掉已经进入整改的问题。
        let observations = tasks.filter { $0.state == .done && $0.origin == "milestone-eyes" && $0.discardedAt == nil }
            .sorted { ($0.endedAt ?? $0.createdAt) > ($1.endedAt ?? $1.createdAt) }
        var seen: Set<String> = []
        for observation in observations {
            guard let branch = field("来源分支", in: observation.prompt),
                  let head = field("证据提交", in: observation.prompt), sha(head) else { continue }
            let sourceID = field("来源任务", in: observation.prompt)
            let matches = tasks.filter {
                $0.repo == observation.repo && $0.branch == branch && !TaskKind.isSupportingTask($0)
                    && (sourceID == nil || sourceID == $0.id)
            }
            guard matches.count == 1, let source = matches.first,
                  source.landedAt == nil, source.discardedAt == nil,
                  let owner = source.ownerRunnerID, let ownerPlatform = source.ownerPlatform,
                  !seen.contains(source.id) else { continue }
            guard let id = nextQuestionID("stage-triage:" + observation.id, events: events) else { continue }
            if findings(for: source, events: events).contains(where: { !$0.resolved }) { continue }
            // 原 Owner 已经提交新版本后，迟到的旧画面不能再触发当前整改。
            let currentHead = GitWorkspace.git(["rev-parse", "--verify", branch + "^{commit}"], in: source.repo, timeout: 5)
            guard currentHead.exitCode == 0,
                  currentHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head else { continue }
            guard let report = report(observation, source: source) else { continue }
            let items = milestones.filter { $0.taskID == source.id && $0.mergeSHA == head && $0.branch == branch }
            let boundDigest = field("证据摘要", in: observation.prompt)
            let item = boundDigest.flatMap { digest in items.first { evidenceDigests($0.evidenceFiles).joined(separator: ",") == digest } }
                ?? (boundDigest == nil && items.count == 1 ? items.first : nil)
            let proof = evidence(item?.evidenceFiles ?? [])
            if observation.prompt.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("证据摘要：") }) {
                guard field("证据摘要", in: observation.prompt) == proof.digests.sorted().joined(separator: ",") else { continue }
            }
            seen.insert(source.id)
            let c = Context(observationID: observation.id, sourceTaskID: source.id,
                sourceOwner: owner, sourceOwnerMachineID: Paths.machineID(), sourceOwnerPlatform: ownerPlatform.rawValue,
                sourceBranch: branch, sourceHead: head, reportRef: report.ref,
                scope: String(source.prompt.prefix(800)), report: String(report.text.prefix(1_000)),
                stage: "triage", findingID: "", evidenceDigests: proof.digests)
            try? submit(c, id: id, source: source, artifacts: proof.paths, registrations: registrations)
        }
        events = CollaborationStore.all()
        for q in events {
            guard let c = context(q), c.stage == "triage", c.sourceOwnerMachineID == Paths.machineID(),
                  let a = assessment(q, events: events) else { continue }
            let id = "stage-finding:" + q.id
            guard !events.contains(where: { $0.id == id }) else { continue }
            let current = GitWorkspace.git(["rev-parse", "--verify", c.sourceBranch + "^{commit}"], in: q.project, timeout: 5)
            let stale = current.exitCode != 0 || current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != c.sourceHead
            _ = try? CollaborationStore.publish(CollaborationEvent(id: id, project: q.project,
                taskID: c.sourceTaskID, senderRunnerID: sender, recipientRunnerID: c.sourceOwner,
                recipientMachineID: c.sourceOwnerMachineID,
                kind: a.decision == "fixNow" && !stale ? .finding : .checkpoint,
                summary: stale ? "范围过期：原 Owner 已推进提交，旧结论不触发整改" : a.decision + "：" + a.reason,
                details: "适用条款：\(a.criterion)\n处置：\(a.steps.joined(separator: "；"))\n"
                    + "原 Owner 用 collaboration ack 确认此事件，修复后提交新的截图/录屏 checkpoint，等待独立复验；收到不代表修好。",
                replyTo: q.id, branch: c.sourceBranch, commitSHA: c.sourceHead))
        }
        events = CollaborationStore.all()
        for source in tasks {
            for f in findings(for: source, events: events) where f.acknowledged && !f.resolved {
                guard identityMatches(source, f.context, machineID: Paths.machineID()) else { continue }
                let checks = events.filter {
                    $0.project == f.event.project && $0.taskID == source.id
                        && context($0)?.findingID == f.event.id
                }
                guard checks.count < 2, !checks.contains(where: { question in
                    assessment(question, events: events) == nil
                        && !AgentConsultation.failed(question, events: events)
                }) else { continue }
                for item in milestones.sorted(by: { $0.landedAt > $1.landedAt }) where item.taskID == source.id
                    && item.branch == source.branch && item.mergeSHA != f.context.sourceHead
                    && sha(item.mergeSHA) && item.landedAt >= f.event.createdAt {
                    let ancestor = GitWorkspace.git(["merge-base", "--is-ancestor", f.context.sourceHead, item.mergeSHA],
                        in: source.repo, timeout: 5)
                    guard ancestor.exitCode == 0 else { continue }
                    let proof = evidence(item.evidenceFiles)
                    guard !proof.digests.isEmpty,
                          !Set(proof.digests).isSubset(of: Set(f.context.evidenceDigests)) else { continue }
                    let proofID = SHA256.hash(data: Data(proof.digests.sorted().joined(separator: ",").utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    guard let questionID = nextQuestionID("stage-recheck:" + f.context.observationID
                        + ":" + item.mergeSHA + ":" + proofID, events: events) else { continue }
                    guard let eyes = observations.first(where: {
                        $0.repo == source.repo && field("来源任务", in: $0.prompt) == source.id
                            && field("来源分支", in: $0.prompt) == source.branch
                            && field("证据提交", in: $0.prompt) == item.mergeSHA
                            && field("证据摘要", in: $0.prompt) == proof.digests.sorted().joined(separator: ",")
                    }),
                       let freshReport = report(eyes, source: source) else { continue }
                    var c = f.context; c.stage = "recheck"; c.findingID = f.event.id
                    c.sourceHead = item.mergeSHA; c.evidenceDigests = proof.digests
                    c.reportRef = freshReport.ref
                    c.report = String(("原问题：" + f.assessment.reason + "\n新视觉观察：" + freshReport.text).prefix(1_000))
                    try? submit(c, id: questionID,
                        source: source, artifacts: proof.paths, registrations: registrations)
                    break
                }
            }
        }
    }

    /// 只在一次执行真正结束后续作，绝不覆盖运行中的 Owner。
    /// 每个已确认问题最多自动续作一次，每个原任务最多两次；复验未通过不能落地。
    private static func identityMatches(_ task: WorkTask, _ c: Context, machineID: String) -> Bool {
        task.ownerRunnerID == c.sourceOwner && task.ownerPlatform?.rawValue == c.sourceOwnerPlatform
            && task.branch == c.sourceBranch && machineID == c.sourceOwnerMachineID
    }
    public static func reconcile(_ tasks: [WorkTask], machineID: String = Paths.machineID()) -> [WorkTask] {
        let events = CollaborationStore.all()
        return tasks.compactMap { task in
            guard task.state == .done || (task.state == .blocked && task.note?.hasPrefix("阶段问题待复验：") == true),
                  task.pendingAsk == nil, task.pausedAt == nil, task.discardedAt == nil,
                  task.landedAt == nil, task.frozenBy == nil,
                  task.retryNotBefore == nil, task.terminalFailureKind == nil,
                  !TechnicalRecovery.holds(task) else { return nil }
            let allFindings = findings(for: task, events: events)
            let open = allFindings.filter { !$0.resolved }
            guard !open.isEmpty else {
                if hasUnverifiedTrackedFinding(task, events: events) {
                    var held = task; held.state = .blocked; held.waitReason = .productionGate
                    held.note = "阶段问题待复验：已登记问题的完整记录尚未读到，不能视为通过"
                    return held.state != task.state || held.note != task.note ? held : nil
                }
                if task.state == .blocked, task.note?.hasPrefix("阶段问题待复验：") == true,
                   let tracked = task.findingRequeueIDs, !tracked.isEmpty,
                   tracked.allSatisfy({ id in allFindings.contains { $0.event.id == id && $0.resolved } }) {
                    var done = task; done.state = .done; done.waitReason = nil
                    done.note = "阶段问题已由独立复验关闭，继续原有交付门禁"
                    return done
                }
                return nil
            }
            var updated = task
            if open.contains(where: { !identityMatches(task, $0.context, machineID: machineID) }) {
                updated.state = .blocked; updated.waitReason = .productionGate
                updated.note = "阶段问题待复验：任务负责人、机器或分支已变化，不能自动改派或丢弃未解决问题"
                return updated.note != task.note || updated.state != task.state ? updated : nil
            }
            let resumed = task.findingRequeueIDs ?? []
            let fresh = open.filter { !resumed.contains($0.event.id) }
            if task.state == .done && resumed.count < 2 && !fresh.isEmpty {
                updated.findingRequeueIDs = resumed + Array(fresh.map { $0.event.id }.prefix(2 - resumed.count))
                updated.state = .queued; updated.waitReason = nil
                updated.startedAt = nil; updated.endedAt = nil; updated.exitCode = nil
                updated.clearDispatchLease()
                updated.prompt += "\n\n阶段观察经架构师确认的当前问题（原任务目标与非目标不变）：\n"
                    + fresh.map { "\($0.event.id)：\($0.assessment.reason)\n适用条款：\($0.assessment.criterion)\n"
                        + $0.assessment.steps.joined(separator: "；") }.joined(separator: "\n")
                    + "\n先用 collaboration ack 确认这些事件，沿用当前分支与会话完成修复，"
                    + "提交新截图/录屏 checkpoint 后等待独立复验。不得把已读或新提交当作通过。"
                updated.note = "原 Owner 继续修复已确认阶段问题并提供新画面"
            } else {
                updated.state = .blocked; updated.waitReason = .productionGate
                updated.note = "阶段问题待复验：" + open.map { $0.assessment.reason }.joined(separator: "；")
            }
            guard updated.state != task.state || updated.note != task.note else { return nil }
            return updated
        }
    }
}

extension StageFindingLoop.Context {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observationID = try c.decodeIfPresent(String.self, forKey: .observationID) ?? ""
        sourceTaskID = try c.decodeIfPresent(String.self, forKey: .sourceTaskID) ?? ""
        sourceOwner = try c.decodeIfPresent(String.self, forKey: .sourceOwner) ?? ""
        sourceOwnerMachineID = try c.decodeIfPresent(String.self, forKey: .sourceOwnerMachineID) ?? ""
        sourceOwnerPlatform = try c.decodeIfPresent(String.self, forKey: .sourceOwnerPlatform) ?? ""
        sourceBranch = try c.decodeIfPresent(String.self, forKey: .sourceBranch) ?? ""
        sourceHead = try c.decodeIfPresent(String.self, forKey: .sourceHead) ?? ""
        reportRef = try c.decodeIfPresent(String.self, forKey: .reportRef) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        report = try c.decodeIfPresent(String.self, forKey: .report) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? "unknown"
        findingID = try c.decodeIfPresent(String.self, forKey: .findingID) ?? ""
        evidenceDigests = try c.decodeIfPresent([String].self, forKey: .evidenceDigests) ?? []
    }
}
extension StageFindingLoop.Assessment {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionID = try c.decodeIfPresent(String.self, forKey: .questionID) ?? ""
        sourceTaskID = try c.decodeIfPresent(String.self, forKey: .sourceTaskID) ?? ""
        sourceHead = try c.decodeIfPresent(String.self, forKey: .sourceHead) ?? ""
        decision = try c.decodeIfPresent(String.self, forKey: .decision) ?? "unknown"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        criterion = try c.decodeIfPresent(String.self, forKey: .criterion) ?? ""
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
    }
}
