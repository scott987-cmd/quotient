import Foundation

/// 仓库级独占：**一个仓库同一时间只让一个 agent 在改。**
///
/// ## 这是架构级的改动，不是补丁
///
/// 老板的问题：「任务做机制的架构设计再好好看看没有更好的解决方案吗」。
///
/// 盘点 238 个任务之后，答案是：现在的架构有一个根本假设是错的 ——
/// **它把任务当成「对共享代码库的独立并行单元」，但它们不独立：
/// 共享文件、共享基线，而基线在移动。**
///
/// 这个假设的代价，在老板自己手写的丢弃理由里已经统计出来了
///（70 个未派任务的丢弃说明，2026-08-17）：
///
/// | 丢弃理由（原话）                                   | 条数 |
/// |---------------------------------------------------|-----|
/// | 「基线错了：从 main 开工，而 main 上没有今天的改动」 | 13  |
/// | 「暂缓：整包任务正在改同一批文件」                  |  7  |
/// | 「与整包任务重复；按新架构改由单 agent 整包负责」    |  5  |
/// | 「过时：build-app.sh 已大改，这条任务的前提不在了」  |  3  |
///
/// 28 个丢弃，一个根因。落地率也对得上：codex 烧 237 分钟机时只落地 5 个
///（27%），kimi 烧 426 分钟落地 16 个（51%）。
///
/// ## 为什么是「仓库级」而不是「文件级」
///
/// 文件级独占听起来更精细（两个 agent 改不相干的文件就该放行），但它
/// 要求**派活前就知道会碰哪些文件** —— 而 agent 是边干边发现的。
/// 猜错一次就把冲突放回来了，而冲突的代价是整条分支腐烂。
///
/// 仓库级的判据不需要预测：任务自带 `repo` 字段。
///
/// 而且实测过，"改新资源不会撞代码" 这种直觉是错的：Greed 的媒体任务
/// 就在 `Assets.xcassets` 上撞了 add/add。所以不给媒体开例外。
///
/// ## 并行度从哪来
///
/// 从**仓库**来，不从平台来。现在有 5 个活仓库，就是 5 条并行流，
/// 照样用得上多个平台。
///
/// 账是这么算的：现在 7 路并发 × 62% 落地；改完 5 路并发 × 接近 95%。
/// 而浪费掉的那 38% 还要额外消耗人的注意力 —— 那才是真正稀缺的东西。
///
/// **代价必须说清楚**：峰值吞吐会降，平台会闲着。这是明知故犯 ——
/// 「没有真需求时闲着是零成本的，产出垃圾要花人的时间去丢弃」这条
/// 已经是这套系统的既定取舍（见 ReservePool）。
public enum RepoLease {

    /// 这个仓库现在有没有人在改。
    ///
    /// 判据是「有任务 running 且 repo 相同」。用 running 而不是
    /// 「有工作区」：工作区按仓库 × 平台长期复用（见 GitWorkspace.stableKey），
    /// 存在不代表有人在用。
    public static func holder(repo: String, tasks: [WorkTask]) -> WorkTask? {
        let want = normalize(repo)
        return tasks.first { $0.state == .running && normalize($0.repo) == want }
    }

    /// 路径比较前先归一：`~/dev/Maw`、`/Users/x/dev/Maw`、
    /// 末尾带斜杠的，都是同一个仓库。不归一的后果是独占形同虚设 ——
    /// 同一个仓库用两种写法就能各拿一把锁。
    static func normalize(_ path: String) -> String {
        var p = NSString(string: path).expandingTildeInPath
        p = URL(fileURLWithPath: p).standardizedFileURL.path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 从就绪队列里滤掉「所在仓库已经有人在改」的任务。
    ///
    /// **同一轮里也要互斥。** 一轮可能连派好几个任务，如果只看
    /// 已有的 running，同一个仓库的两个任务会在同一轮双双派出去 ——
    /// 独占就白做了。所以这里边走边把已放行的仓库记下来。
    public static func filter(_ queue: [WorkTask],
                              tasks: [WorkTask]) -> (allowed: [WorkTask],
                                                     deferred: [(WorkTask, String)]) {
        var busy = Set<String>()
        for t in tasks where t.state == .running {
            busy.insert(normalize(t.repo))
        }
        var allowed: [WorkTask] = []
        var deferred: [(WorkTask, String)] = []
        for t in queue {
            let r = normalize(t.repo)
            if busy.contains(r) {
                let who = holder(repo: t.repo, tasks: tasks)
                let note = who.map {
                    "仓库 \(URL(fileURLWithPath: r).lastPathComponent) 正被 "
                        + ($0.platform?.displayName ?? "另一个 agent")
                        + " 改（任务 \($0.id)）—— 等它落地再开工，"
                        + "免得两条分支撞同一批文件"
                } ?? "同一轮里这个仓库已经派出去一个任务了"
                deferred.append((t, note))
                continue
            }
            allowed.append(t)
            busy.insert(r)   // 同一轮内也占住
        }
        return (allowed, deferred)
    }
}
