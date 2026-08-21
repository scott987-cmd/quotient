import Foundation

/// 分支腐烂：分出去之后 main 一直在走，等到要合的时候已经合不进去了。
///
/// ## 为什么要单独有这么一个东西
///
/// 2026-08-17 盘点，Maw 有三条实质分支躺了两天：
///
/// - 修换档叠影，715 行，带回归测试
/// - 同一个 BUG 的诊断证据，512 行，7 张证据图
/// - 进食三拍动画，148 行
///
/// 三条分出去之后，main 分别又走了 59 / 39 / 39 个提交，现在全是真冲突。
///
/// **先说清楚一个技术事实**：把 main 合进分支、和把分支合进 main，是同一个
/// 三方合并，冲突一模一样。所以「自动 rebase 一下就好了」是行不通的 ——
/// 没有任何机械操作能把一个真冲突变没，冲突必须有人来解。
///
/// 但这活恰好适合 agent：冲突是**已经说清楚的、重复的**工作，而且
/// 工作区按「仓库 × 平台」复用之后，**当初写这条分支的那个平台还留着
/// 它当时的会话** —— 它知道自己当时在干什么、为什么那么改。让它来解，
/// 比让一个从零认路的新 agent（或者人）来解便宜得多。
///
/// 所以这里干的事是：检测到腐烂 → 派一个「刷新分支」任务回给**原平台**。
///
/// ## 边界
///
/// - 只管 `done` 的任务：还在跑的分支下面正有 agent 在动，别去搅。
/// - 一条分支同时只挂一个刷新任务：靠 `DuplicateGuard`（提示词里带分支名，
///   天然去重）。刷完还冲突就不再自动派 —— 那说明不是「过期」而是
///   「真的撞了设计」，该给人。
/// - 太小的分支不值得刷：一个只加了一份报告的分支，重跑一次比解冲突便宜。
public enum StaleBranch {

    /// 一条值得刷新的分支。
    public struct Candidate: Sendable {
        public var branch: String
        public var repo: String
        /// 当初做这条分支的平台。刷新任务要点名派回给它 —— 它有会话。
        public var platform: Platform?
        /// 分出去之后 main 又走了多少个提交
        public var commitsBehind: Int
        public var files: Int
        public var subject: String
    }

    /// 一条分支要多少个文件才值得派 agent 去解冲突。
    ///
    /// 低于这个数，重做比解冲突便宜 —— 解冲突要读两边的改动加上中间那几十个
    /// 提交，而重做只要读当前 main。评审报告那种一个文件的分支就属于这类。
    public static let minFilesToRefresh = 3

