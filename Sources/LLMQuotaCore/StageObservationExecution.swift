import Foundation
import CryptoKit

/// 仅固定媒体执行器的阶段观察可以绕过实现写租约。身份键只依赖任务的
/// 不变字段；开工前另查真实 checkpoint，不能因快照更新改变正在持有的锁。
public enum StageObservationExecution {
    public static let runnerID = "minimax.media"
    public struct Snapshot {
        public var sourceID: String
        public var branch: String
        public var head: String
        public var digest: String
    }
    public static func snapshot(_ task: WorkTask) -> Snapshot? {
        guard task.origin == "milestone-eyes", task.graphID == nil,
              task.preferredPlatform == .minimax,
              task.ownerRunnerID == nil || task.ownerRunnerID == runnerID,
              task.ownerPlatform == nil || task.ownerPlatform == .minimax,
              !task.id.isEmpty, task.id.count <= 100,
              task.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              task.prompt.components(separatedBy: .newlines).contains(VisualReviewScope.observationMarker)
        else { return nil }
        func field(_ name: String) -> String? {
            let lines = task.prompt.components(separatedBy: .newlines).filter { $0.hasPrefix(name + "：") }
            guard lines.count == 1 else { return nil }
            let value = String(lines[0].dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        guard let source = field("来源任务"), let branch = field("来源分支"), branch.hasPrefix("agent/"),
              let head = field("证据提交"), head.count == 40, head.allSatisfy(\.isHexDigit),
              let digest = field("证据摘要"),
              digest.split(separator: ",").allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
              !MiniMaxMediaRunner.visualFiles(in: task.prompt).isEmpty,
              MiniMaxMediaRunner.visualFiles(in: task.prompt).count == digest.split(separator: ",").count else { return nil }
        return Snapshot(sourceID: source, branch: branch, head: head, digest: digest)
    }
    public static func workspaceKey(_ task: WorkTask) -> String? {
        snapshot(task).map { _ in "observation-" + GitWorkspace.stableKey(repo: task.repo, platform: .minimax) + "-" + task.id }
    }
    public static func executionKey(_ task: WorkTask) -> String {
        let repo = RepoLease.normalize(task.repo)
        guard let s = snapshot(task) else { return repo }
        let identity = [repo, s.sourceID, s.head, s.digest].joined(separator: "|")
        return "stage-observation:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// 对照系统的完整原始提示词和真实字节摘要，人工仿写关键词不能获得例外。
    public static func validatedSnapshot(_ task: WorkTask, tasks: [WorkTask],
                                         milestones: [Milestone.Item] = Milestone.all()) -> Snapshot? {
        guard let s = snapshot(task),
              let source = tasks.first(where: { $0.id == s.sourceID && RepoLease.normalize($0.repo) == RepoLease.normalize(task.repo) }),
              source.branch == s.branch, source.discardedAt == nil, source.landedAt == nil,
              source.ownerRunnerID != runnerID,
              let item = milestones.first(where: {
                  $0.isCheckpoint && $0.taskID == s.sourceID && $0.branch == s.branch && $0.mergeSHA == s.head
                    && RepoLease.normalize($0.repo) == RepoLease.normalize(task.repo)
                    && Milestone.visualCheckPrompt($0) == task.prompt
              }), !item.evidenceFiles.isEmpty,
              StageFindingLoop.evidenceDigests(item.evidenceFiles).joined(separator: ",") == s.digest
        else { return nil }
        let current = GitWorkspace.git(["rev-parse", "--verify", s.branch + "^{commit}"], in: source.repo, timeout: 5)
        guard current.exitCode == 0,
              current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == s.head else { return nil }
        return s
    }
    /// 报告提交保留在分支/attempt 中，只回收无人占用且干净的观察工作区。
    /// 正常收尾即时执行；进程异常退出的遗留目录由既有 archive 路径补收。
    @discardableResult public static func cleanupWorkspace(_ task: WorkTask, dryRun: Bool = false) -> Bool {
        guard let key = workspaceKey(task), task.state == .done || task.state == .failed else { return false }
        let lease = LocalExecutionLease(scope: .repo, key: executionKey(task))
        guard lease.acquire() else { return false }
        defer { lease.release() }
        guard let current = TaskStore.all().first(where: { $0.id == task.id }),
              current.rev == task.rev, current.state == task.state,
              let workspace = GitWorkspace.existingWorkspace(taskID: key),
              workspace.branch == "agent/minimax/" + task.id,
              GitWorkspace.occupantsProbe(workspace.path).isEmpty else { return false }
        let status = GitWorkspace.git(["status", "--porcelain"], in: workspace.path, timeout: 5)
        guard status.exitCode == 0, status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if dryRun { return true }
        return GitWorkspace.git(["worktree", "remove", workspace.path], in: task.repo, timeout: 15).exitCode == 0
    }

}
