import Foundation

/// 续做只表达保留现有成果的意愿，不是质量结论、合入授权或账号答复。
enum ReviewContinuation {
    static func blockReason(_ task: WorkTask) -> String? {
        if task.pendingAsk != nil { return "原任务仍在等答复，请到问题页处理；成果会保留。" }
        if task.pausedAt != nil || task.architectureReviewRequestedAt != nil {
            return "原任务已暂停，需要先处理暂停原因；成果会保留。"
        }
        if task.frozenBy != nil || task.waitReason == .humanApproval {
            return "原任务仍有依赖或审批未完成；成果会保留。"
        }
        if task.terminalFailureKind?.blocksDerivedRequeue == true {
            return "原任务的账号、额度或运行环境尚未恢复，请先处理任务阻断；成果会保留。"
        }
        if task.retryNotBefore.map({ $0 > Date() }) == true { return "原任务仍在等待恢复时间；成果会保留。" }
        guard task.state == .done || task.state == .failed else { return "原任务正在处理，暂不重复续作。" }
        guard task.landedAt == nil, task.discardedAt == nil,
              task.graphID == nil, !TaskKind.isSupportingTask(task),
              task.ownerRunnerID != nil, task.ownerPlatform != nil else {
            return "当前成果不能直接续作，请查看原任务状态；成果会保留。"
        }
        return nil
    }

    static func task(repo: String, branch: String, tasks: [WorkTask]) -> WorkTask? {
        let matches = tasks.filter {
            $0.branch == branch && CollaborationStore.normalizeProject($0.repo)
                == CollaborationStore.normalizeProject(repo)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func actionID(repo: String, branch: String, head: String, tasks: [WorkTask]) -> String? {
        guard let task = task(repo: repo, branch: branch, tasks: tasks), blockReason(task) == nil,
              head.count == 40, head.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "review-continuation:request:" + repo + "|" + branch + "|" + head + "|" + MobileAction.taskResource(task)
    }

    static func execute(resource: String, note: String?) -> Bool {
        let bits = resource.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard bits.count == 5, bits.allSatisfy({ !$0.isEmpty }),
              GitWorkspace.isRepo(bits[0]),
              let task = TaskStore.all().first(where: {
                  $0.id == bits[3] && CollaborationStore.normalizeProject($0.repo) == CollaborationStore.normalizeProject(bits[0])
              }) else { return false }
        let marker = "【保留成果续作：" + MobileAction.digest(resource) + "】"
        // 成功后 Agent 可能已经推进 HEAD 或换工作分支；仍应确认此前已接受的请求。
        if task.prompt.contains(marker) { return true }
        guard task.branch == bits[1],
              self.task(repo: bits[0], branch: bits[1], tasks: TaskStore.all())?.id == task.id,
              !Review.isDecided(repo: bits[0], branch: bits[1], in: Review.decidedBranches()) else { return false }
        let head = GitWorkspace.git(["rev-parse", "--verify", "refs/heads/" + bits[1]], in: bits[0])
        guard head.exitCode == 0,
              head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == bits[2] else { return false }
        guard MobileAction.taskResource(task) == bits[3] + "|" + bits[4], blockReason(task) == nil else { return false }
        var next = task
        next.prompt += "\n\n" + marker + "\n保留已有成果，沿用原任务的最新要求继续完善，完成后重新提交验收。"
            + "这不是通过验收或合入授权，不改变既有质量与安全要求。\n"
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next.prompt += String(note.prefix(2_000)) + "\n"
        }
        next.state = .queued; next.waitReason = nil
        next.createdAt = Date(); next.startedAt = nil; next.endedAt = nil
        next.runnerPID = nil; next.exitCode = nil
        next.terminalFailureKind = nil; next.retryNotBefore = nil
        next.preferredPlatform = task.ownerPlatform
        next.triedPlatforms.removeAll { $0 == task.ownerPlatform }
        next.note = "已保留成果，等待原 Agent 沿用当前任务与分支继续完善；完成后仍需验收。"
        do {
            _ = try TaskStore.transition(next, actor: "mobile-action", reason: "保留成果并继续完善")
            Review.invalidateListCache()
            return true
        } catch { return false }
    }
}
