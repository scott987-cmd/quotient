import Foundation

/// 一轮派发使用的不可变输入和结果。调度器只从这份快照领取任务；摄入、手机
/// 操作或后台维护随后写入的新 revision 留到下一轮，不能在半轮中改变选择。
public struct SchedulerSnapshot: Codable, Sendable {
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
    public var ready: [TaskHead]
    public var active: [LocalWorkerSlotPlanner.Active]
    public var decisions: [LocalWorkerSlotPlanner.Decision]

    public init(
        scope: ProjectExecutionScope,
        ready: [WorkTask],
        active: [LocalWorkerSlotPlanner.Active],
        plan: LocalWorkerSlotPlanner.Plan,
        maxConcurrentTasks: Int,
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
        self.ready = ready.map(TaskHead.init)
        self.active = active
        decisions = plan.decisions
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
}

public enum SchedulerSnapshotStore {
    public static var file: URL {
        Paths.appSupport.appendingPathComponent("scheduler-snapshots.jsonl")
    }

    @discardableResult
    public static func save(_ snapshot: SchedulerSnapshot) throws -> SchedulerSnapshot {
        try Paths.ensureDirectories()
        var data = try SnapshotCoding.encoder().encode(snapshot)
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
        guard let data = ICloudSafe.read(file) else { return nil }
        let decoder = SnapshotCoding.decoder()
        return data.split(separator: UInt8(ascii: "\n")).reversed().lazy
            .compactMap { try? decoder.decode(SchedulerSnapshot.self, from: Data($0)) }
            .first
    }
}
