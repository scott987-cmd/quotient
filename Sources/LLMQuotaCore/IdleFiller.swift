import Foundation

/// 额度窗口快过期还没用完时，主动找活干。
///
/// ## 为什么必须有它
///
/// 实测空窗率（`llmq waste`，2026-08-15）：
///
///     Codex 5 小时窗：过去 154 个窗口里 127 个一次都没用（82%）
///     Kimi  5 小时窗：69%     GLM：60%     Qwen 日窗：53%
///
/// 也就是说 ChatGPT Plus 的钱有八成打了水漂 —— **不是因为没活干**
///（待办一直有），而是因为调度是「有任务才派活」：队列空的时候，
/// 所有平台就一起闲着，直到窗口悄无声息地清零。
///
/// 这个项目立项的第一句话是「充分利用所有平台的 token，一分不浪费」。
/// 只做「有活时挑谁干」是做了一半 —— 另一半是**没活时主动找活**。
///
/// ## 为什么不是「一直满负荷跑」
///
/// 因为额度是给人留的。三条闸一起管着：
/// - **留白线**：每个平台留一部分给人自己用（角色配置里的 reserveFraction）
/// - **人在用就让开**：最近人手动用过这个平台就不抢（调度器已有的判定）
/// - **只在窗口尾声动手**：窗口还剩大半时不填 —— 那段时间人可能要用，
///   而且真有正事来了自然会用掉。快过期了才是「不用就废」的时刻。
public enum IdleFiller {

    public struct Opportunity: Sendable {
        public var platform: Platform
        public var windowLabel: String
        /// 窗口还剩多久。
        public var remaining: TimeInterval
        /// 已用比例（0…1）。
        public var used: Double
        public var reason: String
    }

    /// 判据参数。放一处，方便调。
    public enum Policy {
        /// 窗口剩这么久以内才考虑填。默认 90 分钟 ——
        /// 再早填就是在跟人抢额度，再晚填活跑不完。
        public static let fillWithin: TimeInterval = 90 * 60
        /// 已用比例低于这个才算「空着」。默认 25%。
        public static let idleBelow: Double = 0.25
        /// 一个窗口最多主动填几个任务。默认 1 ——
        /// 填活是补漏不是灌满，一次一个，看效果再说。
        public static let maxPerWindow = 1

        /// 会话窗**一轮都没开**时，闲置多久算错过了一轮。
        ///
        /// 用窗口自己的长度：闲了一个窗口那么久，就是实打实少开了一轮。
        /// 拿不到长度时退回这个值。
        public static let idleFallback: TimeInterval = 5 * 3600
    }

    /// 现在有哪些窗口「快过期且没用够」。
    ///
    /// 只看**有明确重置时间**的窗口：没有重置时间就无从判断「快过期」，
    /// 硬猜会在错误的时刻抢额度。
    public static func opportunities(dashboard: Dashboard,
                                     now: Date = Date()) -> [Opportunity] {
        var out: [Opportunity] = []
        let cooling = CooldownLedger.active(now: now)
        for r in dashboard.reports {
            // 冷却中的、被静音的、指挥 —— 都不该被塞活
            if cooling[r.platform] != nil { continue }
            if AgentRoles.isMuted(r.platform) { continue }
            if AgentRoles.isDispatcher(r.platform) { continue }

            for s in r.statuses {
                guard let resets = s.resetsAt else {
                    // **没有重置时间 ≠ 没有浪费。**
                    //
                    // 会话窗（各家的「5 小时额度」）是从你第一次请求开始算的：
                    // 一次都没请求，就没有窗口在走，于是 resetsAt 是空的。
                    // 原来这里直接 continue —— 而没有重置时间的恰好是
                    // Codex / Kimi / GLM 的 5 小时窗，也就是这个填活器
                    // 立项时统计出的空窗率最高的三个（82% / 69% / 60%）。
                    // 安全网的破洞正好开在人掉下去的地方。
                    //
                    // 这种情况下「快过期」这个模型根本不适用：不存在可以卡的
                    // 时刻，损失是连续发生的 —— 每过一个窗口那么久没开张，
                    // 就是白白少用了一轮。所以改用「闲了多久」当信号。
                    if let idle = missedSession(report: r, status: s, now: now) {
                        out.append(idle)
                    }
                    continue
                }
                let remaining = resets.timeIntervalSince(now)
                guard remaining > 0, remaining <= Policy.fillWithin else { continue }
                let used = s.usedFraction ?? 0
                guard used < Policy.idleBelow else { continue }
                // 没配上限时 usedFraction 可能是 nil / 0 —— 那种情况下
                // 「用了多少」本来就说不准，但「窗口快过期」是确定的，
                // 仍然值得填：最坏情况是多干一个活。
                out.append(Opportunity(
                    platform: r.platform,
                    windowLabel: s.label,
                    remaining: remaining,
                    used: used,
                    reason: "\(s.label)窗口还剩 " + Format.duration(remaining)
                        + "，只用了 \(Int(used * 100))% —— 不用就清零"))
            }
        }
        // 最快过期的排最前：那份最接近作废。
        return out.sorted { $0.remaining < $1.remaining }
    }

