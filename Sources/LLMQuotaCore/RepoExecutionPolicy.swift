import Foundation

/// 仓库级的连续负责规则。
///
/// 任务 owner 管“这条已经形成上下文的任务继续给谁”；这里管“一个项目的
/// 新功能任务第一次交给谁”。两者不冲突：已经形成的任务上下文优先，
/// 新任务才采用仓库负责人。审核、媒体和补证据不属于功能实现，不受此限制。
public enum RepoExecutionPolicy {
    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: NSString(string: lhs).expandingTildeInPath)
            .standardizedFileURL.path
            == URL(fileURLWithPath: NSString(string: rhs).expandingTildeInPath)
                .standardizedFileURL.path
    }

    public static func repo(
        for path: String, repos: [RepoAlias] = RepoRegistry.all()
    ) -> RepoAlias? {
        repos.first { samePath($0.localPath, path) || samePath($0.path, path) }
    }

    public static func implementationOwner(
        for repoPath: String, prompt: String,
        repos: [RepoAlias] = RepoRegistry.all()
    ) -> Platform? {
        guard TaskKind.isCoding(prompt) else { return nil }
        return repo(for: repoPath, repos: repos)?.implementationOwner
    }

    /// 恢复中的编码任务先于普通排队任务，尤其先于落地后的低优先级复查。
    /// 它已经付过理解仓库和形成会话的 token，先让它收口最省也最稳。
    public static func queuePriority(_ task: WorkTask) -> Int {
        if TaskKind.isCoding(task.prompt), task.ownerRunnerID != nil { return 0 }
        if task.origin == "post-land-review" { return 2 }
        return 1
    }
}
