import Foundation

/// MiniMax 负面主观结论的架构师复核层。
///
/// 通过结论不增加流程；测试命令的退出码也不经模型复议。只有新机制上线后
/// 产生的主观拒绝才进入这里，避免历史报告在部署时一次性回灌。
public enum ArchitectReview {
    public static let contractMarker = "【负面结论架构复核 v1】"
    private static let originPrefix = "architect-review:"
    private static let batchOriginPrefix = "architect-review-batch:"

    private struct Subject: Hashable {
        var repo: String
        var branch: String
        var head: String
    }

    public enum Decision: Equatable, Sendable {
        case missing, pending, uphold, overturn
    }

    public static func decision(for review: WorkTask, tasks: [WorkTask]) -> Decision {
        guard let task = architectTask(for: review, tasks: tasks) else { return .missing }
        guard task.state == .done else { return .pending }
        // 任务输出本身就是结构化结论的主通道。旧实现即使这里已经明确写了
        // “维持/推翻拒绝”，仍会为每张历史票启动一次 git show 再读报告；
        // 30 张票实测 8.3 秒，单这一层就足以拖垮 10 秒质量闭环。
        let direct = (task.outputs + [task.note ?? ""]).joined(separator: "\n")
        if let decision = parsedDecision(in: direct) { return decision }
        let text = reviewText(task)
        // 架构师常先写“## 架构复核结论”标题，再在报告末尾回显契约行。
        // 旧逻辑拿第一个含“结论”的行，标题既不是维持也不是推翻，于是把
        // 已完成报告永久判成 pending，视觉否决永远交不回原实现 owner。
        // 契约要求最后一行二选一；从尾部找带明确动作的结论也能避开正文讨论。
        return parsedDecision(in: text) ?? .pending
    }

    private static func parsedDecision(in text: String) -> Decision? {
        guard let line = text.components(separatedBy: .newlines).last(where: {
            $0.contains("结论")
                && ($0.contains("推翻拒绝") || $0.contains("维持拒绝"))
        }) else { return nil }
        if line.contains("推翻拒绝") { return .overturn }
        if line.contains("维持拒绝") { return .uphold }
        return nil
    }

    public static func reconcile(_ tasks: [WorkTask]) -> [WorkTask] {
        var made: [WorkTask] = []
        let architect = AgentRoles.architectPlatform()
        let legacySources = Set(tasks.compactMap { task -> String? in
            guard let origin = task.origin, origin.hasPrefix(originPrefix),
                  !origin.hasPrefix(batchOriginPrefix) else { return nil }
            return String(origin.dropFirst(originPrefix.count))
        })
        let batchSubjects = Set(tasks.compactMap { task -> String? in
            guard task.origin?.hasPrefix(batchOriginPrefix) == true,
                  let subject = subject(for: task) else { return nil }
            return subjectKey(subject)
        })
        // 已经有复核票的历史来源不必每 30 秒重新打开 EVAL/git 报告。
        let negative = tasks.filter { task in
            if legacySources.contains(task.id) { return true }
            if let subject = subject(for: task), batchSubjects.contains(subjectKey(subject)) {
                return !TaskKind.isArchitectReview(task.prompt)
            }
            return isNegative(task)
        }
        let grouped = Dictionary(grouping: negative) { review in
            subject(for: review).map(subjectKey) ?? "review:" + review.id
        }

        for reviews in grouped.values {
            let batchOrigins = subject(for: reviews[0]).map {
                [batchOrigin(for: $0)]
            } ?? []
            let origins = Set(reviews.map { originPrefix + $0.id } + batchOrigins)
            let existing = tasks.filter {
                guard let origin = $0.origin else { return false }
                return origins.contains(origin) && $0.discardedAt == nil
            }
            if let canonical = preferredArchitectTask(existing) {
                var updated = canonical
                var changed = false

                if updated.preferredPlatform != architect {
                    updated.preferredPlatform = architect
                    changed = true
                }

                // 平台额度、认证、网络断流都不是复核结论。恢复同一张票，
                // 同时清掉旧的终态/重试时间；平台级短冷却仍由账本负责。
                if updated.state == .failed,
                   CooldownLedger.classify(updated.note ?? "") != nil {
                    updated.state = .queued
                    updated.startedAt = nil
                    updated.endedAt = nil
                    updated.exitCode = nil
                    updated.runnerPID = nil
                    updated.triedPlatforms = []
                    updated.platform = nil
                    updated.terminalFailureKind = nil
                    updated.retryNotBefore = nil
                    updated.note = "架构师平台故障已进入短暂冷却；保留原复核任务和上下文续跑"
                    changed = true
                }
                if changed { made.append(updated) }

                // 升级前可能已经为同一分支/提交生成多张票。保留最有上下文
                // 的一张，其余只做可审计归并，不再排队重复消耗。
                for duplicate in existing where duplicate.id != canonical.id
                    && duplicate.state != .running {
                    var folded = duplicate
                    folded.state = .failed
                    folded.endedAt = folded.endedAt ?? Date()
                    folded.runnerPID = nil
                    folded.discardedAt = folded.discardedAt ?? Date()
                    folded.discardReason = "同一分支同一提交的架构复核已归并到 \(canonical.id)"
                    folded.note = "重复架构复核已归并到 \(canonical.id)，不再调用模型"
                    made.append(folded)
                }
                continue
            }

            let origin = reviews.count == 1
                ? originPrefix + reviews[0].id
                : batchOrigin(for: subject(for: reviews[0])!)
            var task = WorkTask(
                id: reviews.count == 1
                    ? "a" + String(reviews[0].id.prefix(7)).lowercased()
                    : "a" + stableSuffix(subjectKey(subject(for: reviews[0])!)),
                prompt: prompt(for: reviews), repo: reviews[0].repo)
            task.origin = origin
            task.preferredPlatform = architect
            task.profile = TaskProfile(
                tier: .standard, risk: .safe, estimatedMinutes: 8,
                isSelfContained: true,
                rationale: "MiniMax 负面主观结论由架构师复核")
            task.note = reviews.count == 1
                ? "等待架构师复核 MiniMax 的负面结论（\(reviews[0].id)）"
                : "等待架构师统一复核同一提交的 \(reviews.count) 份负面结论"
            made.append(task)
        }
        return made
    }

