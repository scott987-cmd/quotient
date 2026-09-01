import Foundation

/// 黄金样板连续不收敛后的前置设计闭环。
///
/// 原实现任务始终保留原 Owner、分支和会话；架构师只产出架构方案。报告完整且
/// 明确“允许恢复”后，才把方案交回原任务继续实现。
public enum QualityArchitectureReview {
    public static let originPrefix = "quality-architecture-review:"
    public static let promptPrefix = "【架构复核】黄金样板前置设计"
    private static let requiredSections = [
        "目标与差距", "资产管线", "骨骼与握枪约束", "渲染与取证",
        "量化验收门槛", "实施顺序", "停止条件",
    ]
    private static let externalBlockingTypes = ["用户决策", "外部审批", "外部资源"]

    public enum Decision: Equatable, Sendable {
        case pending, allowResume, remainPaused
    }

    public static func decision(for task: WorkTask) -> Decision {
        guard task.state == .done else { return .pending }
        return decision(in: reviewText(task))
    }

    private static func decision(in text: String) -> Decision {
        guard requiredSections.allSatisfy(text.contains) else { return .pending }
        guard let conclusion = text.components(separatedBy: .newlines).last(where: {
            $0.contains("结论") && ($0.contains("允许恢复") || $0.contains("保持暂停"))
        }) else { return .pending }
        if conclusion.contains("允许恢复") { return .allowResume }
        // “样板还没过”是恢复实现后要完成的工作，不能反过来成为恢复前置条件。
        // 只有原 Owner 无法自行解除的结构化外部阻塞才允许继续冻结。
        return hasExternalBlocker(text) ? .remainPaused : .allowResume
    }

    public static func reconcile(_ tasks: [WorkTask], now: Date = Date()) -> [WorkTask] {
        let architect = AgentRoles.architectPlatform()
        let architectName = architect.displayName + " 架构师"
        var latest: [String: WorkTask] = [:]
        for task in tasks { latest[task.id] = task }
        let current = Array(latest.values)
        let byOrigin = Dictionary(
            current.compactMap { task in task.origin.map { ($0, task) } },
            uniquingKeysWith: { _, newer in newer })
        var updates: [WorkTask] = []

        for original in current where original.pausedAt != nil
            && original.architectureReviewRequestedAt != nil {
            let request = original.architectureReviewRequestedAt!
            let origin = originPrefix + original.id + ":" + String(Int(request.timeIntervalSince1970))

            // 已经存在的评审只需对账结论。旧实现仍先跑 branchExists/rev-parse，
            // 既让历史票每轮重复访问 Git，也会在分支暂时不可见时吞掉已经完成的
            // 评审结论。只有首次创建评审时才需要读取分支快照。
            if let review = byOrigin[origin] {
                let text = reviewText(review)
                switch decision(in: text) {
                case .allowResume:
                    var resumed = TaskPause.resume(
                        original,
                        reason: "架构重审 \(review.id) 已形成可执行方案；沿用原 Owner、分支和会话恢复实现",
                        now: now)
                    let marker = "【架构重审方案：\(review.id)】"
                    if !resumed.prompt.contains(marker) {
                        resumed.prompt += "\n\n\(marker)\n" + String(text.suffix(12_000))
                    }
                    resumed.preferredPlatform = resumed.ownerPlatform ?? resumed.platform
                    updates.append(resumed)
                case .remainPaused:
                    var held = original
                    held.note = "架构重审任务 \(review.id) 已完成，结论为保持暂停；"
                        + "实现 Owner、分支和上下文继续保留"
                    if held.note != original.note { updates.append(held) }
                case .pending:
                    if let retried = retryReview(review) { updates.append(retried) }
                    var waiting = original
                    let status: String
                    switch review.state {
                    case .queued: status = "等待 \(architectName)领取"
                    case .running: status = "\(architectName)正在完成前置设计"
                    case .failed:
                        status = (review.interruptedCount ?? 0) >= 2
                            ? "架构重审两次失败，保持暂停"
                            : "架构重审失败，准备同票补跑"
                    case .done:
                        status = (review.interruptedCount ?? 0) >= 2
                            ? "架构报告仍不完整，保持暂停"
                            : "架构报告缺少必填章节或结构化结论，准备补齐"
                    case .blocked: status = "架构重审被阻塞"
                    }
                    waiting.note = "架构重审任务 \(review.id)：\(status)；实现 Owner 保持 "
                        + (original.ownerRunnerID ?? original.platform?.displayName ?? "原 Agent")
                    if waiting.note != original.note { updates.append(waiting) }
                }
                continue
            }

            guard let branch = original.branch,
                  GitWorkspace.branchExists(branch, in: original.repo) else {
                var blocked = original
                blocked.note = "架构重审无法开始：原实现分支不存在；任务保持暂停"
                if blocked.note != original.note { updates.append(blocked) }
                continue
            }
            let head = GitWorkspace.git(["rev-parse", branch], in: original.repo)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { continue }
            var created = WorkTask(
                id: reviewID(origin: origin),
                prompt: prompt(for: original, branch: branch, head: head),
                repo: original.repo)
            created.origin = origin
            created.preferredPlatform = architect
            created.profile = TaskProfile(
                tier: .standard, risk: .safe, estimatedMinutes: 12,
                isSelfContained: true,
                rationale: "质量不收敛后的前置架构设计；不接管原实现")
            created.note = "等待 \(architectName)领取架构重审 · 原任务 \(original.id)"
            updates.append(created)

            var waiting = original
            waiting.note = "架构重审任务 \(created.id)：等待 \(architectName)领取；实现 Owner 保持 "
                + (original.ownerRunnerID ?? original.platform?.displayName ?? "原 Agent")
                + "；快照 " + String(head.prefix(8))
            updates.append(waiting)
        }
        return updates
    }

