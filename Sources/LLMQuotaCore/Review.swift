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

        public var netLines: Int { insertions - deletions }
    }

    /// 列出所有待审分支。
    ///
    /// - Parameter base: 合并目标，通常是 main。
    public static func list(repo: String, base: String = "main",
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
        let unfinishedGraphs: Set<String> = Set(
            tasks.filter {
                $0.graphID != nil && ($0.state == .queued || $0.state == .running
                                      || $0.state == .blocked)
            }.compactMap { $0.graphID })

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
                ["log", "-1", "--format=%s%n%cI", b], in: repo).stdout
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            items.append(Item(
                branch: b, taskID: taskID, platform: platform,
                files: stat.files, insertions: stat.insertions, deletions: stat.deletions,
                subject: log.first ?? "",
                committedAt: log.count > 1 ? ISO8601DateFormatter().date(from: log[1]) : nil,
                mergesCleanly: mergesCleanly(repo: repo, base: base, branch: b),
                overlapsWith: [],
                prompt: byID[taskID]?.prompt,
                hasWorktree: worktrees.contains(b)))
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
    public static func verifyMerge(repo: String, branch: String, base: String,
                                   command: String, timeout: Int = 900) -> String? {
        let tmp = NSTemporaryDirectory() + "llmq-verify-\(UUID().uuidString.prefix(8))"
        defer {
            _ = GitWorkspace.git(["worktree", "remove", "--force", tmp], in: repo)
            _ = GitWorkspace.git(["worktree", "prune"], in: repo)
        }
        let add = GitWorkspace.git(["worktree", "add", "--detach", tmp, base], in: repo)
        guard add.exitCode == 0 else {
            return "建临时工作区失败：\(add.stderr.prefix(160))"
        }
        let m = GitWorkspace.git(
            ["merge", "--no-ff", "-m", "verify \(branch)", branch], in: tmp)
        guard m.exitCode == 0 else {
            return "合并结果有冲突：\(m.stdout.prefix(160))"
        }
        let r = Proc.run("/bin/sh", ["-c", command], cwd: tmp, env: [:],
                         timeout: TimeInterval(timeout))
        guard r.exitCode == 0 else {
            let out = (r.stderr + "\n" + r.stdout)
                .split(separator: "\n")
                .filter { $0.lowercased().contains("error") || $0.contains("failed") }
                .prefix(3).joined(separator: "；")
            return "验证没过（退出码 \(r.exitCode)）"
                + (out.isEmpty ? "" : "：\(out.prefix(240))")
        }
        return nil
    }

    /// 合并一个分支。
    ///
    /// - Parameter verify: 仓库配了验证命令时，先在临时工作区里验一遍合并结果。
    ///   **默认开着**：一个不验证就落地的合并，等于把 agent 的产出直接
    ///   推进主干，而这套系统的产出是无人值守生成的。
    public static func merge(repo: String, branch: String, base: String = "main",
                             deleteBranch: Bool = true,
                             verify: Bool = true) -> Result<String, NSError> {
        if verify, let reg = RepoRegistry.all().first(where: {
            NSString(string: $0.localPath).expandingTildeInPath
                == NSString(string: repo).expandingTildeInPath
        }), let cmd = reg.verifyCommand, !cmd.isEmpty {
            if let why = verifyMerge(repo: repo, branch: branch, base: base,
                                     command: cmd, timeout: reg.verifyTimeout) {
                return .failure(ClusterCA.err("没合：\(why)"))
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
        }
        return r
    }

    static func mergeUnverified(repo: String, branch: String, base: String = "main",
                                deleteBranch: Bool = true) -> Result<String, NSError> {
        let head = GitWorkspace.git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == base else {
            return .failure(ClusterCA.err("当前在 \(head) 上，不是 \(base)。先切过去再合。"))
        }
        let dirty = GitWorkspace.git(["status", "--porcelain"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dirty.isEmpty else {
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
        let r = GitWorkspace.git(["diff", "--numstat", from, to], in: repo)
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
