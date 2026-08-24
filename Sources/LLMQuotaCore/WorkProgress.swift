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

    public init(taskID: String, sequence: Int, phase: String, summary: String,
                nextStep: String? = nil, evidence: [String] = [],
                evidenceFingerprint: String, requestedMinutes: Int = 20,
                updatedAt: Date = Date()) {
        self.taskID = taskID
        self.sequence = sequence
        self.phase = phase
        self.summary = summary
        self.nextStep = nextStep
        self.evidence = evidence
        self.evidenceFingerprint = evidenceFingerprint
        self.requestedMinutes = requestedMinutes
        self.updatedAt = updatedAt
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
                              now: Date = Date()) throws -> WorkProgress {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = load(taskID: taskID)
        let cleanEvidence = evidence.prefix(12).map { String($0.prefix(240)) }
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
            updatedAt: now)
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
        add(GitWorkspace.git(["status", "--porcelain=v1"], in: repo).stdout)
        add(GitWorkspace.git(["diff", "--binary", "HEAD"], in: repo).stdout)
        add(GitWorkspace.git(["diff", "--binary", "main...HEAD"], in: repo).stdout)

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
