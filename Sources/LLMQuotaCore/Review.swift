import Foundation

/// 批量审阅和消化 agent 产出的分支。
///
/// ## 为什么这个必须先于「自动生成任务」做
///
/// 只跑了 8 个任务，仓库里就积了 8 个 `agent/*` 分支、0 个合并、8 个 worktree
/// 残留，其中 2 个已经和 main 冲突了 —— 而且 4 个分支同时改 README.md。
///
/// 生成端做得再好，消化端跟不上就只是把积压做大。所以先有能一次性看完、
/// 挑着合、合完自动清理的工具，再谈自动生成。
public enum Review {

    public struct Item: Sendable {
        public var branch: String
        public var taskID: String
        public var platform: String
        /// 相对合并基点改了哪些文件。
        public var files: [String]
        public var insertions: Int
        public var deletions: Int
        public var subject: String
        public var committedAt: Date?
        /// 分支头的短 sha。
        ///
        /// **审核结论是针对某一版 diff 的，不是针对分支名的。** 有了它，
        /// 「这条分支被否过」才能收窄成「这条分支的**那一版**被否过」——
        /// 改了之后重新提交，理应重新判。
        public var head: String = ""
        /// 能不能干净地合进目标分支。
        public var mergesCleanly: Bool
        /// 和哪些**别的待审分支**改了同一个文件。
        ///
        /// 这个字段是有实际用处的：多个分支改同一个文件时，
        /// 单看每一个都能干净合入，但按顺序合完第一个之后第二个就冲突了。
        /// 先把这种成组的挑出来，人能决定先合哪个。
        public var overlapsWith: [String]
        /// 关联的任务记录（如果还在 tasks.jsonl 里）。
        public var prompt: String?
        public var hasWorktree: Bool

        /// agent 交的**证据截图**（相对仓库根的路径）。
        ///
        /// 终审最大的成本不是判断，是**重跑一遍**：xcodegen + build +
        /// 装模拟器 + 截图，五分钟起步。而 agent 收工前本来就该自己跑一遍
        /// 并截图（AGENTS.md 的质量门槛要求的），那些图就在分支里躺着。
        /// 把它们列出来，人看图就能判，不必自己下场 ——
        /// 实测这是产出积压的头号原因：56% 的完成产出没人来得及审。
        public var evidence: [String]

        public var netLines: Int { insertions - deletions }
    }

    /// 列出所有待审分支。
    ///
    /// - Parameter base: 合并目标，通常是 main。
    /// `list` 的短命缓存。
    ///
    /// ## 为什么必须有
    ///
    /// `list` 对**每一条待审分支**跑 merge-base / numstat / merge-tree ——
    /// 实测单个仓库 10 条分支要 **33.9 秒**。
    ///
    /// 而 2026-08-18 这天我一口气加了五个新调用点（BaselineFreshness、
    /// MergeReview、EvidenceGate、StaleBranch 的两个），加上原有的五个，
    /// 一轮循环里同一个仓库要重算六七遍。后果是「下发视图」（60 秒预算）
    /// 和「提醒」（20 秒预算）**每轮都超时**，连着几十轮 ——
    /// 手机端于是什么都收不到。
    ///
    /// 这是我自己引入的回归：每个新检查单看都合理，合起来把循环压垮了。
    ///
    /// ## 为什么敢缓存
    ///
    /// 待审集合变化很慢：一个任务跑几分钟才产生一条新分支。
    /// 真正会让它立刻变的只有**我们自己执行的合并/丢弃**，
    /// 那两处显式清缓存（`invalidate`）。
    ///
    /// 12 秒：短于循环间隔（30 秒），所以跨轮一定重算；
    /// 长于一轮内部所有调用点的总耗时，所以一轮里只算一次。
    static let listCacheTTL: TimeInterval = 12
    nonisolated(unsafe) private static var listCache:
        [String: (at: Date, items: [Item])] = [:]
    private static let listCacheLock = NSLock()

    /// 合并 / 丢弃之后必须清 —— 那两件事会立刻改变待审集合。
    public static func invalidateListCache() {
        listCacheLock.lock(); defer { listCacheLock.unlock() }
        listCache.removeAll()
    }

    /// 按分支上的 ID 找它的任务记录。**只准有这一个实现。**
    ///
    /// ## 图任务的分支名和记录对不上
    ///
    /// 普通分支是 `agent/<平台>/<任务ID>`，拿末段直接查 `byID` 就行。
    /// 但**图任务的分支名是 `agent/graph/<图ID>`**，而任务记录是按
    /// **步骤**存的（`<图ID>s1`、`<图ID>s2`…）—— 图 ID 本身在 `byID`
    /// 里根本不存在，查出来永远是 nil。
    ///
    /// 实测（2026-08-19）：两个游戏仓库里全部 **5 条** `agent/graph/*`
    /// 分支，精确匹配**全是 0**。它们被一律判成
    /// 「任务记录没了 —— 自动环节一律不碰，只能人工处置」，
    /// 也就是**图任务的产出从来没进过自动落地**，一条都没有。
    ///
    /// 代价是连锁的：`agent/graph/3f68707c`（08-17，38 个文件，
    /// 能干净合入）卡了两天 → main 基线落后 38 个文件 →
    /// `BaselineFreshness` 拿旧基线挡住队列里所有的活 → 什么都不跑 →
    /// 老板在手机上看到的是「正在进行」永远空着。
    /// **一条分支认不出记录，拖停了整套系统两天。**
    ///
    /// 找不到精确匹配时退回到这张图里**最后一个 done 的步骤**：
    /// 分支上的产出就是它提交的，它的状态和风险档才是该拿来判闸的。
    static func taskFor(_ id: String, in byID: [String: WorkTask],
                        all tasks: [WorkTask]) -> WorkTask? {
        if let t = byID[id] { return t }
        guard !id.isEmpty else { return nil }
        // graphID 字段和 `<图ID>sN` 命名约定两条都认：老任务可能没写
        // graphID，只认一条的话老数据会继续卡着。
        let steps = tasks.filter {
            $0.graphID == id || ($0.id.hasPrefix(id) && $0.id != id)
        }
        guard !steps.isEmpty else { return nil }
        // done 的优先：分支上的提交是它打的。都没 done 就返回最后一步，
        // 让上层的状态闸自己去判 —— 而不是在这里假装记录不存在。
        // 「记录没了」走的是「只能人工处置」，「记录在、状态不对」
        // 走的是正常状态闸、会自己好，两者绝不能混。
        return steps.last { $0.state == .done } ?? steps.max { $0.id < $1.id }
    }

    public static func list(repo: String, base: String = "main",
                            tasks: [WorkTask] = TaskStore.all()) -> [Item] {
        // **键里必须带任务集的指纹。**
        //
        // `list` 的结果依赖 `tasks`（图有没有跑完、任务是不是 done 都会
        // 改变哪些分支进名单）。只用 repo|base 当键的话，同一个仓库换一份
        // 任务集去查会拿到上一次的结果 —— 测试立刻抓到了这一点
        //（testUnfinishedGraphIsExcludedFromReview）。
        //
        // 指纹只取 id + 状态：这两样变了结果才可能变，而算它比一次 git 便宜
        // 好几个数量级。
        var fp = Hasher()
        fp.combine(tasks.count)
        for x in tasks { fp.combine(x.id); fp.combine(x.state.rawValue) }
        let cacheKey = repo + "|" + base + "|" + String(fp.finalize())
        listCacheLock.lock()
        if let hit = listCache[cacheKey],
           Date().timeIntervalSince(hit.at) < listCacheTTL {
            listCacheLock.unlock()
            return hit.items
        }
        listCacheLock.unlock()
        let computed = listUncached(repo: repo, base: base, tasks: tasks)
        listCacheLock.lock()
        listCache[cacheKey] = (Date(), computed)
        listCacheLock.unlock()
        return computed
    }

