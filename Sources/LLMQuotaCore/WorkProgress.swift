import CryptoKit
import Foundation

/// Agent 主动汇报的一次可核验里程碑。
///
/// 它单独落盘，不回写 `WorkTask`：worker 和 agent 是两个进程，同时追加任务主记录
/// 会让最后写入者覆盖另一个进程刚写的状态。任务板在发布时把两份数据做投影即可。
public struct WorkProgress: Codable, Sendable, Equatable {
    public var taskID: String
    public var sequence: Int
    public var phase: String
    public var summary: String
    public var nextStep: String?
    public var evidence: [String]
    public var evidenceFingerprint: String
    public var requestedMinutes: Int
    public var updatedAt: Date
    /// 最近一次真实 checkpoint 的时间。普通 diff 只能续租；显式里程碑或
    /// 新提交里真实出现的证据文件才能刷新它。
    public var checkpointAt: Date?

    public init(taskID: String, sequence: Int, phase: String, summary: String,
                nextStep: String? = nil, evidence: [String] = [],
                evidenceFingerprint: String, requestedMinutes: Int = 20,
                updatedAt: Date = Date(), checkpointAt: Date? = nil,
                automatic: Bool = false) {
        self.taskID = taskID
        self.sequence = sequence
        self.phase = phase
        self.summary = summary
        self.nextStep = nextStep
        self.evidence = evidence
        self.evidenceFingerprint = evidenceFingerprint
        self.requestedMinutes = requestedMinutes
        self.updatedAt = updatedAt
        self.checkpointAt = automatic ? checkpointAt : (checkpointAt ?? updatedAt)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        nextStep = try c.decodeIfPresent(String.self, forKey: .nextStep)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        evidenceFingerprint = try c.decodeIfPresent(String.self,
            forKey: .evidenceFingerprint) ?? ""
        requestedMinutes = try c.decodeIfPresent(Int.self, forKey: .requestedMinutes) ?? 20
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        if c.contains(.checkpointAt) {
            checkpointAt = try c.decodeIfPresent(Date.self, forKey: .checkpointAt)
        } else {
            // 老版本没有来源字段。能识别出的 worker 自动文案不冒充 Agent；
            // 其余旧记录按主动汇报兼容，避免升级瞬间制造一批假告警。
            let looksAutomatic = phase == "持续实现" && summary.hasPrefix("检测到")
            checkpointAt = looksAutomatic ? nil : updatedAt
        }
    }
}

public enum WorkProgressStore {
    public static var dirOverride: URL?
    public static var dir: URL {
        dirOverride ?? Paths.appSupport.appendingPathComponent("work-progress", isDirectory: true)
    }

    public static func file(taskID: String) -> URL {
        let safe = taskID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return dir.appendingPathComponent((safe.isEmpty ? "unknown" : safe) + ".json")
    }

    public static func load(taskID: String) -> WorkProgress? {
        guard let data = ICloudSafe.read(file(taskID: taskID)) else { return nil }
        return try? SnapshotCoding.decoder().decode(WorkProgress.self, from: data)
    }

