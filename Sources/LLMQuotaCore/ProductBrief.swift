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

    static func clipped(_ raw: String, fileName: String) -> String {
        if raw.count > maxCharacters {
            return String(raw.prefix(maxCharacters))
                + "\n\n（\(fileName) 太长被截断了 —— 请只保留稳定、可验收的硬标准）"
        }
        return raw
    }

    /// 未截断全文。**ContextPackBuilder 必须用这个** —— 唯一总预算在那里
    /// 决定全文 / 折叠引用 / 拒绝；这里的 per-file 预截断会先把 P0 的尾部
    /// 吃掉，让 builder 把缺了语义的硬约束当完整派发出去。
    public static func fullText(repo: String) -> String? {
        let url = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath)
            .appendingPathComponent(fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return raw
    }

    public static func text(repo: String) -> String? {
        guard let raw = fullText(repo: repo) else { return nil }
        return clipped(raw, fileName: fileName)
    }

    /// 质量契约优先从当前 worktree 读取，配置和兜底内容按主仓库路径查。
    /// 这样已提交到分支的契约用分支版本；刚登记、还没进入稳定 worktree 的
    /// 契约也不会在第一次派活时静默消失。
    public static func qualityText(repo: String, registeredRepo: String? = nil) -> String? {
        guard let (name, raw) = qualityContent(repo: repo,
                                               registeredRepo: registeredRepo)
        else { return nil }
        return clipped(raw, fileName: name)
    }

    private static func qualityContent(
        repo: String, registeredRepo: String?
    ) -> (name: String, body: String)? {
        guard let name = RepoExecutionPolicy.repo(for: registeredRepo ?? repo)?
            .qualityContract?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !name.hasPrefix("/"), !name.contains("..")
        else { return nil }
        let roots = [repo, registeredRepo].compactMap { $0 }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for root in roots {
            let url = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
                .appendingPathComponent(name)
            if let raw = try? String(contentsOf: url, encoding: .utf8),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (name, raw)
            }
        }
        return nil
    }

    /// 拼进提示词的那一段。**明确告诉 agent 这是背景约束、不是任务。**
    public static func briefing(repo: String, registeredRepo: String? = nil) -> String {
        var sections: [String] = []
        if let facts = text(repo: repo) {
            sections.append(header(facts: facts))
        }
        if let quality = qualityText(repo: repo, registeredRepo: registeredRepo) {
            sections.append(qualityHeader(quality: quality))
        }
        return sections.joined()
    }

    /// 未截断版本，专供 ContextPackBuilder：全文 / 折叠引用 / 拒绝由唯一
    /// 总预算统一裁决，per-file 截断不在这条通路上发生 —— AGENTS.md 和
    /// 质量契约都是 P0，谁都不许在这里先被咬掉尾巴。
    public static func fullBriefing(repo: String, registeredRepo: String? = nil) -> String {
        var sections: [String] = []
        if let facts = fullText(repo: repo) {
            sections.append(header(facts: facts))
        }
        if let quality = qualityContent(repo: repo, registeredRepo: registeredRepo)
            .map(\.body) {
            sections.append(qualityHeader(quality: quality))
        }
        return sections.joined()
    }

    private static func header(facts: String) -> String {

        """

        ---
        ## 这个产品是什么、什么不能动（仓库里的 AGENTS.md，人工维护 —— 是约束，不是任务）

        改任何东西之前先读它。你的改动必须和下面的事实相容；
        如果手头的任务和某条铁律冲突，**在产出里明说冲突**，不要不吭声地
        二选一。

        \(facts)
        ---

        """
    }

    private static func qualityHeader(quality: String) -> String {

        """

        ---
        ## 这个项目怎样才算做完（项目质量契约 —— 是验收标准，不是参考建议）

        实现、取证和评审都必须逐条对照。构建通过只证明代码能跑，
        不能替代下面的体验门槛；不满足时必须明确写“未达标”，不能把局部
        功能存在描述成项目质量已经完成。

        \(quality)
        ---

        """
    }
}