    static func listUncached(repo: String, base: String = "main",
                             tasks: [WorkTask] = TaskStore.all()) -> [Item] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })

        let raw = GitWorkspace.git(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads/agent/"], in: repo)
        let branches = raw.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !branches.isEmpty else { return [] }

        // 已经合过的不再列。只看还悬着的。
        let mergedOut = GitWorkspace.git(
            ["branch", "--merged", base, "--list", "agent/*"], in: repo)
        let merged = Set(mergedOut.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "*+"))) })

        let worktrees = Set(activeWorktreeBranches(repo: repo))

        // **跑到一半的图不能进待审名单。**
        //
        // 图内所有节点共用一个分支，第一个节点提交完这条分支就有内容了 ——
        // 而 `work review --auto` 只看「能不能干净合入 + 验证过不过」，
        // 于是一个只改了函数签名、还没改调用点的半成品会被合进 main
        //（只改定义时完全可能编译通过，verify 挡不住语义上做了一半的重构）。
        //
        // 更糟的是合并成功后 mergeUnverified 会 `worktree remove --force`：
        // 如果此刻正有节点在这个目录里干活（review 和 work loop 是两个进程，
        // 只有后者上了锁），活着的 agent 的工作目录会被直接抽走，
        // 未提交的产出无声消失。
        //
        // 判据：图里还有没跑完的节点就跳过。全部终态了才允许审。
        //
        // **但搁浅的图要放行。** 这条排除规则原来把 blocked 一律当成
        // 「还在跑」—— 而一步失败之后下游全都是 blocked，且没有任何东西
        // 会把那个 failed 推回去。三件事连起来是一条静默死亡链：
        //
        //     一步失败 → 下游 blocked → 整图算「还没跑完」
        //     → 分支进不了这个名单 → 手机上永远看不见
        //
        // Greed 的 f2872114 就这么躺了一整天：s1–s4 完成、19 个文件的产出，
        // s5 挂了，没有任何界面提过一个字。
        //
        // 搁浅 ≠ 还在跑。还在跑的不该打扰人，搁浅的必须让人看见 ——
        // 它已经不会自己好了，只有人能决定捞还是丢。
        let strandedGraphs = Set(TaskGraph.stranded(tasks).map(\.graphID))
        let unfinishedGraphs: Set<String> = Set(
            tasks.filter {
                $0.graphID != nil && ($0.state == .queued || $0.state == .running
                                      || $0.state == .blocked)
            }.compactMap { $0.graphID }
        ).subtracting(strandedGraphs)

        var items: [Item] = []
        for b in branches where !merged.contains(b) {
            if b.hasPrefix("agent/graph/") {
                let gid = String(b.dropFirst("agent/graph/".count))
                if unfinishedGraphs.contains(gid) { continue }
            }
            guard let mb = mergeBase(repo: repo, base: base, branch: b) else { continue }
            let stat = numstat(repo: repo, from: mb, to: b)
            guard !stat.files.isEmpty else { continue }

            let parts = b.split(separator: "/")   // agent/<平台>/<任务id>
            let platform = parts.count >= 2 ? String(parts[1]) : "?"
            let taskID = parts.count >= 3 ? String(parts[2]) : ""

            let log = GitWorkspace.git(
                ["log", "-1", "--format=%s%n%cI%n%h", b], in: repo).stdout
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            items.append(Item(
                branch: b, taskID: taskID, platform: platform,
                files: stat.files, insertions: stat.insertions, deletions: stat.deletions,
                subject: log.first ?? "",
                committedAt: log.count > 1 ? ISO8601DateFormatter().date(from: log[1]) : nil,
                head: log.count > 2 ? log[2] : "",
                mergesCleanly: mergesCleanly(repo: repo, base: base, branch: b),
                overlapsWith: [],
                prompt: byID[taskID]?.prompt,
                hasWorktree: worktrees.contains(b),
                // **人能直接看出成败的东西才算证据。**
                //
                // 老板的原话：「我只看人可阅读验证的成功，比如游戏截图、
                // 运行结果」。所以这里认的是截图、录屏、和实跑输出，
                // 不认代码 diff —— 让人读 diff 判断对不对，等于把
                // 「跑一遍」这件最贵的事推回给人。
                //
                // 录屏（.mov/.mp4/.gif）原来不算，实测漏掉过：一条交了
                // 29MB 咬合录屏的分支被判成「没交证据」。动画类的改动
                // 静态图根本证明不了，录屏才是它唯一能交的证据。
                //
                // 不硬性要求目录，agent 放哪儿都能认出来 ——
                // 少一条会被忘掉的规矩。
                // 判定在 EvidenceGate.isEvidenceFile —— 和「什么算证据」的
                // 条款同一个家。原来内联在这里，条款改了它不会跟着改。
                evidence: stat.files.filter(EvidenceGate.isEvidenceFile)))
        }

        // 交叉比对文件重叠。O(n²) 但 n 是待审分支数，几十个顶天了。
        for i in items.indices {
            let mine = Set(items[i].files)
            items[i].overlapsWith = items.enumerated()
                .filter { $0.offset != i && !Set($0.element.files).isDisjoint(with: mine) }
                .map(\.element.branch)
        }
        return items.sorted { (a, b) in
            // 能干净合的排前面（先摘容易的），其次按改动小的优先 —— 小改动审得快。
            if a.mergesCleanly != b.mergesCleanly { return a.mergesCleanly }
            return a.files.count < b.files.count
        }
    }

    /// 合并一个分支。
    ///
    /// 用 `--no-ff`，让每一次 agent 产出在历史上都是一个可识别、可整体回退的合并点。
    /// 快进合并会把它和手写提交混在一起，事后想只回退某个 agent 的改动就很难。
    /// 合并前先验证**合并结果**。
    ///
    /// ## 为什么不能只验证分支本身
    ///
    /// 分支单独跑得过，合进 main 之后照样可能坏 —— 两边各自正确、
    /// 放一起矛盾（一边改了函数签名、另一边新增了调用）。
    /// 所以要验的是合并**之后**的那棵树，不是分支。
    ///
    /// ## 为什么在临时 worktree 里做
    ///
    /// 直接在主仓库里「合了再验、不过再回退」有两个问题：验证要几十秒到几分钟，
    /// 这段时间主仓库处在一个半成品状态，人或别的进程凑巧看一眼就会困惑；
    /// 而且回退本身也可能失败，那就留下一个更糟的现场。
    /// 临时 worktree 是一次性的，验砸了直接删掉，主仓库全程没被碰过。
    ///
    /// 返回 nil 表示通过（或没配验证命令）；返回字符串是失败原因。
    /// 验证失败。`transient` = 不是这份产出的错(超时 / 被杀 / 建不出工作区 /
    /// 主仓库状态不对),下一轮该重试而不是记否决。
    /// NSError.userInfo 里的结构化标志:这次没合是瞬时故障,不该记否决。
    public static let transientKey = "llmq.transient"

    public struct VerifyFailure {
        public var message: String
        public var transient: Bool
    }

    public static func verifyMerge(repo: String, branch: String, base: String,
                                   command: String, timeout: Int = 900) -> VerifyFailure? {
        let tmp = NSTemporaryDirectory() + "llmq-verify-\(UUID().uuidString.prefix(8))"
        defer {
            _ = GitWorkspace.git(["worktree", "remove", "--force", tmp], in: repo)
            _ = GitWorkspace.git(["worktree", "prune"], in: repo)
        }
        let add = GitWorkspace.git(["worktree", "add", "--detach", tmp, base], in: repo)
        guard add.exitCode == 0 else {
            return VerifyFailure(message: "建临时工作区失败：\(add.stderr.prefix(160))",
                                 transient: true)
        }
        let m = GitWorkspace.git(
            ["merge", "--no-ff", "-m", "verify \(branch)", branch], in: tmp)
        guard m.exitCode == 0 else {
            // **把 stderr 也带上。** 原来只贴 stdout，而 git 的失败原因
            // （身份没配、锁冲突、坏对象…）走的是 stderr —— 于是所有
            // 非冲突的失败都被显示成「合并结果有冲突：」后面空空如也，
            // 人和评审 agent 都被误导（2026-08-21 实测：手工同样的命令
            // 退出码 0，而这里报冲突，查了半天才发现是消息在骗人）。
            let detail = (m.stderr + " " + m.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 合并本身失败(冲突/锁/环境)不是验证结论,归 StaleBranch/重试管。
            return VerifyFailure(message: "合并没成（退出码 \(m.exitCode)）：\(detail.prefix(300))",
                                 transient: true)
        }
        let r = Proc.run("/bin/sh", ["-c", command], cwd: tmp, env: [:],
                         timeout: TimeInterval(timeout))
        // **被杀 ≠ 没通过。** 退出码 15（SIGTERM）多半是发布重启 worker 顺手
        // 杀掉了验证子进程，跟这份产出的对错毫无关系。混在一起记的后果实测过：
        // 一份好产出被记进否决名单、下游三步永久冻住、整条图搁浅，
        // 而唯一会发现的是人。详见 ExitClassify。
        let kind = ExitClassify.classify(exitCode: r.exitCode, timedOut: r.timedOut)
        switch kind {
        case .passed:
            return nil
        case .killed, .timedOut:
            // 交回给调用方当「这轮先别合」处理，而不是「这份产出不行」。
            // **transient 必须是结构化标志。** 控制流 review §6 实锤:这句
            // 「（下一轮会重试）」只是文字,autoLand 拿到后照样 setAutoLandVeto,
            // 下一轮 activeVeto 直接 continue —— 文字承诺重试,控制流永久否决。
            // 超过 verifyTimeout(15 分钟构建)、发布重启时被 SIGTERM,都走这条。
            return VerifyFailure(message: ExitClassify.describe(kind) + "（下一轮会重试）",
                                 transient: true)
        case .failed:
            let out = (r.stderr + "\n" + r.stdout)
                .split(separator: "\n")
                .filter { $0.lowercased().contains("error") || $0.contains("failed") }
                .prefix(3).joined(separator: "；")
            return VerifyFailure(message: "验证没过（退出码 \(r.exitCode)）"
                + (out.isEmpty ? "" : "：\(out.prefix(240))"), transient: false)
        }
    }

    /// 合并一个分支。
    ///
    /// - Parameter verify: 仓库配了验证命令时，先在临时工作区里验一遍合并结果。
    ///   **默认开着**：一个不验证就落地的合并，等于把 agent 的产出直接
    ///   推进主干，而这套系统的产出是无人值守生成的。
    /// 自动落地的总开关。**默认关**：用户明确执行过
    /// `llmq work autoland on` 才开启，保证「机器替人合并」是被授权过的行为。
    /// 存成文件而不是内存标记：worker 重启后授权仍然有效。
    static var autoLandFlagURL: URL {
        Paths.appSupport.appendingPathComponent("autoland.on")
    }
    public static func autoLandEnabled() -> Bool {
        FileManager.default.fileExists(atPath: autoLandFlagURL.path)
    }
    public static func setAutoLand(enabled: Bool) {
        if enabled {
            try? ICloudSafe.write(Data("on".utf8), to: autoLandFlagURL)
        } else {
            try? FileManager.default.removeItem(at: autoLandFlagURL)
        }
    }

    /// 自动落地的否决名单：验收失败过的分支，别再自动重试。
    /// 本机文件，人工处置（合入/丢弃）后分支消失，条目就成了死数据，无害。
    static var autoLandVetoURL: URL {
        Paths.appSupport.appendingPathComponent("autoland-veto.json")
    }
    /// 一条否决。**记的是「哪个提交没过验收」，不是「哪条分支坏了」。**
    ///
    /// 和 `MergeReview.verdictIsStale` 是同一个道理、同一天修的同一个洞的
    /// 另一层：审核结论那层 2026-08-20 改成了绑提交，而这层否决还绑着
    /// 分支名 —— 于是「被否 → 改好 → 重新判」在上一层通了，走到这层
    /// 又被旧否决按名字扣住，唯一出路仍是人工清单子。**两层只修一层，
    /// 等于没修。**
    struct VetoEntry: Codable {
        var note: String
        /// 验收失败时分支头的短 sha。空串 = 老格式数据，不知道是哪个提交。
        var head: String
        var at: Date?
    }

    static func autoLandVeto() -> [String: VetoEntry] {
        guard let d = try? Data(contentsOf: autoLandVetoURL) else { return [:] }
        return decodeVetoes(d)
    }

    static func decodeVetoes(_ d: Data) -> [String: VetoEntry] {
        if let m = try? JSONDecoder().decode([String: VetoEntry].self, from: d) {
            return m
        }
        // 老格式：值是纯文字。head 未知 —— 保持原来的粘性行为，
        // 别让升级本身放行一批没验过的分支。
        let old = (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
        return old.mapValues { VetoEntry(note: $0, head: "", at: nil) }
    }

    /// 这条分支现在还被否着吗。**判定只有这一处，所有调用点都走它。**
    ///
    /// - 否决记了提交、分支已经走到新提交 → 否决过期，放它重新验收。
    ///   （验收本身就是闸：新提交要是还坏，会再花一次全量构建然后
    ///   重新被否 —— 贵，但正确性不靠这条否决。）
    /// - 老格式没记提交 → 粘性，维持旧行为。
    static func activeVeto(_ vetoes: [String: VetoEntry],
                           branch: String, head: String) -> String? {
        guard let e = vetoes[branch] else { return nil }
        if !e.head.isEmpty, !head.isEmpty, e.head != head { return nil }
        return e.note
    }

    static func setAutoLandVeto(branch: String, note: String, head: String) {
        var m = autoLandVeto()
        m[branch] = VetoEntry(note: String(note.prefix(300)), head: head, at: Date())
        if let d = try? JSONEncoder().encode(m) {
            try? ICloudSafe.write(d, to: autoLandVetoURL)
        }
    }

    public struct AutoLandOutcome: Sendable {
        public var branch: String
        public var landed: Bool
        public var note: String
    }

    /// 把「机器有把握」的那部分待审分支自动合进 main。
    ///
    /// 背景是一句用户原话：「不是 auto 模式，为啥有这么多需要我确认的」——
    /// 排查发现落地环节 100% 靠人敲 `work review`，agent 干完的活全部
    /// 堆在待审名单里等人，跟 auto 的承诺完全相反。
    ///
    /// 什么样的分支机器敢自己合（**五个条件全满足**）：
    /// - 任务记录还在，且状态是 done —— failed/running 的产出不碰；
    /// - 不是高危（risk != .sensitive）—— 高危本来就该人看；
    /// - 能干净合入（mergesCleanly）；
    /// - 不和其他待审分支改同一个文件（overlapsWith 为空）——
    ///   成组的分支合了第一个第二个就冲突，顺序该人定；
    /// - 改动文件里没有敏感路径（构建脚本、CI、签名配置那批）。
    ///
    /// 满足之后走的还是 `merge`（verify: true）：合并前照样跑仓库的
    /// 验收命令，验不过就不合、原样留给人。所以这里放宽的只是
    /// 「谁来按回车」，不是「按回车前查什么」。
    ///
    /// - Parameter maxPerCall: 一轮最多合几个。默认 1 —— 验收可能要跑
    ///   十几分钟的全量构建，循环每轮只吃一个，别把收答复、派活饿着。
    /// 每条待审分支**为什么**没被自动合入。
    ///
    /// ## 为什么必须有这个
    ///
    /// `autoLand` 的每一条闸都是 `continue` —— 不满足就静默跳过。
    /// 于是「一条都不合」和「没有待审分支」在日志里长得一模一样：
    /// 都是没有任何输出。
    ///
    /// 实测代价（2026-08-18）：Greed 有 9 条能干净合入、任务记录齐全、
    /// 状态 done 的分支堆着不落地，而日志里落地环节**从头到尾没有一行输出**。
    /// 查了否决名单、风险档、仓库脏否、manualReview 开关，全部排除，
    /// 最后只能靠读代码猜是哪条闸 —— 这正是今天反复咬人的那个形状：
    /// **静默跳过**。
    ///
    /// 跳过可以，不吭声不行。
    public struct Blocked: Sendable {
        public var branch: String
        public var reason: String
    }

    static func pending0(repo: String, base: String,
                         tasks: [WorkTask]) -> [Item] {
        list(repo: repo, base: base, tasks: tasks)
    }

    /// 列出每条没落地的分支和原因。判据和 `autoLand` 逐条对齐 ——
    /// 两边分叉的话这个诊断就会撒谎，那比没有还糟。
    public static func whyNotLanding(repo: String, base: String = "main",
                                     tasks: [WorkTask] = TaskStore.all())
        -> [Blocked] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let veto = autoLandVeto()
        let stranded = Set(TaskGraph.stranded(tasks).filter { $0.doneCount > 0 }
            .map(\.branch))
        // **先说清楚两个「整仓库一刀切」的守卫**，它们在 autoLand 里都是
        // 静默 return [] —— 于是「按设计留给人」和「机制坏了」在日志里
        // 长得一模一样。2026-08-18 实测：Greed 有 9 条能干净合入的分支
        // 堆着不动，查了一个多小时才发现是 manualReview 按设计挡住的。
        let wantPath = URL(fileURLWithPath: repo).standardizedFileURL.path
        let needsEvidenceAndReview = RepoRegistry.all().contains {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == wantPath
                && ($0.manualReview || !($0.qualityContract ?? "").isEmpty)
        }
        let needsVisualQuality = RepoRegistry.all().contains {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == wantPath
                && !($0.qualityContract ?? "").isEmpty
        }
        if let _ = dirtBlockingLanding(repo: repo) {
            return pending0(repo: repo, base: base, tasks: tasks).map {
                Blocked(branch: $0.branch,
                        reason: "仓库里有未提交的改动（多半是人正在里面写代码）"
                              + " —— 自动落地整轮让开，免得把人的改动卷进合并")
            }
        }

        let pending = list(repo: repo, base: base, tasks: tasks)
        let landable = pending.filter { i in
            guard i.mergesCleanly,
                  activeVeto(veto, branch: i.branch, head: i.head) == nil
            else { return false }
            guard let t = taskFor(i.taskID, in: byID, all: tasks) else { return false }
            if !stranded.contains(i.branch), t.state != .done { return false }
            let needsReview = requiresAgentReview(
                files: i.files, isStranded: stranded.contains(i.branch),
                repoNeedsManualReview: needsEvidenceAndReview, risk: t.profile?.risk)
            if needsReview {
                guard MergeReview.approved(branch: i.branch, files: i.files, tasks: tasks,
                                           head: i.head, headAt: i.committedAt)
                else { return false }
            }
            if needsVisualQuality, EvidenceGate.changesVisibleBehavior(i.files),
               VisualQualityGate.status(branch: i.branch, head: i.head,
                                        tasks: tasks) != .approved { return false }
            return true
        }
        var out: [Blocked] = []
        var landedOne = false
        for item in pending {
            func note(_ s: String) { out.append(Blocked(branch: item.branch, reason: s)) }
            guard let t = taskFor(item.taskID, in: byID, all: tasks) else {
                note("任务记录没了 —— 自动环节一律不碰，只能人工处置"); continue
            }
            guard item.mergesCleanly else {
                note("合不进去（有冲突）—— 归 StaleBranch 刷新那条路管"); continue
            }
            let isStranded = stranded.contains(item.branch)
            if !isStranded, t.state != .done {
                note("任务状态是 \(t.state)，不是 done"); continue
            }
            if let v = activeVeto(veto, branch: item.branch, head: item.head) {
                note("在否决名单里：" + String(v.prefix(60))); continue
            }
            if needsEvidenceAndReview, item.evidence.isEmpty,
               EvidenceGate.changesVisibleBehavior(item.files) {
                note("这个仓库要「看效果才合」，而这条还没交证据 —— "
                     + "已派回原平台跑一遍截图（EvidenceGate），交了图再判")
                continue
            }
            if needsVisualQuality, EvidenceGate.changesVisibleBehavior(item.files) {
                switch VisualQualityGate.status(
                    branch: item.branch, head: item.head, tasks: tasks) {
                case .approved: break
                case .missing:
                    note("质量契约要求真正看过录屏/截图 —— 尚未派多模态验收")
                    continue
                case .pending:
                    note("多模态 agent 正在逐帧对照质量契约")
                    continue
                case .rejected:
                    note("多模态质量验收判定未达标 —— 不自动合入，留给整改/人工处置")
                    continue
                }
            }
            let needsReview = requiresAgentReview(
                files: item.files, isStranded: isStranded,
                repoNeedsManualReview: needsEvidenceAndReview, risk: t.profile?.risk)
            if needsReview,
               !MergeReview.approved(branch: item.branch, files: item.files, tasks: tasks,
                                     head: item.head, headAt: item.committedAt) {
                let r = MergeReview.approvalsSoFar(branch: item.branch, tasks: tasks,
                                                   head: item.head,
                                                   headAt: item.committedAt)
                let why = isStranded ? "搁浅图"
                    : needsEvidenceAndReview ? "这个仓库要 agent 审过才合"
                    : "高危/敏感路径"
                note("要 agent 审核（\(why)）"
                     + "，现在 \(r.approvals)/\(MergeReview.requiredApprovals(files: item.files)) 票"
                     + (r.attempts == 0 ? " —— **还没派过审核**" : "")
                     + (r.rejected ? " —— 已被判不合入" : ""))
                continue
            }
            if !item.overlapsWith.isEmpty,
               !isOldestInOverlapGroup(item, among: landable) {
                note("和别的分支改了同一批文件，排队等 —— 这一组里先合最老的那条")
                continue
            }
            if landedOne {
                note("这一轮的名额（每轮只合 1 个）已经被前面那条占了")
                continue
            }
            landedOne = true
            note("**该合而没合** —— 所有闸都过了，说明落地环节根本没被执行到")
        }
        return out
    }

    /// 「仓库脏着,落地整轮让开」的**唯一判定**(autoLand / whyNotLanding /
    /// mergeUnverified 三处共用;以前各写一份 `status --porcelain`)。
    ///
    /// 只有 STATUS.md 脏 = 上一次落地自己留下的(提交撞 index.lock 没成),
    /// 先补提交掉再判 —— 不然落地被自己的脏堵死(2026-08-23 Flint 两小时)。
    /// 返回 nil = 干净可落地;非 nil = 脏(porcelain 原文),让开。
    public static func dirtBlockingLanding(repo: String) -> String? {
        func porcelain() -> String {
            GitWorkspace.git(["status", "--porcelain"], in: repo).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let first = porcelain()
        if first.isEmpty { return nil }
        if ProgressLog.healStatusOnlyDirt(repo: repo) {
            let again = porcelain()
            return again.isEmpty ? nil : again
        }
        return first
    }

    public static func autoLand(repo: String, base: String = "main",
                                tasks: [WorkTask] = TaskStore.all(),
                                maxPerCall: Int = 1) -> [AutoLandOutcome] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        // 主仓库脏着（多半是人正在里面改代码）就整轮跳过，
        // 也**不给任何分支记否决**：环境没就绪不是分支的错。
        // 真实翻车：自动落地首航撞上一次会话的未提交改动，
        // 一份完全没问题的产出被记了否决、从此不再自动重试。
        guard dirtBlockingLanding(repo: repo) == nil else {
            return []
        }

        // 登记为「必须人工终审」的仓库（游戏那两个）整个绕行：
        // 构建通过 ≠ 可以合入，手感和画面只有实跑才看得出来。
        // **`manualReview` 不再是「一律不碰」，是「门槛更高」。**
        //
        // 老板的原话（2026-08-18）：「我只看效果，代码合入让 agent review」。
        //
        // 这个标记原来的实现是整个仓库 `return []` —— 自动落地一步都不做。
        // 后果是最坏的组合：**人既要人工审，又没有图可看** ——
        // 因为补证据、agent 审核、分支刷新全被同一个守卫挡在外面，
        // 人只能自己 checkout、构建、跑模拟器才能判。
        // 那正是这套系统存在的意义的反面。
        //
        // 现在它的含义是：这个仓库的产出要合进去，**必须同时满足**
        //   ① 有人能一眼看出成败的证据（截图 / 录屏 / 实跑输出）；
        //   ② 专用评审 agent 判「合入」。
        //
        // 原注释里的理由一个字都没变、只是换了执行者：
        // 「构建通过 ≠ 可以合入 —— 手感和画面只有模拟器实跑才看得出来」。
        // 实跑还是要跑，只是跑的人从「老板」换成了「agent」，
        // 而老板要做的从「读 diff」变成「看图」。
        let wantPath = URL(fileURLWithPath: repo).standardizedFileURL.path
        let needsEvidenceAndReview = RepoRegistry.all().contains {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == wantPath
                && ($0.manualReview || !($0.qualityContract ?? "").isEmpty)
        }
        let needsVisualQuality = RepoRegistry.all().contains {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == wantPath
                && !($0.qualityContract ?? "").isEmpty
        }

        var outcomes: [AutoLandOutcome] = []
        let pending = list(repo: repo, base: base, tasks: tasks)
        // 排队只在**有资格落地**的分支之间排。一条合不进去的分支排在队首，
        // 会把它后面所有人永久挡住 —— 那不是排队，那是堵门。
        let veto = autoLandVeto()
        let strandedForQueue = Set(TaskGraph.stranded(tasks).filter {
            $0.doneCount > 0
        }.map(\.branch))
        let landable = pending.filter { i in
            guard i.mergesCleanly,
                  activeVeto(veto, branch: i.branch, head: i.head) == nil
            else { return false }
            guard let t = taskFor(i.taskID, in: byID, all: tasks) else { return false }
            if !strandedForQueue.contains(i.branch), t.state != .done { return false }
            if needsEvidenceAndReview, i.evidence.isEmpty,
               EvidenceGate.changesVisibleBehavior(i.files) { return false }
            // **系统自己的记账不用过人工终审那道高门槛。**
            //
            // manualReview 的意思是「游戏产出要合进去，得有人能看的效果
            // + agent 判合入」。可 EVAL 报告、证据日志、进度记录**一行
            // 游戏代码都不碰** —— 它们没有任何「效果」可看，而让评审 agent
            // 去评审一份评审报告本身就是循环的。
            //
            // 实测（2026-08-19）：老板批完三条真产出之后，待审列表里
            // 立刻又冒出两条 —— 一份 42 行的单元测试复跑日志、
            // 一份 30 行的 EVAL 合入报告。老板的原话（2026-08-18）：
            //「验收任务发给我的，怎么还有一堆合代码的，我只看人可阅读
            // 验证的成功，比如游戏截图、运行结果」。一份 markdown 不是那个。
            //
            // 判据复用 `changesVisibleBehavior` —— 上面那道证据闸用的
            // 就是它。**这里绝不能另写一个**：两处对「这改动人看得见吗」
            // 给出不同答案，就会出现「不用交证据、却要等 agent 审」
            // 这种半卡死状态。
            let needsReview = requiresAgentReview(
                files: i.files, isStranded: strandedForQueue.contains(i.branch),
                repoNeedsManualReview: needsEvidenceAndReview, risk: t.profile?.risk)
            if needsReview {
                guard MergeReview.approved(branch: i.branch, files: i.files,
                                           tasks: tasks,
                                           head: i.head, headAt: i.committedAt)
                else { return false }
            }
            if needsVisualQuality, EvidenceGate.changesVisibleBehavior(i.files),
               VisualQualityGate.status(branch: i.branch, head: i.head,
                                        tasks: tasks) != .approved { return false }
            return true
        }
        for item in pending {
            // 按「尝试次数」限流而不是「成功次数」：贵的是验收那一步，
            // 失败的尝试一样烧了一次全量构建。
            // 只数真落地的 —— 「没落」不占名额,否则排在前面的一条没落的
            // 分支会挡住后面所有能落的(队头阻塞第三变种,2026-08-22)。
            if outcomes.filter(\.landed).count >= maxPerCall { break }
            // 任务 done 是常规路径。**搁浅图是例外，而且必须是例外。**
            //
            // 搁浅图的任务状态是 blocked / failed（挂了一步，下游冻住），
            // 所以老守卫一律跳过 —— 结果是「已完成 4 步、19 个文件的产出」
            // 永远只能人来捞。Greed 的 f2872114 就这么躺了一整天，
            // 而人在那里做的事就是手工摘分支，正是不该推给他的那种活。
            //
            // 搁浅和「还在跑」是两回事：搁浅的图**不会再自己动了**，
            // 分支上那些产出已经定型。所以放它进来，但要求**必须过 agent 审核**
            // —— 任务状态没给出「跑完了」这个保证，就用一次显式审核补上。
            let strandedBranches = Set(TaskGraph.stranded(tasks).filter {
                $0.doneCount > 0
            }.map(\.branch))
            let isStranded = strandedBranches.contains(item.branch)
            if !isStranded {
                guard let t0 = taskFor(item.taskID, in: byID, all: tasks),
                      t0.state == .done else { continue }
                _ = t0
            }
            guard let t = taskFor(item.taskID, in: byID, all: tasks) else { continue }
            guard item.mergesCleanly else { continue }
            // **机械条件判不了的，问评审 agent，不问人。**
            //
            // 老板的原话：「代码合入审核，你让专用 agent 去判断就可以了」。
            // 原来「高危」和「碰敏感路径」这两类直接跳过自动落地、落到
            // work review 等人 —— 而人在那里要做的事恰恰是读 diff，
            // 那是他反复说过不要推给他的东西。
            //
            // 现在这两类走 MergeReview：派专用评审 agent 出结论，
            // 够票才继续往下走。够票之后**构建和测试照样跑**，
            // 放宽的只是「谁来拿主意」，不是「拿主意前查什么」。
            // 这类仓库先卡证据：没有图就别谈合入 —— 缺证据的分支
            // 由 EvidenceGate 派回去跑一遍截图，下一轮再来。
            //
            // **但纯文档 / 报告类不要求证据。** 判据复用 EvidenceGate 的
            // `changesVisibleBehavior`，不另写一套 —— 同一个概念两套实现
            // 今天已经害了四次（见 DiscardedUpstreamTests 里那条模式测试）。
            //
            // 不排掉的后果实测过：Greed 那 9 条待审里 8 条只改了一个
            // `reviews/EVAL-*.md`。给一份 Markdown 报告截图毫无意义，
            // 而卡着不放会让它们**永远合不进去** —— 要不到图，就永远不满足门槛。
            if needsEvidenceAndReview, item.evidence.isEmpty,
               EvidenceGate.changesVisibleBehavior(item.files) {
                continue
            }
            // 项目级质量契约不是一段提示词装饰：可见改动必须由真正能看图/
            // 录屏的执行器逐帧判过。代码审核票不能替代视觉质量票。
            if needsVisualQuality, EvidenceGate.changesVisibleBehavior(item.files) {
                let visual = VisualQualityGate.status(
                    branch: item.branch, head: item.head, tasks: tasks)
                if visual == .missing {
                    _ = VisualQualityGate.dispatch(item: item, repo: repo, tasks: tasks)
                }
                guard visual == .approved else { continue }
            }
            // **走统一判据，别再内联一份。**
            //
            // 这里原先是第六份手写的同款逻辑，而且用的是无条件的
            // `|| needsEvidenceAndReview`（没有文书豁免）。
            // 于是 `work why` 说「所有闸都过了」、`autoLand` 却一直
            // 挡在这道闸上 —— 两条路径对同一件事给出相反答案，
            // 系统停摆而诊断查不出原因。
            //
            // 2026-08-19 我统一了另外三处并写下「三处共用」，**漏了这一处**。
            // 教训：统一判据时要按**被调用的次数**去数，不是按记忆去数。
            let needsAgentReview = requiresAgentReview(
                files: item.files, isStranded: isStranded,
                repoNeedsManualReview: needsEvidenceAndReview,
                risk: t.profile?.risk)
            if needsAgentReview,
               !MergeReview.approved(branch: item.branch, files: item.files,
                                     tasks: tasks,
                                     head: item.head,
                                     headAt: item.committedAt) {
                continue
            }
            // **重叠不是「永远不合」，是「排队一个一个合」。**
            //
            // 老规则是 overlapsWith 非空就跳过，理由写的是「顺序该人定」。
            // 但没有任何环节会去问人，结果就是一条都不合：2026-08-17 盘点，
            // Maw 三条实质分支（修换档叠影、诊断证据、进食动画）两两都动了
            // GameScene/PlayerNode/Tuning，互相卡住躺了两天。而躺着的时候
            // 新任务还在改这些文件，重叠只会越滚越大 —— 这是个会自我加剧的死锁。
            //
            // 现在：一组重叠的分支里，只放行**最老的那条**。它合进去之后，
            // 其余分支下一轮对着新 main 重新判定 —— 要么还能干净合入（接着合），
            // 要么 mergesCleanly 变 false（这才是真冲突，该给人）。
            // 安全性没放宽：合并前照样跑全量验收，验不过就否决留人工。
            if !item.overlapsWith.isEmpty,
               !isOldestInOverlapGroup(item, among: landable) {
                continue
            }
            if activeVeto(veto, branch: item.branch, head: item.head) != nil {
                // 上次验收就没过（**且分支从那之后没动过**）。不再自动重试 ——
                // 循环每 30 秒一轮，重试一次是十几分钟全量构建，等于把
                // worker 变成了烤炉。改好重新提交后否决自动过期；
                // 人工 `work review` 合入或 discard 之后这条自然消失。
                continue
            }
            switch merge(repo: repo, branch: item.branch, base: base, tasks: tasks) {
            case .success:
                // merge 内部已记 landedAt，这里不用再记。
                outcomes.append(AutoLandOutcome(
                    branch: item.branch, landed: true,
                    note: "任务 done、无冲突、不碰敏感路径、验收通过 —— 自动合入"))
            case .failure(let e):
                // **瞬时失败(超时/被杀/建不出工作区/主仓库状态不对)不记否决。**
                // 控制流 review §6:这些以前全进 setAutoLandVeto,而 veto 只在
                // head 变化时失效 —— 一份正常产出因为一次 15 分钟构建超时、或
                // 验证期间有人切了个分支,就被永久否决,还写着「下一轮会重试」。
                // 现在看结构化标志:瞬时的只记一笔、下轮再试。
                if (e.userInfo[transientKey] as? Bool) == true {
                    outcomes.append(AutoLandOutcome(
                        branch: item.branch, landed: false,
                        note: e.localizedDescription + "（瞬时故障，没记否决，下一轮再试）"))
                    continue
                }
                // **验证没过先派人修,别急着判死。**
                //
                // 原来这里直接记否决 +「留给人工审」——而那个「人」就是老板,
                // 他要的恰恰是不用管(2026-08-22:「总不能跑一步卡一步就需要
                // 你介入」)。一条挂着的分支会把同仓库后面的活用基线闸挡住,
                // 产线看起来就停了。
                //
                // 分工按他定的:机器跑测试(退出码为准),agent 负责修到过。
                // 修不动(到次数上限)才记否决,那时候是真该人看了。
                if let fix = VerifyRepair.dispatch(
                    repo: repo, branch: item.branch,
                    failure: e.localizedDescription, tasks: tasks), fix.enqueued {
                    outcomes.append(AutoLandOutcome(
                        branch: item.branch, landed: false, note: fix.note))
                    continue
                }
                setAutoLandVeto(branch: item.branch, note: e.localizedDescription,
                                head: item.head)
                outcomes.append(AutoLandOutcome(
                    branch: item.branch, landed: false,
                    note: e.localizedDescription + "（已记否决，不再自动重试，留给人工审）"))
            }
        }
        return outcomes
    }

    /// 这条分支是不是它那组重叠分支里**最老的**。
    ///
    /// 用提交时间排序，时间相同（或缺失）用分支名兜底 —— 判据必须是全序，
    /// 否则一组里可能没有任何一条被认为是「最老」，死锁原样还在。
    ///
    /// - Parameter all: 排队的**只能是真正有资格落地的分支**。合不进去的
    ///   不能占位置 —— 否则死锁会换个形式回来：Maw 实测过一次，
    ///   一条分支刷新之后变成组里最新的，而组里另外两条合不进去、
    ///   永远不会被放行，于是刷好的那条也永远轮不到。
    ///   队列里排着一个永远不会走的人，后面的人就永远走不了。
    static func isOldestInOverlapGroup(_ item: Item, among all: [Item]) -> Bool {
        let group = all.filter { item.overlapsWith.contains($0.branch) } + [item]
        let oldest = group.min { a, b in
            let ta = a.committedAt ?? .distantFuture
            let tb = b.committedAt ?? .distantFuture
            if ta != tb { return ta < tb }
            return a.branch < b.branch
        }
        return oldest?.branch == item.branch
    }

    /// 质量契约对这次合入的硬阻断。nil 表示该层允许继续；它不替代构建验证。
    public static func qualityLandingBlock(repo: String, branch: String,
                                           base: String = "main",
                                           tasks: [WorkTask] = TaskStore.all()) -> String? {
        let want = URL(fileURLWithPath: repo).standardizedFileURL.path
        guard RepoRegistry.all().contains(where: {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == want
                && !($0.qualityContract ?? "").isEmpty
        }) else { return nil }
        let files = GitWorkspace.git(
            ["diff", "--name-only", "\(base)...\(branch)"], in: repo).stdout
            .split(separator: "\n").map(String.init)
        guard EvidenceGate.changesVisibleBehavior(files) else { return nil }
        let head = GitWorkspace.git(["rev-parse", "--short", branch], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return "质量闸无法读取分支提交，禁止合入" }
        switch VisualQualityGate.status(branch: branch, head: head, tasks: tasks) {
        case .approved: return nil
        case .missing: return "质量契约要求先逐帧验收截图/录屏；当前还没有视觉结论"
        case .pending: return "多模态 Agent 正在逐帧验收；结论出来前不能合入"
        case .rejected: return "多模态视觉验收判定未达标；已交回原 Agent 会话整改，不能合入"
        }
    }

    public static func merge(repo: String, branch: String, base: String = "main",
                             deleteBranch: Bool = true,
                             verify: Bool = true,
                             allowQualityOverride: Bool = false,
                             tasks: [WorkTask] = TaskStore.all()) -> Result<String, NSError> {
        // 合并会立刻改变待审集合 —— 缓存必须作废，否则同一轮里后面的
        // 调用点会拿着「这条还在待审」的旧清单再处理它一遍。
        defer { invalidateListCache() }
        // 所有合入入口最终都经过这里。手机、CLI --auto、新增调用点不能再各自
        // “记得”补一遍质量判断。人工强行翻案必须显式传 override；普通手机
        // “合入”没有这个权限，避免一指把机器已经看出的画面缺陷推进 main。
        if !allowQualityOverride,
           let reason = qualityLandingBlock(repo: repo, branch: branch, base: base,
                                            tasks: tasks) {
            return .failure(NSError(domain: "Review", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "没合：" + reason]))
        }
        if verify, let reg = RepoRegistry.all().first(where: {
            NSString(string: $0.localPath).expandingTildeInPath
                == NSString(string: repo).expandingTildeInPath
        }), let cmd = reg.verifyCommand, !cmd.isEmpty {
            if let why = verifyMerge(repo: repo, branch: branch, base: base,
                                     command: cmd, timeout: reg.verifyTimeout) {
                return .failure(NSError(
                    domain: "Review", code: why.transient ? 2 : 1,
                    userInfo: [NSLocalizedDescriptionKey: "没合：\(why.message)",
                               transientKey: why.transient]))
            }
        }
        let r = mergeUnverified(repo: repo, branch: branch, base: base,
                                deleteBranch: deleteBranch)
        // 图合成功之后，共享 worktree 才该被清掉。
        //
        // 这是全仓库**唯一**传 graphFinished: true 的地方 —— 在它之前，
        // cleanup 对 agent/graph/* 一律拒绝删除（那道守卫防的是「按节点清理
        // 会毁掉前面几步的提交」）。守卫加了却没人解锁的话，
        // 共享 worktree 会永远堆在磁盘上，而且下次同名图会复用一个陈旧目录。
        if case .success = r, branch.hasPrefix("agent/graph/") {
            if let path = worktreePath(repo: repo, branch: branch) {
                GitWorkspace.cleanup(repo: repo, path: path, graphFinished: true)
            }
            // 图没了，它名下的会话记录也没用了 —— 不清的话这个文件只增不减。
            GraphSession.forgetGraph(String(branch.dropFirst("agent/graph/".count)))
        }
        // 落地即记账。挂在这里而不是任务完成时：任务完成时干活的人还在自己的
        // 分支里，几个分支各写各的进度，合过来每次都冲突在同一段。
        // 合并是串行的，写在合并之后天然不打架。
        if case .success = r {
            ProgressLog.recordLanding(repo: repo, branch: branch)
            // **带录屏的成果落地了 → 记一笔，等着推给老板看。**
            //
            // 老板（2026-08-22）的原话：「这个不应该你驱动，应该是我们的
            // 数字人程序在关键成果产出需要找我确认」。manualReview 仓库
            // 由评审 agent 判合入，人从来不在链路上 —— 而他看录屏发现的
            // 问题（「跑的姿势不像真人」「手歪不拉几」）全是真的。
            // 落地后推、不卡路：卡住会让基线闸冻整仓，那是他更烦的毛病。
            let sha = GitWorkspace.git(["rev-parse", "--short", base], in: repo)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty {
                let files = GitWorkspace.git(
                    ["show", "--name-only", "--format=", sha], in: repo)
                    .stdout.split(separator: "\n").map(String.init)
                let subject = GitWorkspace.git(["log", "-1", "--format=%s", sha], in: repo)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if let m = Milestone.record(repo: repo, branch: branch, mergeSHA: sha,
                                            files: files, subject: subject) {
                    // 先让看得见的那个平台过一眼，别让老板当唯一的眼睛。
                    // 质量契约仓库在合入前已经看过，别为同一份录屏再烧一遍。
                    if !VisualQualityGate.hasApproved(
                        branch: branch, tasks: TaskStore.all()) {
                        Milestone.dispatchVisualCheck(m, repoPath: repo)
                    }
                }
            }
            // 落地即排审查：给审查员（opencode/火山）生成一条【审查】任务
            // 复查这次合并 —— 自动落地放宽了「谁按回车」，
            // 这道事后复查把省下的人审那双眼睛补回来。
            enqueuePostLandReview(repo: repo, branch: branch)
        }
        return r
    }

    /// 为一次已完成的合并生成复查任务。
    ///
    /// 这同时回答了「审查员几乎没有低危的活」：每一次落地都产一条
    /// safe 档审查任务，供给和产出自然挂钩。两个不生成的口子：
    /// - 审查产出自己落地时（否则审查→落地→审查无限递归）；
    /// - 媒体产出（图和音乐没有 diff 可读，进包前的人工查签名照旧）。
    static func enqueuePostLandReview(repo: String, branch: String) {
        let taskID = String(branch.split(separator: "/").last ?? "")
        if let t = TaskStore.all().first(where: { $0.id == taskID }) {
            if TaskKind.isReview(t.prompt) || TaskKind.isMedia(t.prompt) { return }
        }
        let sha = GitWorkspace.git(["rev-parse", "--short", "main"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty else { return }
        var t = WorkTask(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            prompt: """
            【审查】复查刚合入 main 的合并 \(sha)（来源分支 \(branch)）。
            \(PostLandRepair.contractMarker) 具体发现会自动交回原 owner 的项目会话整改。
            步骤：用 `git show \(sha)` 读完整 diff（首行提交带 -m 说明），\
            检查逻辑错误、安全隐患、与现有代码的矛盾、改了定义漏了调用点。
            产出：把结论写进 reviews/REVIEW-\(sha).md —— 每条发现 = \
            文件:行号 + 问题一句话 + 严重度(高/中/低)；没有发现问题也要写\
            「审查通过」加一段为什么可信的摘要。
            边界：只新增这一个文件，不改任何现有代码。
            """,
            repo: repo)
        t.profile = TaskProfile(
            tier: .trivial, risk: .safe, estimatedMinutes: 8,
            isSelfContained: true,
            rationale: "落地后自动生成的复查：只读 diff、只写一份报告")
        t.preferredPlatform = .volcark
        t.origin = "post-land-review"
        t.note = "落地自动排的复查 · \(branch)"
        try? TaskStore.append(t)
    }

    static func mergeUnverified(repo: String, branch: String, base: String = "main",
                                deleteBranch: Bool = true) -> Result<String, NSError> {
        let head = GitWorkspace.git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == base else {
            return .failure(ClusterCA.err("当前在 \(head) 上，不是 \(base)。先切过去再合。"))
        }
        guard dirtBlockingLanding(repo: repo) == nil else {
            // 工作区脏的时候合并会把用户没提交的改动卷进冲突里，很难收拾。
            return .failure(ClusterCA.err("工作区有未提交的改动，先处理掉再合。"))
        }

        let r = GitWorkspace.git(
            ["merge", "--no-ff", "-m", "merge \(branch)", branch], in: repo)
        guard r.exitCode == 0 else {
            // 合失败要把状态还原，不能留一个半合并的仓库给用户。
            _ = GitWorkspace.git(["merge", "--abort"], in: repo)
            return .failure(ClusterCA.err("合并失败，已还原：\(r.stderr.prefix(200))"))
        }
        guard deleteBranch else { return .success(r.stdout) }

        // 顺序错了会静默失败。
        //
        // 原来是先 `worktree prune` 再 `branch -d` —— 但 prune 只清**失效**
        // 条目，活着的 worktree 它不动。而成功任务的 worktree 一直活着
        // （成功路径从不调 cleanup），于是 branch -d 必然报
        // 「cannot delete branch used by worktree at ...」。
        //
        // 更糟的是当时没检查退出码，照样打印「已清理」。而 Review.list 会用
        // `branch --merged` 把已合并的分支过滤掉 —— 它从待审列表里消失了，
        // 看起来就像清理成功了。实测：合过的那个分支和它的 worktree
        // 到现在还都在。夜里跑上百个任务的话，这些会永久沉底且无处可见。
        //
        // pruneMerged 里本来就是对的顺序，这里对齐它。
        if let path = worktreePath(repo: repo, branch: branch) {
            _ = GitWorkspace.git(["worktree", "remove", "--force", path], in: repo)
        }
        _ = GitWorkspace.git(["worktree", "prune"], in: repo)
        markDisposition(branch: branch, landed: true)
        let del = GitWorkspace.git(["branch", "-d", branch], in: repo)
        if del.exitCode != 0 {
            // 合并本身是成功的，只是没清干净。照实说，别谎报。
            return .success(r.stdout + "\n（合并成功，但分支没删掉："
                + del.stderr.trimmingCharacters(in: .whitespacesAndNewlines) + "）")
        }
        return .success(r.stdout)
    }

    /// 把这次产出的去向写回任务记录。
    ///
    /// TaskStore 是 append-only + 后写覆盖，所以「更新」就是再 append 一条。
    static func markDisposition(branch: String, landed: Bool, reason: String? = nil) {
        let id = String(branch.split(separator: "/").last ?? "")
        guard !id.isEmpty else { return }
        let all = TaskStore.all()

        // **图分支要记给图里的每一个节点。**
        //
        // 从分支名取最后一段，对 `agent/graph/<gid>` 拿到的是 gid ——
        // 而 gid 是那个**从没入库的父任务**的 id，图里真实存在的节点叫
        // `<gid>s1`/`<gid>s2`。于是这个 guard 一直查不到任务、静默 return，
        // 图内产出的 landedAt 永远是 nil。
        //
        // 后果不只是少个时间戳：`work review` 的「产出 N 份、落地 M 份、
        // 落地率」对所有图内任务恒为 0 —— 而「跑完了但没人要，那份额度
        // 一样是浪费掉的」正是这个指标存在的全部理由。
        if branch.hasPrefix("agent/graph/") {
            let nodes = all.filter { $0.graphID == id }
            guard !nodes.isEmpty else { return }
            for var t in nodes {
                if landed { t.landedAt = Date() }
                else { t.discardedAt = Date(); t.discardReason = reason }
                try? TaskStore.append(t)
            }
            return
        }

        guard var t = all.first(where: { $0.id == id }) else { return }
        if landed { t.landedAt = Date() }
        else { t.discardedAt = Date(); t.discardReason = reason }
        try? TaskStore.append(t)
    }

    /// 丢弃一个分支和它的工作区。
    public static func discard(repo: String, branch: String, reason: String? = nil) {
        // 和 merge 同理：丢弃立刻改变待审集合。
        defer { invalidateListCache() }
        markDisposition(branch: branch, landed: false, reason: reason)
        // 先摘 worktree 再删分支：分支被 worktree 占用时 git 拒绝删除，
        // 而错误信息（"used by worktree at ..."）不看文档很难懂。
        if let path = worktreePath(repo: repo, branch: branch) {
            _ = GitWorkspace.git(["worktree", "remove", "--force", path], in: repo)
        }
        _ = GitWorkspace.git(["worktree", "prune"], in: repo)
        _ = GitWorkspace.git(["branch", "-D", branch], in: repo)
    }

    /// 清理已经合并过的分支留下的 worktree。
    ///
    /// worktree 不自动回收：8 个任务就留了 6.5MB 和 8 个目录。
    /// 跑几百个任务之后这会变成一个真问题。
    @discardableResult
    public static func pruneMerged(repo: String, base: String = "main") -> [String] {
        let out = GitWorkspace.git(
            ["branch", "--merged", base, "--list", "agent/*"], in: repo)
        let merged = out.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "*+"))) }
            .filter { !$0.isEmpty }
        var cleaned: [String] = []
        for b in merged {
            if let path = worktreePath(repo: repo, branch: b) {
                _ = GitWorkspace.git(["worktree", "remove", "--force", path], in: repo)
            }
            if GitWorkspace.git(["branch", "-d", b], in: repo).exitCode == 0 {
                cleaned.append(b)
            }
        }
        _ = GitWorkspace.git(["worktree", "prune"], in: repo)
        return cleaned
    }

    // MARK: - 底层

    static func mergeBase(repo: String, base: String, branch: String) -> String? {
        let r = GitWorkspace.git(["merge-base", base, branch], in: repo)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.exitCode == 0 && !s.isEmpty) ? s : nil
    }

    /// 会不会冲突。
    ///
    /// 用 `merge-tree` 而不是真去 merge 一次再 abort：前者完全不碰工作区，
    /// 也不需要仓库处于干净状态，列清单的时候可以放心对每个分支都跑一遍。
    static func mergesCleanly(repo: String, base: String, branch: String) -> Bool {
        let r = GitWorkspace.git(["merge-tree", "--write-tree", base, branch], in: repo)
        return r.exitCode == 0 && !r.stdout.contains("CONFLICT")
    }

    static func numstat(repo: String, from: String, to: String)
        -> (files: [String], insertions: Int, deletions: Int) {
        // **`-c core.quotePath=false`：别让 git 把非 ASCII 文件名转义。**
        //
        // 默认行为是把中文路径写成 `"reviews/EVAL-\351\241\271….md"` ——
        // 带引号、带八进制转义。于是**所有按后缀判断的地方全部失效**：
        // 这个字符串结尾是 `"` 而不是 `.md`。
        //
        // 实测代价（2026-08-18）：Greed 有 8 条只改了一个中文名的
        // `reviews/EVAL-项目-*.md` 的分支，被 `changesVisibleBehavior`
        // 判成「改了看得见的东西」，于是卡在证据门槛后面 —— 而给一份
        // Markdown 报告截图毫无意义，图永远交不上来，它们就永远合不进去。
        //
        // 在**产生文件名的这一处**修，不在每个消费者那里补解引号 ——
        // 后者是同一个概念多处实现，今天已经害过四次了。
        let r = GitWorkspace.git(
            ["diff", "--numstat", from, to], in: repo)   // quotePath 已在 hardening 里统一关掉
        var files: [String] = []
        var ins = 0, del = 0
        for line in r.stdout.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            // 二进制文件那两列是 "-"，别当成 0 以外的东西
            ins += Int(f[0]) ?? 0
            del += Int(f[1]) ?? 0
            files.append(String(f[2]))
        }
        return (files, ins, del)
    }

    static func activeWorktreeBranches(repo: String) -> [String] {
        GitWorkspace.git(["worktree", "list", "--porcelain"], in: repo).stdout
            .split(separator: "\n")
            .compactMap { line in
                guard line.hasPrefix("branch refs/heads/") else { return nil }
                return String(line.dropFirst("branch refs/heads/".count))
            }
    }

    public static func worktreePath(repo: String, branch: String) -> String? {
        let lines = GitWorkspace.git(["worktree", "list", "--porcelain"], in: repo)
            .stdout.split(separator: "\n").map(String.init)
        var current: String?
        for line in lines {
            if line.hasPrefix("worktree ") {
                current = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return current
            }
        }
        return nil
    }
}

