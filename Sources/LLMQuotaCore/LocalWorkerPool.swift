import Foundation

/// 工作循环把实际生效的槽位数留给 Presence 读取。`--slots` 是运行时参数，
/// 只按机型默认值上报会让跨机路由把一台已满的机器误判为空闲。
public enum WorkerCapacityStore {
    private struct Snapshot: Codable {
        var maxConcurrentTasks: Int
        var coordinatorPID: Int32
        var updatedAt: Date
    }

    public static var fileOverride: URL?
    private static var file: URL {
        fileOverride ?? Paths.appSupport.appendingPathComponent("worker-capacity.json")
    }

    public static func publish(maxConcurrentTasks: Int,
                               coordinatorPID: Int32 = getpid(),
                               now: Date = Date()) {
        let value = Snapshot(maxConcurrentTasks: min(8, max(1, maxConcurrentTasks)),
                             coordinatorPID: coordinatorPID, updatedAt: now)
        guard let data = try? SnapshotCoding.encoder().encode(value) else { return }
        _ = ICloudSafe.write(data, to: file)
    }

    /// 只有协调器进程仍活着的快照才算数。崩溃留下的文件不能永久占用容量事实。
    public static func current(now: Date = Date(), staleAfter: TimeInterval = 120) -> Int? {
        guard let data = try? Data(contentsOf: file),
              let value = try? SnapshotCoding.decoder().decode(Snapshot.self, from: data),
              value.coordinatorPID > 0, kill(value.coordinatorPID, 0) == 0,
              now.timeIntervalSince(value.updatedAt) <= staleAfter else { return nil }
        return value.maxConcurrentTasks
    }
}

/// 一台机器上的并发边界。
///
/// 协调器仍然只有一个；并发的是彼此隔离的 `llmq work run <taskID>` 子进程。
/// 同仓库继续串行，避免共享基线/稳定 worktree 互踩。
public enum LocalWorkerSlotPlanner {
    public struct Active: Equatable, Codable, Sendable {
        public var taskID: String
        public var repo: String

        public init(taskID: String, repo: String) {
            self.taskID = taskID
            self.repo = repo
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taskID = try c.decode(String.self, forKey: .taskID)
            repo = try c.decode(String.self, forKey: .repo)
        }
    }

    public struct Decision: Equatable, Codable, Sendable {
        public var taskID: String
        public var selected: Bool
        public var reason: String

        public init(taskID: String, selected: Bool, reason: String) {
            self.taskID = taskID
            self.selected = selected
            self.reason = reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taskID = try c.decode(String.self, forKey: .taskID)
            selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
            reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "未记录"
        }
    }

    public struct Plan: Sendable {
        public var selected: [WorkTask]
        public var decisions: [Decision]

        public init(selected: [WorkTask], decisions: [Decision]) {
            self.selected = selected
            self.decisions = decisions
        }
    }

    /// Mac mini 默认给两个槽；其他机器保持一个槽。都可由 `work loop --slots`
    /// 显式覆盖，避免把硬件名字当成不可改的产品规则。
    public static func defaultSlots(machineName: String) -> Int {
        let name = machineName.lowercased()
        return name.contains("mac mini") || name.contains("macmini") ? 2 : 1
    }

    /// 本轮可以启动的任务。已有 running（包括手动 `work run`）和本协调器
    /// 刚启动、尚未来得及落盘成 running 的子进程都会占槽、占仓库。
    public static func select(
        ready: [WorkTask],
        allTasks: [WorkTask],
        active: [Active],
        maxConcurrentTasks: Int
    ) -> [WorkTask] {
        plan(ready: ready, allTasks: allTasks, active: active,
             maxConcurrentTasks: maxConcurrentTasks).selected
    }

