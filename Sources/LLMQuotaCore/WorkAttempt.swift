import Foundation

/// 一次 Runner 执行的不可覆盖事实。最终 WorkTask 只保留终态，不能拿来反推中间接力。
public struct WorkAttempt: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case running, done, failed, blocked
    }

    public enum SessionAction: String, Codable, Sendable {
        case none, fresh, create, resume, projectResume
    }

    public var attemptID: String
    public var taskID: String
    public var runnerID: String
    public var platform: Platform
    public var taskTier: TaskProfile.Tier?
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome
    public var failureKind: String?
    public var workspacePrepared: Bool
    public var headBefore: String?
    public var headAfter: String?
    public var changedFiles: Int
    public var newCommits: Int
    public var timedOut: Bool
    public var sessionSupport: SessionSupport
    public var sessionAction: SessionAction
    public var handoffReason: String?

    public init(attemptID: String = UUID().uuidString.lowercased(),
                taskID: String, runnerID: String, platform: Platform,
                taskTier: TaskProfile.Tier? = nil,
                startedAt: Date, endedAt: Date? = nil,
                outcome: Outcome, failureKind: String? = nil,
                workspacePrepared: Bool = true,
                headBefore: String? = nil, headAfter: String? = nil,
                changedFiles: Int = 0, newCommits: Int = 0,
                timedOut: Bool,
                sessionSupport: SessionSupport = .none,
                sessionAction: SessionAction = .none,
                handoffReason: String? = nil) {
        self.attemptID = attemptID
        self.taskID = taskID
        self.runnerID = runnerID
        self.platform = platform
        self.taskTier = taskTier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.failureKind = failureKind
        self.workspacePrepared = workspacePrepared
        self.headBefore = headBefore
        self.headAfter = headAfter
        self.changedFiles = changedFiles
        self.newCommits = newCommits
        self.timedOut = timedOut
        self.sessionSupport = sessionSupport
        self.sessionAction = sessionAction
        self.handoffReason = handoffReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attemptID = try c.decodeIfPresent(String.self, forKey: .attemptID) ?? UUID().uuidString
        taskID = try c.decode(String.self, forKey: .taskID)
        runnerID = try c.decode(String.self, forKey: .runnerID)
        platform = try c.decode(Platform.self, forKey: .platform)
        taskTier = try c.decodeIfPresent(TaskProfile.Tier.self, forKey: .taskTier)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .failed
        failureKind = try c.decodeIfPresent(String.self, forKey: .failureKind)
        workspacePrepared = try c.decodeIfPresent(Bool.self, forKey: .workspacePrepared) ?? false
        headBefore = try c.decodeIfPresent(String.self, forKey: .headBefore)
        headAfter = try c.decodeIfPresent(String.self, forKey: .headAfter)
        changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
        newCommits = try c.decodeIfPresent(Int.self, forKey: .newCommits) ?? 0
        timedOut = try c.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
        sessionSupport = try c.decodeIfPresent(SessionSupport.self, forKey: .sessionSupport) ?? .none
        sessionAction = try c.decodeIfPresent(SessionAction.self, forKey: .sessionAction) ?? .none
        handoffReason = try c.decodeIfPresent(String.self, forKey: .handoffReason)
    }
}

public enum WorkAttemptStore {
    public static var fileOverride: URL?
    private static let lock = NSLock()

    public static var file: URL {
        fileOverride ?? Paths.appSupport.appendingPathComponent("work-attempts.jsonl")
    }

