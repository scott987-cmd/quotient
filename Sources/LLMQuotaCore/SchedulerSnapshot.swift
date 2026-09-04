import Foundation

/// 一轮派发使用的不可变输入和结果。调度器只从这份快照领取任务；摄入、手机
/// 操作或后台维护随后写入的新 revision 留到下一轮，不能在半轮中改变选择。
public struct SchedulerSnapshot: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle
        case running
        case waiting
        case dispatching
        case paused
    }

    public struct TaskHead: Codable, Sendable, Equatable {
        public var id: String
        public var rev: Int
        public var repo: String
        public var ownerRunnerID: String?

        public init(task: WorkTask) {
            id = task.id
            rev = task.rev
            repo = task.repo
            ownerRunnerID = task.ownerRunnerID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
            repo = try c.decode(String.self, forKey: .repo)
            ownerRunnerID = try c.decodeIfPresent(String.self, forKey: .ownerRunnerID)
        }
    }

    public var version: Int
    public var id: String
    public var createdAt: Date
    public var machineID: String
    public var configVersion: String
    public var executionMode: ProjectExecutionScope.ExecutionMode
    public var focusedRepo: String?
    public var maxConcurrentTasks: Int
    /// 协调器最后一轮到底在做什么。它是“任务为什么没启动”的权威解释，
    /// 不能再让客户端从 queued/running 数量自行猜。
    public var state: State
    public var summary: String
    public var pendingTaskCount: Int
    public var runningTaskCount: Int
    public var heldTaskCount: Int
    public var ready: [TaskHead]
    public var active: [LocalWorkerSlotPlanner.Active]
    public var decisions: [LocalWorkerSlotPlanner.Decision]

    public init(
        scope: ProjectExecutionScope,
        ready: [WorkTask],
        active: [LocalWorkerSlotPlanner.Active],
        plan: LocalWorkerSlotPlanner.Plan,
        maxConcurrentTasks: Int,
        allTasks: [WorkTask]? = nil,
        heldTaskCount: Int = 0,
        stateOverride: State? = nil,
        summaryOverride: String? = nil,
        machineID: String = Paths.machineID(),
        createdAt: Date = Date()
    ) {
        version = 1
        id = UUID().uuidString.lowercased()
        self.createdAt = createdAt
        self.machineID = machineID
        executionMode = scope.mode
        focusedRepo = scope.allowedRepo
        self.maxConcurrentTasks = maxConcurrentTasks
        let visibleTasks = allTasks ?? ready
        pendingTaskCount = visibleTasks.filter {
            $0.pausedAt == nil && ($0.state == .queued || $0.state == .blocked)
        }.count
        runningTaskCount = visibleTasks.filter { $0.state == .running }.count
        self.heldTaskCount = heldTaskCount
        self.ready = ready.map(TaskHead.init)
        self.active = active
        decisions = plan.decisions
        if let stateOverride {
            state = stateOverride
        } else if !plan.selected.isEmpty {
            state = .dispatching
        } else if runningTaskCount > 0 || !active.isEmpty {
            state = .running
        } else if pendingTaskCount > 0 || !ready.isEmpty || heldTaskCount > 0 {
            state = .waiting
        } else {
            state = .idle
        }
        if let summaryOverride {
            summary = summaryOverride
        } else {
            switch state {
            case .idle:
                summary = "当前没有待执行任务"
            case .running:
                summary = "已有 \(max(runningTaskCount, active.count)) 个真实执行进程"
            case .waiting:
                if heldTaskCount > 0 {
                    summary = "有 \(heldTaskCount) 个任务处于短暂派发冷却"
                } else if let reason = decisions.first(where: { !$0.selected })?.reason {
                    summary = reason
                } else {
                    summary = "有 \(pendingTaskCount) 个任务等待依赖或门禁"
                }
            case .dispatching:
                summary = "本轮将启动 \(plan.selected.count) 个任务"
            case .paused:
                summary = "协调器已暂停派发"
            }
        }
        configVersion = Self.stableVersion(
            mode: scope.mode, focusedRepo: scope.allowedRepo,
            maxConcurrentTasks: maxConcurrentTasks)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        machineID = try c.decode(String.self, forKey: .machineID)
        configVersion = try c.decode(String.self, forKey: .configVersion)
        executionMode = try c.decode(
            ProjectExecutionScope.ExecutionMode.self, forKey: .executionMode)
        focusedRepo = try c.decodeIfPresent(String.self, forKey: .focusedRepo)
        maxConcurrentTasks = try c.decodeIfPresent(
            Int.self, forKey: .maxConcurrentTasks) ?? 1
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .waiting
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? "旧版未记录原因"
        pendingTaskCount = try c.decodeIfPresent(Int.self, forKey: .pendingTaskCount)
            ?? (try c.decodeIfPresent([TaskHead].self, forKey: .ready)?.count ?? 0)
        runningTaskCount = try c.decodeIfPresent(Int.self, forKey: .runningTaskCount) ?? 0
        heldTaskCount = try c.decodeIfPresent(Int.self, forKey: .heldTaskCount) ?? 0
        ready = try c.decodeIfPresent([TaskHead].self, forKey: .ready) ?? []
        active = try c.decodeIfPresent(
            [LocalWorkerSlotPlanner.Active].self, forKey: .active) ?? []
        decisions = try c.decodeIfPresent(
            [LocalWorkerSlotPlanner.Decision].self, forKey: .decisions) ?? []
    }

    private static func stableVersion(
        mode: ProjectExecutionScope.ExecutionMode,
        focusedRepo: String?,
        maxConcurrentTasks: Int
    ) -> String {
        let source = [mode.rawValue, focusedRepo ?? "-", String(maxConcurrentTasks)]
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    fileprivate func hasSameMeaning(as other: SchedulerSnapshot) -> Bool {
        state == other.state && summary == other.summary
            && pendingTaskCount == other.pendingTaskCount
            && runningTaskCount == other.runningTaskCount
            && heldTaskCount == other.heldTaskCount
            && configVersion == other.configVersion
            && maxConcurrentTasks == other.maxConcurrentTasks
            && ready == other.ready && active == other.active
            && decisions == other.decisions
    }
}

