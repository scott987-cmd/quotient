import Foundation

/// 代码合入审核：机器判不了的，交给**专用评审 agent** 判，不推给人。
///
/// ## 这东西为什么存在
///
/// 老板的原话：「代码合入审核，你让专用 agent 去判断就可以了」。
///
/// 之前的分工是：`autoland` 用五条机械条件判一遍，过了就合，不过的
/// 全部落到 `work review` 等人。而那五条里有两条根本不是「能不能合」
/// 的问题，是「机器不敢自己拿主意」：
///
/// - 碰了敏感路径（构建脚本、CI、签名配置）
/// - 任务被分诊成高危
///
/// 这两类落到人手里，人要做的事恰恰是读 diff —— 而这正是老板反复说过
/// 不要推给他的东西（「我只看人可阅读验证的成功」）。
///
/// 所以补上中间这一层：机械条件判不了的，派给评审 agent 出结论。
/// 结论是「合入」就交回 autoland 走正常落地（**构建和测试照样跑**），
/// 结论是「不合入」就记进否决名单、连理由一起留着。
///
/// 人从此不参与「这段 diff 要不要合」这个问题。
///
/// ## 一个必须先补的漏
///
/// 评审执行器原来拿到的材料是 STATUS.md / README / 提交历史 / 文件清单
/// —— **没有 diff**。`RepoMap.swift` 记着的那六份「材料不足 ——
/// 评审正文没给我看」就是这么来的。让它判合并却不给它看改动，
/// 判出来的东西没有意义。所以 `kind=合入` 这一路单独喂 diff。
///
/// ## 关于自我指涉那一类的取舍
///
/// 构建脚本 / CI / 签名配置是特殊的：它们**决定了「验收通过」这句话本身
/// 算不算数**。一个改坏了验证流程的改动，可以让之后所有改动都「验收通过」。
/// 所以这一类要求**两次独立审核都说合入**才放行 —— 不是不信任 agent，
/// 是这一类的失败会静默地废掉后面所有的把关。
public enum MergeReview {

    /// 审核结论。
    public enum Verdict: String, Sendable {
        case land = "合入"
        case reject = "不合入"
    }

