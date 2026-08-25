import Foundation

/// MiniMax 负面主观结论的架构师复核层。
///
/// 通过结论不增加流程；测试命令的退出码也不经模型复议。只有新机制上线后
/// 产生的主观拒绝才进入这里，避免历史报告在部署时一次性回灌。
public enum ArchitectReview {
    public static let contractMarker = "【负面结论架构复核 v1】"
    private static let originPrefix = "architect-review:"

    public enum Decision: Equatable, Sendable {
        case missing, pending, uphold, overturn
    }

    public static func decision(for review: WorkTask, tasks: [WorkTask]) -> Decision {
        guard let task = tasks.last(where: {
            $0.origin == originPrefix + review.id && $0.discardedAt == nil
        }) else { return .missing }
        guard task.state == .done else { return .pending }
        let text = reviewText(task)
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { $0.contains("结论") }) else { return .pending }
        if line.contains("推翻拒绝") { return .overturn }
        if line.contains("维持拒绝") { return .uphold }
        return .pending
    }

    public static func reconcile(_ tasks: [WorkTask]) -> [WorkTask] {
        var known = Set(tasks.compactMap(\.origin))
        var made: [WorkTask] = []
        for review in tasks where isNegative(review) {
            let origin = originPrefix + review.id
            guard !known.contains(origin) else { continue }
            var task = WorkTask(
                id: "a" + String(review.id.prefix(7)).lowercased(),
                prompt: prompt(for: review), repo: review.repo)
            task.origin = origin
            task.preferredPlatform = .claude
            task.profile = TaskProfile(
                tier: .standard, risk: .safe, estimatedMinutes: 8,
                isSelfContained: true,
                rationale: "MiniMax 负面主观结论由架构师复核")
            task.note = "等待架构师复核 MiniMax 的负面结论（\(review.id)）"
            made.append(task)
            known.insert(origin)
        }
        return made
    }

    static func hasUnresolvedMergeRejection(branch: String, head: String,
                                             headAt: Date?, tasks: [WorkTask]) -> Bool {
        tasks.contains { review in
            guard MergeReview.isMergeReviewPrompt(review.prompt, of: branch),
                  !MergeReview.verdictIsStale(review, head: head, headAt: headAt),
                  isNegative(review) else { return false }
            let d = decision(for: review, tasks: tasks)
            return d == .missing || d == .pending
        }
    }

    static func isNegative(_ review: WorkTask) -> Bool {
        guard review.state == .done, review.discardedAt == nil,
              review.prompt.contains(contractMarker),
              !TaskKind.isTesting(review.prompt),
              !TaskKind.isArchitectReview(review.prompt) else { return false }

        let text = reviewText(review)
        if review.origin == "merge-review" {
            guard MergeReview.parseVerdict(text) == .reject else { return false }
            return !VerdictQuality.isInconclusive(
                VerdictQuality.fullReport(taskOutputs: text, repoPath: review.repo))
        }
        if review.origin == "visual-quality-review" {
            return VisualQualityGate.verdict(review) == .rejected
        }
        if review.origin == "post-land-review" {
            return !PostLandRepair.findings(in: text).isEmpty
        }
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { $0.contains("结论") }) else { return false }
        return ["不达标", "部分达标", "需要改", "不建议", "不合入", "拒绝"]
            .contains { line.contains($0) }
    }

    private static func prompt(for review: WorkTask) -> String {
        let material = String(reviewText(review).prefix(12_000))
        return """
        【架构复核】MiniMax 评审任务 \(review.id) 的负面结论是否成立。

        原任务：
        \(review.prompt)

        MiniMax 的结论和证据：
        \(material.isEmpty ? "（没有可读结论材料；不得据此推翻拒绝）" : material)

        你是架构师，只复核“拒绝是否有事实和契约依据”，不要代替实现 Agent 改代码。
        能从仓库、diff、机器测试证据核实的必须亲自核实。视觉类只有在你实际看过
        同一组图片/录屏，或发现 MiniMax 存在可证明的事实矛盾时，才允许推翻；
        看不到同一证据不构成推翻理由。

        把完整依据写入 reviews/ARCH-\(review.id).md，最后一行必须二选一：
        **结论**：维持拒绝
        **结论**：推翻拒绝
        并把同一结论行回显到任务输出。只新增这份报告，不改功能代码。
        """
    }

    private static func reviewText(_ task: WorkTask) -> String {
        var text = (task.outputs + [task.note ?? ""]).joined(separator: "\n")
        if task.origin == "post-land-review", let report = PostLandRepair.reportText(for: task) {
            text += "\n" + report
        } else if task.origin == "visual-quality-review" {
            text += "\n" + VisualQualityGate.rejectionDetail(task)
        } else if task.origin == "merge-review" {
            text = VerdictQuality.fullReport(taskOutputs: text, repoPath: task.repo)
        } else if task.origin?.hasPrefix(originPrefix) == true {
            let path = "reviews/ARCH-\(String(task.origin!.dropFirst(originPrefix.count))).md"
            if let branch = task.branch {
                let shown = GitWorkspace.git(["show", "\(branch):\(path)"], in: task.repo)
                if shown.exitCode == 0 { text += "\n" + shown.stdout }
            }
            let local = URL(fileURLWithPath: task.repo).appendingPathComponent(path)
            if let report = try? String(contentsOf: local, encoding: .utf8) {
                text += "\n" + report
            }
        }
        return text
    }
}
