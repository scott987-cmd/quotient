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
    /// 这个任务要**亲眼看**图片或录屏吗。
    ///
    /// 老板 2026-08-22：「MiniMax 支持视频输入,视频图片评审走它,
    /// 不要走 opencode —— opencode 配的 GLM 仅支持文本」。
    /// 纯文本模型对着文件名编一份「看起来没问题」,比不派更糟:
    /// 它的结论会被当成正式票记下来。
    public static func needsEyes(_ prompt: String) -> Bool {
        prompt.hasPrefix("【看效果】")
    }

    public static func isReview(_ prompt: String) -> Bool {
        prompt.hasPrefix("【评审") || prompt.hasPrefix("【审查")
            || prompt.hasPrefix("【看效果】")
    }

    /// 要 agent 跑起来截图取证那一类。
    public static func isEvidence(_ prompt: String) -> Bool {
        prompt.hasPrefix("【证据")
    }

    /// 把分支和 main 重新对齐那一类。
    public static func isRefresh(_ prompt: String) -> Bool {
        prompt.hasPrefix("【刷新")
    }

    /// 这条任务绑的目标分支(审查/证据/刷新这三类派生任务才有)。
    ///
    /// ## 为什么要能读出来
    ///
    /// 派生任务入队时分支还活着,执行时可能早就合入或没了 —— 2026-08-20
    /// 一晚五例:三条审核(288s+两快审)、一条证据(267s)全对着已合入的
    /// 2841e486 白跑,产出还污染 docs/evidence 把正主挤成冲突。
    /// 派活前要核「分支还在且未合」,第一步就是从提示词读出它绑的是谁。
    ///
    /// **和三份模板成对**(改模板必须同步改这里,反之亦然):
    /// - `MergeReview.reviewPrompt`: 「【审查·合入】分支 <b> 的改动…」
    /// - `EvidenceGate.evidencePrompt`: 「【证据】把分支 <b> 的改动跑起来…」
    /// - `StaleBranch` 刷新: 「【刷新】把 main 合进分支 <b>，解决冲突。」
    public static func boundBranch(_ prompt: String) -> String? {
        for marker in ["【审查·合入】分支 ", "【证据】把分支 ", "把 main 合进分支 "] {
            guard let r = prompt.range(of: marker) else { continue }
            let rest = prompt[r.upperBound...]
            let end = rest.firstIndex { $0 == " " || $0 == "，" || $0 == "\n" }
                ?? rest.endIndex
            let b = String(rest[..<end])
            return b.isEmpty ? nil : b
        }
        return nil
    }

    /// 这条分支还有没有**同类**的派生任务在排/在跑。
    ///
    /// ## 为什么派生任务不能用通用查重
    ///
    /// 审查/证据/刷新的提示词都是模板,模板对模板必然「相似」——
    /// DuplicateGuard 会拿一条分支的刷新任务和**另一条分支**的刷新任务
    /// 比出重复,然后 `.duplicate` → 静默 continue,一行日志都没有。
    ///
    /// 实锤两次:2026-08-21 上午审核派发(菜单分支 40+ 轮派不出,整仓空转);
    /// 同日深夜刷新派发(音效分支 18 个文件落后 20 个提交,`stale --dispatch`
    /// 每次都「无输出」)。第 9 例同概念多处判定 —— 精确判据只该有一个:
    /// **同一条分支 + 同一类派生任务 + 还没跑完**。
    ///
    /// - Parameter kind: 用 `isReview` / `isEvidence` / `isRefresh` 传进来。
    public static func hasPendingDerived(branch: String, tasks: [WorkTask],
                                         kind: (String) -> Bool) -> Bool {
        tasks.contains { t in
            (t.state == .queued || t.state == .running)
                && kind(t.prompt)
                && boundBranch(t.prompt) == branch
        }
    }

    /// 普通编码任务 —— 上面几类都不是。
    ///
    /// 这是**默认**：一个没写前缀的任务就是要改代码的活，
    /// 不该被任何专用执行器接走。
    public static func isCoding(_ prompt: String) -> Bool {
        !isMedia(prompt) && !isReview(prompt)
            && !isEvidence(prompt) && !isRefresh(prompt)
    }
    /// **这类活要不要等 main 的基线追平。**
    ///
    /// 基线闸存在的理由是：agent 拿落后几十个提交的 main 当「现状」，
    /// 会把已经做好的东西重造一遍。但这个理由**只对在 main 上盖东西的
    /// 活成立**：
    ///
    /// - `【审查】` 读的是指定的那个 commit（`git show <sha>`）；
    /// - `【证据】` checkout 指定分支跑起来截图；
    /// - `【刷新】` **本身就是把 main 合进分支**的那个机制；
    /// - `【媒体】` 生成素材，根本不读代码现状。
    ///
    /// 这四类拿旧基线也不会重造任何东西。
    ///
    /// ## 不放行的后果是死结
    ///
    /// 实测（2026-08-19）：基线闸原先对所有任务一视同仁，于是
    ///
    ///   基线旧（有分支没合）→ 挡住所有任务 → 审查任务跑不了
    ///     → 分支等不到 agent 审核 → 永远合不进去 → 基线永远旧
    ///
    /// **解开基线的钥匙被基线锁在外面。** 整套系统停摆两天，
    /// 老板在手机上看到的是「正在进行」永远空着。
    ///
    /// git log 里 `e8734d5「死结：autoland 等 agent 审核，而审核永远
    /// 不会被派」` 是同一个形状的上一次 —— 那次堵在派活侧，这次堵在基线侧。
    public static func needsFreshBaseline(_ prompt: String) -> Bool {
        isCoding(prompt)
    }
}
