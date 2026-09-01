import Foundation

/// 已原子领取的模型任务由独立 launchd job 持有，不能再是 Coordinator 的普通
/// 子进程。这样控制面换版、崩溃或被 kickstart 时，真实模型进程仍然存活。
public struct DetachedExecutorSpec: Equatable, Sendable {
    public var taskID: String
    public var repo: String
    public var leaseID: String
    public var executable: String
    public var logPath: String

    public init(taskID: String, repo: String, leaseID: String,
                executable: String, logPath: String) {
        self.taskID = taskID
        self.repo = repo
        self.leaseID = leaseID
        self.executable = executable
        self.logPath = logPath
    }

    public var label: String {
        let raw = "com.llmquotabar.executor.\(taskID).\(leaseID)"
        return String(raw.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-"
        })
    }
}

public enum DetachedExecutorRegistry {
    /// Coordinator 重启后的唯一事实来源是持久化任务 lease/PID，不是上一进程的
    /// 内存 `Process` 对象。派发租约覆盖“submit 成功但 Executor 尚未 claim”的窗口。
    public static func active(
        tasks: [WorkTask], now: Date = Date(),
        processIsAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> [LocalWorkerSlotPlanner.Active] {
        tasks.compactMap { task in
            let running = task.state == .running
                && (task.runnerPID.map(processIsAlive) ?? true)
            let pending = task.state == .queued
                && task.dispatchLeaseID != nil
                && task.dispatchLeaseExpiresAt.map { $0 > now } == true
            guard running || pending else { return nil }
            return LocalWorkerSlotPlanner.Active(taskID: task.id, repo: task.repo)
        }
    }

    /// 首次升级阶段可能仍有旧 Coordinator 的普通子进程在跑。只有父进程已经
    /// 是 launchd 的 Executor 才能安全热重启；否则继续使用旧版在飞保护。
    public static func isIndependent(_ task: WorkTask) -> Bool {
        isIndependent(task, parentPID: systemParentPID)
    }

    public static func isIndependent(
        _ task: WorkTask, parentPID: (Int32) -> Int32?
    ) -> Bool {
        guard task.state == .running, let pid = task.runnerPID, pid > 1 else { return false }
        return parentPID(pid) == 1
    }

    private static func systemParentPID(_ pid: Int32) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(value)
    }
}

public final class DetachedExecutorLauncher {
    public typealias Launchctl = ([String]) -> Int32
    private let launchctl: Launchctl

    private struct Record: Codable {
        var taskID: String
        var leaseID: String
        var label: String
        var plistPath: String
        var createdAt: Date

        init(spec: DetachedExecutorSpec, plistPath: String, createdAt: Date = Date()) {
            taskID = spec.taskID
            leaseID = spec.leaseID
            label = spec.label
            self.plistPath = plistPath
            self.createdAt = createdAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taskID = try c.decode(String.self, forKey: .taskID)
            leaseID = try c.decode(String.self, forKey: .leaseID)
            label = try c.decode(String.self, forKey: .label)
            plistPath = try c.decode(String.self, forKey: .plistPath)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        }
    }

    public init() { launchctl = Self.systemLaunchctl }

    public init(launchctl: @escaping Launchctl) { self.launchctl = launchctl }

    public static func programArguments(for spec: DetachedExecutorSpec) -> [String] {
        [
            spec.executable, "work", "run", spec.taskID, "--slot-child",
            "--dispatch-lease", spec.leaseID,
        ]
    }

    /// `launchctl submit` 会隐式带 KeepAlive：任务正常退出后也会被再次拉起。
    /// 每个 lease 改用唯一的一次性 LaunchAgent，显式关闭 KeepAlive；Coordinator
    /// 换版不会杀掉它，任务终态后再由任意一代 Coordinator 卸载并清理。
    public static func propertyListData(for spec: DetachedExecutorSpec) throws -> Data {
        let plist: [String: Any] = [
            "Label": spec.label,
            "ProgramArguments": programArguments(for: spec),
            "EnvironmentVariables": ["LLMQ_SLOT_CHILD": "1"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ThrottleInterval": 60,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["com.llmquotabar.menubar"],
            "StandardOutPath": spec.logPath,
            "StandardErrorPath": spec.logPath,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func bootstrapArguments(plistPath: String) -> [String] {
        ["bootstrap", "gui/\(getuid())", plistPath]
    }

    @discardableResult
    public func launch(_ spec: DetachedExecutorSpec) throws -> Bool {
        let log = URL(fileURLWithPath: spec.logPath)
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let jobs = Self.jobsDirectory
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let plist = jobs.appendingPathComponent(spec.label + ".plist")
        let record = jobs.appendingPathComponent(spec.label + ".json")
        guard ICloudSafe.write(try Self.propertyListData(for: spec), to: plist),
              ICloudSafe.write(
                try JSONEncoder().encode(Record(spec: spec, plistPath: plist.path)),
                to: record)
        else {
            try? FileManager.default.removeItem(at: plist)
            try? FileManager.default.removeItem(at: record)
            throw NSError(
                domain: "DetachedExecutorLauncher", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "一次性执行器清单写盘失败"])
        }
        guard launchctl(Self.bootstrapArguments(plistPath: plist.path)) == 0 else {
            try? FileManager.default.removeItem(at: plist)
            try? FileManager.default.removeItem(at: record)
            return false
        }
        return true
    }

    /// 清理已经离开 running/有效派发租约的 job。卸载失败不删除记录，下一代
    /// Coordinator 会继续收口，避免留下无法追踪的 launchd 服务。
    @discardableResult
    public func cleanupFinished(tasks: [WorkTask], now: Date = Date()) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.jobsDirectory, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data)
            else { continue }
            let task = byID[record.taskID]
            let running = task?.state == .running
                && task?.dispatchLeaseID == record.leaseID
            let pending = task?.state == .queued
                && task?.dispatchLeaseID == record.leaseID
                && task?.dispatchLeaseExpiresAt.map { $0 > now } == true
            guard !running && !pending else { continue }
            let target = "gui/\(getuid())/\(record.label)"
            guard launchctl(["bootout", target]) == 0 else { continue }
            try? FileManager.default.removeItem(atPath: record.plistPath)
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }

