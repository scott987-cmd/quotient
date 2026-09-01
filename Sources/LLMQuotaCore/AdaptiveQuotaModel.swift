import Foundation

/// 把额度学习从一次性的 `llmq learn --apply` 变成采集主链里的持续校准。
///
/// 学习值单独存放，绝不覆写 plans.json：官方事实始终优先，用户手填上限也
/// 始终优先。只有原本未知的窗口会在运行时采用一条新鲜、可信的学习记录。
public enum AdaptiveQuotaModel {
    public enum Evidence: String, Codable, Sendable {
        case calibrated
        case ceiling
    }

    public struct Record: Codable, Sendable, Equatable {
        public var platform: Platform
        public var windowMinutes: Int
        public var metric: QuotaMetric
        public var limit: Double
        public var samples: Int
        public var confidence: Double
        public var evidence: Evidence
        public var updatedAt: Date
    }

    struct Document: Codable {
        var schemaVersion: Int = 1
        var refreshedAt: Date
        var records: [Record]
        /// 同一批历史样本会被每次后台刷新重复看见；记住指纹，避免把重复扫描
        /// 伪装成“样本越来越多、置信度越来越高”。
        var evidenceFingerprints: [String: String] = [:]

        init(
            schemaVersion: Int = 1, refreshedAt: Date, records: [Record],
            evidenceFingerprints: [String: String] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.refreshedAt = refreshedAt
            self.records = records
            self.evidenceFingerprints = evidenceFingerprints
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, refreshedAt, records, evidenceFingerprints
        }