    /// 会话窗一轮都没开、而且已经闲了至少一个窗口那么久。
    ///
    /// 只认 `.session`：周期窗没到点不算错过（额度还在），
    /// 滚动窗压根不作废。会话窗才是「不开张就等于扔掉」的那一种。
    ///
    /// 返回的 `remaining` 填 0 —— 它排在所有「快过期」的前面，
    /// 因为那些至少还开着，这个是已经在漏了。
    static func missedSession(report: PlatformReport, status: QuotaStatus,
                              now: Date) -> Opportunity? {
        guard status.kind == .session else { return nil }
        // 从没活动过的平台不碰：可能压根没装、没登录。
        // 让它安静地不存在，好过每轮都去试一次。
        guard let last = report.lastActivity else { return nil }
        let idle = now.timeIntervalSince(last)
        let window = windowLength(platform: report.platform,
                                  label: status.label) ?? Policy.idleFallback
        guard idle >= window else { return nil }
        let rounds = Int(idle / window)
        return Opportunity(
            platform: report.platform,
            windowLabel: status.label,
            remaining: 0,
            used: 0,
            reason: "\(status.label)窗口一轮都没开，已经闲了 "
                + Format.duration(idle) + "（约错过 \(rounds) 轮）")
    }

    /// 这个平台这条窗口有多长。问套餐配置，不写死。
    static func windowLength(platform: Platform, label: String) -> TimeInterval? {
        PlansStore.load().plans
            .first { $0.platform == platform }?
            .limits.first { $0.label == label }?
            .windowSeconds
    }

    /// 给一个空窗机会找一个能干的活。
    ///
    /// 找活的顺序（**先用真需求，编造的活排最后**）：
    /// 1. 已经排队但因为别的原因没跑的任务 —— 本来就该干
    /// 2. 储备池里的真实发现（缺注释、缺测试这类从代码里扫出来的事实）
    ///
    /// 返回 nil 表示「没找到合适的活」—— 那就老实闲着，
    /// **绝不为了填窗口而编任务**：编出来的活跑完没人要，
    /// 那不是省额度，是把浪费从「窗口过期」换成「产出没人要」。
    public static func findWork(for opp: Opportunity,
                                repos: [RepoAlias] = RepoRegistry.all(),
                                tasks: [WorkTask] = TaskStore.all()) -> String? {
        found(for: opp, repos: repos, tasks: tasks)?.prompt
    }

    /// 找到的活，连同它出自哪个项目（清单项目要回记一次取用）。
    /// **这条排队的活，调度器真的会去派吗。**
    ///
    /// 原先这里只看 `state == .queued` —— 那等于假设「排着队 = 会被处理」。
    /// 可是**卡住的排队任务永远不会被派**：上游没让开、图搁浅、
    /// 依赖的那步零产出，它就一直躺在队列里。而填活器看见「有活排队」
    /// 就闭嘴不填，于是所有平台跟着一起空转。
    ///
    /// 实测（2026-08-19）：codex 连续 **18 天**一轮没开，
    /// 两天里系统记了 249 次「空窗没活可填」—— 队列里确实有一条活，
    /// 但它派不动，而这一条把所有平台一起饿死了。
    ///
    /// 「不知道」不该当成「会被处理」：就绪判定用 `TaskGraph.isReady`，
    /// 和调度器同一个判据 —— **这里绝不能再造第二个**。
    static func schedulerWillHandle(_ t: WorkTask, in tasks: [WorkTask]) -> Bool {
        t.state == .queued && TaskGraph.isReady(t, in: tasks)
    }

    public static func found(for opp: Opportunity,
                             repos: [RepoAlias] = RepoRegistry.all(),
                             tasks: [WorkTask] = TaskStore.all())
    -> (prompt: String, repo: String?, projectID: String?,
        publishes: Bool, usedTopic: Bool)? {
        // 队列里已经有**派得动的**活 → 不用填，调度器自己会派。
        if tasks.contains(where: { schedulerWillHandle($0, in: tasks) }) { return nil }

        // **先看项目清单。** 那里面是老板批过方案的、有产出价值的常态化项目
        //（资产包、内容生产）；储备池里是从代码扫出来的零碎维护活。
        // 一个能卖钱的资产包，价值高于补一条注释。
        if let hit = Playbook.nextWork(for: opp.platform) {
            return (hit.prompt, hit.project.repo, hit.project.id,
                    hit.recipe.publishes, hit.recipe.prompt.contains("{{topic}}"))
        }

        for repo in repos {
            let path = NSString(string: repo.localPath).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let facts = ReservePool.facts(repo: path, limitPerRule: 5)
            // 真需求排前面：审查发现 > TODO > 缺测试 > 缺注释
            let todo = ReservePool.pending(facts, tasks: tasks)
                .sorted { $0.rule.priority < $1.rule.priority }
            // 挑第一个**不碰高危路径**的 —— 空窗填的是零碎活，
            // 碰构建配置的活要人确认，塞进来只会变成又一个 blocked。
            for f in todo {
                let p = ReservePool.prompt(for: f)
                if GitWorkspace.mentionsRiskyPath(p) { continue }
                return (p, path, nil, false, false)
            }
        }
        return nil
    }
}
