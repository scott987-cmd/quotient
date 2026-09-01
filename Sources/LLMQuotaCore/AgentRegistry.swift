import Foundation

/// 跨机 Agent 注册事实。每台机器只写自己的文件，同名机器和同名 Runner 都以
/// `(machineID, runnerID)` 区分；接收方机器由问题事件固定，不能靠显示名猜。
public struct AgentRegistration: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var machineID: String
    public var machineName: String
    public var runnerID: String
    public var platform: Platform
    public var canConsult: Bool
    public var updatedAt: Date

    public init(machineID: String, machineName: String, runnerID: String,
                platform: Platform, canConsult: Bool, updatedAt: Date = Date()) {
        schemaVersion = 1; self.machineID = machineID; self.machineName = machineName
        self.runnerID = runnerID; self.platform = platform
        self.canConsult = canConsult; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? "unknown"
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? "?"
        runnerID = try c.decodeIfPresent(String.self, forKey: .runnerID) ?? "unknown"
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? .codex
        canConsult = try c.decodeIfPresent(Bool.self, forKey: .canConsult) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public enum AgentRegistry {
    public static var directoryOverride: URL?
    public static let staleAfter: TimeInterval = 3600

    public static var directory: URL {
        directoryOverride
            ?? Paths.sharedRoot.appendingPathComponent("agent-registry", isDirectory: true)
    }

    public static func publish(_ registrations: [AgentRegistration],
                               machineID: String = Paths.machineID()) throws {
        guard registrations.allSatisfy({ $0.machineID == machineID }) else {
            throw NSError(domain: "AgentRegistry", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不能替另一台机器注册 Agent"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SnapshotCoding.prettyEncoder().encode(registrations)
        guard ICloudSafe.write(data, to: directory.appendingPathComponent(safe(machineID) + ".json")) else {
            throw NSError(domain: "AgentRegistry", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Agent 注册表写入失败"])
        }
    }

    public static func publishLocal(
        runners: [AgentRunner] = RunnerRegistry.all,
        machineID: String = Paths.machineID(), machineName: String = Paths.machineName(),
        now: Date = Date()
    ) throws {
        let registrations = runners.filter { $0.isAvailable }.map {
            AgentRegistration(machineID: machineID, machineName: machineName,
                              runnerID: $0.runnerID, platform: $0.platform,
                              canConsult: AgentConsultation.supportsReadOnlyConsultation($0),
                              updatedAt: now)
        }
        try publish(registrations, machineID: machineID)
    }

    public static func all(now: Date = Date(), staleAfter: TimeInterval = staleAfter)
        -> [AgentRegistration] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        var byIdentity: [String: AgentRegistration] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = ICloudSafe.read(file),
                  let items = try? SnapshotCoding.decoder().decode([AgentRegistration].self, from: data)
            else { continue }
            for item in items where now.timeIntervalSince(item.updatedAt) <= staleAfter {
                let key = item.machineID + "|" + item.runnerID
                if byIdentity[key] == nil || byIdentity[key]!.updatedAt < item.updatedAt {
                    byIdentity[key] = item
                }
            }
        }
        return byIdentity.values.sorted {
            if $0.runnerID != $1.runnerID { return $0.runnerID < $1.runnerID }
            return $0.machineID < $1.machineID
        }
    }

    private static func safe(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
