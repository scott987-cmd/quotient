import Foundation

/// 把“合入后审查”里的具体缺陷变成确定性的整改任务。
///
/// `ReservePool` 只在额度快作废且队列空时取活，适合维护候选，不适合质量闭环。
/// 已经由审查员确认的问题必须立刻入队；否则报告写得再准也只是躺在磁盘上。
public enum PostLandRepair {
    public static let contractMarker = "【整改契约 v1】"

    public static func reconcile(_ tasks: [WorkTask]) -> [WorkTask] {
        reconcile(tasks, reportText: loadReport)
    }

    static func reconcile(_ tasks: [WorkTask],
                          reportText: (WorkTask) -> String?) -> [WorkTask] {
        var repairs: [WorkTask] = []
        var knownOrigins = Set(tasks.compactMap(\.origin))

        for review in tasks where review.origin == "post-land-review"
            && review.state == .done && review.discardedAt == nil
            && review.prompt.contains(contractMarker) {
            let origin = "post-land-repair:" + review.id
            guard !knownOrigins.contains(origin),
                  let text = reportText(review) else { continue }
            let findings = findings(in: text)
            guard !findings.isEmpty else { continue }
            if review.prompt.contains(ArchitectReview.contractMarker),
               ArchitectReview.decision(for: review, tasks: tasks) != .uphold {
                continue
            }

            let sourceBranch = reviewedBranch(in: review.prompt)
            let sourceID = sourceBranch.map {
                String($0.split(separator: "/").last ?? "")
            }
            let source = sourceID.flatMap { id in
                tasks.last(where: { $0.id == id })
            } ?? sourceBranch.flatMap { branch in
                tasks.last(where: {
                    $0.repo == review.repo && $0.branch == branch
                        && $0.origin != "post-land-review"
                })
            }
            let list = findings.enumerated().map { i, finding in
                "\(i + 1). \(finding)"
            }.joined(separator: "\n")

            var repair = WorkTask(
                id: "r" + String(review.id.prefix(7)).lowercased(),
                prompt: """
                【合入后审查整改｜保持原 Agent 项目会话】
                审查任务 \(review.id) 对已合入成果发现了以下确定缺陷：

                \(list)

                逐项定位并修复，给每条缺陷补能复现失败形状的回归测试；不要只改
                报告或措辞。修完跑仓库完整验证，并在提交说明里逐条对应上面的编号。
                这是原成果的整改续作，不要扩张无关功能。
                """,
                repo: review.repo)
            repair.origin = origin
            repair.ownerPlatform = source?.ownerPlatform ?? source?.platform
            repair.ownerRunnerID = source?.ownerRunnerID
            repair.ownerAssignedAt = source?.ownerAssignedAt ?? source?.startedAt
            repair.preferredPlatform = repair.ownerPlatform ?? source?.preferredPlatform
            repair.platform = repair.ownerPlatform
            repair.profile = source?.profile
            repair.production = source?.production
            repair.note = "合入后审查发现 \(findings.count) 条缺陷，已交回原 Agent 项目会话"
            repairs.append(repair)
            knownOrigins.insert(origin)
        }
        return repairs
    }

    private static func reviewedBranch(in prompt: String) -> String? {
        guard let marker = prompt.range(of: "来源分支 ") else { return nil }
        let tail = prompt[marker.upperBound...]
        let branch = tail.prefix {
            !$0.isWhitespace && $0 != "）" && $0 != ")" && $0 != "。"
        }
        return branch.isEmpty ? nil : String(branch)
    }

    private static func reportPath(in prompt: String) -> String? {
        guard let start = prompt.range(of: "reviews/REVIEW-") else { return nil }
        let tail = prompt[start.lowerBound...]
        guard let end = tail.range(of: ".md") else { return nil }
        return String(tail[..<end.upperBound])
    }

    static func findings(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap(ReservePool.findingNote)
    }

    static func reportText(for review: WorkTask) -> String? {
        loadReport(review)
    }

    private static func loadReport(_ review: WorkTask) -> String? {
        guard let path = reportPath(in: review.prompt) else { return nil }
        if let branch = review.branch {
            let shown = GitWorkspace.git(["show", "\(branch):\(path)"], in: review.repo)
            if shown.exitCode == 0, !shown.stdout.isEmpty { return shown.stdout }
        }
        return try? String(contentsOf: URL(fileURLWithPath: review.repo)
            .appendingPathComponent(path), encoding: .utf8)
    }
}
