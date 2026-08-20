import Foundation

/// 产品事实注入：把仓库根目录的 `AGENTS.md` 拼进每个任务的提示词。
///
/// ## 这东西为什么存在
///
/// 老板（2026-08-20）：「项目的设计和产品文档如何避免后期频繁的改变，
/// 或者让不同的 agent 不知道自己在干啥」。
///
/// 两个问题其实是一个：**产品事实只存在于老板脑子里（或散在聊天记录里），
/// agent 只能临场猜** —— 猜错了就返工，返工就要改文档，文档就频繁变。
///
/// 解法分两半：
///
/// 1. **每个仓库一份 `AGENTS.md`，只放不随时间变的事实**：这是什么产品、
///    什么绝对不能动（铁律）、验证怎么跑。状态类信息（还差什么、进度）
///    写别的文件 —— 会变的和不变的分开放，不变的那份才不会被改来改去。
/// 2. **派活时自动注入**（就在这里）：agent 不用猜、不用翻，
///    每个任务开工时产品事实就在提示词里。
///
/// 和 `RepoMap`（结构，自动生成）互补：地图告诉 agent **去哪找**，
/// 这份告诉 agent **在给什么干活、什么不能碰**。
public enum ProductBrief {

    /// 约定文件名。AssetPacks 已经用它记「上架三关」这类铁律，沿用。
    public static let fileName = "AGENTS.md"

    /// 注入上限。产品事实该是一页纸 —— 超了截断并提醒去精简，
    /// 别让一份写飞的文档吃掉任务本身的上下文。
    public static let maxCharacters = 8_000

    public static func text(repo: String) -> String? {
        let url = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath)
            .appendingPathComponent(fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if raw.count > maxCharacters {
            return String(raw.prefix(maxCharacters))
                + "\n\n（AGENTS.md 太长被截断了 —— 这个文件该是一页纸的铁律，考虑精简）"
        }
        return raw
    }

    /// 拼进提示词的那一段。**明确告诉 agent 这是背景约束、不是任务。**
    public static func briefing(repo: String) -> String {
        guard let facts = text(repo: repo) else { return "" }
        return """


        ---
        ## 这个产品是什么、什么不能动（仓库里的 AGENTS.md，人工维护 —— 是约束，不是任务）

        改任何东西之前先读它。你的改动必须和下面的事实相容；
        如果手头的任务和某条铁律冲突，**在产出里明说冲突**，不要不吭声地
        二选一。

        \(facts)
        ---

        """
    }
}
