import Foundation

/// **仓库闲下来时,按常设目标自己补下一块活。**
///
/// 老板 2026-08-22:「总不能跑一步卡一步就需要你介入」「常设目标自动续活开干」。
///
/// ## 它替掉的是谁
///
/// 替掉的是**我**。在这之前,队列空了就得我来派下一批 ——
/// 老板真正要的「不用介入」,卡的一直是这一环,而不是单个任务跑得快不快。
///
/// ## 和储备池的区别
///
/// `ReservePool` 是「额度快作废了,塞点零碎维护活别浪费」——填空。
/// 这个是「这个项目的下一块该干什么」——推进。两件事,别混。
///
/// ## 为什么不派「规划任务」再由它派活
///
/// 多一跳就多一次失败面,而且规划的产物是文本,又要解析。
/// 直接让干活的 agent 读目标文档、自己挑下一块 —— 它本来就有这个能力
/// (老板 2026-08-22:「kimi 不比你差」)。一条任务,粗粒度,自带方向。
public enum AutoRefill {
    /// 同一个仓库两次自动补活至少隔这么久。
    ///
    /// 不设间隔的话,一个跑得快的仓库会被连续补活,把别的仓库挤没;
    /// 而且万一目标文档写得含糊,会连着生成一串同样含糊的任务。
    public static let minInterval: TimeInterval = 2 * 3600

    /// 目标从哪读。**放仓库里,不放配置里** ——
    /// 它要能被 agent 读到、被评审看到、跟着代码一起演进。
    static let goalFiles = ["PLAN.md", "ROADMAP.md", "AGENTS.md"]

    public struct Outcome: Sendable {
        public var repo: String
        public var enqueued: Bool
        public var note: String
    }

    /// 这个仓库现在是不是真闲。
    ///
    /// 三样都得空:没有在排/在跑的活、没有等落地的产出、没有等人拍板的。
    /// 少判一样就会在「其实有活、只是卡着」的时候硬塞新活 ——
    /// 那是火上浇油,老板会看到队列越堵越长。
    public static func isIdle(repo: String, tasks: [WorkTask]) -> Bool {
        let mine = tasks.filter {
            NSString(string: $0.repo).expandingTildeInPath
                == NSString(string: repo).expandingTildeInPath
        }
        var latest: [String: WorkTask] = [:]
        for t in mine { latest[t.id] = t }
        // **被「已死上游」冻住的 blocked 不算忙。**
        //
        // 实锤(2026-08-23):人物形象第一版图的 s6/s7 被上游 s4(failed)冻住,
        // 永远不会解冻 —— 它们不是在干活,是僵尸。可原来这里把一切 blocked
        // 都算忙,于是 Flint 永远 isIdle=false,续活专注了半天一次没触发,
        // 老板反复看到「进行中的任务没有了」。
        // 只有还能恢复的 blocked 才算忙:等人拍板的(frozenBy==nil),
        // 或上游还活着(非 failed/discarded)的。
        let busy = latest.values.contains { t in
            if t.state == .queued || t.state == .running { return true }
            guard t.state == .blocked else { return false }
            guard let up = t.frozenBy.flatMap({ latest[$0] }) else { return true } // 等人,算忙
            return !(up.state == .failed || up.discardedAt != nil)               // 上游活着才算忙
        }
        if busy { return false }
        // **等落地的分支,只有系统还在主动处理它时才算忙。**
        //
        // 原来是 `Review.list(repo:).isEmpty` —— 那个 list 是「所有未合入的
        // agent 分支」,**包含一切「留给人工」的终态**:被否决的、审核放弃的、
        // 证据派到上限的、刷新刷不动的。任一条存在,仓库就永远 isIdle=false,
        // 续活永远不触发。控制流 review 在 worker.log 里数出来:
        // 「要看效果 flint:1 条还没交证据」连续 59 轮、跨三天 ——
        // 这整段时间 Flint 不可能续活,不管我把续活挪到哪。
        //
        // 改成:某条分支算忙,当且仅当它有在排/在跑的派生任务(审核/证据/
        // 刷新/修验证)—— 系统正在动它。没人动的分支是「留给人工」,
        // 不该挡住主线往前推。
        let pending = Review.list(repo: repo)
        let activelyHandled = pending.contains { item in
            let b = item.branch
            return TaskKind.hasPendingDerived(branch: b, tasks: tasks, kind: TaskKind.isReview)
                || TaskKind.hasPendingDerived(branch: b, tasks: tasks, kind: TaskKind.isEvidence)
                || TaskKind.hasPendingDerived(branch: b, tasks: tasks, kind: TaskKind.isRefresh)
                || tasks.contains { ($0.state == .queued || $0.state == .running)
                                    && VerifyRepair.isRepairPrompt($0.prompt, of: b) }
        }
        return !activelyHandled
    }

    static func lastRefillAt(repo: String, tasks: [WorkTask]) -> Date? {
        tasks.filter { $0.origin == "auto-refill"
            && NSString(string: $0.repo).expandingTildeInPath
                == NSString(string: repo).expandingTildeInPath }
            .compactMap(\.createdAt).max()
    }