        /// 兼容早期没有指纹字段的派生文件；升级后仍可继续学习，而不是把整份
        /// 历史校准当成损坏数据丢弃。
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            refreshedAt = try values.decodeIfPresent(Date.self, forKey: .refreshedAt)
                ?? .distantPast
            records = try values.decodeIfPresent([Record].self, forKey: .records) ?? []
            evidenceFingerprints = try values.decodeIfPresent(
                [String: String].self, forKey: .evidenceFingerprints) ?? [:]
        }
    }

    public typealias CeilingEstimate = (
        platform: Platform, windowMinutes: Int, windowLabel: String,
        metric: String, value: Double, samples: Int
    )

    nonisolated(unsafe) public static var pathOverride: URL?
    public static let refreshInterval: TimeInterval = 20 * 60
    public static let maxAge: TimeInterval = 45 * 86400

    static var path: URL {
        pathOverride ?? Paths.appSupport.appendingPathComponent("adaptive-quota-model.json")
    }

    public static func load() -> [Record] {
        loadDocument()?.records ?? []
    }

    /// 合并新观测。可信反解做加权校准；撞顶记录是硬下界，只允许把上限往上推。
    @discardableResult
    public static func update(
        estimates: [LimitLearner.Estimate], ceilings: [CeilingEstimate], now: Date
    ) -> [Record] {
        withLock {
            let previous = loadDocument()
            var byKey: [String: Record] = [:]
            for record in previous?.records ?? [] { byKey[key(record)] = record }
            var fingerprints = previous?.evidenceFingerprints ?? [:]
            for estimate in estimates where estimate.method == .calibrated
                && estimate.isTrustworthy {
                let candidate = Record(
                    platform: estimate.platform, windowMinutes: estimate.windowMinutes,
                    metric: estimate.metric, limit: estimate.value,
                    samples: estimate.samples,
                    confidence: max(0, min(1, 1 - (estimate.spread ?? 1))),
                    evidence: .calibrated, updatedAt: now)
                let fingerprintKey = key(candidate) + "|calibrated"
                let fingerprint = "\(estimate.samples)|\(estimate.value)|\(estimate.spread ?? -1)"
                guard fingerprints[fingerprintKey] != fingerprint else { continue }
                merge(candidate, into: &byKey)
                fingerprints[fingerprintKey] = fingerprint
            }
            for ceiling in ceilings {
                guard let metric = QuotaMetric(rawValue: ceiling.metric), ceiling.value > 0 else {
                    continue
                }
                let candidate = Record(
                    platform: ceiling.platform, windowMinutes: ceiling.windowMinutes,
                    metric: metric, limit: ceiling.value, samples: ceiling.samples,
                    confidence: 0.9, evidence: .ceiling, updatedAt: now)
                let fingerprintKey = key(candidate) + "|ceiling"
                let fingerprint = "\(ceiling.samples)|\(ceiling.value)"
                guard fingerprints[fingerprintKey] != fingerprint else { continue }
                merge(candidate, into: &byKey)
                fingerprints[fingerprintKey] = fingerprint
            }
            let records = byKey.values.sorted(by: recordOrder)
            save(Document(refreshedAt: now, records: records,
                          evidenceFingerprints: fingerprints))
            return records
        }
    }

    /// 采集频率很高，学习无需每轮重扫日志。20 分钟一次，并把“本轮无新样本”
    /// 也记作刷新，避免数据不足时每 30 秒重复扫描。
    @discardableResult
    public static func refreshIfNeeded(now: Date = Date()) throws -> [Record] {
        if let document = loadDocument(),
           now.timeIntervalSince(document.refreshedAt) < refreshInterval {
            return document.records
        }
        let scan = try Collector().scanRaw(now: now)
        return update(estimates: LimitLearner.learn(from: scan, now: now),
                      ceilings: QuotaCeiling.estimates(), now: now)
    }

    /// 仅填补未知窗口。运行时生成副本，不改持久化套餐配置。
    public static func applying(to config: PlansConfig, now: Date = Date()) -> PlansConfig {
        var result = config
        let records = load().filter {
            now.timeIntervalSince($0.updatedAt) <= maxAge && $0.limit > 0
        }
        for pi in result.plans.indices {
            for li in result.plans[pi].limits.indices {
                let current = result.plans[pi].limits[li]
                guard current.limit == nil
                        || current.hint?.hasPrefix("持续学习") == true else { continue }
                let matches = records.filter {
                    $0.platform == result.plans[pi].platform
                        && $0.windowMinutes == current.windowMinutes
                }.sorted {
                    if $0.evidence != $1.evidence {
                        return $0.evidence == .calibrated
                    }
                    if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                    return $0.updatedAt > $1.updatedAt
                }
                guard let learned = matches.first else { continue }
                result.plans[pi].limits[li].limit = learned.limit
                result.plans[pi].limits[li].metric = learned.metric
                result.plans[pi].limits[li].hint = "持续学习估算 · \(learned.samples) 个样本"
            }
        }
        return result
    }

    private static func merge(_ candidate: Record, into records: inout [String: Record]) {
        let k = key(candidate)
        guard let old = records[k] else {
            records[k] = candidate
            return
        }
        var next = candidate
        if candidate.evidence == .ceiling, old.evidence == .calibrated {
            // 撞顶样本只证明“至少用了这么多”，信息量低于完整百分比反解。
            // 保留校准证据和置信度，只用撞顶值抬高硬下界。
            next = old
            next.limit = max(old.limit, candidate.limit)
            next.samples = max(old.samples, candidate.samples)
            next.updatedAt = candidate.updatedAt
        } else if candidate.evidence == .ceiling {
            next.limit = max(old.limit, candidate.limit)
        } else if old.evidence == .calibrated {
            // 新批次是覆盖当前历史窗的重新拟合，并非与旧批次完全独立；
            // 用温和 EMA 校准，不能把同一批样本权重加两遍。
            let alpha = 0.35
            next.limit = old.limit * (1 - alpha) + candidate.limit * alpha
            next.confidence = old.confidence * (1 - alpha)
                + candidate.confidence * alpha
        } else {
            // 官方百分比反解比撞顶下界信息更完整，但不能低于已经真实撞过的量。
            next.limit = max(old.limit, candidate.limit)
        }
        next.samples = max(old.samples, candidate.samples)
        records[k] = next
    }

    private static func key(_ record: Record) -> String {
        "\(record.platform.rawValue)|\(record.windowMinutes)|\(record.metric.rawValue)"
    }

    private static func recordOrder(_ lhs: Record, _ rhs: Record) -> Bool {
        if lhs.platform != rhs.platform { return lhs.platform.sortIndex < rhs.platform.sortIndex }
        if lhs.windowMinutes != rhs.windowMinutes { return lhs.windowMinutes < rhs.windowMinutes }
        return lhs.metric.rawValue < rhs.metric.rawValue
    }

    private static func loadDocument() -> Document? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return SafeDecode.json(data, as: Document.self,
                               from: "adaptive-quota-model.json",
                               decoder: SnapshotCoding.decoder())
    }

    private static func save(_ document: Document) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? SnapshotCoding.prettyEncoder().encode(document) else { return }
        try? data.write(to: path, options: .atomic)
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        let lockPath = path.path + ".lock"
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        guard let handle = FileHandle(forUpdatingAtPath: lockPath) else { return body() }
        defer { try? handle.close() }
        flock(handle.fileDescriptor, LOCK_EX)
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        return body()
    }
}