    /// 挑出腐烂到该刷、又值得刷的分支。
    public static func candidates(repo: String, base: String = "main",
                                  tasks: [WorkTask] = TaskStore.all()) -> [Candidate] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return Review.list(repo: repo, base: base, tasks: tasks).compactMap { item in
            // 合得进去的不用刷
            guard !item.mergesCleanly else { return nil }
            // 还在跑 / 失败的不碰：跑着的下面有 agent 在动，
            // 失败的产出本来就该人看，刷新只会把一堆垃圾洗干净再端上来。
            // **图分支要走统一查找。** 2026-08-20 早上把 Review 侧的
            // taskFor 统一成「图 ID 找步骤」时,这里漏了(按调用次数数的,
            // 它自己另写了一份 byID 直查)——于是图分支永远「任务记录没了、
            // 不自动刷」:Flint 产线图 13 个文件卡冲突数小时,连 skipped
            // 清单都标错原因。第 7 例同概念多处判定。
            guard let t = Review.taskFor(item.taskID, in: byID, all: tasks),
                  t.state == .done else { return nil }
            guard item.files.count >= minFilesToRefresh else { return nil }
            let behind = commitsBehind(repo: repo, branch: item.branch, base: base)
            // main 一步没动却冲突 —— 那不是腐烂，是两条分支撞了同一处设计，
            // 刷新解决不了，留给人。
            guard behind > 0 else { return nil }
            return Candidate(branch: item.branch, repo: repo,
                             platform: t.platform, commitsBehind: behind,
                             files: item.files.count, subject: item.subject)
        }
    }

    /// 过期了、但**够不着自动刷新**的分支，和够不着的原因。
    ///
    /// 单独列出来是有必要的：这些分支正是「躺两天没人发现」的那批 ——
    /// 自动环节悄悄跳过它们，人也就永远看不见。跳过可以，
    /// 不吭声不行。
    public struct Skipped: Sendable {
        public var branch: String
        public var reason: String
        public var files: Int
    }

    /// 挑出过期但不自动刷的，连原因一起给出来。
    public static func skipped(repo: String, base: String = "main",
                               tasks: [WorkTask] = TaskStore.all()) -> [Skipped] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return Review.list(repo: repo, base: base, tasks: tasks).compactMap { item in
            guard !item.mergesCleanly else { return nil }
            let n = item.files.count
            guard let t = Review.taskFor(item.taskID, in: byID, all: tasks) else {
                return Skipped(branch: item.branch,
                               reason: "任务记录没了 —— 不知道当初谁做的、跑完没有，"
                                     + "自动环节一律不碰，只能人工 work review 处置",
                               files: n)
            }
            if t.state != .done {
                return Skipped(branch: item.branch,
                               reason: "任务状态是 \(t.state) —— 跑着的下面有 agent 在动，"
                                     + "失败的本来就该人看",
                               files: n)
            }
            if n < minFilesToRefresh {
                return Skipped(branch: item.branch,
                               reason: "只有 \(n) 个文件 —— 重做比解冲突便宜",
                               files: n)
            }
            if commitsBehind(repo: repo, branch: item.branch, base: base) == 0 {
                return Skipped(branch: item.branch,
                               reason: "main 一步没动却冲突 —— 那是撞了同一处设计，"
                                     + "不是过期，刷新解决不了",
                               files: n)
            }
            return nil
        }
    }

    /// 分出去之后 base 又走了多少个提交。
    static func commitsBehind(repo: String, branch: String, base: String) -> Int {
        let r = GitWorkspace.git(["rev-list", "--count", "\(branch)..\(base)"], in: repo)
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 刷新任务的提示词。
    ///
    /// 写法上要顶住一个具体的失败模式：agent 拿到「解决冲突」这种指令，
    /// 很容易顺手把冲突处**两边都删掉**，或者按自己的想法重写一遍 ——
    /// 合是合上了，但原来那条分支想做的事没了，而外面看起来是「刷新成功」。
    /// 所以指令里把「不许改变原意图」写死，并且要求跑验证。
    public static func refreshPrompt(_ c: Candidate) -> String {
        """
        【刷新】把 main 合进分支 \(c.branch)，解决冲突。

        这条分支是你之前做的：\(c.subject)
        它分出去之后 main 又走了 \(c.commitsBehind) 个提交，现在合不回去了。

        步骤：
        - `git checkout \(c.branch)` 然后 `git merge main`
        - 逐个解冲突。**只解冲突，不做别的改动。**
        - 解完跑一遍仓库的验证命令，确认还是通过的
        - 提交这次合并

        要求：
        - **不许改变这条分支原本的意图**。冲突两边都留着有用的东西时，
          要把两边的意图都保住；实在只能留一边时，留 main 的结构、
          把本分支的改动重新落到新结构上。
        - 不许为了「合得上」把本分支的改动删掉 —— 那等于这条分支白做了。
        - 解不了就说解不了，说清楚卡在哪个文件的哪一处，别硬凑。
        """
    }

    public struct Outcome: Sendable {
        public var branch: String
        public var enqueued: Bool
        public var note: String
    }

    /// 给腐烂的分支派刷新任务。
    ///
    /// - Parameter maxPerCall: 一轮最多派几个。默认 1 —— 解冲突是重活，
    ///   一次派一堆会把额度全占住，把真正的新活饿着。
    public static func dispatchRefresh(repo: String, base: String = "main",
                                       tasks: [WorkTask] = TaskStore.all(),
                                       maxPerCall: Int = 1) -> [Outcome] {
        var out: [Outcome] = []
        for c in candidates(repo: repo, base: base, tasks: tasks) {
            // 只数真派出去的 —— 「不重复派 / 收口」这种不动手的结果不占名额,
            // 否则排在前面的一条永久挡住后面所有(队头阻塞,2026-08-22)。
            if out.filter(\.enqueued).count >= maxPerCall { break }
            // **派够次数还刷不动就收口。** 刷新没有上限的代价实测过
            // （2026-08-22 凌晨）：Maw 的 cdce40f3 落后 102 个提交，
            // Kimi 跑 10 分钟超时、火山接力跑 20 分钟又超时，而它还会
            // 一轮一轮接着派。判据复用 MergeReview.exhausted —— 审核和
            // 证据两条路都用它，刷新没有理由自己另立一套。
            let tried = tasks.filter {
                TaskKind.isRefresh($0.prompt) && TaskKind.boundBranch($0.prompt) == c.branch
            }.count
            if MergeReview.exhausted(attempts: tried, needed: 1) {
                out.append(Outcome(
                    branch: c.branch, enqueued: false,
                    note: "派了 \(tried) 次都没刷动 —— 不再重试，留给人工"
                        + "（落后 \(c.commitsBehind) 个提交、\(c.files) 个文件）"))
                continue
            }
            // **精确判重**：同一条分支的刷新还在排/在跑才算重复。
            // 通用查重对模板化的提示词必然误判 —— 它拿这条分支的刷新和
            // 别条分支的刷新比出「相似」，然后 .duplicate 静默跳过，
            // 一行日志都没有（详见 TaskKind.hasPendingDerived 的故障记录）。
            if TaskKind.hasPendingDerived(branch: c.branch, tasks: tasks,
                                          kind: TaskKind.isRefresh) {
                out.append(Outcome(branch: c.branch, enqueued: false,
                                   note: "同分支的刷新还在排/跑，不重复派"))
                continue
            }
            do {
                // 不分诊不拆图：这是一件说死了的机械活，
                // 分诊要花一次推理额度，拆图会把「解冲突」拆成一堆没意义的步。
                let r = try TaskIntake.enqueue(
                    prompt: refreshPrompt(c), repo: repo,
                    classify: false, split: false,
                    // 精确判重已在上面做过；通用模糊查重必然误判模板，跳过它。
                    force: true,
                    origin: "stale-branch",
                    preferredPlatform: c.platform)
                switch r {
                case .duplicate:
                    // 已经派过了，还没跑完 —— 别再派。
                    continue
                default:
                    out.append(Outcome(
                        branch: c.branch, enqueued: true,
                        note: "落后 \(c.commitsBehind) 个提交、\(c.files) 个文件"
                            + "，已派给 \(c.platform?.rawValue ?? "自动挑选") 刷新"))
                }
            } catch {
                out.append(Outcome(branch: c.branch, enqueued: false,
                                   note: "派刷新失败：\(error.localizedDescription)"))
            }
        }
        return out
    }
}
