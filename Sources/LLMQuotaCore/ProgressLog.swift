import Foundation

/// 把「项目进度」写进仓库，让下一个 agent 不用从 diff 里反推。
///
/// ## 为什么 git 历史不够
///
/// git 记的是**改了什么**，不是**进度到哪了**。`git log` 能告诉你昨天动过
/// `ClusterNet.swift`，但推不出「跨机 mTLS 已经能用」还是「还差一半」——
/// 要从 diff 反推进度，读的人得把每条改动看一遍，而那正是我们想省掉的成本。
///
/// ## 为什么不能只靠「要求 agent 更新」
///
/// 忘了没有任何后果，下一个 agent 也不知道它忘了。约定不是机制。
/// 这个项目的任务列表就是活证据：三个做完的一直标着「未做」，
/// 两个早已作废的还挂着，于是有人照着它去「实现」一个已经存在的模块。
///
/// 所以分两半：
///
/// - **算得出来的别让 agent 写**。任务库里已经存着每个任务的描述、平台、
///   改了几个文件、什么状态、卡在哪 —— 这些由系统渲染，agent 忘不了，
///   因为它不用记。
/// - **算不出来的用标记逼**。「为什么这么做、还差什么」自动化拿不到。
///   落地时如果一个改了好几个文件的任务没留下任何说明，就在进度里标出来，
///   让缺口本身可见。
///
/// ## 为什么挂在合并之后，不挂在任务完成时
///
/// 任务完成时人还在自己的分支里。几个分支各写各的进度，合过来就是冲突 ——
/// 而且是**每次都冲突**，因为大家都在改同一段。合并是串行的，
/// 写在合并之后天然不打架。
///
/// 合并本身要求工作区干净（见 `Review.mergeUnverified`），
/// 所以合完之后写文件、单独提交，不会卷进用户没提交的改动。
public enum ProgressLog {

    /// 机器生成段的边界。**段外的内容一律不动** —— 那是人写的部分，
    /// 也是这份文件里唯一自动化产不出来的部分。
    public static let begin = "<!-- llmq:progress 自动生成，别手改；手写的内容放在这个块外面 -->"
    public static let end = "<!-- /llmq:progress -->"

    /// 新建 STATUS.md 时的开头。留出人写的位置，并且说清楚该写什么 ——
    /// 一份只有机器段的文件会让人以为这文件不用管。
    static let header = """
        # 实现状态

        **这份文件的作用**：让下一个动这个仓库的人（或 agent）不必从代码里
        重新推断「做到哪了」。下面「最近落地」那段是自动写的，别手改；
        **需要你写的是它写不出来的那部分：为什么这么做、还差什么、哪些坑别再踩。**

        ## 还没做的

        （写在这里。落地闸门不会替你想。）

        """

    // MARK: - 渲染