// MARK: - 发给手机

extension Review {
    /// 待审产出的手机端视图。
    ///
    /// **为什么必须有这个**：系统推了一条「10 份产出等你验收」，而 App 里
    /// 根本没有对应的页面 —— 老板的原话是「显示有 94 个消息但是我也看不到」。
    /// 一个数字指向不存在的地方，比不显示更糟。
    public struct Digest: Codable, Sendable, Identifiable {
        public var id: String { repo + "|" + branch }
        public var repo: String
        public var repoName: String
        public var branch: String
        public var platform: String
        public var subject: String
        public var prompt: String?
        public var files: [String]
        public var insertions: Int
        public var deletions: Int
        public var mergesCleanly: Bool
        public var overlapsWith: [String]
        public var committedAt: Date?
        /// agent 交的证据截图（相对仓库根的路径）。
        public var evidence: [String]
        /// 已经抽出来放进共享目录的图（文件名，在 `evidence/<id 去斜杠>/` 下）。
        public var evidenceFiles: [String] = []
        /// 非空时服务端不提供普通“合入”动作，并直接把原因展示给人。
        public var landingBlockReason: String? = nil
    }

    /// 手机上的验收结论。写进 `shared/verdicts/<repo>|<branch>.json`，
    /// Mac 端下一轮读到就执行 —— 和批准项目走 approvals/ 是同一套路子。
    public struct Verdict: Codable, Sendable {
        public var repo: String
        public var branch: String
        /// merge / discard
        public var action: String
        public var reason: String?
        public var decidedAt: Date
    }