    public static func latestByTaskID(taskIDs: Set<String>? = nil) -> [String: WorkProgress] {
        if let taskIDs {
            return Dictionary(uniqueKeysWithValues: taskIDs.compactMap { id in
                load(taskID: id).map { (id, $0) }
            })
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return [:]
        }
        var result: [String: WorkProgress] = [:]
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = ICloudSafe.read(url),
                  let item = try? SnapshotCoding.decoder().decode(WorkProgress.self, from: data),
                  !item.taskID.isEmpty else { continue }
            result[item.taskID] = item
        }
        return result
    }

    @discardableResult
    public static func record(taskID: String, phase: String, summary: String,
                              nextStep: String?, evidence: [String],
                              requestedMinutes: Int, repo: String,
                              now: Date = Date(), automatic: Bool = false) throws -> WorkProgress {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = load(taskID: taskID)
        let incomingEvidence = evidence.prefix(12).map { String($0.prefix(240)) }
        // worker 的客观 diff/commit 续期没有新的证据参数。它只能补一条进度，
        // 不能把 Agent 已明确上报、正等着同步到手机的截图/录屏清空。
        // 新的非空列表仍可替换旧列表，让 Agent 主动提交下一版证据。
        let cleanEvidence = incomingEvidence.isEmpty
            ? (old?.evidence ?? [])
            : incomingEvidence
        let item = WorkProgress(
            taskID: taskID,
            sequence: (old?.sequence ?? 0) + 1,
            phase: String(phase.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
            summary: String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
            nextStep: nextStep.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            },
            evidence: cleanEvidence,
            evidenceFingerprint: fingerprint(repo: repo, evidence: cleanEvidence),
            requestedMinutes: min(60, max(10, requestedMinutes)),
            updatedAt: now,
            checkpointAt: automatic
                ? (incomingEvidence.isEmpty ? old?.checkpointAt : now)
                : now,
            automatic: automatic)
        let data = try SnapshotCoding.prettyEncoder().encode(item)
        guard ICloudSafe.write(data, to: file(taskID: taskID)) else {
            throw NSError(domain: "WorkProgress", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "进度记录写入失败"])
        }
        return item
    }

    /// 工作区内容 + 显式证据文件元数据的摘要。只改汇报文案不会改变它，
    /// 因而不能靠“我还在做”这种心跳无限续期。
    public static func fingerprint(repo: String, evidence: [String] = []) -> String {
        var material = Data()
        func add(_ text: String) {
            material.append(contentsOf: text.utf8)
            material.append(0)
        }
        add(GitWorkspace.headSHA(in: repo) ?? "no-head")
        let status = GitWorkspace.git(["status", "--porcelain=v1", "-z"], in: repo).stdout
        add(status)

        // HEAD already fingerprints every committed byte.  Serialising a full binary patch here
        // made a branch with a large evidence video block the worker before the model could start.
        // For pending work, the index blob IDs plus each changed file's metadata are sufficient to
        // detect a new checkpoint without copying media into memory.
        add(GitWorkspace.git(
            ["diff", "--cached", "--raw", "--full-index", "-z", "HEAD"], in: repo
        ).stdout)
        let changed = GitWorkspace.git(
            ["diff", "--name-only", "-z", "HEAD"], in: repo
        ).stdout + GitWorkspace.git(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: repo
        ).stdout
        for path in Set(changed.split(separator: "\0").map(String.init)).sorted() {
            add(path)
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: repo))
                .standardizedFileURL
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                add(String(describing: attrs[.size] ?? "missing-size"))
                add(String(describing: attrs[.modificationDate] ?? "missing-date"))
            } else {
                add("missing")
            }
        }

        for raw in evidence.sorted() {
            let url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: repo))
                .standardizedFileURL
            add(raw)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                add(String(describing: attrs[.size] ?? "missing-size"))
                add(String(describing: attrs[.modificationDate] ?? "missing-date"))
            } else {
                add("missing")
            }
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

/// 独立于 Agent 自报的长任务巡检。
///
/// Agent 忘记调用 `work progress` 时，租约闸会拒绝给它续时；但手机端过去仍只写
/// “运行中”，也没有任何提醒。巡检只陈述一件能确定的事实：最近 20 分钟没有
/// 结构化、可核验的里程碑。它不据此换 owner，也不假装判断代码质量。
public enum WorkProgressSentinel {
    public static let interval: TimeInterval = 20 * 60

    public struct Finding: Sendable, Equatable {
        public var taskID: String
        public var minutesWithoutProgress: Int
        public var neverReported: Bool
    }

    public static func finding(for task: WorkTask, progress: WorkProgress?,
                               now: Date = Date()) -> Finding? {
        let isRunning = task.state == .running
        let isUnownedTechnicalBlock = TechnicalDisposition.isBlocked(task)
        guard isRunning || isUnownedTechnicalBlock else { return nil }
        guard let startedAt = isRunning ? task.startedAt : (task.endedAt ?? task.startedAt) else {
            return nil
        }
        // worker 看到文件变化会自动续租，但那不是 Agent 主动交出的阶段成果。
        // 两者共用 updatedAt 会让一个一直改文件却从不交 checkpoint 的任务
        // 永远逃过 20 分钟巡检。
        let lastProof = progress?.checkpointAt ?? startedAt
        let age = now.timeIntervalSince(lastProof)
        guard age >= interval else { return nil }
        return Finding(taskID: task.id,
                       minutesWithoutProgress: max(20, Int(age / 60)),
                       neverReported: progress == nil)
    }

    public static func inspect(_ tasks: [WorkTask],
                               progressByTaskID: [String: WorkProgress],
                               now: Date = Date()) -> [Finding] {
        tasks.compactMap { finding(for: $0, progress: progressByTaskID[$0.id], now: now) }
    }
}

