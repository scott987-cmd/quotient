import Foundation

/// 任务属于哪一类 —— **只准有这一处判定。**
///
/// ## 为什么必须收成一处
///
/// 2026-08-18 实测：同一个概念在代码里有四种写法 ——
/// `hasPrefix("【评审")`、`hasPrefix("【审查】")`、`contains("【审查·合入】")`、
/// `hasPrefix("【媒体】")`。于是调度那道闸只认 `【评审`，
/// 而当天新加的合入审核用的是 `【审查·合入】`，两边对不上。
///
/// 后果不是「少拦一次」，是**编码任务被静默转成评审报告**：
///
/// > 任务「把 Maw 里的临时调试入口清干净」被派给 MiniMax 评审执行器。
/// > 那个执行器把**任何**提示词都当评审处理，于是 20 秒写了一份
/// > `reviews/EVAL-项目-*.md` 就报「完成」，一行调试代码都没删。
///
/// 而且它是静默的：任务状态是 done、有提交、有分支，
/// 外面看起来一切正常。盘点发现**12 个非评审任务**被这样处理过 ——
/// 那 8 条一直合不进去的 EVAL-*.md 分支，大半就是这么来的。
///
/// 「同一个概念多处判定」这个形状当天已经害了五次
///（见 DiscardedUpstreamTests 里那条模式测试）。所以这里收成一处，
/// 谁要判任务类型都走这个类型，别再自己写前缀比较。
public enum TaskKind {

    /// 生成图片 / 音频那一类，只有媒体执行器能干。
    ///
    /// 判前缀而不是判「含有」：提示词正文里提到「媒体」两个字太常见了
    ///（「这一步不做媒体资源」也会中）。
    public static func isMedia(_ prompt: String) -> Bool {
        prompt.hasPrefix("【媒体")
    }

    /// 读材料给判断、不改功能代码那一类，评审执行器专用。
    ///
    /// **必须同时认「评审」和「审查」两种写法。** 它们在这套系统里
    /// 一直混着用：人写的是 `【评审·项目】`，机器发的是 `【审查·合入】`、
    /// `【审查】复查刚合入 main 的合并 …`。
    /// 只认一种的代价见类型注释。
    public static func isReview(_ prompt: String) -> Bool {
        prompt.hasPrefix("【评审") || prompt.hasPrefix("【审查")
    }

    /// 要 agent 跑起来截图取证那一类。
    public static func isEvidence(_ prompt: String) -> Bool {
        prompt.hasPrefix("【证据")
    }

    /// 把分支和 main 重新对齐那一类。
    public static func isRefresh(_ prompt: String) -> Bool {
        prompt.hasPrefix("【刷新")
    }

    /// 普通编码任务 —— 上面几类都不是。
    ///
    /// 这是**默认**：一个没写前缀的任务就是要改代码的活，
    /// 不该被任何专用执行器接走。
    public static func isCoding(_ prompt: String) -> Bool {
        !isMedia(prompt) && !isReview(prompt)
            && !isEvidence(prompt) && !isRefresh(prompt)
    }
}
