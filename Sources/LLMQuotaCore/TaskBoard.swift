import Foundation

/// 把本机的任务记录，压成一份能发给手机的「现在有哪些活」。
///
/// # 为什么要有上限
///
/// 这份东西最终会被塞进 `dashboard.json`，走 iCloud 同步到手机，
/// 而 iCloud 上的写入**可以永久阻塞**（实测卡在 `rename()`，把 work loop
/// 整个冻住过）。文件越大越危险，而任务记录是只增不减的 ——
/// 跑了几个月之后 `tasks.jsonl` 里躺着几千条终态任务，
/// 全发过去既没人看，又把一个「给手机看一眼」的写入变成一次大 IO。
///
/// 所以范围是固定的：**所有还活着的**（running / queued / blocked）
/// 加上**最近 15 条终态**，总数封顶 60。
///
/// # 为什么截断必须留痕
///
/// 截掉之后手机上那句「一共 3 个任务」就是假的，而且是没人会去核对的那种假。
/// `tasksTruncated` 存在的唯一理由就是让界面有机会说「还有更多」。
public enum TaskBoard {
    /// 发给手机的条数上限。
    public static let maxTasks = 60
    /// 终态任务保留最近几条。
    public static let recentFinishedCount = 15

    public struct Result: Sendable {
        public var tasks: [TaskBrief]
        /// 上限真的砍掉了东西。
        public var truncated: Bool
    }

    /// 排序分档。running 优先，然后 queued，然后 blocked，终态垫底。
    ///
    /// blocked 排在 queued 后面而不是前面：它在等人，不占额度槽，
    /// 也不会自己动 —— 而 queued 是「马上就轮到」。上限砍下来的时候，
    /// 先保住会动的那些。
    private static func rank(_ s: WorkTask.State) -> Int {
        switch s {
        case .running: return 0
        case .queued:  return 1
        case .blocked: return 2
        case .done, .failed: return 3
        }
    }

    private static func isFinished(_ s: WorkTask.State) -> Bool {
        s == .done || s == .failed
    }

    public static func build(
        from tasks: [WorkTask],
        machineName: String,
        repoAliases: [RepoAlias] = [],
        now: Date = Date()
    ) -> Result {
        // 一张图有几步：**按 graphID 数出来**，不是从记录里读。
        // 拆解时没有把总数写进每个节点，而且节点还可能被单独删掉，
        // 现数一遍才是当下的事实。
        var stepTotals: [String: Int] = [:]
        for t in tasks {
            guard let g = t.graphID else { continue }
            stepTotals[g, default: 0] += 1
        }

        let aliasByPath = aliasIndex(repoAliases)

        let live = tasks.filter { !isFinished($0.state) }
        // 终态只留最近的：先按结束时间倒序，再切。没有 endedAt 的
        // （老记录、被外力改过的）退回 createdAt，总比丢掉强。
        let finished = tasks.filter { isFinished($0.state) }
            .sorted { endTime($0) > endTime($1) }
            .prefix(recentFinishedCount)

        let picked = (live + finished).sorted(by: order)
        let truncated = picked.count > maxTasks

        let briefs = picked.prefix(maxTasks).map {
            brief(for: $0, machineName: machineName,
                  stepTotals: stepTotals, aliasByPath: aliasByPath, now: now)
        }
        return Result(tasks: Array(briefs), truncated: truncated)
    }

    // MARK: - 一条任务

    private static func brief(
        for t: WorkTask,
        machineName: String,
        stepTotals: [String: Int],
        aliasByPath: [String: String],
        now: Date
    ) -> TaskBrief {
        // queued 的任务身上可能还挂着**上一轮**的 startedAt（重排、接力过的）。
        // 照发的话手机上会显示「已经跑了 3 天」——一个排队中的任务。
        // 排队就是没在跑，这两个字段一起按下。
        let running = t.state != .queued
        let started = running ? t.startedAt : nil
        return TaskBrief(
            id: t.id,
            title: TaskBrief.title(for: t),
            state: t.state,
            platform: t.platform,
            machineName: machineName,
            startedAt: started,
            elapsedSeconds: started.flatMap { elapsed(from: $0, to: t.endedAt ?? now) },
            graphID: t.graphID,
            stepIndex: t.stepIndex,
            stepTotal: t.graphID.flatMap { stepTotals[$0] },
            repoAlias: aliasByPath[standardized(t.repo)]
        )
    }

    private static func elapsed(from start: Date, to end: Date) -> Int? {
        let d = end.timeIntervalSince(start)
        // 负数只可能是时钟被调过或者记录被改坏。发一个负的「跑了多久」
        // 比不发更糟 —— 手机那边没有理由去防这个。
        guard d >= 0 else { return nil }
        return Int(d.rounded())
    }

    /// 同一档里的次序。
    private static func order(_ a: WorkTask, _ b: WorkTask) -> Bool {
        let (ra, rb) = (rank(a.state), rank(b.state))
        if ra != rb { return ra < rb }
        switch a.state {
        case .running:
            // 跑得最久的排前面 —— 卡住的那个最该被看见。
            return (a.startedAt ?? a.createdAt) < (b.startedAt ?? b.createdAt)
        case .queued, .blocked:
            return a.createdAt < b.createdAt
        case .done, .failed:
            return endTime(a) > endTime(b)
        }
    }

    private static func endTime(_ t: WorkTask) -> Date {
        t.endedAt ?? t.createdAt
    }

    // MARK: - 仓库别名

    /// 绝对路径 → 别名。
    ///
    /// 手机上不该出现 `/Users/<你>/Documents/<项目>`：又长、在别的机器上还不一样。
    /// 别名是这套系统里本来就有的那层翻译，这里只是复用它。
    private static func aliasIndex(_ list: [RepoAlias]) -> [String: String] {
        var out: [String: String] = [:]
        for r in list {
            // localPath 是本机的实际路径，path 只是兜底 —— 两个都登记上，
            // 任务记录里存的是哪一个都能认出来。
            for p in Set([r.localPath, r.path]) where !p.isEmpty {
                out[standardized(p)] = r.alias
            }
        }
        return out
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.path
    }
}
