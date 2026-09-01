import Foundation

/// 纯技术高危路径的自动处置闭环。
///
/// 实现 Agent 仍然拥有原任务和会话；架构师只检查隔离分支上的快照并给出
/// 放行/拒绝结论。这样不会因为一次 `project.pbxproj` 生成改动而把编码工作
/// 整项换人，也不会把“等架构师处置”写成一个永远没人领取的静态标签。
public enum TechnicalDisposition {
    public static let promptPrefix = "【技术处置】"
    public static let originPrefix = "technical-disposition:"

    public enum Decision: Equatable, Sendable {
        case pending, approve, reject
    }

    public enum CheckpointResult: Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    /// 把尚未提交的高危改动保存到隔离分支。分支提交不是合入；它只是让
    /// 临时 worktree 被清理、磁盘恢复或进程退出后仍能完整复核和恢复。
    public static func checkpoint(repo: String, workspace: String,
                                  platform: Platform?, prompt: String) -> CheckpointResult {
        let dirty = !GitWorkspace.git(["status", "--porcelain"], in: workspace)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if dirty {
            let commit = GitWorkspace.commit(
                in: workspace,
                message: "wip(blocked): \(prompt.prefix(60))\n\n"
                    + "高危路径技术复核前的可恢复快照；尚未获准合入。")
            guard commit.exitCode == 0 else {
                return .failure(String(commit.stderr.suffix(240)))
            }
        }
        let head = GitWorkspace.git(["rev-parse", "HEAD"], in: workspace)
        let sha = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.exitCode == 0, !sha.isEmpty else {
            return .failure("无法读取快照提交")
        }
        return .success(sha)
    }

    public static func isBlocked(_ task: WorkTask) -> Bool {
        let note = task.note ?? ""
        return task.state == .blocked && task.frozenBy == nil
            && (note.contains("等 Claude 处置") // 兼容升级前的在途任务
                || note.contains("等架构师处置")
                || note.hasPrefix("技术处置任务 ")
                || note.hasPrefix("技术拦截无法")
                || note.hasPrefix("原实现 Owner 续作后没有产生新快照"))
    }

    public static func decision(for task: WorkTask) -> Decision {
        guard task.state == .done else { return .pending }
        let text = dispositionText(task)
        guard let line = text.components(separatedBy: .newlines).last(where: {
            $0.contains("结论") && ($0.contains("放行") || $0.contains("拒绝"))
        }) else { return .pending }
        return line.contains("放行") ? .approve : .reject
    }

    /// 每轮任务图对账时调用。返回值既可能包含新建的架构处置任务，也可能
    /// 包含原任务的状态更新；调用方仍通过 TaskStore 的 revision 规则统一落盘。
    public static func reconcile(_ tasks: [WorkTask]) -> [WorkTask] {
        let architect = AgentRoles.architectPlatform()
        let architectName = architect.displayName + " 架构师"
        var latest: [String: WorkTask] = [:]
        for task in tasks { latest[task.id] = task }
        let current = Array(latest.values)
        let byOrigin = Dictionary(
            current.compactMap { task in task.origin.map { ($0, task) } },
            uniquingKeysWith: { _, newer in newer })
        var updates: [WorkTask] = []

        for original in current where isBlocked(original) {
            guard let branch = original.branch,
                  GitWorkspace.branchExists(branch, in: original.repo) else {
                var lost = original
                lost.note = "技术拦截无法进入复核：隔离分支不存在，等待恢复快照"
                if lost.note != original.note { updates.append(lost) }
                continue
            }
            let head = GitWorkspace.git(["rev-parse", branch], in: original.repo)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { continue }

            // 处置结论只对一个精确快照有效。原 Owner 根据拒绝意见继续提交后，
            // 新 HEAD 必须产生新一轮复核；绝不能把上一轮拒绝无限套在新代码上。
            let origin = originPrefix + original.id + ":" + head
            guard let disposition = byOrigin[origin] else {
                var review = WorkTask(
                    id: dispositionID(origin: origin),
                    prompt: prompt(for: original, branch: branch, head: head),
                    repo: original.repo)
                review.origin = origin
                review.preferredPlatform = architect
                review.profile = TaskProfile(
                    tier: .standard, risk: .safe, estimatedMinutes: 8,
                    isSelfContained: true,
                    rationale: "技术高危路径复核：只检查隔离分支并写结论，不接管实现")
                review.note = "等待 \(architectName)领取技术处置 · 原任务 \(original.id)"
                updates.append(review)

                var waiting = original
                waiting.note = "技术处置任务 \(review.id) 已排给架构师；实现 Owner 保持 "
                    + (original.ownerRunnerID ?? original.platform?.displayName ?? "原 Agent")
                    + "；快照 " + String(head.prefix(8))
                if waiting.note != original.note { updates.append(waiting) }
                continue
            }

            switch decision(for: disposition) {
            case .approve:
                var resolved = original
                resolved.state = .done
                resolved.endedAt = Date()
                resolved.runnerPID = nil
                resolved.terminalFailureKind = nil
                resolved.retryNotBefore = nil
                resolved.note = "架构师技术处置 \(disposition.id) 已放行隔离分支；"
                    + "实现 Owner 保持 "
                    + (original.ownerRunnerID ?? original.platform?.displayName ?? "原 Agent")
                    + "；等待评审与合入"
                updates.append(resolved)
            case .reject:
                let marker = "【架构师技术处置反馈：\(disposition.id)】"
                let legacyMarker = "【Claude 技术处置反馈：\(disposition.id)】"
                if original.prompt.contains(marker) || original.prompt.contains(legacyMarker) {
                    // 原 Agent 已经拿过这份意见却没有形成新提交。保持阻塞并让
                    // 巡检告警，避免在原 Agent 与同一张复核票之间无限空转烧额度。
                    var unchanged = original
                    unchanged.note = "原实现 Owner 续作后没有产生新快照；"
                        + "仍停在架构师拒绝的提交 \(String(head.prefix(8)))"
                    if unchanged.note != original.note { updates.append(unchanged) }
                    continue
                }

                var retry = original
                let feedback = String(dispositionText(disposition).suffix(6_000))
                retry.prompt += "\n\n\(marker)\n\(feedback)\n"
                retry.state = .queued
                retry.createdAt = Date()
                retry.startedAt = nil
                retry.endedAt = nil
                retry.exitCode = nil
                retry.changedFiles = nil
                retry.runnerPID = nil
                retry.outputs = []
                retry.triedPlatforms = []
                retry.pendingAsk = nil
                retry.answeredAsk = nil
                retry.askRounds = 0
                retry.preferredPlatform = retry.ownerPlatform ?? retry.platform
                retry.note = "架构师技术处置 \(disposition.id) 拒绝该快照；"
                    + "已把意见交回原实现 Owner 的同一任务续作"
                updates.append(retry)
            case .pending:
                if disposition.state == .failed
                    || (disposition.state == .done
                        && decision(for: disposition) == .pending) {
                    if let retry = retryDisposition(disposition) {
                        updates.append(retry)
                    }
                }
                var waiting = original
                let stateText: String
                switch disposition.state {
                case .queued: stateText = "等待 \(architectName)领取"
                case .running: stateText = "\(architectName)正在检查"
                case .failed: stateText = "架构师处置失败，等待恢复"
                case .done: stateText = "架构师已完成但缺少结构化结论"
                case .blocked: stateText = "架构师处置被阻塞"
                }
                waiting.note = "技术处置任务 \(disposition.id)：\(stateText)；"
                    + "实现 Owner 保持 "
                    + (original.ownerRunnerID ?? original.platform?.displayName ?? "原 Agent")
                if waiting.note != original.note { updates.append(waiting) }
            }
        }
        return updates
    }