    /// 证据截图放这儿（手机端按 digest.id 找）。
    public static var evidenceDir: URL {
        Paths.sharedRoot.appendingPathComponent("evidence", isDirectory: true)
    }

    /// 把分支里的证据截图抽出来、压小、放进共享目录。
    ///
    /// **只给文件名的验收是走过场。** 老板的原话：「验收只有文字看不到图片，
    /// 那还不如别让我验收」。他说得对 —— agent 交的是实跑截图
    ///（Greed 那四张是真的游戏界面），而手机上只显示一行 `docs/evidence/…`，
    /// 人根本没法判断这活干得怎么样。
    ///
    /// 压到宽 800：原图一张 4.7MB，四张就 19MB，走 iCloud 同步会把
    /// 整个镜像拖垮 —— 而验收只需要看清画面，不需要原分辨率。
    ///
    /// - Returns: 抽出来的文件名（相对 evidence/<id>/）。
    @discardableResult
    /// 这个文件名是不是录屏。
    ///
    /// **只准有这一处判定** —— 抽取、去重、手机端渲染都得给同一个答案，
    /// 分叉的话会出现「抽出来了但手机不认」这种静默失败。
    public static func isVideoName(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.hasSuffix(".mp4") || l.hasSuffix(".mov") || l.hasSuffix(".m4v")
    }