    private static func retryReview(_ task: WorkTask) -> WorkTask? {
        guard task.state == .failed || task.state == .done else { return nil }
        let attempts = task.interruptedCount ?? 0
        let platformFailure = task.state == .failed
            && CooldownLedger.classify(task.note ?? "") != nil
        // 正常的执行/报告质量问题最多补两次；平台额度、认证或环境故障并不
        // 是评审结论，旧任务已经耗尽两次同平台重试时，再给一次迁移机会。
        // 平台故障只重开同一票；架构师角色不能因额度故障静默换给普通开发。
        let retryLimit = platformFailure ? 3 : 2
        guard attempts < retryLimit else { return nil }
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
        retry.note = platformFailure
            ? "架构重审平台故障已进入冷却；保留同一任务交给独立候选续跑（\(attempts + 1)/3）"
            : task.state == .done
            ? "架构报告不完整，保留同一任务补齐（\(attempts + 1)/2）"
            : "架构重审执行失败，保留同一任务补跑（\(attempts + 1)/2）"
        return retry
    }

    private static func prompt(for original: WorkTask, branch: String, head: String) -> String {
        let report = "docs/design/quality-architecture-\(original.id).md"
        return """
        \(promptPrefix)：原任务 \(original.id)

        原实现 Owner：\(original.ownerRunnerID ?? original.platform?.displayName ?? "未知")
        原实现分支：\(branch)
        冻结快照：\(head)
        暂停原因：\(original.pauseReason ?? original.note ?? "质量未收敛")
        原始目标：\(String(original.prompt.prefix(4_000)))

        你是架构师，只做恢复实现前的完整前置设计，不接管实现、不修改功能代码、
        不更换原任务 Owner。先检查 `git diff main...\(branch)`、冻结提交、现有模型/
        骨骼/Blender 脚本、视觉证据和失败记录；禁止通过降低、删除或绕过质量门槛
        让结果过关。

        把可直接执行的方案写入 \(report)，且必须包含以下七个二级标题：
        ## 目标与差距
        ## 资产管线
        ## 骨骼与握枪约束
        ## 渲染与取证
        ## 量化验收门槛
        ## 实施顺序
        ## 停止条件

        “量化验收门槛”必须登记现有批准阈值、证据视角和失败判定；“实施顺序”必须
        给出先验证哪个最小样板、通过后才能进入哪一步；“停止条件”必须说明何时不再
        迭代旧资产而改走重建/替换路径。只允许新增这份报告。

        “保持暂停”只用于原 Owner 无法自行解除的外部条件；必须在结论前另起一行，
        从以下三类中精确填写一类：
        **阻塞类型**：用户决策
        **阻塞类型**：外部审批
        **阻塞类型**：外部资源
        样板尚未通过、仍需实现 PBR/模型/代码、还要跑测试或独立评审，都是恢复后
        要执行的步骤，不是外部阻塞，必须选择“允许恢复”。

        最后一行必须二选一，并在任务输出中原样回显：
        **结论**：允许恢复
        **结论**：保持暂停
        """
    }

    private static func hasExternalBlocker(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return externalBlockingTypes.contains { compact == "**阻塞类型**：\($0)" }
        }
    }

    private static func reviewText(_ task: WorkTask) -> String {
        var text = (task.outputs + [task.note ?? ""]).joined(separator: "\n")
        guard let originalID = task.origin.map({
            String($0.dropFirst(originPrefix.count).split(separator: ":", maxSplits: 1).first ?? "")
        }) else { return text }
        let path = "docs/design/quality-architecture-\(originalID).md"
        if let branch = task.branch {
            let shown = GitWorkspace.git(["show", "\(branch):\(path)"], in: task.repo)
            if shown.exitCode == 0 { text += "\n" + shown.stdout }
        }
        let local = URL(fileURLWithPath: task.repo).appendingPathComponent(path)
        if let report = try? String(contentsOf: local, encoding: .utf8) {
            text += "\n" + report
        }
        return text
    }

    private static func reviewID(origin: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in origin.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return "q" + String(format: "%07x", hash & 0x0fff_ffff)
    }
}