    private static func prompt(for original: WorkTask, branch: String, head: String) -> String {
        """
        \(promptPrefix)复核原任务 \(original.id) 的高危路径改动。

        原实现 Owner：\(original.ownerRunnerID ?? original.platform?.displayName ?? "未知")
        隔离分支：\(branch)
        快照提交：\(head)
        拦截原因：\(original.note ?? "高危路径")

        你只负责技术复核，不接管实现、不修改功能代码，也不要更换原任务 Owner。
        必须先用 `git diff main...\(branch)` 和 `git show \(head)` 检查现有增量；
        能运行仓库验证命令时必须运行。把依据写入
        reviews/TECH-\(original.id).md，只允许新增这份报告。

        最后一行必须二选一，并在任务输出中原样回显：
        **结论**：放行
        **结论**：拒绝
        """
    }

    private static func dispositionText(_ task: WorkTask) -> String {
        var text = (task.outputs + [task.note ?? ""]).joined(separator: "\n")
        guard let originalID = task.origin.map({
            String($0.dropFirst(originPrefix.count).split(separator: ":", maxSplits: 1).first ?? "")
        }),
              let branch = task.branch else { return text }
        let path = "reviews/TECH-\(originalID).md"
        let shown = GitWorkspace.git(["show", "\(branch):\(path)"], in: task.repo)
        if shown.exitCode == 0 { text += "\n" + shown.stdout }
        return text
    }

    private static func retryDisposition(_ task: WorkTask) -> WorkTask? {
        let attempts = task.interruptedCount ?? 0
        guard attempts < 2 else { return nil }
        var retry = task
        retry.state = .queued
        retry.startedAt = nil
        retry.endedAt = nil
        retry.exitCode = nil
        retry.runnerPID = nil
        retry.triedPlatforms = []
        retry.platform = nil
        retry.preferredPlatform = AgentRoles.architectPlatform()
        retry.interruptedCount = attempts + 1
        retry.note = task.state == .done
            ? "架构师技术处置缺少结构化结论，保留同一任务自动补跑（\(attempts + 1)/2）"
            : "架构师技术处置失败，保留同一任务自动续跑（\(attempts + 1)/2）"
        return retry
    }

    /// 8 位稳定 ID：同一个原任务/快照在并发对账时只会得到同一张处置票；
    /// 换了 HEAD 就换票。FNV-1a 的 28 位尾部足够用于本地任务去重。
    private static func dispositionID(origin: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in origin.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return "t" + String(format: "%07x", hash & 0x0fff_ffff)
    }
}
