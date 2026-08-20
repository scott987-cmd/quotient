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
        /// 被审的那个提交（短 sha）。见 `Review.Item.head`。
        public var head: String = ""
        /// 那个提交的时间。老格式审核任务没记 sha 时用它兜底。
        public var headAt: Date?
    }

    /// 挑出该派给评审 agent 的分支。
    ///
    /// 只挑「能干净合入、但机械条件不敢自己拿主意」的那些。合不进去的
    /// 不在这里管 —— 那是 `StaleBranch` 的事（先刷新，刷完再来这里过审）。
    public static func candidates(repo: String, base: String = "main",
                                  tasks: [WorkTask] = TaskStore.all()) -> [Candidate] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        // 搁浅图也要能进来。它的任务状态是 blocked/failed，如果这里也按
        // 「必须 done」挡掉，就成了死结：autoland 要求它过审才敢合，
        // 而审核根本不会被派 —— 于是它永远只能等人手工捞。
        let stranded = Set(TaskGraph.stranded(tasks).filter { $0.doneCount > 0 }
            .map(\.branch))
        return Review.list(repo: repo, base: base, tasks: tasks).compactMap { item in
            guard item.mergesCleanly else { return nil }
            guard let t = byID[item.taskID] else { return nil }
            let isStranded = stranded.contains(item.branch)
            if !isStranded, t.state != .done { return nil }

            let risky = GitWorkspace.mentionsRiskyPath(item.files.joined(separator: " "))
            let sensitive = t.profile?.risk == .sensitive
            // **标了「看效果才合」的仓库也要派审核。**
            //
            // 这一条是漏的：当天在 `autoLand` 里加了「manualReview 仓库
            // 要过 agent 审核」，**却忘了让派发端也认它** —— 于是
            // autoland 等它过审，而审核永远不会被派，成了死结。
            //
            // 实测：Maw 的 agent/kimi/17d7f010 交齐了 5 张实跑截图、
            // 通过了证据闸，`work why` 说「要 agent 审核，还没派过」，
            // 而 `MergeReview.candidates` 返回 **0 条**。两处判据分叉，
            // 这一天里第八次。
            let needsByRepo = RepoRegistry.all().contains {
                URL(fileURLWithPath: $0.localPath).standardizedFileURL.path
                    == URL(fileURLWithPath: repo).standardizedFileURL.path
                    && $0.manualReview
            }
            guard risky || sensitive || isStranded || needsByRepo else { return nil }

            var why: [String] = []
            if risky { why.append("碰了构建/CI/签名这类路径") }
            if sensitive { why.append("分诊判成高危") }
            if isStranded { why.append("任务图搁浅，已完成的步骤要单独判能不能落地") }
            if needsByRepo && why.isEmpty {
                why.append("这个仓库要「看效果才合」，代码能不能合由 agent 判")
            }
            return Candidate(branch: item.branch, repo: repo, files: item.files,
                             subject: item.subject,
                             whyNotMechanical: why.joined(separator: "；"),
                             needed: requiredApprovals(files: item.files),
                             head: item.head, headAt: item.committedAt)
        }
    }

    /// 派给评审 agent 的提示词。
    ///
    /// 前缀必须是 `【审查·合入】`：执行器按提示词里有没有「合入」二字选
    /// `kind`，而 `TaskIntake` 按 `【评审` / `【审查` 前缀决定走评审平台。
    public static func reviewPrompt(_ c: Candidate) -> String {
        var s = """
        【审查·合入】分支 \(c.branch) 的改动能不能合进 main。

        \(headMarker(c.head))
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
    /// **派够次数还读不出结论 —— 收口，别再派。**
    ///
    /// 第二票要跳过查重，所以 `dispatch` 里传了 `force: attempts > 0`。
    /// 但审核任务如果**读不出结论**（比如它零产出），票数永远是 0
    /// 而 attempts 一直涨 —— 于是每一轮都 force 重派，永远不停。
    ///
    /// 实测（2026-08-19 隔夜）：同两条分支被派了 **16 次和 13 次**审核，
    /// 每次跑 8~20 秒、零产出，一夜烧掉 29 次调用。
    ///
    /// 「读不出结论就不算票，会再派一次」——「再派一次」在读不出结论时
    /// 就是「永远再派」。这就是为什么这里必须有个硬上限。
    ///
    /// 宽限 2 次：容得下「第一次读不出、重试一次成功」这种正常抖动，
    /// 超过就说明这条路走不通，该留给人工。
    ///
    /// **这个判断只准有一处实现。** 它原先内联在 `dispatch` 里，
    /// 而 `dispatch` 要跑 git、没法单测 —— 于是这条最该被测的规则
    /// 一行覆盖都没有。抽出来是为了让它能被钉住。
    public static func exhausted(attempts: Int, needed: Int) -> Bool {
        attempts >= needed + 2
    }

    public static func dispatch(repo: String, base: String = "main",
                               tasks: [WorkTask] = TaskStore.all(),
                               maxPerCall: Int = 1) -> [Outcome] {
        var out: [Outcome] = []
        for c in candidates(repo: repo, base: base, tasks: tasks) {
            if out.count >= maxPerCall { break }
            let done = approvalsSoFar(branch: c.branch, tasks: tasks,
                                      head: c.head, headAt: c.headAt)
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
            if exhausted(attempts: done.attempts, needed: c.needed) {
                out.append(Outcome(
                    branch: c.branch, action: "放弃审核",
                    note: "派了 \(done.attempts) 次都没读出结论"
                        + "（只拿到 \(done.approvals)/\(c.needed) 票）——"
                        + "不再重试，留给人工处置"))
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
    /// 写进审核提示词的「被审提交」标记。
    ///
    /// 格式固定，因为它要被 `reviewedHead` 读回来 —— 改动格式就等于
    /// 让所有历史审核任务的标记失效，别顺手改。
    static func headMarker(_ head: String) -> String {
        head.isEmpty ? "" : "被审提交：\(head)"
    }

    /// 从审核任务的提示词里读回它当时审的是哪个提交。
    ///
    /// 老格式（2026-08-20 之前派的）没有这个标记，返回 nil ——
    /// 那种情况下由时间兜底，见 `verdictIsStale`。
    static func reviewedHead(in prompt: String) -> String? {
        guard let r = prompt.range(of: "被审提交：") else { return nil }
        let rest = prompt[r.upperBound...]
        let sha = rest.prefix { $0.isHexDigit }
        return sha.isEmpty ? nil : String(sha)
    }

    /// 这条审核结论是不是**已经过期了** —— 它审的那一版已经不是现在这一版。
    ///
    /// ## 为什么必须有这个判断
    ///
    /// 原来 `approvalsSoFar` 只按分支名匹配审核任务，于是结论**永久绑在
    /// 分支名上**。两个方向都出事：
    ///
    /// - **被否的分支永远进不去。** 哪怕后来的提交正是为了回应审核意见 ——
    ///   实测 2026-08-20：`agent/claude/009f44f5` 被判不合入，理由是
    ///   「分支里看不到任何验证证据」；证据补进分支之后，`rejected` 照旧为真，
    ///   唯一的出路变成「人工丢弃那条否决」。而「人工绕过一个 no」正是
    ///   这套审核机制存在的意义所要防的事。
    /// - **拿到票之后推什么都能进。** 这一头更严重：一票同意之后再往分支上
    ///   追加任意提交，`approvals` 照样成立 —— 审核闸对新提交等于不存在。
    ///
    /// 结论是针对**某一版 diff** 的，不是针对一个名字的。
    ///
    /// ## 兜底为什么用时间
    ///
    /// 老的审核任务没记 sha。全当成有效，上面第二个洞就继续开着；
    /// 全当成无效，会把已经判过的分支重新派一遍、白烧额度。
    /// 用「分支在这次审核**结束之后**又有新提交」兜底，两头都站得住。
    static func verdictIsStale(_ t: WorkTask, head: String?, headAt: Date?) -> Bool {
        if let recorded = reviewedHead(in: t.prompt) {
            guard let head, !head.isEmpty else { return false }
            return recorded != head
        }
        // 老格式：没记提交，看时间。
        guard let headAt, let ended = t.endedAt else { return false }
        return headAt > ended
    }

    /// - Parameters:
    ///   - head: 分支现在的头（短 sha）。传 nil 就是老行为（只按分支名），
    ///     留给还没接上的调用点和单测。
    ///   - headAt: 分支头的提交时间，给没记 sha 的老审核任务兜底。
    public static func approvalsSoFar(branch: String, tasks: [WorkTask],
                                      head: String? = nil,
                                      headAt: Date? = nil)
        -> (approvals: Int, rejected: Bool, attempts: Int) {
        var approvals = 0, attempts = 0, rejected = false
        for t in tasks where TaskKind.isReview(t.prompt)
            && t.prompt.contains("合入") && t.prompt.contains(branch) {
            // 过期的结论连 attempts 都不算 —— 否则分支改好之后，
            // 「派了几次」这个计数从一开始就贴着上限，
            // `exhausted` 会立刻收口，新的一版根本轮不到被审。
            if verdictIsStale(t, head: head, headAt: headAt) { continue }
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
                               tasks: [WorkTask],
                               head: String? = nil,
                               headAt: Date? = nil) -> Bool {
        let r = approvalsSoFar(branch: branch, tasks: tasks,
                               head: head, headAt: headAt)
        return !r.rejected && r.approvals >= requiredApprovals(files: files)
    }
}