    /// 手机验收用统一的轻量容器名。原始录屏仍留在成果分支里，iCloud 只传
    /// 适合移动端的审阅副本；否则一段 58 秒录屏可达 27MB，首次打开 2.5 秒
    /// 下不完，客户端看起来就像“永远加载不出来”。
    static func mobileVideoName(prefix: String, sourceName: String) -> String {
        prefix + (sourceName as NSString).deletingPathExtension + ".m4v"
    }

    static func extractEvidence(repo: String, branch: String,
                                files: [String], digestID: String,
                                limit: Int = 4) -> [String] {
        // **平铺，不建子目录。** 镜像的目录推送只看平铺文件
        //（regularFiles 不递归），放进子目录的话一张都推不过去 ——
        // 实测抽出来 18 张，iCloud 里一张都没有。
        // 文件名带上分支标识，用 `__` 隔开。
        let safe = digestID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "|", with: "-")
        let dir = evidenceDir
        let fm = FileManager.default
        let prefix = safe + "__"
        if let have = try? fm.contentsOfDirectory(atPath: dir.path) {
            let mine = have.filter {
                $0.hasPrefix(prefix) && (isVideoName($0) || $0.hasSuffix(".jpg"))
            }
            // 已经抽过就不重复干 —— 这个函数挂在 5 分钟一次的发布里。
            if !mine.isEmpty { return mine.sorted() }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var out: [String] = []
        for f in files.prefix(limit) {
            let base = (f as NSString).lastPathComponent
            // **录屏转成手机审阅副本，不把原片塞进 iCloud。**
            //
            // 老板要的是「模拟器跑通的视频」，而这条管线原先端到端只认图片：
            // 这里 sips 转 jpeg，手机那边 evidenceCache 是 [String: UIImage]。
            // mp4 进来 sips 直接失败，一帧都到不了手机。
            //
            // 有些东西静态图证明不了：存档扛不扛得住强杀，要看
            //「玩到某个状态 → 强杀 → 重开数字还对得上」这一整串动作。
            if isVideoName(base) {
                let raw = dir.appendingPathComponent("." + prefix + base)
                let esc = { (x: String) in
                    "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }
                let cmd = "git show " + esc(branch + ":" + f) + " > " + esc(raw.path)
                let r = Proc.run("/bin/sh", ["-c", cmd], cwd: repo, env: [:], timeout: 60)
                guard r.exitCode == 0,
                      (try? raw.checkResourceIsReachable()) == true else {
                    try? fm.removeItem(at: raw); continue
                }

                let mobile = mobileVideoName(prefix: prefix, sourceName: base)
                let dest = dir.appendingPathComponent(mobile)
                let conv = Proc.run("/usr/bin/avconvert", [
                    "--source", raw.path,
                    "--preset", "PresetAppleM4VWiFi",
                    "--output", dest.path,
                    "--replace", "--disableMetadataFilter"],
                    cwd: nil, env: [:], timeout: 120)
                if conv.exitCode == 0,
                   (try? dest.checkResourceIsReachable()) == true {
                    try? fm.removeItem(at: raw)
                    out.append(mobile)
                } else {
                    // 格式不受 avconvert 支持时仍保留原片，不能把证据静默吃掉。
                    try? fm.removeItem(at: dest)
                    let fallback = dir.appendingPathComponent(prefix + base)
                    try? fm.removeItem(at: fallback)
                    do {
                        try fm.moveItem(at: raw, to: fallback)
                        out.append(prefix + base)
                    } catch {
                        try? fm.removeItem(at: raw)
                    }
                }
                continue
            }
            let jpg = prefix + ((base as NSString).deletingPathExtension) + ".jpg"
            let raw = dir.appendingPathComponent("." + prefix + base)
            let esc = { (x: String) in
                "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            // git show 的输出是二进制，走 shell 重定向 —— 不让字节过 String。
            let cmd = "git show " + esc(branch + ":" + f) + " > " + esc(raw.path)
            let r = Proc.run("/bin/sh", ["-c", cmd], cwd: repo, env: [:], timeout: 30)
            guard r.exitCode == 0,
                  (try? raw.checkResourceIsReachable()) == true else {
                try? fm.removeItem(at: raw); continue
            }
            // sips 转 jpg + 缩宽。失败就退回原图（大是大，总比没有强）。
            let dest = dir.appendingPathComponent(jpg)
            let conv = Proc.run("/usr/bin/sips", [
                "-s", "format", "jpeg", "-s", "formatOptions", "70",
                "-Z", "800", raw.path, "--out", dest.path],
                cwd: nil, env: [:], timeout: 30)
            try? fm.removeItem(at: raw)
            if conv.exitCode == 0 { out.append(jpg) }
        }
        return out.sorted()
    }

    /// **这条分支要不要过 agent 审核 —— 只准有这一个实现。**
    ///
    /// 这个判断原先在三个地方各写一份（落地过滤、诊断输出、排队过滤）。
    /// 2026-08-19 我只改了其中一处「纯文书不用审」，另外两处没动 ——
    /// 于是 `llmq work why` 照旧说「要 agent 审核……还没派过审核」，
    /// 而落地那条路已经放行了。**系统自己的诊断把我的不彻底暴露了。**
    ///
    /// 四个理由任一成立就要审：
    /// - 搁浅图捞回来的（没人知道它当初为什么停）
    /// - 仓库登记了人工终审 **且这条真碰了人看得见的东西**
    ///   （EVAL 报告、证据日志这类系统记账不算 —— 让评审 agent
    ///   去评审一份评审报告是循环的，还要人在中间点一下）
    /// - 任务被判成敏感档
    /// - 碰了高危路径（构建 / CI / 签名）
    static func requiresAgentReview(
        files: [String], isStranded: Bool,
        repoNeedsManualReview: Bool, risk: TaskProfile.Risk?) -> Bool {
        isStranded
            || (repoNeedsManualReview && EvidenceGate.changesVisibleBehavior(files))
            || risk == .sensitive
            || GitWorkspace.mentionsRiskyPath(files.joined(separator: " "))
    }

    /// 本机那一份待审清单写在哪。
    ///
    /// **路径里带机器 ID 是这个设计的全部要点**：两台机器永远不会
    /// 写同一个文件，也就永远不可能盖掉对方 —— 不需要合并、不需要锁、
    /// 不需要守卫。合并交给读的一方（手机端把各机器的合起来）。
    ///
    /// 布局照抄 `snapshots/<machineID>.json`，MirrorService 的
    /// `perMachineDirs` 已经有这套搬运逻辑。
    public static func machineDigestURL(machineID: String = Paths.machineID()) -> URL {
        Paths.sharedRoot
            .appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent(machineID + ".json")
    }

    /// **这一份值不值得写出去。**
    ///
    /// 自己算不出内容、也没有别人的内容要保留时，写出去的就是个空数组，
    /// 而这份文件是多机整份推到 iCloud 同一路径的 —— 空写只可能盖掉
    /// 别人刚推上去的东西，不可能带来任何信息。
    ///
    /// 抽成函数是因为它原先内联在 `publishDigests` 里，
    /// 而那个函数要跑 git、要读仓库注册表，没法单测 ——
    /// 于是这条唯一能挡住「手机页面变空」的规则会一行覆盖都没有。
    public static func worthWriting(merged: [Digest], previous: [Digest]) -> Bool {
        !(merged.isEmpty && previous.isEmpty)
    }

    /// **「这个仓库还有几条要人验收」——只准有这一个判据。**
    ///
    /// 曾经有两处各判各的：`Brief` 用 `list().count`（不扣已表态的），
    /// `publishDigests` 扣掉 `decided` 的。于是同一时刻，
    /// 手机通知说「6 条待审」、点进去的页面只有 3 条 ——
    /// 人会觉得这个数字是编的。
    ///
    /// 已经表过态的必须扣掉：人做过决定了，列表里还挂着
    /// 只会让他以为自己点了没用。
    public static func pendingForHuman(repo: String, base: String = "main",
                                       tasks: [WorkTask] = TaskStore.all(),
                                       decided: Set<String>? = nil) -> [Item] {
        let d = decided ?? decidedBranches()
        return list(repo: repo, base: base, tasks: tasks)
            .filter { !isDecided(repo: repo, branch: $0.branch, in: d) }
            // **人的队列里只放「有东西可看」的。**
            //
            // 老板 2026-08-22:「minimax 咋都让人审批,不是说没有图片或者
            // 视频的申请不要找我批」。他在这条链上的角色是**看效果**——
            // 没有图、没有录屏,就没有他能判的东西,那是 agent 审核的活。
            //
            // 实测:四条只含 `reviews/EVAL-*.md`(评审自己写的报告)的分支
            // 排在他的待批队列里,还各自被另一个评审 agent 判了不合入。
            // 纯文书/纯代码的产出照旧走 agent 审核那条路,只是不打扰人。
            .filter { $0.evidence.contains(where: EvidenceGate.isEvidenceFile) }
    }

    /// 读回**已经发布给手机的**那份待审清单。
    ///
    /// 存在的理由：推送和手机页面必须读同一份数据。各算各的话，
    /// 在多机环境下必然对不上 —— 每台机器看得见的仓库不一样。
    /// 实测就是这么产生「弹了消息、点进去是空的」。
    /// 带证据(录屏/截图)却被评审判「不合入」的分支 —— 这些要让人知道。
    ///
    /// 只挑带证据的:那是「做出来了、能看效果」的产出,被毙掉是大事。
    /// 纯文书被否不打扰人(见 Milestone 的同款判据)。
    public static func rejectedWithEvidence(
        repos: [RepoAlias] = RepoRegistry.all(),
        tasks: [WorkTask] = TaskStore.all()) -> [Digest] {
        var out: [Digest] = []
        for repo in repos {
            let path = NSString(string: repo.localPath).expandingTildeInPath
            for item in list(repo: path) {
                guard item.evidence.contains(where: EvidenceGate.isEvidenceFile) else { continue }
                let done = MergeReview.approvalsSoFar(
                    branch: item.branch, tasks: tasks,
                    head: item.head, headAt: item.committedAt)
                guard done.rejected else { continue }
                out.append(Digest(
                    repo: path, repoName: repo.alias, branch: item.branch,
                    platform: item.platform ?? "", subject: item.subject,
                    prompt: nil, files: item.files, insertions: 0, deletions: 0,
                    mergesCleanly: true, overlapsWith: [], committedAt: item.committedAt,
                    evidence: item.evidence))
            }
        }
        return out
    }

    public static func publishedDigests() -> [Digest] {
        let f = Paths.sharedRoot.appendingPathComponent("reviews.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: f))
            .flatMap { try? dec.decode([Digest].self, from: $0) } ?? []
    }

    /// 把所有仓库的待审产出写给手机。
    @discardableResult
    public static func publishDigests(repos: [RepoAlias] = RepoRegistry.all()) -> [Digest] {
        var out: [Digest] = []
        // 已经表过态的不再发给手机 —— 人做过决定了，列表里还挂着只会
        // 让他以为自己点了没用。执行失败的走 verdicts-failed 单独暴露。
        let decided = decidedBranches()
        for r in repos {
            let path = NSString(string: r.localPath).expandingTildeInPath
            guard GitWorkspace.isRepo(path) else { continue }
            for item in pendingForHuman(repo: path, decided: decided) {
                out.append(Digest(
                    repo: path, repoName: r.alias, branch: item.branch,
                    platform: item.platform, subject: item.subject,
                    prompt: item.prompt, files: item.files,
                    insertions: item.insertions, deletions: item.deletions,
                    mergesCleanly: item.mergesCleanly,
                    overlapsWith: item.overlapsWith,
                    committedAt: item.committedAt,
                    evidence: item.evidence,
                    // 图真抽出来放到共享目录，不然手机上只有一行文件名。
                    evidenceFiles: extractEvidence(
                        repo: path, branch: item.branch, files: item.evidence,
                        digestID: path + "|" + item.branch),
                    landingBlockReason: qualityLandingBlock(
                        repo: path, branch: item.branch)))
            }
        }
        // **按仓库合并，绝不整份覆盖。**
        //
        // 这份文件是发给手机的待审清单，而**每台机器看得见的仓库不一样**：
        // 上面那句 `guard isRepo(path) else { continue }` 会把本机没有的
        // 仓库直接跳过 —— 然后整份写出去，把别的机器发的内容一起抹掉。
        //
        // 实测（2026-08-18，老板的原话「移动端老是弹出一个消息，
        // 但是点进去看里面又没有」）：MacBook 上**根本没有 Greed 和 Maw
        // 这两个目录**，但它跑着同一个工作循环，于是每轮算出「0 条待审」
        // 并把 Mac mini 发的 10 条覆盖成空。
        // 推送是 Mac mini 发的（它看得见），页面是 MacBook 清空的
        // （它看不见）—— 于是「弹了消息，点进去是空的」。
        //
        // 所以：只替换**本机看得见的那些仓库**的条目，
        // 别的仓库的条目原样留着，等那台机器自己来更新。
        let seen = Set(repos.compactMap { r -> String? in
            let p = NSString(string: r.localPath).expandingTildeInPath
            return GitWorkspace.isRepo(p) ? p : nil
        })
        let existingURL = Paths.sharedRoot.appendingPathComponent("reviews.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let previous = (try? Data(contentsOf: existingURL))
            .flatMap { try? dec.decode([Digest].self, from: $0) } ?? []
        // 本机看不见的仓库：保留上一份里的条目
        let kept = previous.filter { !seen.contains($0.repo) }
        let merged = kept + out

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(
            at: Paths.sharedRoot, withIntermediateDirectories: true)
        // **自己没内容、也没有别人的内容要保留时，一个字都别写。**
        //
        // 这份文件是「只推不拉」的：每台机器整份推到 iCloud 同一个路径，
        // 后推的盖掉先推的。而 `previous` 读的是**本机自己的**暂存文件 ——
        // MacBook 那份里从来就没有 Mac mini 的条目，所以上面那段
        // 「保留我看不见的仓库」无事可保，它推上去的就是个空数组。
        //
        // 实测（2026-08-19，老板的原话「弹消息有两份待验收，但是点击去
        // 验收的页面又没有，过了好几分钟才加载出来」）：
        // Mac mini 算出 3 条推上去并发推送 → MacBook（**根本没有 Greed
        // 和 Maw 这两个目录**）算出 0 条把它盖成 `[]` → 人点进去是空的
        // → 下一轮 Mac mini 又写回 3 条，就成了「过几分钟才加载出来」。
        //
        // 空写只可能造成破坏，不可能带来信息。所以：什么都没有就不写。
        // （真要清空最后一条时 `previous` 非空，照常写得下去。）
        // **每台机器写自己那一份 —— 这才是根治。**
        //
        // `reviews.json` 是「只推不拉」的单文件：两台机器整份推到 iCloud
        // 同一路径，后推的盖先推的。守卫（worthWriting）只挡得住
        // 「一边空一边有」，挡不住两台都有内容时的互相覆盖 ——
        // 那时候先推的那台的条目照样会消失。
        //
        // 每机一份就没有这个问题：**这个文件本机独占**，写空也只是
        // 如实说「我这儿没有」，伤不到别人的条目。合并交给读的一方。
        // 布局照抄 `snapshots/<machineID>.json`，MirrorService 的
        // perMachineDirs 已经有这套搬运逻辑。
        let mine = machineDigestURL()
        try? FileManager.default.createDirectory(
            at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(out) { try? d.write(to: mine) }

        // 旧路径继续写：手机上还没更新的版本读的是它。
        // 等两端都升上去之后这一段可以删。
        guard worthWriting(merged: merged, previous: previous) else { return out }
        if let d = try? enc.encode(merged) {
            try? d.write(to: existingURL)
        }
        return out
    }

    static var verdictsDir: URL {
        Paths.sharedRoot.appendingPathComponent("verdicts", isDirectory: true)
    }

    /// 执行失败的结论记在这儿。**失败必须留痕** ——
    /// 悄悄失败的后果是那份产出永远卡在待审里，人被反复提醒却做不了任何事。
    static var failedDir: URL {
        Paths.sharedRoot.appendingPathComponent("verdicts-failed", isDirectory: true)
    }

    /// 已经表过态、正在等执行（或者执行失败）的分支。
    ///
    /// 待验收的计数必须扣掉这些 —— 人已经做过决定了，再提醒他一次
    /// 只会让他觉得这个数字是假的。
    /// 手机上**已经办成**的处置 —— 这些不再出现在待处理列表里。
    ///
    /// ## 「表过态」不等于「办成了」
    ///
    /// 原来这里读的是**结论文件存不存在**:只要人在手机上点过一下,
    /// 这条产出就从列表里永久消失。可点击只是意图,执行是另一回事 ——
    /// 合并可能因为冲突、因为评审判不合入而失败。
    ///
    /// 实锤(2026-08-22 早):老板点进推送,页面空的。查下来 Flint 的两条
    /// 分支(Bot AI、枪声)都在「已表态」名单里,可它们既没合进去、
    /// 也不在他眼前 —— 决定记下了、活没干成、条目消失了。**黑洞。**
    /// 而推送还在数它们,于是「弹了消息点进去没有」。
    ///
    /// 现在只认 `.done` 台账:执行成功、或者重试到上限彻底放弃,才算办完。
    /// 正在重试的留在列表里 —— 人有权看见「我点了合入但一直没合上」。
    /// 记「这条产出人已经处置完了」—— 待验收列表靠这个台账隐藏它。
    ///
    /// 原来只有 verdicts 那条路(原生「等你验收」)会写 .done;下发页面
    /// (views/review)走的是 actions 通道 → runInvocation → merge/discard,
    /// **办成了也不记** → 卡片不消失、人再点一次 → 分支已没 → 失败 3 次
    /// 静默放弃(本地 actions/.failures.json 里 9 条全是这样)。
    /// 两条路同一个台账,人点了哪条都生效。
    public static func markDecided(repo: String, branch: String) {
        let f = verdictsDir.appendingPathComponent(".done")
        try? FileManager.default.createDirectory(at: verdictsDir, withIntermediateDirectories: true)
        var lines = Set((try? String(contentsOf: f, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
        lines.insert(repo + "|" + branch)
        try? lines.sorted().joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    }

    /// `.done` 里两种键并存:`repo|branch`(markDecided 写)和 `repo|branch|action`
    /// (ingestVerdicts / giveUp 写)。原来只按两段键匹配,三段键的「已办」在这里看不见:
    /// 合入重试满 3 次 giveUp 之后分支照样再发给手机,人重点一次又被同一个三段键拦下,
    /// 什么都不会发生(契约评审 2026-08-23)。两种键都认。
    public static func isDecided(repo: String, branch: String, in done: Set<String>) -> Bool {
        let two = repo + "|" + branch
        if done.contains(two) { return true }
        return done.contains { $0.hasPrefix(two + "|") }
    }

    public static func decidedBranches() -> Set<String> {
        let doneFile = verdictsDir.appendingPathComponent(".done")
        return Set((try? String(contentsOf: doneFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
    }

    /// 收手机上的验收结论并执行。
    ///
    /// 和 approvals 一样**不删文件**：verdicts 是双向同步的，本地删掉
    /// 下一轮就被云端拉回来。改成执行过的记进 `verdicts/.done`，
    /// 靠它幂等。
    @discardableResult
    public static func ingestVerdicts() -> [(Verdict, Bool)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: verdictsDir.path)
        else { return [] }
        let doneFile = verdictsDir.appendingPathComponent(".done")
        var done = Set((try? String(contentsOf: doneFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var applied: [(Verdict, Bool)] = []

        // `.attempts.json` / `.done` 这类自己的账本文件也在这个目录,别当 verdict 解。
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let v = SafeDecode.json(
                at: verdictsDir.appendingPathComponent(name), as: Verdict.self)
            else { continue }
            let key = v.repo + "|" + v.branch + "|" + v.action
            guard !done.contains(key) else { continue }
            // **这台机器没有这个仓库就别碰这条结论。**
            //
            // 契约评审实锤(2026-08-23):verdicts/ 双向同步,两台机器都跑 ingest。
            // 下面「分支不存在 = 早办完了」的捷径用 branchExists 判,而 git 在
            // 没有该仓库的机器上同样返回 false → 这台先把它记进 .done,同步过去,
            // 真有仓库的那台被 .done 拦住永远跳过 —— 手机上条目正常消失、无报错,
            // 代码从未合入。discard 更直接:不查就执行、记办结。
            // 没仓库的机器:既不执行、也不记,留给有仓库的那台。
            guard GitWorkspace.isRepo(v.repo) else { continue }

            var ok = false
            var failure = ""
            // **分支已经不存在 = 这件事早就办完了，不是失败。**
            //
            // 合并成功之后分支会被删掉（merge 的 deleteBranch 默认为真）。
            // 所以一条已经执行过的结论，下次再看到时分支必然不在 ——
            // 而 `merge` 对着不存在的分支只会返回失败，于是这条结论
            // 永远留在待办里重试。
            //
            // 实测（2026-08-18）：30 条手机结论里 **24 条的分支已经不存在**，
            // 它们每一轮都被重试一次、每次都失败，把「下发视图」和「提醒」
            // 两个环节挤到超时。人在手机上看到的是这些产出一直没被处理，
            // 而实际上它们早就合进去了。
            if v.action == "merge",
               !GitWorkspace.branchExists(v.branch, in: v.repo) {
                done.insert(key)
                bumpAttempts(key, to: 0)
                applied.append((v, true))
                continue
            }
            if v.action == "merge" {
                switch merge(repo: v.repo, branch: v.branch) {
                case .success: ok = true
                case .failure(let e): failure = e.localizedDescription
                }
            } else {
                discard(repo: v.repo, branch: v.branch,
                        reason: v.reason ?? "手机上丢弃")
                ok = true
            }

            // **只有成功才记进 .done。**
            //
            // 原来是「尝试过就记」，于是合并失败（比如两边都加了同名文件
            // 起冲突）之后：那份产出永远留在待审列表里，推送每天喊人去验收，
            // 人点开却什么也做不了 —— 因为他明明已经点过合入了。
            // 实测卡了 16 小时，老板的原话是「老是弹出评审消息但是没有
            // 真正未评审的消息」。
            //
            // 失败的留着不记，下一轮会重试（冲突这类问题可能被别的合并
            // 顺手解决）。但重试也不能无限：写一份失败记录，让人看得见。
            if ok {
                done.insert(key)
                bumpAttempts(key, to: 0)
            } else {
                // **重试要有上限，而且必须真的生效。**
                //
                // 这段原来的注释写着「重试也不能无限：写一份失败记录，
                // 让人看得见」—— 但它只写了记录，**从来没设上限**。
                //
                // 实测代价（2026-08-18，老板的原话「已经到构建 38 了」）：
                // 20 条手机上点过合入的分支全都合不上（和 main 有冲突），
                // 于是每一轮循环重试 20 次合并，每次都可能跑构建验收。
                // 连带把「下发视图」（60 秒预算）和「提醒」（20 秒预算）
                // 挤到每轮超时 —— 整个循环被这件事拖垮。
                //
                // 一个因为真冲突而失败的合并，重试一次和重试三百次
                // 得到的信息一样多。所以：试满就收口，把最后一次的原因留下。
                let n = bumpAttempts(key, to: nil)
                let note = failedDir.appendingPathComponent(
                    (v.repo + "-" + v.branch).replacingOccurrences(of: "/", with: "_")
                    + ".txt")
                try? FileManager.default.createDirectory(
                    at: failedDir, withIntermediateDirectories: true)
                let giveUp = n >= maxVerdictAttempts
                try? (v.action + " 失败（第 \(n)/\(maxVerdictAttempts) 次）："
                      + failure
                      + (giveUp ? "\n试满了，不再自动重试。修掉原因之后在手机上重点一次。"
                                : "")
                      + "\n").write(to: note, atomically: true, encoding: .utf8)
                if giveUp { done.insert(key) }
            }
            applied.append((v, ok))
        }
        // **写之前先重读合并，绝不能整个覆盖。**
        //
        // 这个文件在 iCloud 上，而**两台机器都在跑同一个工作循环**
        //（mac-mini 和 macbook-pro-intel，实测两边都有 llmq work loop 进程）。
        // 原来的写法是 `done.joined().write(...)` —— 整份覆盖、最后写的赢。
        // 于是 A 机刚收口的条目，被 B 机用它自己那份旧集合整个盖掉，
        // 下一轮又活过来。
        //
        // 这是那场失控的**真正根因**：不是「失败不收口」那么简单，
        // 是「收口了也会被另一台机器抹掉」。实测同一批分支反复重试了
        // 几百次，人工止血也一次次失效 —— 因为止血写进去的东西被覆盖了。
        //
        // 共享文件 + 多写者 = 只能合并，不能覆盖。
        var merged = Set((try? String(contentsOf: doneFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
        merged.formUnion(done)
        // 只留最近 500 条，和别处一个道理：这是防重复执行的账，不是审计日志。
        let keep = merged.sorted().suffix(500)
        try? keep.joined(separator: "\n").write(to: doneFile,
                                                atomically: true, encoding: .utf8)
        return applied
    }
}

extension Review {
    /// 一条手机结论最多试几次。
    ///
    /// 3 次：够扛住「冲突被别的合并顺手解决了」这种真能自愈的情况，
    /// 又不至于让一堆合不上的分支把循环拖垮。
    static let maxVerdictAttempts = 3

    static var verdictAttemptsFile: URL {
        verdictsDir.appendingPathComponent(".attempts.json")
    }

    /// 记一次尝试，返回累计次数。`to: 0` 表示清零（成功之后）。
    @discardableResult
    static func bumpAttempts(_ key: String, to reset: Int?) -> Int {
        var m = (try? JSONDecoder().decode(
            [String: Int].self, from: Data(contentsOf: verdictAttemptsFile))) ?? [:]
        let n: Int
        if let reset { n = reset; m[key] = nil }
        else { n = (m[key] ?? 0) + 1; m[key] = n }
        if m.count > 200 {
            m = Dictionary(uniqueKeysWithValues:
                m.sorted { $0.key < $1.key }.suffix(200).map { ($0.key, $0.value) })
        }
        if let d = try? JSONEncoder().encode(m) {
            try? ICloudSafe.write(d, to: verdictAttemptsFile)
        }
        return n
    }

    /// 距离上次发布够久了吗。
    ///
    /// 发布一次要对每个仓库的每个待审分支跑 git —— 挂在 30 秒的循环里
    /// 每轮都超时。而待审集合变化很慢（一个任务跑几分钟），
    /// 5 分钟一次的新鲜度绰绰有余。
    public static func shouldRepublish(every: TimeInterval = 300,
                                       now: Date = Date()) -> Bool {
        let stamp = Paths.sharedRoot.appendingPathComponent("reviews.json")
        guard let mod = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return true }
        return now.timeIntervalSince(mod) >= every
    }
}
