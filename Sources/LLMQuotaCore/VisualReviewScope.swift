import Foundation

/// 阶段观察只产生事实反馈；正式质量票才能影响合入和自动整改。
/// 来源字段优先于正文，避免来源任务引用的阶段标记降低正式验收范围。
public enum VisualReviewScope: String, Sendable {
    case observation, acceptance

    public static let observationMarker = "【阶段观察 v1】"

    /// 机器用途由 origin 决定，不能把等价 Markdown 排版当成模型失败。
    /// 无判定的阶段标题也可保留，但绝不能由程序猜成“通过/失败”。
    public var acceptedHeadings: [String] {
        switch self {
        case .observation:
            return ["**阶段观察**：发现可见问题", "**阶段观察**：未见明显问题",
                    "**阶段观察**：证据不足", "# 阶段观察", "## 阶段观察",
                    "**阶段观察**", "阶段观察"]
        case .acceptance:
            return ["**结论**：达标", "**结论**：未达标"]
        }
    }

    public func acceptsReportHeading(_ report: String) -> Bool {
        guard let heading = report.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return false }
        return acceptedHeadings.contains(heading)
    }

    public static func resolve(task: WorkTask) -> Self {
        if let origin = task.origin {
            return origin == "milestone-eyes" ? .observation : .acceptance
        }
        return resolve(prompt: task.prompt)
    }

    static func resolve(prompt: String) -> Self {
        let lines = prompt.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return lines.contains(observationMarker)
            || lines.contains(where: {
                $0.hasPrefix("【看效果】看一遍这次产出的录屏/截图")
            }) ? .observation : .acceptance
    }

    var rules: String {
        let evidenceLimits = """
        先写本次范围，再按“可见事实 / 对应画面 / 本次适用条款 / 无法判断项”报告。
        来源任务明确的目标和非目标优先于通用 QUALITY；安全、真实性和冻结边界不放宽。
        未出现在送审材料中，不等于整个项目不存在。静态图不能证明动画、帧率、交互或完整流程；
        抽帧只能证明被抽到的画面，不能断言逐帧看完或实时性能。A/T-pose 母版参考姿势
        不等于游戏运行中卡在 T-pose；只有证据和本次适用目标支持时才报告为缺陷。
        不得因模型参考图未展示 HUD、武器或连续对局，就断言游戏缺失这些功能。
        """
        switch self {
        case .observation:
            return """
            本次是阶段观察，不是整项目验收，不签发合入票，不指令原 Owner 自动返工。
            第一行必须是“**阶段观察**：发现可见问题”、“**阶段观察**：未见明显问题”
            或“**阶段观察**：证据不足”。不得输出“**结论**：达标/未达标”。
            \(evidenceLimits)
            缺少支持当前阶段声明的材料时列为待核验，不虚构通过，也不升级成整个项目失败。
            通用项目验收标准仅供范围对照，不要求这次局部证据一次证明全部终验条款。
            """
        case .acceptance:
            return """
            本次是正式质量验收。第一行必须是“**结论**：达标”或“**结论**：未达标”。
            \(evidenceLimits)
            必须逐条核对本次适用的验收要求；任一适用要求失败或证据不足均不得通过，
            证据不足应明确写“未验证”，而不是编造实现缺陷。非目标不能作为否决项。
            """
        }
    }

    var framePrompt: String {
        "只描述实际可见的画面，分开记录几何/材质/姿势/界面与看不清的部分，不凭文件名猜。"
            + "静态图不能证明动画、帧率或交互流程。A/T-pose 可能是参考姿势，不推断运行时卡死。"
            + "若实际看见持枪画面，再描述双手接触、手腕和穿模；若看见界面，再描述可读性。"
            + "本次用途：\(rawValue)。不要套用所有游戏共有的 HUD/持枪清单；最终范围由任务限定。"
    }
}
