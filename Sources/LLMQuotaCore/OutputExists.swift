import Foundation

/// 产出已存在：**这一步要造的东西，已经在了。**
///
/// ## 老板的问题
///
/// > 为啥已经在了任务却还要重复执行？问题原因在哪里？
///
/// 实况（2026-08-17）：Greed 两条图的五个步骤冻着等上游，而它们要做的事
/// —— BGM 接进玩法阶段、SettingsView、根视图设置入口、两个持久化开关 ——
/// **全都已经在 main 上了**，连 UserDefaults 的 key 名
///（`audio.bgmEnabled` / `audio.sfxEnabled`）都和任务描述里写的一字不差。
///
/// 根因是三层：
///
/// 1. **查重只跟「别的任务」比，从不跟「仓库现状」比。**
///    `DuplicateGuard.matches(prompt:repo:in tasks:)` 比的是提示词之间的
///    相似度和共同符号 —— 参数里连 git 都不碰。「这活已经在代码里做完了」
///    对它完全不可见。
///
/// 2. **图在定义时一次性写死，执行前没人重新问一遍。**
///    拆解发生在入队那一刻，每步提示词都是对着当时的世界写的
///    （「本步新增 SettingsView」）。之后它在队列里等几小时到几天，
///    这期间：人可能手工做了、别的任务可能顺手做了、上游 agent 可能一并
///    做了（很常见 —— agent 看到相关代码会顺手补全）。而执行前的检查只有
///    两条：依赖满足了吗（图）、有平台吗（调度）。
///
/// 3. **`PremiseCheck` / `BaselineFreshness` 也没覆盖这个。**
///    那两条问的是「我依赖的东西在不在」「基线是不是真的」——
///    **都是输入侧**。这里问的是输出侧。两个不同的问题。
///
/// ## 判据
///
/// 用提示词里明写要新建的路径。这正好是 `PremiseCheck` 故意**排除**的那些
/// （它排除是对的：要新建的文件不该当成前提）—— 在这里它们恰恰是主角。
///
/// 要求**声明的产出全部都已存在**才算已完成。少一个就照旧跑 ——
/// 半成品状态下跳过，等于把活扔在半路。
///
/// ## 验收类任务绝不能跳
///
/// 「模拟器实跑验收」「端到端取证出报告」这类任务的前提就是**东西都已经在了**，
/// 它要干的事是跑起来看对不对。按「产出已存在」把它们跳掉，
/// 等于永远不验收 —— 而那恰恰是唯一能证明这些改动真的работает 的环节。
public enum OutputExists {

    public enum Result: Sendable, Equatable {
        /// 该跑。
        case shouldRun
        /// 声明的产出全在了 —— 这一步已经由别的路径做完。
        case alreadyDone(paths: [String])
    }

    /// 验收 / 审查类任务的前缀和关键词。这些一律不跳。
    static let neverSkip = ["【评审", "【审查", "【证据", "【刷新",
                            "验收", "取证", "实跑", "复查"]

    /// 从提示词里摘出「本步要新建的文件」。
    ///
    /// 认这几种写法（都是实测在用的）：
    ///   「新建 `X`」「新增 `X`」「产出：`X`」「产出 `X`」「创建 `X`」
    public static func declaredOutputs(in prompt: String) -> [String] {
        let verbs = ["新建 `", "新增 `", "产出：`", "产出 `", "创建 `"]
        var out: [String] = []
        for v in verbs {
            var search = Substring(prompt)
            while let r = search.range(of: v) {
                let after = r.upperBound
                guard let end = search[after...].firstIndex(of: "`") else { break }
                let token = String(search[after..<end])
                search = search[search.index(after: end)...]
                guard PremiseCheck.looksLikePath(token) else { continue }
                out.append(token)
            }
        }
        return Array(Set(out)).sorted()
    }

    /// 核一个任务。
    public static func check(prompt: String, repo: String,
                             base: String = "main") -> Result {
        // 验收类的前提就是「东西都在了」，跳掉它等于永远不验收
        if neverSkip.contains(where: { prompt.contains($0) }) { return .shouldRun }

        let declared = declaredOutputs(in: prompt)
        guard !declared.isEmpty else { return .shouldRun }

        let root = NSString(string: repo).expandingTildeInPath
        // **全部都在**才算已完成。少一个就照旧跑 ——
        // 半成品状态下跳过等于把活扔在半路。
        for p in declared where !PremiseCheck.exists(p, in: root, at: base) {
            return .shouldRun
        }
        return .alreadyDone(paths: declared)
    }

    public static func describe(_ r: Result) -> String {
        switch r {
        case .shouldRun:
            return "该跑"
        case .alreadyDone(let paths):
            return "这一步要造的东西已经在了：" + paths.prefix(3).joined(separator: "、")
                + "（可能是人工做的、别的任务做的、或者上游 agent 顺手做的）"
        }
    }
}
