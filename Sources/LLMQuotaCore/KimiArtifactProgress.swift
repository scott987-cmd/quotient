import CryptoKit
import Foundation

/// Reads only the selected workspace's Kimi session and current attempt's tool events.
/// A model response, waiting message, or file mtime alone is never progress.
public final class KimiArtifactProgress {
    private struct Cursor { var offset: UInt64 = 0; var partial = Data() }
    private struct Call { let time: Date; let paths: [URL] }
    private struct Artifact {
        var hash: String?
        var active: Bool
        let firstCallAt: Date
        var needsBaseline: Bool
        var observedStat: String?
    }
    private let workspace: URL
    private let home: URL
    private let startedAt: Date
    private let roots: [URL]
    private var session: URL?
    private var cursors: [URL: Cursor] = [:]
    private var calls: [String: Call] = [:]
    private var artifacts: [URL: Artifact] = [:]
    private var consumed = Set<String>()
    private var nextPoll = Date.distantPast
    private let pollInterval: TimeInterval
    private let maxFileBytes = 16 * 1_024 * 1_024
    private var hashBudget = 32 * 1_024 * 1_024
    private let extensions: Set<String> = ["json", "png", "jpg", "jpeg", "usdz", "blend", "mp4", "mov"]

    public init(workspace: String, startedAt: Date, kimiHome: URL? = nil,
                artifactRoots: [URL]? = nil, pollInterval: TimeInterval = 10) {
        self.workspace = URL(fileURLWithPath: workspace).resolvingSymlinksInPath()
        self.startedAt = startedAt
        self.home = kimiHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code")
        self.roots = (artifactRoots ?? [URL(fileURLWithPath: "/tmp"),
            FileManager.default.temporaryDirectory,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")])
            .map { $0.resolvingSymlinksInPath() }
        self.pollInterval = pollInterval
        session = findSession()
        // Do not replay old calls/results on resume, including old subagents.
        for wire in wireFiles() {
            cursors[wire] = Cursor(offset: fileSize(wire), partial: Data())
        }
    }

    /// Returns newly changed, small, local artifacts. Caller records them as automatic
    /// evidence, not as an Agent declaration of completion or a visual acceptance vote.
    public func poll(now: Date = Date()) -> [String] {
        guard now >= nextPoll else { return [] }
        nextPoll = now.addingTimeInterval(pollInterval)
        hashBudget = 32 * 1_024 * 1_024
        if session == nil { session = findSession() }
        var wireBudget = 1_024 * 1_024
        for wire in wireFiles() where wireBudget > 0 {
            var cursor = cursors[wire] ?? Cursor()
            let size = fileSize(wire)
            // Rotation/truncation must not reinterpret old data as new work.
            if size < cursor.offset { cursor = Cursor(offset: size, partial: Data()) }
            guard let handle = try? FileHandle(forReadingFrom: wire) else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: cursor.offset)
                let chunk = try handle.read(upToCount: min(wireBudget, 256 * 1_024)) ?? Data()
                cursor.offset += UInt64(chunk.count)
                wireBudget -= chunk.count
                cursor.partial.append(chunk)
                while let end = cursor.partial.firstIndex(of: 10) {
                    let line = cursor.partial.prefix(upTo: end)
                    consume(Data(line), wire: wire, now: now)
                    cursor.partial.removeSubrange(...end)
                }
                // Overlong records cannot grow the monitor without bound.
                if cursor.partial.count > 1_024 * 1_024 { cursor.partial.removeAll() }
                cursors[wire] = cursor
            } catch { continue }
        }
        var result: [String] = []
        for path in artifacts.keys.sorted(by: { $0.path < $1.path }) {
            guard var item = artifacts[path], item.active,
                  let attributes = attributes(path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified >= item.firstCallAt, modified <= now,
                  let size = attributes[.size] as? NSNumber else { continue }
            let stat = "\(size.intValue):\(modified.timeIntervalSince1970)"
            guard stat != item.observedStat || item.needsBaseline,
                  size.intValue <= hashBudget, let hash = contentHash(path) else { continue }
            item.observedStat = stat
            if item.needsBaseline {
                item.hash = hash
                item.needsBaseline = false
                consumed.insert(hash)
                artifacts[path] = item
                continue
            }
            if hash != item.hash {
                item.hash = hash
                if consumed.insert(hash).inserted { result.append(path.path) }
            }
            artifacts[path] = item
            if result.count == 12 { break }
        }
        return result
    }

    private func findSession() -> URL? {
        let index = home.appendingPathComponent("session_index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: index) else { return nil }
        defer { try? handle.close() }
        let count = fileSize(index)
        try? handle.seek(toOffset: count > 1_024 * 1_024 ? count - 1_024 * 1_024 : 0)
        guard let data = try? handle.read(upToCount: 1_024 * 1_024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = value["workDir"] as? String,
                  URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == workspace,
                  let raw = value["sessionDir"] as? String else { continue }
            let candidate = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
            guard within(candidate, home.appendingPathComponent("sessions").resolvingSymlinksInPath()),
                  fileSize(candidate.appendingPathComponent("state.json")) <= 256 * 1_024,
                  let stateData = try? Data(contentsOf: candidate.appendingPathComponent("state.json")),
                  let state = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
                  let stateCWD = state["cwd"] as? String,
                  URL(fileURLWithPath: stateCWD).resolvingSymlinksInPath() == workspace,
                  state["archived"] as? Bool != true else { continue }
            return candidate
        }
        return nil
    }

    private func wireFiles() -> [URL] {
        guard let session else { return [] }
        let directory = session.appendingPathComponent("agents")
        let agents = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        return agents.compactMap { agent -> URL? in
            let wire = agent.appendingPathComponent("wire.jsonl").resolvingSymlinksInPath()
            guard within(wire, directory.resolvingSymlinksInPath()),
                  FileManager.default.fileExists(atPath: wire.path) else { return nil }
            return wire
        }.sorted { fileModified($0) > fileModified($1) }.prefix(32).map { $0 }
    }

    private func consume(_ data: Data, wire: URL, now: Date) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["type"] as? String == "context.append_loop_event",
              let milliseconds = value["time"] as? NSNumber,
              let event = value["event"] as? [String: Any],
              let id = event["toolCallId"] as? String else { return }
        let time = Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
        guard time >= startedAt, time <= now else { return }
        let key = wire.path + "#" + id
        if event["type"] as? String == "tool.call" {
            guard calls.count < 128 else { return }
            let paths = referencedPaths(event["args"])
            for path in paths { register(path, callAt: time, active: false) }
            calls[key] = Call(time: time, paths: paths)
        } else if event["type"] as? String == "tool.result",
                  let call = calls.removeValue(forKey: key),
                  let result = event["result"] as? [String: Any],
                  result["isError"] as? Bool != true, result["error"] == nil,
                  (result["exitCode"] as? Int ?? 0) == 0 {
            let output = result["output"] as? String ?? ""
            guard !output.contains("Command failed with exit code") else { return }
            for path in call.paths + referencedPaths(result) {
                register(path, callAt: call.time, active: true)
            }
        }
    }

    private func referencedPaths(_ value: Any?) -> [URL] {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              data.count <= 1_024 * 1_024, let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?:/|~/)[^\s"'<>\\{}\[\](),;:]+\.(?:json|png|jpg|jpeg|usdz|blend|mp4|mov)"#)
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(64).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let raw = (String(text[range]) as NSString).expandingTildeInPath
            let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
            guard extensions.contains(path.pathExtension.lowercased()),
                  roots.contains(where: { within(path, $0) }),
                  !within(path, home.resolvingSymlinksInPath()) else { return nil }
            return path
        }
    }