public enum SchedulerSnapshotStore {
    public static var file: URL {
        Paths.appSupport.appendingPathComponent("scheduler-snapshots.jsonl")
    }

    public static var currentFile: URL {
        Paths.appSupport.appendingPathComponent("scheduler-current.json")
    }

    @discardableResult
    public static func save(_ snapshot: SchedulerSnapshot) throws -> SchedulerSnapshot {
        try Paths.ensureDirectories()
        let encoded = try SnapshotCoding.encoder().encode(snapshot)
        let previous = current()
        // current 是心跳：即使状态没变也刷新时间。JSONL 只留状态转换，避免
        // 5 秒一轮的协调器把另一份账本也写成上百 MB。
        guard ICloudSafe.write(encoded, to: currentFile) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard previous?.hasSameMeaning(as: snapshot) != true else { return snapshot }

        var data = encoded
        data.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return snapshot
    }

    public static func latest() -> SchedulerSnapshot? {
        if let current = current() { return current }
        guard let data = ICloudSafe.read(file) else { return nil }
        let decoder = SnapshotCoding.decoder()
        return data.split(separator: UInt8(ascii: "\n")).reversed().lazy
            .compactMap { try? decoder.decode(SchedulerSnapshot.self, from: Data($0)) }
            .first
    }

    private static func current() -> SchedulerSnapshot? {
        guard let data = try? Data(contentsOf: currentFile) else { return nil }
        return try? SnapshotCoding.decoder().decode(SchedulerSnapshot.self, from: data)
    }
}
