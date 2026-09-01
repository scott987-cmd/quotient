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
    private static let escalationOriginPrefix = "merge-review-escalation:"
    private static let remediationMarker = "【终审整改："

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
        /// 这条分支**要做的事**(来源任务的标题),没有任务记录时为空。
        public var taskTitle: String = ""
        /// 来源任务的完整目标、非目标和验收范围。
        ///
        /// 只传标题会丢掉任务级例外：例如「本轮冻结美术，功能缺陷照常拦，
        /// 但美术质量不作为本轮阻塞项」。评审随后只能退回仓库通用旧门槛。
        public var taskContract: String = ""
        /// 分支上相对 main 的全部提交主题(旧→新)。
        ///
        /// 只给 `subject`(= 最后一个提交的主题)是个坑:多提交分支的最后一个
        /// 提交往往是收尾小活(「xcodegen 重新生成…」),评审拿它当「PR 描述」
        /// 去对照整条 diff,判「标题与实际改动严重不符 → 不合入」——
        /// 实锤 2026-08-23 Flint 主线第 3 块被这样否了两票,而改动本身站得住。
        /// 把任务标题和全部提交摆出来,评审才知道这条分支到底是干什么的。
        public var commits: [String] = []
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
            // **判据只有一处:`Review.requiresAgentReview`。**
            //
            // 上面那段注释记着「两处判据分叉,这一天里第八次」,可修法是
            // 在这里又抄了一遍条件 —— 于是第九次:抄的这份漏了
            // `requiresAgentReview` 里的「**且真碰了人看得见的东西**」,
            // 结果**评审 agent 自己写的 EVAL 报告**被拖去过审核,
            // 被另一个评审 agent 判不合入,还排进了老板的待批队列。
            // 老板 2026-08-22 原话:「minimax 咋都让人审批,不是说没有
            // 图片或者视频的申请不要找我批」。抄条件就会漏条件,调它。
            let needsByRepo = RepoRegistry.all().contains {
                URL(fileURLWithPath: $0.localPath).standardizedFileURL.path
                    == URL(fileURLWithPath: repo).standardizedFileURL.path
                    && $0.manualReview
            }
            guard Review.requiresAgentReview(
                files: item.files, isStranded: isStranded,
                repoNeedsManualReview: needsByRepo,
                risk: sensitive ? .sensitive : t.profile?.risk) else { return nil }

            var why: [String] = []
            if risky { why.append("碰了构建/CI/签名这类路径") }
            if sensitive { why.append("分诊判成高危") }
            if isStranded { why.append("任务图搁浅，已完成的步骤要单独判能不能落地") }
            if needsByRepo && why.isEmpty {
                why.append("这个仓库要「看效果才合」，代码能不能合由 agent 判")
            }
            let title = item.prompt?.split(separator: "\n").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? ""
            var commits: [String] = []
            if let mb = Review.mergeBase(repo: repo, base: base, branch: item.branch) {
                commits = GitWorkspace.git(["log", "--reverse", "--format=%s", "\(mb)..\(item.branch)"], in: repo)
                    .stdout.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
            }
            return Candidate(branch: item.branch, repo: repo, files: item.files,
                             subject: item.subject,
                             whyNotMechanical: why.joined(separator: "；"),
                             needed: requiredApprovals(files: item.files),
                             head: item.head, headAt: item.committedAt,
                             taskTitle: title, taskContract: t.prompt,
                             commits: commits)
        }
    }

    /// 这条任务是不是「审这条分支能不能合入」的审核任务。
    ///
    /// **和下面 `reviewPrompt` 的模板是一对 —— 改模板必须同步改这里。**
    ///
    /// 匹配的是模板首行的精确前缀，不是子串。原来的判法是
    /// `isReview && prompt.contains("合入") && prompt.contains(branch)`，
    /// 实测（2026-08-20）被落地后自动排的复查任务污染：
    ///
    ///     【审查】复查刚合入 main 的合并 8dbb47c（来源分支 agent/graph/3f68707c）
    ///
    /// 这条**复查**任务同时含「合入」和分支名 —— 于是被当成那条分支的
    /// 合入审核计票、计次。票数被无关任务污染的审核闸，判出来的就不是
    /// 这条分支的事实。
    ///
    /// 尾部空格是防前缀吞并：`agent/a/x` 不能匹配到 `agent/a/xy` 的任务。
    static func isMergeReviewPrompt(_ prompt: String, of branch: String) -> Bool {
        prompt.hasPrefix("【审查·合入】分支 " + branch + " ")
    }

    /// 派给评审 agent 的提示词。
    ///
    /// 前缀必须是 `【审查·合入】`：执行器按提示词里有没有「合入」二字选
    /// `kind`，而 `TaskIntake` 按 `【评审` / `【审查` 前缀决定走评审平台。
    /// **首行格式被 `isMergeReviewPrompt` 依赖 —— 两处一起改。**
    /// 给评审看的「这条分支是干什么的」。
    ///
    /// 任务标题 + 全部提交主题(旧→新)。**最后一个提交的主题不是 PR 描述**,
    /// 别让评审拿它去对照整条 diff(见 Candidate.commits 的实锤)。
    static func describe(_ c: Candidate) -> String {
        var lines: [String] = []
        if !c.taskTitle.isEmpty { lines.append("这条分支要做的事（来源任务）：\(c.taskTitle)") }
        if c.commits.count > 1 {
            lines.append("分支上共 \(c.commits.count) 个提交（旧→新），下面是全部主题；"
                         + "**整条 diff 是它们的总和，别拿最后一个提交的标题去对照整条改动**：")
            for (i, m) in c.commits.prefix(20).enumerated() { lines.append("  \(i + 1). \(m)") }
            if c.commits.count > 20 { lines.append("  …（还有 \(c.commits.count - 20) 个，git log main..\(c.branch) 看全）") }
        } else {
            lines.append("这条分支：\(c.subject)")
        }
        return lines.joined(separator: "\n")
    }

    /// 把来源任务的范围契约原样带给评审，避免口头更新只到实现 Agent、
    /// 评审 Agent 仍按旧的全局规则办事。限制长度只为防止历史反馈无限累积；
    /// 任务开头的目标/非目标/验收范围会完整保留。
    static func taskContractSection(_ c: Candidate) -> String {
        let raw = c.taskContract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "（来源任务没有记录专属契约）" }
        let limit = 12_000
        if raw.count <= limit { return raw }
        return String(raw.prefix(limit)) + "\n…（仅截断更早轮次累积的尾部历史）"
    }

    public static func reviewPrompt(_ c: Candidate) -> String {
        var s = """
        【审查·合入】分支 \(c.branch) 的改动能不能合进 main。

        \(headMarker(c.head))
        \(describe(c))
        机器不敢自己拿主意的原因：\(c.whyNotMechanical)

        ## 本次任务专属评审契约
        \(taskContractSection(c))

        ## 规则优先级
        - 不弄虚作假、安全和离线边界始终生效，任务不能覆盖。
        - 其余范围与质量门槛按「本次任务专属契约 > 当前阶段契约 > 仓库通用
          QUALITY」执行。通用规则不得扩大本次明确写出的验收范围。
        - 本次明确列为非目标的质量，不得单独作为不合入理由；但实际修改了
          冻结目录、破坏既有功能或与交付声明矛盾，仍是本次改动自身的问题。

        MiniMax 评审通道没有仓库终端权限；驱动会内联项目规则和待审 diff。
        只能依据实际收到的材料下结论。材料若截断，「看不到」不是否决理由，
        更不能猜；只报告已核实事实，完整仓库核验交给后续架构复核。

        """
        if c.needed > 1 {
            // **点名是哪个文件触发的，别替评审下结论。**
            //
            // 原来这里直接断言「这条改动碰了决定验收算不算数的东西
            // （构建脚本 / CI / 签名配置）」。而触发判据是
            // `isRiskyPath`，它对**任何** `.sh` 都为真 —— 包括
            // `reviews/verify-*.sh` 这种纯核对脚本，跟验收闸毫无关系。
            //
            // 实测（2026-08-20）：评审拿整个第 1 条去反驳这句话
            // （「分诊器把它判成高危是误报」），而它是对的。
            // 一句不准确的断言，换来的是评审注意力被引开。
            //
            // 判据本身不放松 —— 它的假阳性只是多要一票，
            // 假阴性是审核闸被绕过，不对称摆在那。**该改的是措辞。**
            let hits = c.files.filter { GitWorkspace.isRiskyPath($0) }
            let named = hits.isEmpty
                ? "（判据没点出具体文件）"
                : hits.prefix(6).joined(separator: "\n              - ")
            s += """
            **这条改动里有被判成「可能决定验收算不算数」的文件**：

              - \(named)

            判据很粗（任何 `.sh`、`Tools/`、`.github/`、`.xcodeproj/` 都算），
            所以**先自己看一眼它到底是不是那种东西**：是构建脚本 / CI 配置 /
            签名配置，就按下面几条重点查；只是个跟构建无关的辅助脚本，
            就直说判据误报了，然后正常审改动本身 —— 不用为这一条扣分。

            真是那种东西时要查的：

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
        /// 这条是不是真的派出了一个审核任务。`maxPerCall` 只数它 ——
        /// 「已否决 / 已够票 / 已在队」这种不动手的结果不占名额。
        public var enqueued: Bool = false
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

    /// 这条分支这一版的审核是不是已经在队里/在跑。
    ///
    /// ## 为什么不用通用查重
    ///
    /// 审核提示词是模板,模板对模板必然「相似」—— 实锤(2026-08-21):
    /// 菜单分支的审核连续 40+ 轮被 DuplicateGuard 静默判重,一票都派
    /// 不出去,整仓等它落地的任务全部空转;而它「撞」的是**别的分支**
    /// 的审核。第 8 例同概念多处判定:精确计数(approvalsSoFar)早就
    /// 存在,派发口却又请了一个模糊判官。
    public static func hasPendingReview(branch: String, head: String,
                                        tasks: [WorkTask]) -> Bool {
        tasks.contains { t in
            guard t.state == .queued || t.state == .running else { return false }
            return (isMergeReviewPrompt(t.prompt, of: branch)
                        && reviewedHead(in: t.prompt) == head)
                || t.origin == escalationOrigin(branch: branch, head: head)
        }
    }

    public static func dispatch(repo: String, base: String = "main",
                               tasks: [WorkTask] = TaskStore.all(),
                               maxPerCall: Int = 1) -> [Outcome] {
        var out: [Outcome] = []
        for c in candidates(repo: repo, base: base, tasks: tasks) {
            // **只数真派出去的。** 原来数 out.count —— 「已否决」也算一条,
            // 于是被否决的分支排在第一个就把唯一名额占了,后面的分支永远
            // 轮不到审核。实锤(2026-08-22 05:00):Bot AI 被否 → 音效分支
            // 「0/2 票,还没派过审核」一整夜。队头阻塞的第三个变种。
            if out.filter(\.enqueued).count >= maxPerCall { break }
            let done = approvalsSoFar(branch: c.branch, tasks: tasks,
                                      head: c.head, headAt: c.headAt)
            if done.approvals >= c.needed {
                out.append(Outcome(branch: c.branch, action: "已够票",
                                   note: "\(done.approvals)/\(c.needed) 票同意合入"))
                continue
            }
            if done.rejected {
                out.append(Outcome(branch: c.branch, action: "已否决",
                                   note: "MiniMax 的否决已由架构师复核确认，不再派"))
                continue
            }
            if ArchitectReview.hasUnresolvedMergeRejection(
                branch: c.branch, head: c.head, headAt: c.headAt, tasks: tasks) {
                out.append(Outcome(branch: c.branch, action: "等架构复核",
                                   note: "MiniMax 给出负面结论，架构师尚未裁定"))
                continue
            }
            if exhausted(attempts: done.attempts, needed: c.needed) {
                let origin = escalationOrigin(branch: c.branch, head: c.head)
                if tasks.contains(where: { $0.origin == origin && $0.discardedAt == nil }) {
                    out.append(Outcome(
                        branch: c.branch, action: "等架构师终审",
                        note: "普通审核已到上限；同提交的唯一 Codex 终审票正在处理"))
                    continue
                }
                do {
                    let result = try TaskIntake.enqueue(
                        prompt: escalationPrompt(c, attempts: done.attempts,
                                                 approvals: done.approvals),
                        repo: repo, classify: false, split: false, force: true,
                        origin: origin,
                        idempotencyKey: origin,
                        source: "merge-review-escalation",
                        preferredPlatform: AgentRoles.architectPlatform())
                    switch result {
                    case .duplicate:
                        out.append(Outcome(branch: c.branch, action: "等架构师终审",
                                           note: "同提交的 Codex 终审票已经存在"))
                    default:
                        out.append(Outcome(
                            branch: c.branch, action: "升级架构终审",
                            note: "派了 \(done.attempts) 次仍只有 "
                                + "\(done.approvals)/\(c.needed) 票；已收口为一张 Codex 终审票",
                            enqueued: true))
                    }
                } catch {
                    out.append(Outcome(branch: c.branch, action: "架构升级失败",
                                       note: error.localizedDescription))
                }
                continue
            }
            if hasPendingReview(branch: c.branch, head: c.head, tasks: tasks) {
                out.append(Outcome(branch: c.branch, action: "已在队",
                                   note: "同提交的审核还在排/跑,不重复派"))
                continue
            }
            do {
                // 上一轮判「看不清」的,重派时把话挑明:自己去 git diff。
                let prompt = done.inconclusive > 0
                    ? reviewPrompt(c) + VerdictQuality.lookHarderClause
                    : reviewPrompt(c)
                let r = try TaskIntake.enqueue(
                    prompt: prompt, repo: repo,
                    classify: false, split: false,
                    // 一律跳过通用查重:上面 hasPendingReview 已做**精确**
                    // 判重(同分支同提交在队)。模糊查重对模板化的审核提示词
                    // 必然误判 —— 它把别的分支的审核当成了重复(2026-08-21)。
                    force: true,
                    origin: "merge-review",
                    idempotencyKey: "merge-review:\(c.branch):\(c.head):\(done.attempts)",
                    source: "merge-review")
                switch r {
                case .duplicate:
                    continue
                default:
                    out.append(Outcome(
                        branch: c.branch, action: "已派审核",
                        note: c.whyNotMechanical + "，需要 \(c.needed) 票", enqueued: true))
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
        -> (approvals: Int, rejected: Bool, attempts: Int, inconclusive: Int) {
        var approvals = 0, attempts = 0, rejected = false
        var inconclusive = 0
        for t in tasks where isMergeReviewPrompt(t.prompt, of: branch) {
            // 过期的结论连 attempts 都不算 —— 否则分支改好之后，
            // 「派了几次」这个计数从一开始就贴着上限，
            // `exhausted` 会立刻收口，新的一版根本轮不到被审。
            if verdictIsStale(t, head: head, headAt: headAt) { continue }
            attempts += 1
            guard t.state == .done else { continue }
            let text = t.outputs.joined(separator: "\n") + "\n" + (t.note ?? "")
            switch parseVerdict(text) {
            case .land: approvals += 1
            case .reject:
                // **「我没看清」不算否决。** 详见 VerdictQuality:
                // 评审只有「合入 / 不合入」两个格子，不确定就被塞进后者，
                // 而一票否决是终局。通篇讲「截断 / 看不到」的，退回重审。
                // 理由在 EVAL 文件里,不在任务输出里 —— 必须读回来再判。
                let full = VerdictQuality.fullReport(taskOutputs: text, repoPath: t.repo)
                if VerdictQuality.isInconclusive(full) {
                    inconclusive += 1
                } else {
                    // 旧任务保持原语义，避免升级时把历史否决全部翻成新任务。
                    // 新任务的主观否决只有经架构师确认才生效；被推翻则视作
                    // 一票认可，但不能绕过高危改动原本的双票门槛。
                    if t.prompt.contains(ArchitectReview.contractMarker) {
                        switch ArchitectReview.decision(for: t, tasks: tasks) {
                        case .uphold: rejected = true
                        case .overturn: approvals += 1
                        case .missing, .pending: break
                        }
                    } else {
                        rejected = true
                    }
                }
            case nil: break   // 结论读不出来 —— 不算票，也不算否
            }
        }
        // 普通评审达到上限后只生成一张 Codex 架构终审票。它是收口裁决，
        // 同意即满足最多两票的机械门槛，拒绝即终局；不会再生成第七、第八份
        // 内容相同的评审任务。
        if let head,
           let escalation = tasks.last(where: {
               $0.origin == escalationOrigin(branch: branch, head: head)
                   && $0.discardedAt == nil
           }), escalation.state == .done {
            let text = escalation.outputs.joined(separator: "\n")
                + "\n" + (escalation.note ?? "")
            switch parseVerdict(text) {
            case .land: approvals = max(approvals, 2)
            case .reject: rejected = true
            case nil: break
            }
        }
        return (approvals, rejected, attempts, inconclusive)
    }

    static func escalationOrigin(branch: String, head: String) -> String {
        escalationOriginPrefix + branch + ":" + head
    }

    /// 唯一架构终审拒绝的是当前提交时，恢复原实现任务继续整改。
    ///
    /// 不另造任务：原 ID、分支、Owner 和 runner 会话都保留。终审票 ID 复用
    /// 现有质量整改幂等键，保证同一裁决只重开一次；新提交会产生新的 head，
    /// 后续审核自然进入下一轮，而不是对旧提交重复消耗。
    public static func reconcileRemediation(_ tasks: [WorkTask],
                                             now: Date = Date()) -> [WorkTask] {
        let upheld = tasks.filter { review in
            guard review.origin == "merge-review", review.state == .done,
                  review.discardedAt == nil,
                  ArchitectReview.isNegative(review),
                  ArchitectReview.decision(for: review, tasks: tasks) == .uphold,
                  let branch = TaskKind.boundBranch(review.prompt),
                  let head = reviewedHead(in: review.prompt) else { return false }
            return !branch.isEmpty && !head.isEmpty
        }.sorted { ($0.endedAt ?? $0.createdAt) < ($1.endedAt ?? $1.createdAt) }
        let rejected = tasks.filter { task in
            guard task.state == .done, task.discardedAt == nil,
                  task.origin?.hasPrefix(escalationOriginPrefix) == true else {
                return false
            }
            return parseVerdict((task.outputs + [task.note ?? ""])
                .joined(separator: "\n")) == .reject
        }.sorted { ($0.endedAt ?? $0.createdAt) < ($1.endedAt ?? $1.createdAt) }
        var updates: [String: WorkTask] = [:]

        // 2026-08-31 之前，合入代码拒绝复用了视觉整改的计数器。第二次代码
        // 审核不通过会把功能任务误报成“黄金样板连续不收敛”，并派一张完全
        // 无关的 Blender/骨骼架构票。只纠偏能由结构化关联证明的记录；人工
        // 暂停和真正的视觉连续失败绝不能在这里被解冻。
        for source in tasks where source.pausedAt != nil
            && source.architectureReviewRequestedAt != nil {
            guard let reviewID = source.visualRemediationReviewID,
                  let review = tasks.first(where: {
                      $0.id == reviewID && $0.origin == "merge-review"
                  }),
                  ArchitectReview.decision(for: review, tasks: tasks) == .uphold,
                  let branch = TaskKind.boundBranch(review.prompt),
                  let head = reviewedHead(in: review.prompt),
                  source.branch == branch,
                  branchIsStillAtReviewedHead(repo: review.repo, branch: branch,
                                              head: head) else { continue }

            var resumed = TaskPause.resume(
                source,
                reason: "已纠正合入代码拒绝被误计为视觉不收敛；沿用原 Owner、分支和会话继续整改（\(reviewID)）",
                now: now)
            resumed.qualityRejectionCount = 0
            resumed.preferredPlatform = resumed.ownerPlatform ?? resumed.platform
            updates[resumed.id] = resumed

            let obsoletePrefix = QualityArchitectureReview.originPrefix
                + source.id + ":"
            for task in tasks where task.origin?.hasPrefix(obsoletePrefix) == true
                && task.state != .running && task.discardedAt == nil {
                var obsolete = task
                obsolete.state = .failed
                obsolete.endedAt = now
                obsolete.runnerPID = nil
                obsolete.discardedAt = now
                obsolete.discardReason = "误把合入代码拒绝计为视觉不收敛，架构票已撤销"
                obsolete.note = "错误派生的黄金样板架构票已撤销；原任务继续由原 Owner 整改代码"
                updates[obsolete.id] = obsolete
            }
        }

        // 普通 MiniMax 合入否决经 Codex 维持后，也必须回到原实现任务。
        // 旧状态机只处理下面的 `merge-review-escalation:`，现场因此出现：
        // Codex 已确认代码缺陷，来源任务仍是 done，随后又错误派出视觉票；
        // 视觉票一停，整个分支就再也没有 owner 可运行。
        for review in upheld {
            guard let branch = TaskKind.boundBranch(review.prompt),
                  let head = reviewedHead(in: review.prompt),
                  var source = sourceTask(branch: branch, repo: review.repo,
                                          tasks: tasks) else { continue }
            guard source.state == .done || source.state == .failed else { continue }
            if source.state == .failed, source.terminalFailureKind != .qualityGate {
                continue
            }
            if source.visualRemediationReviewID == review.id { continue }
            if let handledID = source.visualRemediationReviewID,
               let handled = tasks.first(where: { $0.id == handledID }),
               (handled.endedAt ?? handled.createdAt) >= (review.endedAt ?? review.createdAt) {
                continue
            }
            guard branchIsStillAtReviewedHead(repo: review.repo, branch: branch,
                                              head: head) else { continue }

            let detail = architectRemediationDetail(review, tasks: tasks)
            let compact = VisualQualityGate.compactRemediationPrompt(source.prompt)
            let marker = "【合入复核整改："
            let base = compact.range(of: marker).map {
                compact[..<$0.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? compact
            source = Review.requeuedAfterHumanRejection(
                source, reason: detail, head: head,
                countsTowardVisualQualityLimit: false, now: now)
            source.prompt = base + """


            【合入复核整改：\(review.id)｜保持原 Owner、分支和会话】
            MiniMax 对分支 \(branch) 提交 \(head) 的合入否决，已经由 Codex
            架构师复核并维持。代码合入门尚未通过，先修下面已核实的阻塞项；
            保留任务专属范围和已完成成果，不得扩大范围、从头重做，亦不得
            修改、绕过或放宽质量门槛。产生新提交后再进入合入与视觉验收：

            \(detail)
            """
            source.visualRemediationReviewID = review.id
            if source.pausedAt == nil {
                let who = source.ownerRunnerID
                    ?? source.ownerPlatform?.displayName
                    ?? source.platform?.displayName ?? "原 Agent"
                source.note = "合入拒绝经架构师确认，已交回 \(who) 的同一任务整改（\(review.id)）"
            }
            updates[source.id] = source
        }

        for review in rejected {
            guard let target = escalationTarget(review.origin),
                  var source = sourceTask(
                    branch: target.branch, repo: review.repo, tasks: tasks) else {
                continue
            }
            guard source.state == .done || source.state == .failed else { continue }
            if source.state == .failed, source.terminalFailureKind != .qualityGate {
                continue
            }
            if source.visualRemediationReviewID == review.id { continue }
            if let handledID = source.visualRemediationReviewID,
               let handled = tasks.first(where: { $0.id == handledID }),
               (handled.endedAt ?? handled.createdAt) >= (review.endedAt ?? review.createdAt) {
                continue
            }
            // 先做纯内存幂等/时序判断，再查 Git。否则历史终审票会在每轮
            // TaskGraph 对账时各跑一次 rev-parse，队列越久控制面越慢。
            guard branchIsStillAtReviewedHead(
                repo: review.repo, branch: target.branch, head: target.head) else {
                continue
            }

            let detail = remediationDetail(review)
            let compact = VisualQualityGate.compactRemediationPrompt(source.prompt)
            let base = compact.range(of: remediationMarker).map {
                compact[..<$0.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? compact
            source.prompt = base
            source = Review.requeuedAfterHumanRejection(
                source, reason: detail, head: target.head,
                countsTowardVisualQualityLimit: false, now: now)
            // 上面的 helper 负责统一重置执行态和质量不收敛上限；它的提示词
            // 面向人工拒绝，这里替换成真实的 Codex 终审来源，不能伪称用户反馈。
            source.prompt = base + """


            【终审整改：\(review.id)｜保持原 Owner、分支和会话】
            Codex 唯一终审拒绝了分支 \(target.branch) 的提交 \(target.head)。
            这不是新项目；先保留终审已确认有效的成果，只修下面明确阻塞项，
            产生新提交后再走一次正常验收。不得修改、绕过或放宽质量门槛：

            \(detail)
            """
            source.visualRemediationReviewID = review.id
            if source.pausedAt == nil {
                let who = source.ownerRunnerID
                    ?? source.ownerPlatform?.displayName
                    ?? source.platform?.displayName ?? "原 Agent"
                source.note = "Codex 终审不合入，已交回 \(who) 的同一任务整改（\(review.id)）"
            }
            updates[source.id] = source
        }
        return updates.values.sorted { $0.createdAt < $1.createdAt }
    }

    private static func architectRemediationDetail(_ review: WorkTask,
                                                    tasks: [WorkTask]) -> String {
        let exactOrigin = "architect-review:" + review.id
        let architects = tasks.filter {
            $0.origin == exactOrigin && $0.state == .done && $0.discardedAt == nil
        }
        let lines = architects.flatMap(\.outputs).filter {
            !$0.contains("**结论**") && !$0.contains("完整复核报告已写入")
        }
        let detail = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return String(detail.prefix(12_000)) }
        return remediationDetail(review)
    }

    private static func escalationTarget(_ origin: String?)
        -> (branch: String, head: String)? {
        guard let origin, origin.hasPrefix(escalationOriginPrefix) else { return nil }
        let value = origin.dropFirst(escalationOriginPrefix.count)
        guard let separator = value.lastIndex(of: ":") else { return nil }
        let branch = String(value[..<separator])
        let head = String(value[value.index(after: separator)...])
        return branch.isEmpty || head.isEmpty ? nil : (branch, head)
    }

    private static func sourceTask(branch: String, repo: String,
                                   tasks: [WorkTask]) -> WorkTask? {
        let id = String(branch.split(separator: "/").last ?? "")
        let matching = tasks.filter {
            $0.repo == repo && !TaskKind.isReview($0.prompt)
                && ($0.id == id || $0.branch == branch)
        }
        return matching.first(where: { $0.id == id })
            ?? matching.max { $0.createdAt < $1.createdAt }
    }

    private static func branchIsStillAtReviewedHead(repo: String, branch: String,
                                                     head: String) -> Bool {
        let result = GitWorkspace.git(["rev-parse", "\(branch)^{commit}"],
                                      in: repo, timeout: 3)
        let current = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !current.isEmpty else { return false }
        return current.hasPrefix(head) || head.hasPrefix(current)
    }

    private static func remediationDetail(_ review: WorkTask) -> String {
        let lines = review.outputs.filter {
            !$0.contains("ARCH-MERGE-") && !$0.contains("**结论**")
        }
        let detail = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return String(detail.prefix(12_000)) }
        return "终审判定当前提交未达到合入条件；先读取现有终审报告，"
            + "逐项修复后提交新版本，不要重复提交同一 HEAD。"
    }

    static func escalationPrompt(_ candidate: Candidate, attempts: Int,
                                 approvals: Int) -> String {
        """
        【架构复核】合入审核已到自动重试上限，请对同一提交做唯一终审。

        目标分支：\(candidate.branch)
        目标提交：\(candidate.head)
        普通审核：已派 \(attempts) 次，只取得 \(approvals)/\(candidate.needed) 票
        机械系统不敢直接合入的原因：\(candidate.whyNotMechanical)

        本次任务专属契约（范围优先于仓库通用质量门槛）：
        \(taskContractSection(candidate))

        必须先读取 `git diff main...\(candidate.branch)`、完整提交历史和现有
        reviews/ 报告，能跑验证就实跑。你只负责裁决，不接管实现、不修改功能代码。
        把完整依据写入 reviews/ARCH-MERGE-\(candidate.head).md，并在输出最后一行
        原样回显且只能二选一：
        **结论**：合入
        **结论**：不合入
        """
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