    public static func all() -> [WorkAttempt] {
        guard let data = ICloudSafe.read(file) else { return [] }
        let decoder = SnapshotCoding.decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(WorkAttempt.self, from: Data($0))
        }
    }

    /// 每次执行会先追加 running，再用同一个 attemptID 追加终态。
    /// 给人看的“当前尝试”必须先折叠，否则已经失败/完成的尝试会同时显示成
    /// running，历史事件就冒充了当前状态。
    public static func latestSnapshots(_ attempts: [WorkAttempt]? = nil) -> [WorkAttempt] {
        var latest: [String: (index: Int, attempt: WorkAttempt)] = [:]
        for (index, attempt) in (attempts ?? all()).enumerated() {
            latest[attempt.attemptID] = (index, attempt)
        }
        return latest.values.sorted { $0.index < $1.index }.map(\.attempt)
    }

    public static func append(_ attempt: WorkAttempt) throws {
        try Paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try SnapshotCoding.encoder().encode(attempt)
        data.append(UInt8(ascii: "\n"))
        lock.lock(); defer { lock.unlock() }
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NSError(domain: "WorkAttemptStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "attempt 记录文件打不开"])
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw NSError(domain: "WorkAttemptStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "attempt 记录加锁失败"])
        }
        defer { flock(fd, LOCK_UN) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw NSError(domain: "WorkAttemptStore", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "attempt 记录写入不完整"])
            }
            offset += count
        }
    }

    /// 取出只有开工事件、还没有终态事件的尝试。worker 重启时用它补记中断事实。
    public static func unresolvedRunning(taskID: String) -> [WorkAttempt] {
        latestSnapshots(all().filter { $0.taskID == taskID })
            .filter { $0.outcome == .running }
    }

    /// 同一任务和 Runner 最近一次已经收尾的尝试。
    ///
    /// 每次尝试会先写 `running`、结束后再用同一个 attemptID 追加终态，
    /// 所以必须先按 attemptID 折叠。尤其不能直接找“历史上最后一个 failed”：
    /// 后续成功创建的新会话已经证明旧失败失效，再翻出旧失败会把好会话误删。
    public static func latestTerminal(taskID: String, runnerID: String) -> WorkAttempt? {
        latestSnapshots(all().filter {
            $0.taskID == taskID && $0.runnerID == runnerID
        }).last { $0.outcome != .running }
    }
}

public enum WorkAttemptMetrics {
    public struct Group: Sendable, Equatable {
        public var platform: Platform
        public var tier: TaskProfile.Tier?
        public var attempts: Int
        public var timeouts: Int
        public var successes: Int
    }

    public struct Recovery: Sendable, Equatable {
        public var sameOwnerAttempts = 0
        public var sameOwnerSuccesses = 0
        public var handoffAttempts = 0
        public var handoffSuccesses = 0
    }

    public struct Summary: Sendable, Equatable {
        public var groups: [Group]
        public var recovery: Recovery
    }

    public static func summarize(_ attempts: [WorkAttempt]) -> Summary {
        // 同一个 attemptID 会追加 running 和终态两条事件。指标只看每次尝试的
        // 最新终态，既不重复计数，也不把尚未回收的孤儿当成一次已完成尝试。
        var latest: [String: (index: Int, attempt: WorkAttempt)] = [:]
        for (index, attempt) in attempts.enumerated() {
            latest[attempt.attemptID] = (index, attempt)
        }
        let terminal = latest.values
            .filter { $0.attempt.outcome != .running }
            .sorted { $0.index < $1.index }
            .map(\.attempt)

        var counts: [String: Group] = [:]
        for item in terminal {
            let key = item.platform.rawValue + "|" + (item.taskTier?.rawValue ?? "unknown")
            var value = counts[key] ?? Group(
                platform: item.platform, tier: item.taskTier,
                attempts: 0, timeouts: 0, successes: 0)
            value.attempts += 1
            if item.timedOut { value.timeouts += 1 }
            if item.outcome == .done { value.successes += 1 }
            counts[key] = value
        }
        let groups = counts.values.sorted {
            if $0.platform.rawValue != $1.platform.rawValue {
                return $0.platform.rawValue < $1.platform.rawValue
            }
            return ($0.tier?.rankValue ?? -1) < ($1.tier?.rankValue ?? -1)
        }

        var recovery = Recovery()
        let byTask = Dictionary(grouping: terminal, by: \.taskID)
        for sequence in byTask.values {
            let ordered = sequence.sorted { $0.startedAt < $1.startedAt }
            guard ordered.count > 1 else { continue }
            for index in 0..<(ordered.count - 1) where ordered[index].timedOut {
                let next = ordered[index + 1]
                if next.runnerID == ordered[index].runnerID {
                    recovery.sameOwnerAttempts += 1
                    if next.outcome == .done { recovery.sameOwnerSuccesses += 1 }
                } else {
                    recovery.handoffAttempts += 1
                    if next.outcome == .done { recovery.handoffSuccesses += 1 }
                }
            }
        }
        return Summary(groups: groups, recovery: recovery)
    }
}

public extension WorkAttempt.SessionAction {
    static func from(_ mode: GraphSession.Mode) -> WorkAttempt.SessionAction {
        switch mode {
        case .fresh: return .fresh
        case .create: return .create
        case .resume: return .resume
        case .projectResume: return .projectResume
        }
    }
}
