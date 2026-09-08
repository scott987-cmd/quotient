import Foundation

/// Completed review artifacts are immutable for a task revision, but one task-graph
/// reconciliation asks several gates for the same report. Avoid spawning `git show`
/// repeatedly while keeping misses and changed task revisions retryable.
enum ReviewArtifactCache {
    private struct Key: Hashable {
        let taskID: String
        let revision: Int
        let repo: String
        let branch: String
        let path: String
    }

    private static let lock = NSLock()
    private static var values: [Key: String] = [:]
    private static let maximumEntries = 512

    static func load(task: WorkTask, path: String,
                     loader: () -> String?) -> String? {
        guard task.state == .done, let branch = task.branch else {
            return loader()
        }
        let key = Key(
            taskID: task.id, revision: task.rev,
            repo: URL(fileURLWithPath: task.repo).standardizedFileURL.path,
            branch: branch, path: path)
        lock.lock()
        let cached = values[key]
        lock.unlock()
        if let cached { return cached }

        guard let loaded = loader(), !loaded.isEmpty else { return nil }
        lock.lock()
        if values.count >= maximumEntries { values.removeAll(keepingCapacity: true) }
        values[key] = loaded
        lock.unlock()
        return loaded
    }

    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}