    private static func architectTask(for review: WorkTask,
                                      tasks: [WorkTask]) -> WorkTask? {
        let exactOrigin = originPrefix + review.id
        if let exact = preferredArchitectTask(tasks.filter {
            $0.origin == exactOrigin && $0.discardedAt == nil
        }) {
            return exact
        }
        var origins = Set<String>()
        if let target = subject(for: review) {
            origins.insert(batchOrigin(for: target))
            for source in tasks where subject(for: source) == target && isNegative(source) {
                origins.insert(originPrefix + source.id)
            }
        }
        return preferredArchitectTask(tasks.filter {
            guard let origin = $0.origin else { return false }
            return origins.contains(origin) && $0.discardedAt == nil
        })
    }

    private static func preferredArchitectTask(_ tasks: [WorkTask]) -> WorkTask? {
        tasks.enumerated().max { lhs, rhs in
            let l = architectPriority(lhs.element)
            let r = architectPriority(rhs.element)
            return l == r ? lhs.offset < rhs.offset : l < r
        }?.element
    }

    private static func architectPriority(_ task: WorkTask) -> Int {
        if task.state == .done, parsedDecision(in:
            (task.outputs + [task.note ?? ""]).joined(separator: "\n")) != nil { return 50 }
        if task.state == .running { return 40 }
        if task.ownerRunnerID != nil { return 30 }
        if task.state == .queued { return 20 }
        if task.state == .failed { return 10 }
        return 0
    }

    private static func subject(for review: WorkTask) -> Subject? {
        guard let branch = TaskKind.boundBranch(review.prompt) else { return nil }
        let head = MergeReview.reviewedHead(in: review.prompt)
            ?? headAfterSubmitMarker(in: review.prompt)
        guard let head, !head.isEmpty else { return nil }
        return Subject(
            repo: URL(fileURLWithPath: review.repo).standardizedFileURL.path,
            branch: branch, head: head)
    }

    private static func headAfterSubmitMarker(in prompt: String) -> String? {
        guard let marker = prompt.range(of: " 提交 ") else { return nil }
        let sha = prompt[marker.upperBound...].prefix { $0.isHexDigit }
        return sha.isEmpty ? nil : String(sha)
    }

    private static func subjectKey(_ subject: Subject) -> String {
        subject.repo + "|" + subject.branch + "|" + subject.head
    }

    private static func batchOrigin(for subject: Subject) -> String {
        batchOriginPrefix + stableSuffix(subjectKey(subject))
    }

    private static func stableSuffix(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%07x", hash & 0x0fff_ffff)
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
              !TaskKind.isArchitectReview(review.prompt),
              !TaskKind.isTechnicalDisposition(review.prompt) else { return false }

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

    private static func prompt(for reviews: [WorkTask]) -> String {
        let review = reviews[0]
        let target = subject(for: review)
        let materialLimit = max(2_000, 12_000 / reviews.count)
        let materials = reviews.map { source in
            let material = String(reviewText(source).prefix(materialLimit))
            return """
            ### 来源评审 \(source.id)（\(source.origin ?? "未知类型")）
            \(material.isEmpty ? "（没有可读结论材料；不得据此推翻拒绝）" : material)
            """
        }.joined(separator: "\n\n")
        // 原评审提示词会嵌入来源任务，而视觉整改又会把上一轮报告追加到来源
        // 任务。若这里原样复制，复核提示会按轮次膨胀；现场一条已经超过
        // 70 万字符。架构师只需要任务身份、分支/提交和负面证据，前 4000
        // 字足以保留这些稳定字段，完整改动仍应直接从仓库核查。
        let original = String(review.prompt.prefix(4_000))
        let title = reviews.count == 1
            ? "MiniMax 评审任务 \(review.id) 的负面结论是否成立。"
            : "同一分支同一提交的 \(reviews.count) 份负面结论是否成立。"
        let targetLine = target.map {
            "目标分支：\($0.branch)\n目标提交：\($0.head)"
        } ?? ""
        return """
        【架构复核】\(title)

        \(targetLine)

        原任务：
        \(original)
        \(review.prompt.count > original.count ? "\n（来源任务历史已截断；请以仓库、分支和提交为准，不要依赖累积提示词。）" : "")

        MiniMax 的结论和证据（同一目标只开这一张架构票）：
        \(materials)

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
