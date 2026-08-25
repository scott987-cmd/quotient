import Foundation

/// 项目质量契约的多模态合入闸。
///
/// 代码审核回答“会不会坏”，这一层回答“画面上是否真的达到项目标准”。
/// 只对配置了 qualityContract、且改动会影响可见行为的仓库生效。
public enum VisualQualityGate {
    private static let remediationMarker = "【视觉整改："

    /// 历史否决不能永久堆进任务正文。每次整改只需要“原始任务 + 最新一票”；
    /// 更早的票已经被后续实现取代，重复发送只会扩大上下文并诱导 Agent 重做。
    public static func compactRemediationPrompt(_ prompt: String) -> String {
        guard let first = prompt.range(of: remediationMarker),
              let latest = prompt.range(of: remediationMarker, options: .backwards),
              first.lowerBound != latest.lowerBound else { return prompt }
        let base = prompt[..<first.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let current = prompt[latest.lowerBound...]
        return base + "\n\n" + current
    }

    private static func remediationBasePrompt(_ prompt: String) -> String {
        guard let first = prompt.range(of: remediationMarker) else { return prompt }
        return prompt[..<first.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum Status: Equatable, Sendable {
        case missing, pending, approved, rejected
    }

    static func marker(branch: String, head: String) -> String {
        "【看效果】分支 \(branch) 提交 \(head)"
    }

    static func verdict(_ task: WorkTask) -> Status? {
        let text = (task.outputs + [task.note ?? ""]).joined(separator: "\n")
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { $0.contains("结论") }) else { return nil }
        if line.contains("未达标") { return .rejected }
        if line.contains("达标") { return .approved }
        return nil
    }

    private static func verdictDate(_ task: WorkTask) -> Date {
        task.endedAt ?? task.createdAt
    }

    private static func resolvedStatus(_ matching: [WorkTask], tasks: [WorkTask]) -> Status {
        // 新一轮正在看时，旧票不能先放行。TaskStore.all() 已把同 ID 的状态
        // 快照折成最后一条，这里处理的是不同验收任务。
        if matching.contains(where: { $0.state == .queued || $0.state == .running }) {
            return .pending
        }
        // 票会重跑。必须取最新完成的一票，不能按数组顺序返回第一票：旧否决
        // + 新批准时，旧实现会永远返回旧否决；hasApproved 却又返回 true。
        let completed = matching.filter { $0.state == .done && verdict($0) != nil }
        guard let latest = completed.max(by: {
            verdictDate($0) < verdictDate($1)
        }) else { return .missing }
        guard verdict(latest) == .rejected,
              latest.prompt.contains(ArchitectReview.contractMarker) else {
            return verdict(latest) ?? .missing
        }
        switch ArchitectReview.decision(for: latest, tasks: tasks) {
        case .uphold: return .rejected
        case .overturn: return .approved
        case .missing, .pending: return .pending
        }
    }

    public static func status(branch: String, head: String,
                              tasks: [WorkTask]) -> Status {
        let prefix = marker(branch: branch, head: head)
        return resolvedStatus(tasks.filter { $0.prompt.hasPrefix(prefix) }, tasks: tasks)
    }

    /// 分支跨多个提交的最新视觉结论。黄金样板落地后分支可能已被删除，
    /// 此时只能用这条分支的最新票判断，不能让任意一张历史批准票放行。
    public static func latestStatus(branch: String, tasks: [WorkTask]) -> Status {
        let prefix = "【看效果】分支 \(branch) 提交 "
        return resolvedStatus(tasks.filter { $0.prompt.hasPrefix(prefix) }, tasks: tasks)
    }

    public static func hasApproved(branch: String, tasks: [WorkTask]) -> Bool {
        latestStatus(branch: branch, tasks: tasks) == .approved
    }

    @discardableResult
    public static func dispatch(item: Review.Item, repo: String,
                                tasks: [WorkTask]) -> String? {
        // 查重只绑定 branch + head。执行器会串行消费队列，一个项目的视觉任务
        // 在跑不该让其他项目连排队都排不进去；旧全局互斥会让一条卡住的录屏
        // 验收静默冻结全网。
        guard status(branch: item.branch, head: item.head, tasks: tasks) == .missing
        else { return nil }
        let visual = item.evidence.filter {
            let l = $0.lowercased()
            return [".png", ".jpg", ".jpeg", ".mov", ".mp4"].contains(where: l.hasSuffix)
        }
        guard !visual.isEmpty else { return nil }
        let extracted = Review.extractEvidence(
            repo: repo, branch: item.branch, files: visual,
            digestID: repo + "|quality|" + item.branch + "|" + item.head)
        guard !extracted.isEmpty else { return nil }
        let prompt = """
        \(marker(branch: item.branch, head: item.head)) 的视觉质量是否达到项目契约。

        成果：\(item.subject)
        文件（都在 \(Review.evidenceDir.path) 下）：
        \(extracted.map { "  - " + $0 }.joined(separator: "\n"))

        必须真的逐帧看图/录屏，并逐条对照任务目标和注入的 QUALITY.md。
        第一行结论只能写“**结论**：达标”或“**结论**：未达标”。
        """
        guard let result = try? TaskIntake.enqueue(
            prompt: prompt, repo: repo, classify: false, split: false,
            force: true, origin: "visual-quality-review", preferredPlatform: .minimax),
              case .single(let task) = result else { return nil }
        return task.id
    }

    /// 把已完成的视觉否决重新交回原实现任务。
    ///
    /// 返回原任务的新快照而不是新任务：任务 ID、owner、稳定工作区和 runner
    /// 会话键都不变，原 Agent 可以接着项目上下文整改。调用方把快照 append
    /// 进 TaskStore；`visualRemediationReviewID` 保证每张票只重开一次。
    public static func reconcileRemediation(_ tasks: [WorkTask],
                                             now: Date = Date()) -> [WorkTask] {
        let rejected = tasks.filter {
            $0.origin == "visual-quality-review" && $0.state == .done
                && verdict($0) == .rejected
                && (!$0.prompt.contains(ArchitectReview.contractMarker)
                    || ArchitectReview.decision(for: $0, tasks: tasks) == .uphold)
        }.sorted { verdictDate($0) < verdictDate($1) }
        var updates: [String: WorkTask] = [:]

        for review in rejected {
            guard let target = target(of: review),
                  var source = sourceTask(branch: target.branch, repo: review.repo,
                                          tasks: tasks) else { continue }
            // 对账只能把上一轮已经结束的实现重新入队，不能改写正在执行、
            // 已经排队或正在等人的任务。否则 worker 手里真实 running，质量闭环
            // 却会拿历史否决票再写一条 queued，手机看到假状态，下一轮还可能重派。
            guard source.state == .done || source.state == .failed else { continue }
            // 同一黄金样板已经有更新的实现续作时，旧否决已被后续任务接住。
            // 部署新机制时不能把所有历史旧票一起翻成新任务。
            if superseded(review: review, source: source, tasks: tasks) { continue }
            // 第一版闭环上线后的现场回放抓到：任务重开成功，但派活前的“这条
            // 分支已合过”优化又把它写回 done。要精确救这一种假完成；真正完成
            // 过一轮整改（note 是改了 N 个文件）不能被旧否决反复重开。
            let falseCompletion = source.visualRemediationReviewID == review.id
                && source.state == .done && source.landedAt == nil
                && source.note?.contains("产出早已落地") == true
            // visualRemediationReviewID 不只是“同一票幂等键”，还代表这条实现
            // 已经处理到哪一张票。处理过较新的否决后，任何更旧的票都不能倒灌。
            if !falseCompletion,
               let handledID = source.visualRemediationReviewID,
               let handled = tasks.first(where: { $0.id == handledID }),
               verdictDate(review) <= verdictDate(handled) {
                continue
            }
            if source.visualRemediationReviewID == review.id && !falseCompletion { continue }
            if let newer = updates[source.id], newer.visualRemediationReviewID == review.id {
                continue
            }

            if !falseCompletion {
                source.prompt = remediationBasePrompt(source.prompt)
                source.prompt += """


            【视觉整改：\(review.id)｜保持原 owner 和原会话】
            独立多模态验收对分支 \(target.branch) 的提交 \(target.head) 判定未达标。
            这不是新项目，也不要扩张同类角色；直接沿用当前实现上下文，只修下面
            已被画面证实的问题，重新从正常入口实跑并提交新的截图/连续录屏：

            \(rejectionDetail(review))

            代码审核、单测通过不能替代这张视觉票。修完仍由独立视觉验收重新判；
            有硬门槛没达到就如实保留“未达标”，不要用特写/文档冒充完成。
            """
            }
            source.state = .queued
            source.createdAt = now
            source.startedAt = nil
            source.endedAt = nil
            source.exitCode = nil
            source.changedFiles = nil
            source.outputs = []
            let who = source.ownerPlatform?.displayName
                ?? source.platform?.displayName ?? "原 Agent"
            source.note = "视觉验收未达标，已自动交回 \(who) 原会话整改（\(review.id)）"
            source.landedAt = nil
            source.discardedAt = nil
            source.discardReason = nil
            source.triedPlatforms = []
            source.pendingAsk = nil
            source.answeredAsk = nil
            source.askRounds = 0
            source.handoff = nil
            source.visualRemediationReviewID = review.id
            if source.preferredPlatform == nil {
                source.preferredPlatform = source.ownerPlatform ?? source.platform
            }
            updates[source.id] = source
        }
        return updates.values.sorted { $0.createdAt < $1.createdAt }
    }

    private static func target(of task: WorkTask) -> (branch: String, head: String)? {
        let prefix = "【看效果】分支 "
        guard task.prompt.hasPrefix(prefix),
              let range = task.prompt.range(of: " 提交 ") else { return nil }
        let start = task.prompt.index(task.prompt.startIndex, offsetBy: prefix.count)
        let branch = String(task.prompt[start..<range.lowerBound])
        let rest = task.prompt[range.upperBound...]
        let head = String(rest.prefix { !$0.isWhitespace && $0 != "的" })
        return branch.isEmpty || head.isEmpty ? nil : (branch, head)
    }

    private static func sourceTask(branch: String, repo: String,
                                   tasks: [WorkTask]) -> WorkTask? {
        let id = String(branch.split(separator: "/").last ?? "")
        return tasks.filter {
            $0.repo == repo && $0.origin != "visual-quality-review"
                && ($0.branch == branch || $0.id == id)
        }.max { $0.createdAt < $1.createdAt }
    }

    private static func superseded(review: WorkTask, source: WorkTask,
                                   tasks: [WorkTask]) -> Bool {
        guard let production = source.production else { return false }
        let after = verdictDate(review)
        return tasks.contains { candidate in
            guard candidate.id != source.id, candidate.repo == source.repo,
                  candidate.createdAt > after,
                  candidate.origin != "visual-quality-review",
                  let next = candidate.production else { return false }
            return next.stage == production.stage
                && next.goldenSampleID == production.goldenSampleID
                && next.deliverableKind == production.deliverableKind
        }
    }

    static func rejectionDetail(_ review: WorkTask) -> String {
        // MiniMax 的短输出通常只给报告路径，真正逐帧发现都在报告文件里。
        // 把正文直接塞回原会话，避免实现 Agent 还要猜报告是否已合入 main。
        if let line = review.outputs.first(where: { $0.contains("报告：") }),
           let marker = line.range(of: "报告：") {
            let path = line[marker.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                let local = URL(fileURLWithPath: review.repo).appendingPathComponent(path)
                if let text = try? String(contentsOf: local, encoding: .utf8),
                   !text.isEmpty { return String(text.prefix(12_000)) }
                if let branch = review.branch {
                    let shown = GitWorkspace.git(["show", "\(branch):\(path)"], in: review.repo)
                    if shown.exitCode == 0, !shown.stdout.isEmpty {
                        return String(shown.stdout.prefix(12_000))
                    }
                }
            }
        }
        let joined = review.outputs.joined(separator: "\n")
        if joined.count > 20 { return String(joined.prefix(4_000)) }
        return "视觉验收明确判定未达标；先读取该验收分支/报告，再逐项复现整改。"
    }
}
