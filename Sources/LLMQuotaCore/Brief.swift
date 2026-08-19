import Foundation

/// 「自上次以来发生了什么」——多个会话共享同一份事实的通道。
///
/// ## 为什么需要它
///
/// 派活/盯进度和改代码分成两个会话之后，最怕的是两边各自记着一半真相
/// （一边以为任务还在跑、另一边已经把它 discard 了）。解法不是同步对话，
/// 而是**共享状态存储**：tasks.jsonl / 冷却台账 / 待审分支本来就是唯一
/// 事实源，谁都能读。这个命令只是把「读」这件事压成一行，
/// 让每个会话开工前花两秒就能对齐。
///
/// 判据全部来自时间戳，不维护任何额外状态 —— 没有「已读游标」这种
/// 会漂移的东西，`--since` 由调用方给（通常是上次看的时间）。
public enum Brief {

    public struct Change: Sendable {
        public var kind: String     // 完成 / 失败 / 卡住 / 落地 / 丢弃 / 新排队
        public var taskID: String
        public var title: String
        public var platform: String?
        public var at: Date
        public var note: String?
    }

    /// 从 since 之后发生的任务状态变化，按时间正序。
    public static func changes(since: Date, tasks: [WorkTask] = TaskStore.all()) -> [Change] {
        var out: [Change] = []
        for t in tasks {
            let title = String(t.prompt.prefix(60))
                .replacingOccurrences(of: "\n", with: " ")
            if let d = t.landedAt, d > since {
                out.append(Change(kind: "落地", taskID: t.id, title: title,
                                  platform: t.platform?.displayName, at: d, note: nil))
            }
            if let d = t.discardedAt, d > since {
                out.append(Change(kind: "丢弃", taskID: t.id, title: title,
                                  platform: t.platform?.displayName, at: d,
                                  note: t.discardReason))
            }
            if let d = t.endedAt, d > since {
                let kind: String
                switch t.state {
                case .done: kind = "完成"
                case .failed: kind = "失败"
                case .blocked: kind = "卡住"
                default: kind = t.state.rawValue
                }
                out.append(Change(kind: kind, taskID: t.id, title: title,
                                  platform: t.platform?.displayName, at: d,
                                  note: t.note.map { String($0.prefix(120)) }))
            } else if t.createdAt > since, t.state == .queued {
                out.append(Change(kind: "新排队", taskID: t.id, title: title,
                                  platform: nil, at: t.createdAt, note: nil))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// 此刻的全景：在跑什么、堵着什么、谁在冷却、有多少待审。
    ///
    /// 这部分**不看 since** —— 「现在什么状态」和「刚才发生了什么」是
    /// 两个问题，混在一起会让人以为没有变化就等于没有积压。
    public struct Snapshot: Sendable {
        public var running: [WorkTask] = []
        public var queued: [WorkTask] = []
        public var blocked: [WorkTask] = []
        public var pendingReview: [(repo: String, branches: Int)] = []
        public var cooling: [(platform: String, reason: String, until: Date)] = []
        public var pendingAsks: Int = 0
        /// 最近七天有多少次「窗口开着但没活可填」，按平台归并。
        ///
        /// 这个数字原来是一条推送（24 小时弹 5 次）。但它报的是一个
        /// **系统自己已经认可的状态**（宁可闲着也不编任务），
        /// 而人收到之后唯一能做的是「想个活给它干」—— 那是把工作推给人。
        /// 单点没意义、趋势有意义的东西，属于报表，不属于打断。
        public var idleWindows: [(platform: String, times: Int)] = []
    }

    public static func snapshot(tasks: [WorkTask] = TaskStore.all(),
                                now: Date = Date()) -> Snapshot {
        var s = Snapshot()
        for t in tasks {
            switch t.state {
            case .running: s.running.append(t)
            case .queued: s.queued.append(t)
            case .blocked: s.blocked.append(t)
            default: break
            }
            if t.pendingAsk != nil, t.state == .blocked { s.pendingAsks += 1 }
        }
        for (p, cd) in CooldownLedger.active(now: now) {
            s.cooling.append((p.displayName, cd.cause.displayName, cd.until))
        }
        s.cooling.sort { $0.until < $1.until }
        for r in RepoRegistry.all() {
            let path = NSString(string: r.localPath).expandingTildeInPath
            let n = Review.pendingForHuman(repo: path, tasks: tasks).count
            if n > 0 { s.pendingReview.append((r.alias, n)) }
        }
        // 空窗记账（见 idleWindows 的说明）。只算最近 7 天，
        // 老记录留着也没用 —— 那时候的策略可能都不一样了。
        var idleCount: [String: Int] = [:]
        for e in Nudge.idleLog()
        where now.timeIntervalSince(e.at) < 7 * 24 * 3600 {
            idleCount[e.platform, default: 0] += 1
        }
        s.idleWindows = idleCount.sorted { $0.value > $1.value }
            .map { (platform: $0.key, times: $0.value) }
        return s
    }
}