    /// 续活的跨机认领。写进同步目录(config,双向同步),别的机器读得到。
    /// 文件里存认领时间;新鲜(< minInterval)就算别人占着。
    /// 用 machineID 标认领者,自己上一轮写的不挡自己(幂等重试)。
    static func claimRefill(repo: String, now: Date) -> Bool {
        let dir = Paths.sharedRoot.appendingPathComponent("config/refill-claims",
                                                          isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = repo.replacingOccurrences(of: "/", with: "_")
        let f = dir.appendingPathComponent(safe + ".json")
        let me = Paths.machineID()
        let iso = ISO8601DateFormatter()
        // 已有新鲜 claim 且不是自己 → 让开。
        if let d = try? Data(contentsOf: f),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let at = (obj["at"] as? String).flatMap({ iso.date(from: $0) }),
           now.timeIntervalSince(at) < minInterval,
           (obj["by"] as? String) != me {
            return false
        }
        let payload: [String: Any] = ["repo": repo, "by": me, "at": iso.string(from: now)]
        guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return true }
        // 走 ICloudSafe:claim 落在同步目录,裸原子写会在 iCloud 卡死时永久阻塞
        // (仓库铁律,ICloudWriteGuardTests 守着)。写失败不拦补活 —— 顶多退回到
        // 「各机各判两小时」的旧行为,不会更糟。
        _ = ICloudSafe.write(out, to: f)
        return true
    }

    static func goalDoc(repo: String) -> String? {
        for f in goalFiles {
            let p = (repo as NSString).appendingPathComponent(f)
            if let s = try? String(contentsOfFile: p, encoding: .utf8), !s.isEmpty {
                return f + "\n\n" + String(s.prefix(6000))
            }
        }
        return nil
    }

    static func prompt(repoName: String, goal: String) -> String {
        """
        【续活】\(repoName) 的队列空了 —— 按项目目标挑出下一块该做的事,并做完它。

        这是一条**自主任务**:没有人给你指定具体做什么,你自己从目标文档里挑。

        目标文档:
        ---
        \(goal)
        ---

        怎么挑 —— **不是让你自由发挥,是严格照主线走**:
        1. 找到上面「⭐ 续活主线」那一节的编号清单。**没有这一节就什么都别做**,
           如实说「PLAN.md 没有续活主线,不知道该做哪块」然后停 ——
           绝不自己从别处猜一块活出来(那正是老板说的「瞎续活」)。
        2. 看仓库现状(git log、STATUS.md、已有目录/资产),判断主线里
           **每一块做到哪了**。
        3. 做**从上往下第一个「还没完成」的那一块** —— 就那一块,不要跳、
           不要挑后面顺眼的、不要同时开好几块。这是为了「活的连续性」:
           一块接一块,不留半成品。
        4. 如果第一个未完成的那块**已经有分支在做**(git branch 里有对应
           agent 分支),说明它在进行中 —— 别重复开,什么都别做,如实说明。
        5. **提交信息第一行写:主线第 N 块「块名」,以及你判断它未完成的依据。**

        避开这两类(归老板,主线里也标了):账号/签名/上架/花钱/商标;
        以及需要他看效果拍板的(做完交录屏,别等他)。

        做完照 AGENTS.md 的规矩(测试、证据、资产登记)。
        判断不了「第一个未完成的是哪块」时,**什么都别改**,说清卡在哪 ——
        空跑一次,比挑错一块烧掉额度好。
        """
    }

    /// 给一个仓库补一条活。不该补就返回 nil。
    public static func refill(repo: String, alias: String,
                              tasks: [WorkTask] = TaskStore.all(),
                              now: Date = Date()) -> Outcome? {
        guard isIdle(repo: repo, tasks: tasks) else { return nil }
        if let last = lastRefillAt(repo: repo, tasks: tasks),
           now.timeIntervalSince(last) < minInterval {
            return nil
        }
        guard let goal = goalDoc(repo: repo) else {
            return Outcome(repo: repo, enqueued: false,
                           note: "没有目标文档(PLAN.md / ROADMAP.md / AGENTS.md),不知道该往哪走")
        }
        // **跨机抢占,先到先得。**
        //
        // 2026-08-23 复审(第三轮)逮到:lastRefillAt 读的是 tasks.jsonl,
        // 而它是**机器本地、不同步**的 —— 两台机器各算各的「两小时」,
        // 会同时给同一仓库补活,两个 agent 各挑「下一块」大概率撞车,
        // 重复产出、白烧额度、落地冲突。RepoLease 也只看本地 running,拦不住。
        //
        // 修法:补活前往**同步**目录写一个带时间戳的 claim,先到先得。
        // 别的机器同一轮看到新鲜 claim 就让开。这道闸落在同步且能被对端
        // 读到的地方,不像 tasks.jsonl 是各存各的。
        guard claimRefill(repo: repo, now: now) else {
            return Outcome(repo: repo, enqueued: false,
                           note: "另一台机器刚认领了这个仓库的续活,让开")
        }
        do {
            let r = try TaskIntake.enqueue(
                prompt: prompt(repoName: alias, goal: goal),
                repo: repo, classify: true, split: false, force: true,
                origin: "auto-refill")
            if case .single = r {
                return Outcome(repo: repo, enqueued: true, note: "队列空了,按目标补了一块活")
            }
            return Outcome(repo: repo, enqueued: false, note: "入队没成")
        } catch {
            return Outcome(repo: repo, enqueued: false,
                           note: "补活失败:\(error.localizedDescription)")
        }
    }
}
