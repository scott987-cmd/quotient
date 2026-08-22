import Foundation

/// **「我没看清」不等于「我看到问题了」。**
///
/// ## 这条规则是怎么来的
///
/// 2026-08-22 凌晨,Flint 的两条产出被评审 agent 判「不合入」:
/// Bot AI(90 条测试全绿、有 60 秒交战录屏)和枪声三层混音。
/// 把两份报告里「截断 / 看不到 / 看不出 / 如果…没有」数一遍:**19 次和 10 次**。
/// 也就是说,评审**没有自己去拉 diff**,靠任务提示词里被截断的内联摘要
/// 猜出一堆「可能会出事」,然后保守地判了不合入。
///
/// 而一票否决是终局:分支从此不再派审核,产线一整夜卡着,老板问
/// 「任务为啥又停了」才发现。
///
/// 这不是评审 agent 笨,是**机制没给它「我需要再看看」这个选项** ——
/// 只有「合入」和「不合入」两个格子,它把不确定塞进了后者。
///
/// 所以:结论是「不合入」但通篇讲的是「我看不到」的,判为**看不清**,
/// 不记否决、退回去重审一次(带上「自己去 git diff」的硬要求)。
/// 真看到问题的照旧否决 —— 判据只看它讲的是缺信息还是缺质量。
public enum VerdictQuality {
    /// 「我没看清」类措辞。
    static let blindMarkers = ["截断", "看不到", "看不出", "没看到", "看不见",
                               "无法确认", "不确定是否", "需要看到", "diff 里没有"]

    /// 阈值用真实报告标定过(2026-08-22,六份历史评审):
    ///   盲 8/实 1、盲 9/实 3、盲 22/实 7  → 这三份确实是「没看就否」
    ///   盲 4/实 5、盲 2/实 2、盲 3/实 3  → 这三份有实据,必须照旧生效
    /// `盲 >= 5 且 盲 > 实 * 2` 把两组干净分开。
    /// 「我看到问题了」类措辞 —— 具体、可核对。
    /// 「我看到问题了」类措辞 —— 具体、可核对。
    ///
    /// **不能放「第 」「行」这种词**:任何讨论代码的报告都会命中,
    /// 于是「具体证据」被虚高,判据永远不成立(2026-08-22 实测:
    /// 一份 19 处盲目措辞的报告,因为「行」出现了 15 次而被判成有实据)。
    static let concreteMarkers = ["违反", "缺少登记", "没有登记", "未登记",
                                  "硬编码", "泄漏", "崩溃", "删除了", "绕过",
                                  "会失败", "入库", "未同步", "冲突"]

    /// 把评审真正的理由取出来。
    ///
    /// **任务输出里只有两行**:「已写 reviews/EVAL-xxx.md(6773 字)」和
    /// 「**结论**:不合入」—— 理由全在那个文件里。只看输出的话,
    /// 判据永远看不到「截断/看不到」那些话,这个检测等于没做
    /// (2026-08-22 实测:三条被否分支 inconclusive 全是 0,而报告里
    /// 那些话有 19 次和 10 次)。这就是**同一份信息两个地方**的老毛病:
    /// 结论在输出、依据在文件,谁读一半都会判错。
    public static func fullReport(taskOutputs: String, repoPath: String) -> String {
        // 输出里点名的报告文件,拼上仓库路径读回来。
        var text = taskOutputs
        let pattern = #"reviews/EVAL-[^\s（(]+\.md"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = taskOutputs as NSString
        for m in re.matches(in: taskOutputs, range: NSRange(location: 0, length: ns.length)) {
            let rel = ns.substring(with: m.range)
            let full = (repoPath as NSString).appendingPathComponent(rel)
            if let body = try? String(contentsOfFile: full, encoding: .utf8) {
                text += "\n" + body
            }
        }
        return text
    }

    /// 这份否决是不是「看不清」而不是「有问题」。
    ///
    /// 判据故意保守:盲目措辞要**明显多于**具体证据才算看不清。
    /// 宁可放过几份该重审的,也不要把真发现的问题当成「它没看清」洗掉 ——
    /// 后者是把审核闸拆了,前者只是多等一轮。
    public static func isInconclusive(_ report: String) -> Bool {
        guard !report.isEmpty else { return false }
        let blind = blindMarkers.reduce(0) { $0 + report.components(separatedBy: $1).count - 1 }
        let concrete = concreteMarkers.reduce(0) { $0 + report.components(separatedBy: $1).count - 1 }
        return blind >= 5 && blind > concrete * 2
    }

    /// 重审时追加的话:把「你没看」这件事直说。
    public static let lookHarderClause = """

        ---
        **上一轮的结论被退回了。** 上一份报告里「截断 / 看不到 / 看不出」
        这类话出现了很多次 —— 说明结论建立在没看全的摘要上,而不是改动本身。

        这一轮必须先做这件事,再写结论:

            git diff main...<分支>          # 全量改动,没有截断
            git show <某个提交>              # 单个提交
            git log main..<分支>            # 有哪些提交

        仓库就在你的工作区里,想看多少看多少。「看不到」不是理由,
        也不是扣分项 —— **去看**。结论只能建立在你真读过的内容上:
        没问题就判合入,有问题就指出具体是哪个文件哪一行。
        """
}