    /// 和 `select` 使用同一份状态、同一遍循环生成结果与解释，避免看板写一套
    /// “为什么没选”而调度器实际按另一套规则执行。
    public static func plan(
        ready: [WorkTask],
        allTasks: [WorkTask],
        active: [Active],
        maxConcurrentTasks: Int
    ) -> Plan {
        let limit = max(1, maxConcurrentTasks)
        let running = allTasks.filter { $0.state == .running }
        let occupiedIDs = Set(running.map(\.id) + active.map(\.taskID))
        let capacity = max(0, limit - occupiedIDs.count)
        guard capacity > 0 else {
            return Plan(selected: [], decisions: ready.map {
                Decision(taskID: $0.id, selected: false, reason: "本机执行槽已满")
            })
        }

        var busyRepos = Set(running.map { RepoLease.normalize($0.repo) })
        busyRepos.formUnion(active.map { RepoLease.normalize($0.repo) })
        let ownerByTaskID = Dictionary(uniqueKeysWithValues: allTasks.compactMap { task in
            task.ownerRunnerID.map { (task.id, $0) }
        })
        var busyOwnerRunnerIDs = Set(running.compactMap(\.ownerRunnerID))
        busyOwnerRunnerIDs.formUnion(active.compactMap { ownerByTaskID[$0.taskID] })
        let taskByID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        var busyResources = Set(running.flatMap(\.resourceClaims))
        busyResources.formUnion(active.flatMap { taskByID[$0.taskID]?.resourceClaims ?? [] })
        var selected: [WorkTask] = []
        var decisions: [Decision] = []
        for task in ready {
            if occupiedIDs.contains(task.id) {
                decisions.append(Decision(
                    taskID: task.id, selected: false, reason: "任务已有执行进程"))
                continue
            }
            // 已形成上下文的任务等自己的 owner 空闲；不能因为并发槽新增，
            // 反而把它交给另一个 Agent 从零认识项目。
            if let owner = task.ownerRunnerID, busyOwnerRunnerIDs.contains(owner) {
                decisions.append(Decision(
                    taskID: task.id, selected: false,
                    reason: "原 Owner \(owner) 正在执行另一任务"))
                continue
            }
            let repo = RepoLease.normalize(task.repo)
            guard !busyRepos.contains(repo) else {
                decisions.append(Decision(
                    taskID: task.id, selected: false, reason: "同项目已有任务执行中"))
                continue
            }
            let conflicts = Set(task.resourceClaims).intersection(busyResources)
            guard conflicts.isEmpty else {
                decisions.append(Decision(
                    taskID: task.id, selected: false,
                    reason: "独占资源正在使用：" + conflicts.sorted().joined(separator: "、")))
                continue
            }
            guard selected.count < capacity else {
                decisions.append(Decision(
                    taskID: task.id, selected: false, reason: "本轮可用执行槽已分配完"))
                continue
            }
            selected.append(task)
            decisions.append(Decision(
                taskID: task.id, selected: true, reason: "项目、Owner 与执行槽均可用"))
            busyRepos.insert(repo)
            busyResources.formUnion(task.resourceClaims)
            if let owner = task.ownerRunnerID { busyOwnerRunnerIDs.insert(owner) }
        }
        return Plan(selected: selected, decisions: decisions)
    }
}

/// 跨线程、跨进程的本机执行租约。
///
/// 任务账本里的 `running` 是可观察状态，不是原子锁：两个进程可能同时读到
/// queued。这里用内核 `flock` 补上那一小段竞态窗口。进程被 kill -9 后锁也会
/// 自动释放，不会留下永久“占用中”。
public final class LocalExecutionLease {
    public enum Scope: String, Sendable { case repo, runner, resource }

    private let url: URL
    private var handle: FileHandle?

    public init(scope: Scope, key: String, root: URL? = nil) {
        let directory = root ?? Paths.appSupport.appendingPathComponent(
            "execution-leases", isDirectory: true)
        self.url = directory.appendingPathComponent(
            "\(scope.rawValue)-\(Self.stableKey(key)).lock")
    }

    public func acquire() -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return false }
        guard flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? file.close()
            return false
        }
        try? file.truncate(atOffset: 0)
        try? file.write(contentsOf: Data("\(getpid())\n".utf8))
        handle = file
        return true
    }

    public func release() {
        guard let file = handle else { return }
        flock(file.fileDescriptor, LOCK_UN)
        try? file.close()
        handle = nil
    }

    deinit { release() }

    /// FNV-1a 64-bit：只为得到稳定、安全的文件名，不承担密码学用途。
    private static func stableKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

/// 子进程执行槽。协调器只负责启动和回收，不共享 Agent 的会话内存、stdout
/// 或工作目录，因此一个任务崩溃不会污染另一个任务。
public final class LocalWorkerProcessPool {
    public struct Completion: Equatable, Sendable {
        public var taskID: String
        public var repo: String
        public var exitCode: Int32
        public var startedAt: Date
        public var endedAt: Date
        public var logPath: String
    }

    private struct Child {
        var taskID: String
        var repo: String
        var process: Process
        var log: FileHandle
        var logPath: String
        var startedAt: Date
    }

    private var children: [String: Child] = [:]

    public init() {}

    public var active: [LocalWorkerSlotPlanner.Active] {
        children.values.map { .init(taskID: $0.taskID, repo: $0.repo) }
    }

    public var count: Int { children.count }
    public var isEmpty: Bool { children.isEmpty }

    @discardableResult
    public func launch(
        taskID: String,
        repo: String,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        logURL: URL
    ) throws -> Bool {
        guard children[taskID] == nil else { return false }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        try log.write(contentsOf: Data(
            "\n=== slot start \(ISO8601DateFormatter().string(from: Date())) pid pending ===\n".utf8))

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }
        children[taskID] = Child(
            taskID: taskID, repo: repo, process: process, log: log,
            logPath: logURL.path, startedAt: Date())
        return true
    }

    public func reap(now: Date = Date()) -> [Completion] {
        var completed: [Completion] = []
        for (id, child) in children where !child.process.isRunning {
            try? child.log.synchronize()
            try? child.log.close()
            completed.append(Completion(
                taskID: child.taskID, repo: child.repo,
                exitCode: child.process.terminationStatus,
                startedAt: child.startedAt, endedAt: now,
                logPath: child.logPath))
            children.removeValue(forKey: id)
        }
        return completed.sorted { $0.startedAt < $1.startedAt }
    }
}
