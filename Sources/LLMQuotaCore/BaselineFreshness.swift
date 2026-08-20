import Foundation

/// 基线新鲜度：**main 上没有的东西，不代表它不存在。**
///
/// ## 这条是回放真实数据倒逼出来的
///
/// 先做了 `PremiseCheck`（核任务自己写出来的前置事实）。拿历史数据回放，
/// 结果很难看：17 个当初被人以「基线错了 / 过时」丢掉的任务里，
/// **只有 1 个**带显式前置段落 —— 也就是那个机制当初只能挡住 1/17。
///
/// 原因是剩下 16 个没写前置，它们是**隐含**假设「今天的成果在 main 上」。
/// 所以该核的不是任务写出来的前提，是**基线本身是不是真的**。
///
/// 老板的原话（丢弃理由，完整版）：
///
/// > 基线错了：从 main 开工，而 main 上没有任何今天的游戏改动
/// >（野生物系统/深度世界/透明修复/色泽/开局保护，**28 个提交全在
/// > agent/volcark/9932ef49 上未合**）。首条提交已写「现状基线：无猎物系统，
/// > 食物为静止圆点」，照这个做等于重造一遍。
///
/// 一个 agent 拿着落后 28 个提交的基线开工，写下「现状是没有猎物系统」，
/// 然后认认真真重造一遍已经做好的东西 —— 跑完一整轮，产出全废。
/// 而它自己完全没做错：它看到的 main 确实是那样。
///
/// ## 判据不依赖任何提示词约定
///
/// 「这个仓库有没有实质性的未合并成果」是纯 git 事实。所以这条对
/// **所有**任务生效，不管提示词怎么写 —— 这是它比 PremiseCheck 值钱的地方。
///
/// ## 为什么不会死等
///
/// 只有**能落地的**未合分支才算「基线不新鲜」。真冲突、被评审否决、
/// 记录已丢的那些不算 —— 它们可能永远合不进来，拿它们挡新活等于
/// 把整个仓库冻死。这类分支各有各的处置路径（StaleBranch 刷新、
/// MergeReview 出结论），不该在这里再堵一次。
public enum BaselineFreshness {

    /// 一条分支要多大才算「实质性成果」。
    ///
    /// 评审报告那种一个文件的分支不算 —— main 少一份评审报告，
    /// 不影响任何人对代码现状的判断。
    public static let substantialFiles = 3

    public enum Result: Sendable, Equatable {
        /// main 就是真实状态，可以派。
        case fresh
        /// main 落后于已经做好、马上要落地的成果 —— 等它落地再派。
        case stale(branches: [String], files: Int)
    }

    /// 这个仓库的 main 还是不是真实状态。
    public static func check(repo: String, base: String = "main",
                             tasks: [WorkTask] = TaskStore.all()) -> Result {
        let path = NSString(string: repo).expandingTildeInPath
        guard GitWorkspace.isRepo(path) else { return .fresh }

        var names: [String] = []
        var total = 0
        for item in Review.list(repo: path, base: base, tasks: tasks) {
            guard item.files.count >= substantialFiles else { continue }
            // **只算能落地的。** 合不进去 / 被否 / 记录已丢的分支可能永远
            // 进不来，拿它们挡新活会把整个仓库冻死。
            guard item.mergesCleanly else { continue }
            names.append(item.branch)
            total += item.files.count
        }
        return names.isEmpty ? .fresh
            : .stale(branches: names.sorted(), files: total)
    }

    /// 这个候选任务到底该不该被挡 —— **亲任务豁免**在这里。
    ///
    /// ## 为什么要豁免
    ///
    /// 2026-08-20 实测死锁（Flint 首日）：移动手感任务超时失败，
    /// 分支上躺着 7 个文件的半成品；重试它时，这道闸说「main 还差
    /// agent/kimi/c3dcbbaa 的成果没合」把它挡住 —— **闸等分支合入，
    /// 分支等任务跑完，任务被闸挡着**，三环扣死，整个仓库冻结。
    ///
    /// 亲任务不是来「拿旧基线重造」的 —— 它带着接力现场、就是去
    /// **完成**那条分支的。挡它 = 挡住唯一能解开基线的人。
    /// 和「审查/刷新任务豁免」同一个道理：解锁钥匙不能被锁在门外。
    ///
    /// 别的分支造成的不新鲜照样挡（把亲分支摘掉后还有剩 → 仍算 stale）。
    public static func blocks(_ r: Result, candidateBranch: String?) -> Result {
        guard case .stale(let branches, let files) = r else { return r }
        let others = branches.filter { $0 != candidateBranch }
        return others.isEmpty ? .fresh : .stale(branches: others, files: files)
    }

    /// 给日志 / 人看的一句话。
    ///
    /// 必须写出**是什么在等**和**为什么不能先干** —— 只说「基线不新鲜」
    /// 的话，看的人（和以后改这段代码的人）会以为这是个可以放宽的保守限制。
    public static func describe(_ r: Result) -> String {
        switch r {
        case .fresh:
            return "基线是最新的"
        case .stale(let branches, let files):
            return "main 还差 \(files) 个文件的已完成成果没合（"
                + branches.prefix(2).joined(separator: "、")
                + (branches.count > 2 ? " 等 \(branches.count) 条" : "")
                + "）—— 现在派，agent 会拿落后的基线当「现状」，"
                + "把已经做好的东西重造一遍"
        }
    }
}