    /// 从审核报告 / 任务输出里读结论。
    ///
    /// 认的是「**结论**：合入」这种写法，也认没加粗的。**先找「不合入」**
    /// —— 「不合入」里包含「合入」两个字，顺序反了会把所有否决读成放行，
    /// 而这个方向的错误是把机器不敢合的东西直接合进主干。
    public static func parseVerdict(_ text: String) -> Verdict? {
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { $0.contains("结论") }) else { return nil }
        if line.contains("不合入") { return .reject }
        if line.contains("合入") { return .land }
        return nil
    }

    /// 这条分支需要几次一致的「合入」才放行。
    ///
    /// 碰了构建 / CI / 签名那批要两次：它们决定「验收通过」算不算数，
    /// 改坏了会让之后所有改动都自动过关，而且没人会发现。
    public static func requiredApprovals(files: [String]) -> Int {
        GitWorkspace.mentionsRiskyPath(files.joined(separator: " ")) ? 2 : 1
    }

    /// 一条需要 agent 审核的分支。
    public struct Candidate: Sendable {
        public var branch: String
        public var repo: String
        public var files: [String]
        public var subject: String
        /// 为什么机械条件判不了
        public var whyNotMechanical: String
        public var needed: Int
    }

    /// 挑出该派给评审 agent 的分支。
    ///
    /// 只挑「能干净合入、但机械条件不敢自己拿主意」的那些。合不进去的
    /// 不在这里管 —— 那是 `StaleBranch` 的事（先刷新，刷完再来这里过审）。
    public static func candidates(repo: String, base: String = "main",
                                  tasks: [WorkTask] = TaskStore.all()) -> [Candidate] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return Review.list(repo: repo, base: base, tasks: tasks).compactMap { item in
            guard item.mergesCleanly else { return nil }
            guard let t = byID[item.taskID], t.state == .done else { return nil }

            let risky = GitWorkspace.mentionsRiskyPath(item.files.joined(separator: " "))
            let sensitive = t.profile?.risk == .sensitive
            guard risky || sensitive else { return nil }  // 机械条件能判的不用派

            var why: [String] = []
            if risky { why.append("碰了构建/CI/签名这类路径") }
            if sensitive { why.append("分诊判成高危") }
            return Candidate(branch: item.branch, repo: repo, files: item.files,
                             subject: item.subject,
                             whyNotMechanical: why.joined(separator: "；"),
                             needed: requiredApprovals(files: item.files))
        }
    }

    /// 派给评审 agent 的提示词。
    ///
    /// 前缀必须是 `【审查·合入】`：执行器按提示词里有没有「合入」二字选
    /// `kind`，而 `TaskIntake` 按 `【评审` / `【审查` 前缀决定走评审平台。
    public static func reviewPrompt(_ c: Candidate) -> String {
        var s = """
        【审查·合入】分支 \(c.branch) 的改动能不能合进 main。

        这条分支：\(c.subject)
        机器不敢自己拿主意的原因：\(c.whyNotMechanical)

        """
        if c.needed > 1 {
            s += """
            **这条改动碰了决定「验收通过」算不算数的东西**（构建脚本 / CI /
            签名配置）。改坏了它，之后所有改动都会自动过关，而且没人会发现。
            所以这一段要特别看：

            - 改完之后，验证命令还会真的跑测试吗？还是被绕过去了？
            - 有没有放宽或删掉原本会失败的检查？
            - 有没有动签名 / 证书 / 密钥相关的配置？

            """
        }
        return s
    }

    public struct Outcome: Sendable {
        public var branch: String
        public var action: String
        public var note: String
    }

    /// 派审核任务。一轮最多一个 —— 评审也烧额度。
    public static func dispatch(repo: String, base: String = "main",
                               tasks: [WorkTask] = TaskStore.all(),
                               maxPerCall: Int = 1) -> [Outcome] {
        var out: [Outcome] = []
        for c in candidates(repo: repo, base: base, tasks: tasks) {
            if out.count >= maxPerCall { break }
            let done = approvalsSoFar(branch: c.branch, tasks: tasks)
            if done.approvals >= c.needed {
                out.append(Outcome(branch: c.branch, action: "已够票",
                                   note: "\(done.approvals)/\(c.needed) 票同意合入"))
                continue
            }
            if done.rejected {
                out.append(Outcome(branch: c.branch, action: "已否决",
                                   note: "评审 agent 判不合入，不再派"))
                continue
            }
            do {
                let r = try TaskIntake.enqueue(
                    prompt: reviewPrompt(c), repo: repo,
                    classify: false, split: false,
                    // 同一条分支要两票时，第二次的提示词和第一次一样，
                    // 会被查重挡掉 —— 所以第二票必须显式跳过查重。
                    force: done.attempts > 0,
                    origin: "merge-review")
                switch r {
                case .duplicate:
                    continue
                default:
                    out.append(Outcome(
                        branch: c.branch, action: "已派审核",
                        note: c.whyNotMechanical + "，需要 \(c.needed) 票"))
                }
            } catch {
                out.append(Outcome(branch: c.branch, action: "派失败",
                                   note: error.localizedDescription))
            }
        }
        return out
    }

    /// 这条分支到目前为止拿到了几票、有没有被否。
    ///
    /// 从已完成的审核任务的输出里读结论。认任务的办法是提示词里带着分支名 ——
    /// 和 `DuplicateGuard` 依赖的是同一个约定。
    public static func approvalsSoFar(branch: String, tasks: [WorkTask])
        -> (approvals: Int, rejected: Bool, attempts: Int) {
        var approvals = 0, attempts = 0, rejected = false
        for t in tasks where t.prompt.contains("【审查·合入】")
            && t.prompt.contains(branch) {
            attempts += 1
            guard t.state == .done else { continue }
            let text = t.outputs.joined(separator: "\n") + "\n" + (t.note ?? "")
            switch parseVerdict(text) {
            case .land: approvals += 1
            case .reject: rejected = true
            case nil: break   // 结论读不出来 —— 不算票，也不算否
            }
        }
        return (approvals, rejected, attempts)
    }

    /// 这条分支的 agent 审核过了没有 —— 给 autoland 用。
    ///
    /// 没派过审核 → `false`（还没轮到它）。够票 → `true`。
    /// 被否 → `false`，理由已经进了否决名单。
    public static func approved(branch: String, files: [String],
                               tasks: [WorkTask]) -> Bool {
        let r = approvalsSoFar(branch: branch, tasks: tasks)
        return !r.rejected && r.approvals >= requiredApprovals(files: files)
    }
}