    private func register(_ path: URL, callAt: Date, active: Bool) {
        if var old = artifacts[path] {
            // A new call suspends even previously accepted artifacts until success.
            old.active = active
            artifacts[path] = old
            return
        }
        if artifacts.count >= 128,
           let oldest = artifacts.min(by: { $0.value.firstCallAt < $1.value.firstCallAt })?.key {
            artifacts.removeValue(forKey: oldest)
        }
        let attrs = attributes(path)
        let created = attrs?[.creationDate] as? Date ?? .distantPast
        // Existing files become a baseline. Merely reading or touching them cannot
        // claim progress; a genuinely newly created output has no prior content.
        let baseline = created >= callAt ? nil : contentHash(path)
        if let baseline { consumed.insert(baseline) }
        let stat: String?
        if baseline != nil, let bytes = attrs?[.size] as? NSNumber,
           let modified = attrs?[.modificationDate] as? Date {
            stat = "\(bytes.intValue):\(modified.timeIntervalSince1970)"
        } else { stat = nil }
        artifacts[path] = Artifact(hash: baseline, active: active, firstCallAt: callAt,
                                  needsBaseline: attrs != nil && created < callAt && baseline == nil,
                                  observedStat: stat)
    }

    private func attributes(_ path: URL) -> [FileAttributeKey: Any]? {
        guard roots.contains(where: { within(path.resolvingSymlinksInPath(), $0) }),
              let value = try? FileManager.default.attributesOfItem(atPath: path.path),
              value[.type] as? FileAttributeType == .typeRegular,
              let bytes = value[.size] as? NSNumber,
              bytes.intValue > 0, bytes.intValue <= maxFileBytes else { return nil }
        return value
    }

