import Foundation

/// 共享配置的不可变版本账。
///
/// iCloud 文件没有 CAS，mtime 也不是 revision。这里不再让多台机器直接争写同一个
/// 配置文件：每次修改先追加一条唯一事件，原文件只作为旧版本兼容视图。同步发生冲突时
/// 两条事件都会保留，选择规则确定，失败修改也会留下可见冲突记录。
public enum SharedConfigJournal {
    public struct Snapshot: Sendable {
        public var data: Data?
        public var revision: Int
        public var entryID: String?
    }

    public struct StaleRevision: Error, Equatable, Sendable {
        public var document: String
        public var expected: Int
        public var actual: Int
    }

    public struct Conflict: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var id: String
        public var document: String
        public var expectedRevision: Int
        public var actualRevision: Int
        public var writerMachineID: String
        public var createdAt: Date

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            document = try c.decodeIfPresent(String.self, forKey: .document) ?? "unknown"
            expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision) ?? 0
            actualRevision = try c.decodeIfPresent(Int.self, forKey: .actualRevision) ?? 0
            writerMachineID = try c.decodeIfPresent(String.self, forKey: .writerMachineID) ?? "unknown"
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        }

        public init(id: String = UUID().uuidString.lowercased(), document: String,
                    expectedRevision: Int, actualRevision: Int,
                    writerMachineID: String, createdAt: Date = Date()) {
            schemaVersion = 1; self.id = id; self.document = document
            self.expectedRevision = expectedRevision; self.actualRevision = actualRevision
            self.writerMachineID = writerMachineID; self.createdAt = createdAt
        }
    }

    private struct Entry: Codable, Sendable {
        var schemaVersion: Int
        var id: String
        var document: String
        var revision: Int
        var baseRevision: Int
        var writerMachineID: String
        var createdAt: Date
        var payload: Data

        init(document: String, revision: Int, baseRevision: Int,
             writerMachineID: String, payload: Data) {
            schemaVersion = 1
            id = UUID().uuidString.lowercased()
            self.document = document; self.revision = revision
            self.baseRevision = baseRevision; self.writerMachineID = writerMachineID
            createdAt = Date(); self.payload = payload
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            document = try c.decodeIfPresent(String.self, forKey: .document) ?? "unknown"
            revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
            baseRevision = try c.decodeIfPresent(Int.self, forKey: .baseRevision) ?? max(0, revision - 1)
            writerMachineID = try c.decodeIfPresent(String.self, forKey: .writerMachineID) ?? "unknown"
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
            payload = try c.decodeIfPresent(Data.self, forKey: .payload) ?? Data()
        }
    }

    public static var directoryOverride: URL?
    private static let processLock = NSLock()

    public static var directory: URL {
        directoryOverride
            ?? Paths.sharedRoot.appendingPathComponent("config-journal", isDirectory: true)
    }

    public static func snapshot(document: String, compatibilityFile: URL) -> Snapshot {
        guard shouldJournal(compatibilityFile) else {
            return Snapshot(data: ICloudSafe.read(compatibilityFile), revision: 0, entryID: nil)
        }
        let matching = entries().filter { $0.document == document }
        if let head = matching.max(by: entryOrder) {
            return Snapshot(data: head.payload, revision: head.revision, entryID: head.id)
        }
        return Snapshot(data: ICloudSafe.read(compatibilityFile), revision: 0, entryID: nil)
    }

    @discardableResult
    public static func commit(
        document: String, payload: Data, expectedRevision: Int,
        compatibilityFile: URL, writerMachineID: String = Paths.machineID()
    ) throws -> Int {
        guard shouldJournal(compatibilityFile) else {
            guard expectedRevision == 0 else {
                throw StaleRevision(document: document, expected: expectedRevision, actual: 0)
            }
            guard ICloudSafe.write(payload, to: compatibilityFile) else {
                throw NSError(domain: "SharedConfigJournal", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "测试/本地配置写入失败"])
            }
            return 0
        }
        processLock.lock(); defer { processLock.unlock() }
        let lease = LocalExecutionLease(
            scope: .repo, key: "shared-config:" + document,
            root: directory.appendingPathComponent("locks", isDirectory: true))
        guard lease.acquire() else {
            throw NSError(domain: "SharedConfigJournal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "共享配置正在被另一个本机进程修改"])
        }
        defer { lease.release() }

        let current = snapshot(document: document, compatibilityFile: compatibilityFile)
        guard current.revision == expectedRevision else {
            let conflict = Conflict(document: document, expectedRevision: expectedRevision,
                                    actualRevision: current.revision,
                                    writerMachineID: writerMachineID)
            try append(conflict: conflict)
            throw StaleRevision(document: document, expected: expectedRevision,
                                actual: current.revision)
        }
        let entry = Entry(document: document, revision: current.revision + 1,
                          baseRevision: current.revision,
                          writerMachineID: writerMachineID, payload: payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let eventFile = directory.appendingPathComponent(
            "entry--\(safe(document))--r\(entry.revision)--\(safe(writerMachineID))--\(entry.id).json")
        let data = try SnapshotCoding.prettyEncoder().encode(entry)
        guard ICloudSafe.write(data, to: eventFile) else {
            throw NSError(domain: "SharedConfigJournal", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "共享配置版本事件写入失败"])
        }
        // 原文件只给旧二进制和手机读。新版本的事实来源是上面的不可变事件。
        guard ICloudSafe.write(payload, to: compatibilityFile) else {
            throw NSError(domain: "SharedConfigJournal", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "配置版本已保存，但兼容视图写入失败；下轮会从版本账恢复"])
        }
        return entry.revision
    }

    public static func conflicts(document: String) -> [Conflict] {
        let files = regularFiles().filter { $0.lastPathComponent.hasPrefix("conflict--") }
        var out = files.compactMap { ICloudSafe.read($0) }
            .compactMap { try? SnapshotCoding.decoder().decode(Conflict.self, from: $0) }
            .filter { $0.document == document }
        // 两台离线机器可能都从 revision 0 成功写出 revision 1；当时谁也看不见
        // 对方，所以不可能预先追加 stale 事件。镜像做集合并集后，在读取侧识别
        // 同 base 的兄弟事件，不能让确定性选赢家变成“静默丢了另一台的修改”。
        let siblings = Dictionary(grouping: entries().filter { $0.document == document }) {
            "\($0.baseRevision)|\($0.revision)"
        }
        for group in siblings.values where group.count > 1 {
            let sorted = group.sorted(by: entryOrder)
            guard let winner = sorted.last else { continue }
            for loser in sorted.dropLast() {
                out.append(Conflict(
                    id: "concurrent-" + loser.id, document: document,
                    expectedRevision: loser.baseRevision,
                    actualRevision: winner.revision,
                    writerMachineID: loser.writerMachineID,
                    createdAt: max(loser.createdAt, winner.createdAt)))
            }
        }
        var unique: [String: Conflict] = [:]
        for conflict in out { unique[conflict.id] = conflict }
        return unique.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }

    private static func entries() -> [Entry] {
        regularFiles().filter { $0.lastPathComponent.hasPrefix("entry--") }
            .compactMap { ICloudSafe.read($0) }
            .compactMap { try? SnapshotCoding.decoder().decode(Entry.self, from: $0) }
    }

    private static func entryOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        // 同一 base 的跨机并发没有可靠时钟；用稳定 ID 决胜，同时两条原始事件都保留。
        if lhs.writerMachineID != rhs.writerMachineID {
            return lhs.writerMachineID < rhs.writerMachineID
        }
        return lhs.id < rhs.id
    }

    private static func append(conflict: Conflict) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "conflict--\(safe(conflict.document))--\(safe(conflict.writerMachineID))--\(conflict.id).json")
        let data = try SnapshotCoding.prettyEncoder().encode(conflict)
        guard ICloudSafe.write(data, to: file) else {
            throw NSError(domain: "SharedConfigJournal", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "共享配置冲突记录写入失败"])
        }
    }

    private static func regularFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    private static func safe(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func shouldJournal(_ compatibilityFile: URL) -> Bool {
        if directoryOverride != nil { return true }
        let root = Paths.sharedRoot.standardizedFileURL.path + "/"
        return compatibilityFile.standardizedFileURL.path.hasPrefix(root)
    }
}