/// 续期闸门只认“新鲜的、新序号的、证据摘要真的变化了”的汇报。
/// 每次最多续 60 分钟，但总次数不封顶：方向正确就让同一个会话继续做。
public final class ExecutionLeaseGate {
    private let taskID: String
    private var lastAcceptedSequence: Int
    private var lastAcceptedFingerprint: String
    public let freshness: TimeInterval

    public init(taskID: String, baselineFingerprint: String,
                existing: WorkProgress? = nil, freshness: TimeInterval = 5 * 60) {
        self.taskID = taskID
        self.lastAcceptedSequence = existing?.sequence ?? 0
        self.lastAcceptedFingerprint = baselineFingerprint
        self.freshness = freshness
    }

    /// 新鲜里程碑立即兑换成一段追加租约；不能等到临近截止再消费，
    /// 否则较早完成的真实进展会在等待期间过期。
    public func renewal(now: Date = Date(), progress: WorkProgress?)
        -> (seconds: TimeInterval, progress: WorkProgress)? {
        guard let progress, progress.taskID == taskID,
              progress.sequence > lastAcceptedSequence,
              !progress.phase.isEmpty, !progress.summary.isEmpty,
              !progress.evidenceFingerprint.isEmpty,
              progress.evidenceFingerprint != lastAcceptedFingerprint,
              now.timeIntervalSince(progress.updatedAt) >= 0,
              now.timeIntervalSince(progress.updatedAt) <= freshness else { return nil }
        let seconds = TimeInterval(min(60, max(10, progress.requestedMinutes)) * 60)
        lastAcceptedSequence = progress.sequence
        lastAcceptedFingerprint = progress.evidenceFingerprint
        return (seconds, progress)
    }
}

/// Agent 忘记主动汇报时，用工作区的客观变化兜底续期。
///
/// 新提交当然算进展；一批尚未提交、但已经落盘的代码和证据也算。后者正是长任务
/// 最容易被误杀的窗口：Kimi 已写了五个取证文件，服务端却因为 HEAD 没变把会话
/// 杀掉。同一份 HEAD + diff 指纹只能消费一次，因此静止的 WIP 不能无限续命。
public final class ObjectiveProgressLeaseGate {
    private var lastAcceptedHead: String?
    private var lastAcceptedFingerprint: String
    public let secondsPerChange: TimeInterval

    public init(baselineHead: String?, baselineFingerprint: String,
                secondsPerChange: TimeInterval = 20 * 60) {
        self.lastAcceptedHead = baselineHead
        self.lastAcceptedFingerprint = baselineFingerprint
        self.secondsPerChange = max(60, secondsPerChange)
    }

    /// Agent 已主动提交并被租约闸接受时同步基线，避免同一份成果下一轮又被兜底消费。
    public func observe(currentHead: String?, currentFingerprint: String) {
        lastAcceptedHead = currentHead
        lastAcceptedFingerprint = currentFingerprint
    }

    public func renewal(currentHead: String?, currentFingerprint: String)
        -> (seconds: TimeInterval, head: String?, fingerprint: String,
            headChanged: Bool)? {
        guard !currentFingerprint.isEmpty,
              currentHead != lastAcceptedHead
                || currentFingerprint != lastAcceptedFingerprint else { return nil }
        let headChanged = currentHead != lastAcceptedHead
        lastAcceptedHead = currentHead
        lastAcceptedFingerprint = currentFingerprint
        return (secondsPerChange, currentHead, currentFingerprint, headChanged)
    }
}

public enum WorkProgressContract {
    public static func clause() -> String {
        """

        ## 长任务进度与续期
        你必须保持当前会话连续工作，不要因为任务耗时长就自行拆给另一个 Agent。
        每完成一个可核验里程碑，运行：
        `llmq work progress --phase "阶段" --summary "已经完成的具体事实" --next "下一步" --evidence "证据路径" --request-minutes 20`
        任务编号由环境变量 `LLMQ_TASK_ID` 自动提供。证据可以是测试日志、截图或产物路径；
        系统也会自动核对当前提交和工作区差异。只改汇报文字、没有新提交/差异/证据，不能续期。
        在当前时限不够时再次提交最新里程碑；证据持续推进就会延长同一执行会话，续期总次数不封顶。
        """
    }
}