    private static var jobsDirectory: URL {
        Paths.appSupport.appendingPathComponent("executor-jobs", isDirectory: true)
    }

    private static func systemLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Coordinator / Projector 的代际凭据。共享视图发布前必须重新核对本地权威代际；
/// 新版本激活后，旧进程即使从慢扫描中醒来，也不能再开始一次发布。
public enum PublicationGeneration {
    public enum Role: String, Codable, Sendable { case coordinator, projector }

    private struct Record: Codable, Sendable {
        var role: Role
        var id: String
        var pid: Int32
        var activatedAt: Date

        init(role: Role, id: String, pid: Int32, activatedAt: Date) {
            self.role = role
            self.id = id
            self.pid = pid
            self.activatedAt = activatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(Role.self, forKey: .role)
            id = try c.decode(String.self, forKey: .id)
            pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
            activatedAt = try c.decodeIfPresent(Date.self, forKey: .activatedAt) ?? .distantPast
        }
    }

    public struct Token: Sendable {
        public let role: Role
        public let id: String

        public var isCurrent: Bool { PublicationGeneration.current(role: role)?.id == id }

        @discardableResult
        public func commitIfCurrent(_ body: () -> Void) -> Bool {
            guard isCurrent else { return false }
            body()
            return true
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activePublicationToken: Token?

    private static func file(_ role: Role) -> URL {
        Paths.appSupport.appendingPathComponent(
            "lifecycle/\(role.rawValue)-generation.json")
    }

    @discardableResult
    public static func activate(role: Role, pid: Int32 = getpid(),
                                now: Date = Date()) throws -> Token {
        let record = Record(role: role, id: UUID().uuidString.lowercased(),
                            pid: pid, activatedAt: now)
        let target = file(role)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        guard ICloudSafe.write(data, to: target) else {
            throw NSError(domain: "PublicationGeneration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "代际凭据写盘失败"])
        }
        let token = Token(role: role, id: record.id)
        if role == .projector {
            lock.lock(); activePublicationToken = token; lock.unlock()
        }
        return token
    }

    private static func current(role: Role) -> Record? {
        guard let data = try? Data(contentsOf: file(role)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// 只有 Projector 进程会激活此进程内守卫。普通 CLI 的显式发布保持兼容；
    /// Projector 一旦被新代替换，所有后续共享写入统一拒绝。
    public static func allowsPublication() -> Bool {
        lock.lock(); let token = activePublicationToken; lock.unlock()
        return token?.isCurrent ?? true
    }

    public static func resetForTesting() {
        lock.lock(); activePublicationToken = nil; lock.unlock()
    }
}

/// 共享视图只由 Projector 重建。Coordinator/Executor 只写任务与事件事实；
/// iCloud、Git 扫描或移动端发布挂住时，最多损失一轮展示，不影响模型执行。
public enum ProjectorService {
    @discardableResult
    public static func publishAll(token: PublicationGeneration.Token) -> Bool {
        guard token.isCurrent else { return false }
        var published = false
        let dashboard = Watchdog.runLatest(
            "projector.dashboard", timeout: 30,
            prepare: { LLMQuota.dashboard() },
            commit: { dash in
                guard token.isCurrent else { return }
                Inbox.publishDashboard(dash)
                _ = TaskBoardStore.prune()
                Inbox.publishRepos()
            })
        if case .done = dashboard { published = true }

        guard token.isCurrent else { return false }
        _ = Review.publishDigests()
        let guarded = Showcase.defaultPublishers.map { publisher in
            { if token.isCurrent { publisher() } }
        }
        if Showcase.refresh(force: true, publishers: guarded) { published = true }
        return published && token.isCurrent
    }
}

/// Executor/Coordinator 对投影器的单向提示。它不是任务事实，只让独立 Projector
/// 尽快重建；丢失最多导致下一次周期刷新，不影响正确性。
public enum ProjectionInvalidation {
    private static var file: URL {
        Paths.appSupport.appendingPathComponent("lifecycle/projection-dirty")
    }

    public static func markDirty() {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = ICloudSafe.write(Data(UUID().uuidString.utf8), to: file)
    }

    public static var isDirty: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    public static func clear() { try? FileManager.default.removeItem(at: file) }
}