    private func contentHash(_ path: URL) -> String? {
        guard let before = attributes(path), let bytes = before[.size] as? NSNumber,
              bytes.intValue <= hashBudget else { return nil }
        hashBudget -= bytes.intValue
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1),
              data.count <= maxFileBytes, let after = attributes(path),
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func within(_ path: URL, _ root: URL) -> Bool { path.path.hasPrefix(root.path + "/") }
    private func fileSize(_ path: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
    private func fileModified(_ path: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date) ?? .distantPast
    }
}

/// One observer per live attempt. All observers disappear when their tasks stop;
/// a retry starts at the new session offsets and cannot reuse the prior evidence.
public final class KimiArtifactProgressCoordinator {
    public struct Observation {
        public let taskID: String
        public let attemptID: String
        public let runnerID: String
        public let runnerPID: Int32
        public let workspace: String
        public let evidence: [String]
    }
    private struct Entry {
        let attemptID: String
        let pid: Int32
        let workspace: String
        let observer: KimiArtifactProgress
    }
    private var entries: [String: Entry] = [:]
    private let kimiHome: URL?
    private let roots: [URL]?
    private let interval: TimeInterval

    public init(kimiHome: URL? = nil, artifactRoots: [URL]? = nil, pollInterval: TimeInterval = 10) {
        self.kimiHome = kimiHome; self.roots = artifactRoots; self.interval = pollInterval
    }

    public func poll(tasks: [WorkTask], attempts: [WorkAttempt], now: Date = Date(),
                     workspaceForTask: (WorkTask) -> String?) -> [Observation] {
        var live = Set<String>()
        var result: [Observation] = []
        for task in tasks {
            guard task.state == .running, task.platform == .kimi,
                  let pid = task.runnerPID, pid > 1, let owner = task.ownerRunnerID,
                  let attempt = attempts.filter({ $0.taskID == task.id })
                    .max(by: { $0.startedAt < $1.startedAt }),
                  attempt.outcome == .running, attempt.runnerID == owner,
                  attempt.startedAt <= now else { continue }
            live.insert(task.id)
            if entries[task.id]?.attemptID != attempt.attemptID || entries[task.id]?.pid != pid {
                guard let workspace = workspaceForTask(task) else { continue }
                entries[task.id] = Entry(attemptID: attempt.attemptID, pid: pid, workspace: workspace,
                    observer: KimiArtifactProgress(workspace: workspace, startedAt: attempt.startedAt,
                        kimiHome: kimiHome, artifactRoots: roots, pollInterval: interval))
            }
            guard let entry = entries[task.id] else { continue }
            let evidence = entry.observer.poll(now: now)
            if !evidence.isEmpty {
                result.append(Observation(taskID: task.id, attemptID: attempt.attemptID,
                    runnerID: owner, runnerPID: pid, workspace: entry.workspace, evidence: evidence))
            }
        }
        entries = entries.filter { live.contains($0.key) }
        return result
    }
}
