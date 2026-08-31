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
    /// `flock` 负责跨进程；同一进程里的多个前台线程还需要这一层。
    /// Darwin 的 advisory lock 是进程级语义，不能拿线程测试代替互斥锁。
    private static let refillClaimLock = NSLock()

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
            // `pause` 也落成 blocked，但语义是主动封存：保留分支/会话供未来
            // 恢复，并没有人在处理或等待答复。把它算忙会让一个已冻结的旧
            // 方向永久堵住同仓库后续主线。
            if t.pausedAt != nil { return false }
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
    /// 用 machineID 标认领者，供审计看是谁抢到；新鲜认领连本机自己也挡。
    /// 幂等由 `lastRefillAt` 和任务账本负责，不能靠“自己不挡自己”——两个
    /// 前台进程会在同一秒都读到空队列，各派一份完全相同的任务。
    static func claimRefill(repo: String, now: Date) -> Bool {
        refillClaimLock.lock()
        defer { refillClaimLock.unlock() }

        // 同机的“读 claim → 写 claim”必须放进内核锁。只改下面的新鲜时间
        // 判断仍有竞态：两个进程都可能在任一方写入前读到不存在。
        let lease = LocalExecutionLease(
            scope: .repo,
            key: "auto-refill:\(repo)",
            root: Paths.appSupport.appendingPathComponent(
                "refill-claim-leases", isDirectory: true))
        guard lease.acquire() else { return false }
        defer { lease.release() }

        let dir = Paths.sharedRoot.appendingPathComponent("config/refill-claims",
                                                          isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = repo.replacingOccurrences(of: "/", with: "_")
        let f = dir.appendingPathComponent(safe + ".json")
        let me = Paths.machineID()
        let iso = ISO8601DateFormatter()
        // 已有新鲜 claim → 让开。本机也必须让开，否则并发前台会重复派活。
        if let d = try? Data(contentsOf: f),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let at = (obj["at"] as? String).flatMap({ iso.date(from: $0) }),
           now.timeIntervalSince(at) < minInterval {
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

    /// 主线里的一块。
    public struct MainlineItem: Equatable, Sendable {
        public var index: Int      // 1-based
        public var text: String    // 「【人物·皮肤】人物有真皮肤…」那一整行(去掉序号)
    }

    /// 从 PLAN.md 的「⭐ 续活主线」一节里挑**第一个没标「已完成」的块**。
    ///
    /// 老板 2026-08-23:「续活任务也不知道在干啥」。原来只把整份 PLAN.md 塞给
    /// agent 让它自己挑,挑了哪块、做完前谁也看不出 —— 任务标题永远是通用的
    /// 「按目标挑下一块」。现在**系统选块**:标题直接写「主线 N:块名」,
    /// 手机上一眼看出它在干哪一块;也从机制上保证「一块接一块」的连续性,
    /// 不靠 agent 自觉。做完要在 PLAN.md 那一条末尾标「已完成」,下次就跳过。
    public static func nextMainlineItem(in plan: String, skipping: Set<Int> = []) -> MainlineItem? {
        guard let start = plan.range(of: "续活主线") else { return nil }
        let tail = plan[start.upperBound...]
        // 主线一节到下一个「## 」标题为止
        let section = tail.split(separator: "\n", omittingEmptySubsequences: false)
        var idx = 0
        var current: (Int, String)? = nil
        var items: [(Int, String)] = []
        func flush() { if let c = current { items.append(c) }; current = nil }
        for raw in section.dropFirst() {
            let line = String(raw)
            if line.hasPrefix("## ") { break }          // 下一节
            let t = line.trimmingCharacters(in: .whitespaces)
            // 「1. 【…】…」开头 = 新的一块;续行(以空格/— 开头)并进上一块
            if let m = t.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                flush()
                idx = Int(t[m.lowerBound..<m.upperBound].filter(\.isNumber)) ?? idx + 1
                current = (idx, String(t[m.upperBound...]))
            } else if var c = current, !t.isEmpty, !t.hasPrefix("**"), !t.hasPrefix(">") {
                c.1 += " " + t; current = c
            }
        }
        flush()
        for (i, text) in items where !text.contains("已完成") && !text.contains("✅") {
            if skipping.contains(i) { continue }
            return MainlineItem(index: i, text: text)
        }
        return nil
    }

    /// 一条已派过的主线任务,它的分支现在处于什么状态。
    public enum BranchState: Sendable { case merged, pending, gone }

    /// **已经派出去、还没落地的主线块。** 这些块不能再派第二遍。
    ///
    /// 实锤(2026-08-23):主线第 3 块 14:09 派给 Kimi,14:49 做完、36 个文件、
    /// 证据齐全,分支等审核/落地;PLAN.md 的「已完成」标在它的分支上,main 上的
    /// PLAN 还写着没完成 —— 16:10 续活又把第 3 块派了一遍(Kimi 跑 10 分钟、
    /// 零产出)。「已完成」只看 main 上的 PLAN 不够:**派过且分支还在、没合、
    /// 没丢的块就是在飞**,跳过它。这是老板说的「一块接一块」真正的判据。
    ///
    /// 判据(每个主线任务取最新一条记录):
    ///   - 在排/在跑/在等人 → 在飞(其实 isIdle 早已拦住,写全为了判定完整)
    ///   - done:分支还在且没合进 base → 在飞;合了/丢了/分支没了 → 不在
    ///   - failed / 已丢弃 → 不在(该重派)
    public static func mainlineItemsInFlight(
        repo: String, tasks: [WorkTask], base: String = "main",
        branchState: ((String) -> BranchState)? = nil
    ) -> Set<Int> {
        let want = NSString(string: repo).expandingTildeInPath
        let state = branchState ?? { branch in
            guard GitWorkspace.branchExists(branch, in: repo) else { return .gone }
            let r = GitWorkspace.git(["merge-base", "--is-ancestor", branch, base], in: repo)
            return r.exitCode == 0 ? .merged : .pending
        }
        var latest: [String: WorkTask] = [:]
        for t in tasks where NSString(string: t.repo).expandingTildeInPath == want {
            latest[t.id] = t
        }
        var out: Set<Int> = []
        for t in latest.values {
            guard let n = mainlineIndex(ofTitle: t.prompt) else { continue }
            if t.discardedAt != nil { continue }
            switch t.state {
            case .queued, .running, .blocked:
                out.insert(n)
            case .done:
                if let b = t.branch, state(b) == .pending { out.insert(n) }
            default:
                continue
            }
        }
        return out
    }

    /// 从任务标题(提示词首行)读出「主线第几块」。
    public static func mainlineIndex(ofTitle prompt: String) -> Int? {
        let first = prompt.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard let r = first.range(of: #"【续活·主线 (\d+)】"#, options: .regularExpression) else { return nil }
        return Int(first[r].filter(\.isNumber))
    }

    static func goalDoc(repo: String) -> String? {
        for f in goalFiles {
            // 保存仓库不保证正检出在 main：架构师、本地人工修复都可能临时
            // 占着其他分支。续活任务却一定从主线建立，目标也必须读主线；
            // 否则当前工作分支上的旧 PLAN 会让项目误判为已完成或走错方向。
            let main = GitWorkspace.git(["show", "main:\(f)"], in: repo)
            if main.exitCode == 0, !main.stdout.isEmpty {
                return f + "\n\n" + String(main.stdout.prefix(6000))
            }
            // 非 Git 仓库、还没有 main，或目标文件尚未提交时保留原有回退。
            let p = (repo as NSString).appendingPathComponent(f)
            if let s = try? String(contentsOfFile: p, encoding: .utf8), !s.isEmpty {
                return f + "\n\n" + String(s.prefix(6000))
            }
        }
        return nil
    }

    static func prompt(repoName: String, goal: String, item: MainlineItem) -> String {
        """
        【续活·主线 \(item.index)】\(item.text.prefix(40))

        \(repoName) 的队列空了。**系统已经按主线替你选好了要做的块 —— 就做这一块**:

        > 主线第 \(item.index) 块:\(item.text)

        这不是让你自由挑;做完这一块之后,**在 PLAN.md 的「⭐ 续活主线」里把
        第 \(item.index) 条末尾加上「— 已完成」**(系统靠这个标记知道该进下一块)。

        目标文档:
        ---
        \(goal)
        ---

        怎么做:
        1. 先看仓库现状(git log、STATUS.md、已有目录/资产),确认这一块**目前做到哪**。
           如果它其实已经做完了(只是 PLAN.md 没标),就只把 PLAN.md 标上「已完成」
           然后停,别重做。
        2. 如果已经有分支在做这一块(git branch 里有对应 agent 分支),别重复开 ——
           什么都别改,如实说明。
        3. 否则就把这一块做完:一整块,不留半成品,不顺手开别的块。
        4. **边做边提交:每完成一个能独立成立的部分就 `git commit`**,别攒到最后。
           单次运行有时限(实测一块大活 45 分钟会被掐),中途提交的就不会丢,
           下次接力直接续。时限快到时**先收尾提交、写清做到哪**,不要硬撑到被杀。
        5. **提交信息第一行写:主线第 \(item.index) 块「块名」。**

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
        // **系统选块,不让 agent 猜。** 没有主线 / 主线全部已完成 → 不派,
        // 而不是派一条「你自己看着办」—— 那正是老板说的「瞎续活」。
        // **派过还没落地的块不重复派。** main 上的 PLAN 只在分支落地后才会标
        // 「已完成」;这中间(等审核/等验收)的窗口里不能把同一块再派一遍。
        let inFlight = mainlineItemsInFlight(repo: repo, tasks: tasks)
        guard let item = nextMainlineItem(in: goal, skipping: inFlight) else {
            if let waiting = nextMainlineItem(in: goal) {
                return Outcome(repo: repo, enqueued: false,
                               note: "主线第 \(waiting.index) 块已经做完在等落地/验收,后面没有别的块 —— 不重复派")
            }
            return Outcome(repo: repo, enqueued: false,
                           note: "PLAN.md 没有「续活主线」或主线全部已完成 —— 等老板给下一段")
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
                prompt: prompt(repoName: alias, goal: goal, item: item),
                repo: repo, classify: true, split: false, force: true,
                origin: "auto-refill",
                preferredPlatform: RepoExecutionPolicy.implementationOwner(
                    for: repo, prompt: prompt(repoName: alias, goal: goal, item: item)))
            if case .single = r {
                return Outcome(repo: repo, enqueued: true,
                               note: "主线第 \(item.index) 块:\(item.text.prefix(30))")
            }
            return Outcome(repo: repo, enqueued: false, note: "入队没成")
        } catch {
            return Outcome(repo: repo, enqueued: false,
                           note: "补活失败:\(error.localizedDescription)")
        }
    }
}