    /// 把某个仓库的任务记录渲染成进度段。
    ///
    /// 只看这个仓库的任务。`landedRecently` 是刚合进来的那个 —— 它排第一，
    /// 并且带上「这次合并有没有留下说明」的判断。
    public static func render(repo: String, tasks: [WorkTask],
                              needsNote: Set<String> = [], now: Date = Date()) -> String {
        let mine = tasks.filter { samePath($0.repo, repo) }
        var out = [begin, "", "## 最近落地（自动记录，别手改）", ""]
        out.append("最后更新：" + stamp(now) + "　共 \(mine.count) 个任务")
        out.append("")

        let landed = mine
            .filter { $0.state == .done }
            .sorted { ($0.landedAt ?? $0.endedAt ?? $0.createdAt)
                    > ($1.landedAt ?? $1.endedAt ?? $1.createdAt) }
            .prefix(12)

        if landed.isEmpty {
            // 空状态要自证：分不清「没有落地过」和「进度没在记」的话，
            // 这段就等于没写。
            out += ["还没有任务落地到这个仓库。", ""]
        } else {
            out += ["| 时间 | 干了什么 | 谁干的 | 改动 |", "|---|---|---|---|"]
            for t in landed {
                let when = short(t.landedAt ?? t.endedAt ?? t.createdAt)
                var what = oneLine(t.prompt, max: 46)
                if needsNote.contains(t.id) { what += " ⚠️ 说明待补" }
                let who = t.platform?.displayName ?? "—"
                let n = t.changedFiles.map { "\($0) 个文件" } ?? "—"
                out.append("| \(when) | \(what) | \(who) | \(n) |")
            }
            out.append("")
        }

        // 卡着的东西比做完的更值钱：下一个人最该知道的是「哪里停了、为什么」。
        //
        // 但**主动丢掉的不算卡住**。被人取消、或者本来就是验证闸门用的一次性
        // 用例，混在这份名单里会让人去查一个根本没人在等的东西 ——
        // 把「已放弃」说成「卡住了」，比不说更耽误事。
        let stuck = mine.filter {
            $0.discardedAt == nil
                && ($0.state == .blocked || $0.state == .failed || $0.state == .running)
        }.sorted { $0.createdAt > $1.createdAt }.prefix(8)
        if !stuck.isEmpty {
            out += ["**卡着的**：", ""]
            for t in stuck {
                let why = t.note.map { "：" + oneLine($0, max: 70) } ?? ""
                out.append("- `\(t.id.prefix(8))` \(stateLabel(t.state))"
                           + " — \(oneLine(t.prompt, max: 46))\(why)")
            }
            out.append("")
        }

        if !needsNote.isEmpty {
            out += ["> ⚠️ 上面标了「说明待补」的改动动了好几个文件却没在这份文件里",
                    "> 留下任何说明。**为什么这么做、还差什么，只有写的人知道** ——",
                    "> 自动记录补不上这一块，请手工补在本段之外。", ""]
        }
        out.append(end)
        return out.joined(separator: "\n")
    }

    // MARK: - 写回

    /// 合并成功之后调用：把进度段写进 `<repo>/STATUS.md` 并单独提交。
    ///
    /// 返回是否真的写了。内容没变就不写 —— 否则每次合并都多一个空提交。
    @discardableResult
    public static func recordLanding(repo: String, branch: String?,
                                     tasks: [WorkTask] = TaskStore.all(),
                                     now: Date = Date()) -> Bool {
        // 「这次合并有没有留下说明」只能在合并当下判断：HEAD 就是那个合并提交。
        var needsNote: Set<String> = []
        // 图分支上所有节点的 branch 都一样，`first(where:)` 会随便挑一个 ——
        // 「说明待补」于是被贴到一个随机节点头上。图按整张算：
        // 只要这次合并没动 STATUS.md，改动量够大的节点都标上。
        if let branch {
            let onBranch = tasks.filter { $0.branch == branch }
            if !mergeTouchedStatus(repo: repo) {
                for t in onBranch where (t.changedFiles ?? 0) >= 3 {
                    needsNote.insert(t.id)
                }
            }
        }

        let url = URL(fileURLWithPath: repo).appendingPathComponent("STATUS.md")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? header
        let block = render(repo: repo, tasks: tasks, needsNote: needsNote, now: now)
        let new = replaceBlock(in: old, with: block)
        guard new != old else { return false }
        guard (try? new.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return false }

        // 只提交这一个路径。用 pathspec 而不是 `add -A`：
        // 万一工作区里还有别的东西，不能顺手替用户提交掉。
        return commitStatus(repo: repo, message: "进度：记录 \(branch ?? "落地")")
    }

