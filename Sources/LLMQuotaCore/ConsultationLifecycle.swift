import Foundation

/// 一条定向咨询由接收机器上的一次性 launchd job 执行。它不属于当前模型任务的
/// 子进程，因此 Coordinator 换版、主任务退出或提问者额度耗尽都不会把回答链截断。
public struct ConsultationJobSpec: Equatable, Sendable {
    public var questionID: String
    public var machineID: String
    public var executable: String
    public var logPath: String

    public init(questionID: String, machineID: String, executable: String, logPath: String) {
        self.questionID = questionID; self.machineID = machineID
        self.executable = executable; self.logPath = logPath
    }

    public var label: String {
        let raw = "com.llmquotabar.consultation.\(machineID).\(questionID)"
        return String(raw.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-"
        })
    }
}

public final class ConsultationJobLauncher {
    public typealias Launchctl = ([String]) -> Int32
    private let launchctl: Launchctl

    private struct Record: Codable {
        var schemaVersion: Int
        var questionID: String
        var machineID: String
        var label: String
        var plistPath: String
        var createdAt: Date

        init(spec: ConsultationJobSpec, plistPath: String) {
            schemaVersion = 1
            questionID = spec.questionID; machineID = spec.machineID
            label = spec.label; self.plistPath = plistPath; createdAt = Date()
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            questionID = try c.decodeIfPresent(String.self, forKey: .questionID) ?? "unknown"
            machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? "unknown"
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? "unknown"
            plistPath = try c.decodeIfPresent(String.self, forKey: .plistPath) ?? ""
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        }
    }

    public init() { launchctl = Self.systemLaunchctl }
    public init(launchctl: @escaping Launchctl) { self.launchctl = launchctl }

    public static func programArguments(for spec: ConsultationJobSpec) -> [String] {
        [spec.executable, "collaboration", "respond", spec.questionID]
    }

    public static func propertyListData(for spec: ConsultationJobSpec) throws -> Data {
        let plist: [String: Any] = [
            "Label": spec.label,
            "ProgramArguments": programArguments(for: spec),
            "EnvironmentVariables": ["LLMQ_CONSULTATION_WORKER": "1"],
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

    @discardableResult
    public func launch(_ spec: ConsultationJobSpec) throws -> Bool {
        try FileManager.default.createDirectory(
            at: Self.jobsDirectory, withIntermediateDirectories: true)
        let log = URL(fileURLWithPath: spec.logPath)
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let plist = Self.jobsDirectory.appendingPathComponent(spec.label + ".plist")
        let record = Self.jobsDirectory.appendingPathComponent(spec.label + ".json")
        // 已有记录表示本机已经派过，不能每个 tick 再消耗一次模型额度。
        if FileManager.default.fileExists(atPath: record.path) { return false }
        guard ICloudSafe.write(try Self.propertyListData(for: spec), to: plist),
              ICloudSafe.write(try JSONEncoder().encode(
                Record(spec: spec, plistPath: plist.path)), to: record)
        else { throw Self.error(1, "咨询执行器清单写盘失败") }
        let status = launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: plist)
            try? FileManager.default.removeItem(at: record)
            return false
        }
        return true
    }

    /// 只处理事件明确指定给本机的问题。没有 recipientMachineID 的旧事件不自动
    /// 猜测接收方，避免两台机器同时回答并重复扣额度。
    @discardableResult
    public func dispatchPending(events: [CollaborationEvent], executable: String,
                                machineID: String = Paths.machineID()) -> Int {
        let answered = Set(events.compactMap { event in
            event.kind == .answer ? event.replyTo : nil
        })
        let failed = Set(events.compactMap { event in
            event.id.hasPrefix("consultation-failure:") ? event.replyTo : nil
        })
        var launched = 0
        for question in events where question.kind == .question
            && question.recipientMachineID == machineID
            && !answered.contains(question.id) && !failed.contains(question.id) {
            let safe = String(question.id.map {
                $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-"
            })
            let log = Paths.appSupport.appendingPathComponent(
                "logs/consultation-" + safe + ".log").path
            let spec = ConsultationJobSpec(
                questionID: question.id, machineID: machineID,
                executable: executable, logPath: log)
            if (try? launch(spec)) == true { launched += 1 }
        }
        return launched
    }

    @discardableResult
    public func cleanupFinished(events: [CollaborationEvent], now: Date = Date()) -> Int {
        let terminal = Set(events.compactMap { event -> String? in
            if event.kind == .answer { return event.replyTo }
            if event.id.hasPrefix("consultation-failure:") { return event.replyTo }
            return nil
        })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.jobsDirectory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            let stale = now.timeIntervalSince(record.createdAt) > 15 * 60
            guard terminal.contains(record.questionID) || stale else { continue }
            let target = "gui/\(getuid())/\(record.label)"
            let loaded = launchctl(["print", target]) == 0
            if loaded && launchctl(["bootout", target]) != 0 { continue }
            if stale, !terminal.contains(record.questionID),
               let question = events.first(where: {
                   $0.id == record.questionID && $0.kind == .question
               }) {
                _ = try? CollaborationStore.publish(CollaborationEvent(
                    id: "consultation-failure:" + record.questionID + ":" + record.machineID,
                    project: question.project, taskID: question.taskID,
                    graphID: question.graphID, senderRunnerID: "consultation-executor",
                    senderMachineID: record.machineID,
                    recipientRunnerID: question.senderRunnerID, kind: .finding,
                    summary: "咨询独立进程 15 分钟内未形成回答，已停止自动重试",
                    replyTo: record.questionID))
            }
            try? FileManager.default.removeItem(atPath: record.plistPath)
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }

    private static var jobsDirectory: URL {
        Paths.appSupport.appendingPathComponent("consultation-jobs", isDirectory: true)
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

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "ConsultationJobLauncher", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
