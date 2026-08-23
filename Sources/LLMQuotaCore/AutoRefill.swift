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
        let busy = latest.values.contains {
            $0.state == .queued || $0.state == .running || $0.state == .blocked
        }
        if busy { return false }
        return Review.list(repo: repo).isEmpty
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

        怎么挑:
        1. 先看仓库现状(git log 最近几十条、STATUS.md、已有的目录结构),
           判断上面那份计划**做到哪儿了**。
        2. 挑**下一块**还没做的 —— 要是一整块能交付的东西,不是一个碎片。
           宁可一次做一件完整的事,也别开三个半成品。
        3. 挑的时候避开这两类(它们归别人):
           - 要老板拍板的(账号、签名、上架、花钱、商标)
           - 需要他看效果才能定的(那种做完了交录屏就行,别等他)
        4. **在提交信息第一行写清你挑了什么、为什么是它** —— 别人要能复核你的判断。

        做完的标准照仓库 AGENTS.md 的规矩来(测试、证据、资产登记)。
        如果你判断当前没有值得做的下一块(比如在等外部条件),
        就**什么都别改**,如实说清为什么 —— 空跑一次比乱开一个坑好。
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