    /// 把 STATUS.md 提交掉。**提交失败不能装没事。**
    ///
    /// 实锤(2026-08-23 14:59,Flint):落地跑在后台线程,主循环同一时刻在对
    /// 同一个仓库跑 `git diff`/`merge-tree`(发验收摘要),`git commit` 撞上
    /// index.lock 失败 —— 结果被 `_ =` 吞掉,STATUS.md 留在暂存区。下一轮
    /// autoLand 的「仓库脏着就整轮让开」把**自己留下的脏**当成了人在写代码,
    /// 整仓两小时没落地一条;续活以为主线第 3 块没人做,又派了一遍(白烧
    /// 10 分钟 Kimi)。自己弄脏的自己得收:重试几次,还不行就把 STATUS.md
    /// 还原,宁可少记一行进度,也不能把落地整个堵死。
    @discardableResult
    static func commitStatus(repo: String, message: String) -> Bool {
        for attempt in 0..<4 {
            _ = GitWorkspace.git(["add", "--", "STATUS.md"], in: repo)
            let r = GitWorkspace.git(["commit", "-m", message, "--", "STATUS.md"], in: repo)
            if r.exitCode == 0 { return true }
            // 没东西可提交(别处已经提交过了)也算完成。
            if r.stdout.contains("nothing to commit") || r.stderr.contains("nothing to commit") {
                return true
            }
            Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
        }
        // 还原,别留脏。锁还在的话 restore/checkout 也会失败,所以再用不碰
        // index 的办法把工作区内容写回 HEAD 版本;暂存区里残留的那份等锁一放,
        // 下一轮 healStatusOnlyDirt 会补提交掉(它只认 STATUS.md 一个文件脏)。
        _ = GitWorkspace.git(["restore", "--staged", "--", "STATUS.md"], in: repo)
        _ = GitWorkspace.git(["checkout", "--", "STATUS.md"], in: repo)
        let headVersion = GitWorkspace.git(["show", "HEAD:STATUS.md"], in: repo)
        if headVersion.exitCode == 0 {
            try? headVersion.stdout.write(
                to: URL(fileURLWithPath: repo).appendingPathComponent("STATUS.md"),
                atomically: true, encoding: .utf8)
        }
        FileHandle.standardOutput.write(Data(
            "  ⚠︎ STATUS.md 提交没成(多半撞上了 index.lock),已还原,这一行进度没记\n".utf8))
        return false
    }

    /// 仓库只有 STATUS.md 脏着(上次提交没成留下的)—— 那是我们自己的文件,
    /// 补提交掉,别让它挡住落地。返回 true = 处理过且现在干净了。
    /// 人真正在改别的文件时不碰(那时仓库脏是对的,该让开)。
    @discardableResult
    public static func healStatusOnlyDirt(repo: String) -> Bool {
        let lines = GitWorkspace.git(["status", "--porcelain"], in: repo).stdout
            .split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let paths = lines.map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        guard paths.allSatisfy({ $0 == "STATUS.md" }) else { return false }
        return commitStatus(repo: repo, message: "进度：补记（上次提交没成）")
    }

    /// 把 begin/end 之间换成新内容；没有标记就追加到末尾。
    static func replaceBlock(in text: String, with block: String) -> String {
        guard let b = text.range(of: begin), let e = text.range(of: end),
              b.lowerBound < e.lowerBound else {
            let base = text.hasSuffix("\n") ? text : text + "\n"
            return base + "\n" + block + "\n"
        }
        return text.replacingCharacters(in: b.lowerBound..<e.upperBound, with: block)
    }

    /// 这次合并（HEAD 相对第一父）有没有动过 STATUS.md。
    static func mergeTouchedStatus(repo: String) -> Bool {
        let r = GitWorkspace.git(["diff", "--name-only", "HEAD^1", "HEAD"], in: repo)
        guard r.exitCode == 0 else { return true }   // 判不了就别乱标
        return r.stdout.split(separator: "\n").contains { $0.trimmingCharacters(
            in: .whitespaces) == "STATUS.md" }
    }

    // MARK: - 小工具

    static func samePath(_ a: String, _ b: String) -> Bool {
        NSString(string: a).expandingTildeInPath
            == NSString(string: b).expandingTildeInPath
    }

    static func stateLabel(_ s: WorkTask.State) -> String {
        switch s {
        case .blocked: return "等人工确认"
        case .failed: return "失败"
        case .running: return "在跑"
        default: return "\(s.rawValue)"
        }
    }

    /// 表格里不能出现换行和竖线，否则整张表塌掉。
    static func oneLine(_ s: String, max n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
    }

    static func fmt(_ f: String, _ d: Date) -> String {
        let x = DateFormatter()
        x.dateFormat = f
        x.locale = Locale(identifier: "en_US_POSIX")
        return x.string(from: d)
    }
    static func stamp(_ d: Date) -> String { fmt("yyyy-MM-dd HH:mm", d) }
    static func short(_ d: Date) -> String { fmt("MM-dd HH:mm", d) }
}
