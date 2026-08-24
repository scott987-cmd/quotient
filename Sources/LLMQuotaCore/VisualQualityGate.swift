import Foundation

/// 项目质量契约的多模态合入闸。
///
/// 代码审核回答“会不会坏”，这一层回答“画面上是否真的达到项目标准”。
/// 只对配置了 qualityContract、且改动会影响可见行为的仓库生效。
public enum VisualQualityGate {
    public enum Status: Equatable, Sendable {
        case missing, pending, approved, rejected
    }

    static func marker(branch: String, head: String) -> String {
        "【看效果】分支 \(branch) 提交 \(head)"
    }

    public static func status(branch: String, head: String,
                              tasks: [WorkTask]) -> Status {
        let prefix = marker(branch: branch, head: head)
        let matching = tasks.filter { $0.prompt.hasPrefix(prefix) }
        if matching.contains(where: { $0.state == .queued || $0.state == .running }) {
            return .pending
        }
        for t in matching where t.state == .done {
            let text = (t.outputs + [t.note ?? ""]).joined(separator: "\n")
            guard let line = text.components(separatedBy: .newlines)
                .first(where: { $0.contains("结论") }) else { continue }
            if line.contains("未达标") { return .rejected }
            if line.contains("达标") { return .approved }
        }
        return .missing
    }

    public static func hasApproved(branch: String, tasks: [WorkTask]) -> Bool {
        tasks.contains { t in
            t.state == .done
                && t.prompt.hasPrefix("【看效果】分支 \(branch) 提交 ")
                && (t.outputs + [t.note ?? ""]).contains(where: {
                    $0.components(separatedBy: .newlines).contains(where: {
                        $0.contains("结论") && $0.contains("达标")
                            && !$0.contains("未达标")
                    })
                })
        }
    }

    @discardableResult
    public static func dispatch(item: Review.Item, repo: String,
                                tasks: [WorkTask]) -> String? {
        guard status(branch: item.branch, head: item.head, tasks: tasks) == .missing,
              !tasks.contains(where: {
                  $0.origin == "visual-quality-review"
                      && ($0.state == .queued || $0.state == .running)
              })
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
}
