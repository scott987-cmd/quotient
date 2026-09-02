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
    /// 下面这些都是接收机器自报的执行事实。跨机路由不能拿“本机同名
    /// Runner”的能力去猜另一台机器，也不能只凭额度看板猜它装没装。
    public var canEdit: Bool
    public var canReadFiles: Bool
    public var mediaOnly: Bool
    public var reviewOnly: Bool
    public var canSeeMedia: Bool
    public var maxRisk: TaskProfile.Risk
    public var maxTier: TaskProfile.Tier
    public var isDispatcher: Bool
    public var isMuted: Bool
    /// 扣掉给人预留的比例后，调度器还能使用的额度。nil 表示平台没有
    /// 可比较的数值上限；0 表示当前不能再自动接活。
    public var quotaAvailableFraction: Double?
    /// 额度用尽、冷却或预留线命中时的明确原因。跨机选路不能把 nil
    /// 当成有额度，但也不能因某个平台不公布上限就永久排除它。
    public var quotaBlockedReason: String?
    public var updatedAt: Date

    public init(machineID: String, machineName: String, runnerID: String,
                platform: Platform, canConsult: Bool,
                canEdit: Bool = false, canReadFiles: Bool = false,
                mediaOnly: Bool = false, reviewOnly: Bool = false,
                canSeeMedia: Bool = false,
                maxRisk: TaskProfile.Risk = .safe,
                maxTier: TaskProfile.Tier = .trivial,
                isDispatcher: Bool = false, isMuted: Bool = false,
                quotaAvailableFraction: Double? = nil,
                quotaBlockedReason: String? = nil,
                updatedAt: Date = Date()) {
        schemaVersion = 2; self.machineID = machineID; self.machineName = machineName
        self.runnerID = runnerID; self.platform = platform
        self.canConsult = canConsult; self.canEdit = canEdit
        self.canReadFiles = canReadFiles; self.mediaOnly = mediaOnly
        self.reviewOnly = reviewOnly; self.canSeeMedia = canSeeMedia
        self.maxRisk = maxRisk; self.maxTier = maxTier
        self.isDispatcher = isDispatcher; self.isMuted = isMuted
        self.quotaAvailableFraction = quotaAvailableFraction
        self.quotaBlockedReason = quotaBlockedReason
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? "unknown"
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? "?"
        runnerID = try c.decodeIfPresent(String.self, forKey: .runnerID) ?? "unknown"
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? .codex
        canConsult = try c.decodeIfPresent(Bool.self, forKey: .canConsult) ?? false
        canEdit = try c.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
        canReadFiles = try c.decodeIfPresent(Bool.self, forKey: .canReadFiles) ?? false
        mediaOnly = try c.decodeIfPresent(Bool.self, forKey: .mediaOnly) ?? false
        reviewOnly = try c.decodeIfPresent(Bool.self, forKey: .reviewOnly) ?? false
        canSeeMedia = try c.decodeIfPresent(Bool.self, forKey: .canSeeMedia) ?? false
        maxRisk = try c.decodeIfPresent(TaskProfile.Risk.self, forKey: .maxRisk) ?? .safe
        maxTier = try c.decodeIfPresent(TaskProfile.Tier.self, forKey: .maxTier) ?? .trivial
        isDispatcher = try c.decodeIfPresent(Bool.self, forKey: .isDispatcher) ?? false
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        quotaAvailableFraction = try c.decodeIfPresent(
            Double.self, forKey: .quotaAvailableFraction)
        quotaBlockedReason = try c.decodeIfPresent(String.self, forKey: .quotaBlockedReason)
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
        let data = try SnapshotCoding.prettyEncoder().encode(
            registrations.filter { !$0.platform.isRetired })
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
        let history = TaskStore.all()
        let dashboard = LLMQuota.dashboard(now: now)
        let registrations = runners.filter { !$0.platform.isRetired && $0.isAvailable }.map {
            let role = AgentRoles.role(for: $0.platform)
            let quota = quotaFacts(for: $0.platform, dashboard: dashboard, now: now)
            let cooldown = CooldownLedger.active(
                platform: $0.platform, runnerID: $0.runnerID,
                capability: PlatformHealth.capability(for: $0).rawValue, now: now)
            return AgentRegistration(machineID: machineID, machineName: machineName,
                              runnerID: $0.runnerID, platform: $0.platform,
                              canConsult: AgentConsultation.supportsReadOnlyConsultation($0),
                              canEdit: $0.canEdit, canReadFiles: $0.canReadFiles,
                              mediaOnly: $0.mediaOnly, reviewOnly: $0.reviewOnly,
                              canSeeMedia: $0.canSeeMedia,
                              maxRisk: role.maxRisk,
                              maxTier: role.maxTier
                                ?? PlatformCapability.effectiveTier(
                                    for: $0.platform, history: history),
                              isDispatcher: AgentRoles.isDispatcher($0.platform),
                              isMuted: AgentRoles.isMuted($0.platform),
                              quotaAvailableFraction: quota.available,
                              quotaBlockedReason: cooldown.map {
                                  "\($0.cause.displayName)，\(Format.duration($0.remaining))后重试"
                              } ?? quota.blockedReason,
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
            for item in items where !item.platform.isRetired
                    && now.timeIntervalSince(item.updatedAt) <= staleAfter {
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

    private static func quotaFacts(for platform: Platform, dashboard: Dashboard,
                                   now: Date) -> (available: Double?, blockedReason: String?) {
        guard let report = dashboard.reports.first(where: { $0.platform == platform }) else {
            return (nil, nil)
        }
        if let exhausted = report.statuses.first(where: {
            $0.isFresh(now: now) && $0.health == .exhausted && !$0.advisory
        }) {
            return (0, "\(exhausted.label)额度已用尽")
        }
        let configured = report.statuses.compactMap { status -> (QuotaStatus, Double)? in
            guard !status.advisory, status.isFresh(now: now),
                  let used = status.usedFraction else { return nil }
            return (status, used)
        }
        guard let tightest = configured.max(by: { $0.1 < $1.1 }) else {
            return (nil, nil)
        }
        let reserve = AgentRoles.reserve(
            for: platform, default: WorkScheduler.defaultHumanReserve)
        let available = max(0, 1 - tightest.1 - reserve)
        if available <= 0 {
            return (0, "\(tightest.0.label)已触及调度预留线")
        }
        return (available, nil)
    }
}
