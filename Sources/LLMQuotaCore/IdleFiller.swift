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
                guard let resets = s.resetsAt else { continue }
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
    public static func found(for opp: Opportunity,
                             repos: [RepoAlias] = RepoRegistry.all(),
                             tasks: [WorkTask] = TaskStore.all())
    -> (prompt: String, repo: String?, projectID: String?, publishes: Bool)? {
        // 队列里已经有活 → 不用填，调度器自己会派
        if tasks.contains(where: { $0.state == .queued }) { return nil }

        // **先看项目清单。** 那里面是老板批过方案的、有产出价值的常态化项目
        //（资产包、内容生产）；储备池里是从代码扫出来的零碎维护活。
        // 一个能卖钱的资产包，价值高于补一条注释。
        if let hit = Playbook.nextWork(for: opp.platform) {
            return (hit.prompt, hit.project.repo, hit.project.id, hit.recipe.publishes)
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
                return (p, path, nil, false)
            }
        }
        return nil
    }
}
