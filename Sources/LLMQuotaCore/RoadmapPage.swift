import Foundation

/// 项目进度是每机任务板的只读投影，不是另一份任务账本，也不从提交标题猜完成度。
public enum RoadmapPage {
    /// 共享页只能有一个发布者。沿用已登记的项目协调机；没有协调机时按集群
    /// 节点名确定唯一发布者。离线不自动抢写，避免不完整的快照覆盖完整页面。
    public static func isPublisher(
        machineID: String = Paths.machineID(),
        repos: [RepoAlias] = RepoRegistry.all(),
        nodeName: String? = ClusterConfigStore.load()?.nodeName,
        peerNames: [String] = ClusterConfigStore.load().map { Array($0.peers.keys) } ?? []
    ) -> Bool {
        if let owner = repos.sorted(by: { $0.alias < $1.alias })
            .compactMap(\.coordinatorMachineID).first(where: { !$0.isEmpty }) {
            return owner.caseInsensitiveCompare(machineID) == .orderedSame
        }
        guard let nodeName else { return peerNames.isEmpty }
        return (peerNames + [nodeName]).sorted().first == nodeName
    }

    public static func page(now: Date = Date(),
                            listing: TaskBoardStore.Listing? = nil) -> ViewFeed.Page {
        let source = listing ?? TaskBoardStore.loadAll()
        // 兼容旧文件名/重复快照，同一机器只取最新板；任务 ID 只在机器内唯一。
        let boards = Dictionary(source.boards.map { ($0.machineID, $0) },
            uniquingKeysWith: { $0.generatedAt >= $1.generatedAt ? $0 : $1 })
            .values.sorted { $0.machineID < $1.machineID }
        let stale = boards.filter { isStale($0, now: now) }
        let complete = source.isComplete && !source.directoryMissing
        var sections = [ViewFeed.Section(
            kind: "text", title: "项目进度", tone: complete && stale.isEmpty ? .neutral : .warn,
            text: "汇总 \(boards.count) 台机器的任务板 · \(stamp(now)) 更新\n"
                + (complete ? "" : "部分任务板无法读取，当前内容不完整。\n")
                + (stale.isEmpty ? "" : "\(stale.count) 台机器数据已过期，不能据此判断仍在运行。\n")
                + "阶段、证据来自任务汇报；任务完成不等于已验收或已合入。超过 30 分钟未更新时请勿当作实时状态。")]
        let aliases = Set(boards.flatMap { board in
            board.tasks.map { $0.repoAlias ?? "未归类项目" }
                + board.planned.map { $0.repoAlias ?? "未归类项目" }
                + [board.focusedRepoAlias].compactMap { $0 }
        }).sorted()
        for alias in aliases {
            var entries: [(MachineTaskBoard, TaskBrief)] = []
            var plannedCards: [ViewFeed.Card] = []
            for board in boards {
                let tasks = Dictionary(board.tasks.map { ($0.id, $0) },
                    uniquingKeysWith: { ($0.progressUpdatedAt ?? .distantPast)
                        >= ($1.progressUpdatedAt ?? .distantPast) ? $0 : $1 })
                entries += tasks.values.filter { ($0.repoAlias ?? "未归类项目") == alias }
                    .map { (board, $0) }
                plannedCards += board.planned.filter { ($0.repoAlias ?? "未归类项目") == alias }
                    .map { plan in ViewFeed.Card(
                        id: "planned-\(board.machineID)-\(plan.id)",
                        title: "待安排 · \(plan.title)",
                        body: "\(displayName(board)) · 尚未开工",
                        trailing: isStale(board, now: now) ? "数据已过期" : nil) }
            }
            entries.sort {
                if rank($0.1) != rank($1.1) { return rank($0.1) < rank($1.1) }
                let a = $0.1.progressUpdatedAt ?? $0.1.startedAt ?? .distantPast
                let b = $1.1.progressUpdatedAt ?? $1.1.startedAt ?? .distantPast
                return a == b ? $0.0.machineID + $0.1.id < $1.0.machineID + $1.1.id : a > b
            }
            // 所有活跃/待验收主任务保留；终态只展示最近三项，不让历史淹没当前工作。
            let active = entries.filter { rank($0.1) < 3 }
            let recent = entries.filter { rank($0.1) >= 3 }.prefix(3)
            let cards = (active + recent).map { card($0.1, board: $0.0, now: now) }
                + plannedCards.prefix(5)
            let running = entries.filter { $0.1.state == .running && !isStale($0.0, now: now) }.count
            let waiting = entries.filter {
                ($0.1.state == .queued || $0.1.state == .blocked) && !isStale($0.0, now: now)
            }.count
            let uncertain = entries.filter { isStale($0.0, now: now) }.count
            let truncated = boards.contains { $0.tasksTruncated }
                || recent.count < entries.count - active.count || plannedCards.count > 5
            sections.append(ViewFeed.Section(kind: cards.isEmpty ? "text" : "cards",
                title: alias, note: "运行记录 \(running) 项 · 排队/阻塞 \(waiting) 项"
                    + (uncertain > 0 ? " · 过期状态待核 \(uncertain) 项" : "")
                    + (truncated ? " · 仅显示部分历史" : ""),
                text: cards.isEmpty ? "本机已专注此项目，但尚无任务进度汇报。" : nil,
                cards: cards.isEmpty ? nil : cards))
        }
        if aliases.isEmpty {
            sections.append(ViewFeed.Section(kind: "text", title: "暂无项目任务数据",
                tone: .warn, text: boards.isEmpty
                    ? "尚未收到机器任务板；请检查桌面端刷新服务与同步，不能据此断言项目已完成。"
                    : "已收到任务板，但没有当前主任务或待安排计划。"))
        }
        return ViewFeed.Page(page: "roadmap", sections: sections, now: now)
    }

    private static func rank(_ task: TaskBrief) -> Int {
        if task.state == .running { return 0 }
        if task.state == .queued || task.state == .blocked { return 1 }
        if task.state == .done && task.landedAt == nil
            && task.progressPhase == "等待合入" { return 2 }
        return 3
    }

    private static func isStale(_ board: MachineTaskBoard, now: Date) -> Bool {
        now.timeIntervalSince(board.generatedAt) > TaskBoardStore.staleAfter
            || board.generatedAt > now.addingTimeInterval(TaskBoardStore.futureTolerance)
    }

    private static func displayName(_ board: MachineTaskBoard) -> String {
        Paths.privacySafeMachineDisplayName(
            nodeName: board.nodeName, machineName: board.machineName, machineID: board.machineID)
    }

    private static func stamp(_ date: Date) -> String {
        if date == .distantPast { return "时间未知" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func card(_ task: TaskBrief, board: MachineTaskBoard,
                             now: Date) -> ViewFeed.Card {
        let stale = isStale(board, now: now)
        let phase: String
        if stale { phase = "状态待更新" }
        else if task.landedAt != nil { phase = "已合入 main" }
        else if task.progressPhase == "已合入 main" { phase = "已合入 main（旧版任务记录）" }
        else {
            switch task.state {
            case .running: phase = "进行中"
            case .queued: phase = "排队中"
            case .blocked: phase = "已阻塞"
            case .failed: phase = "未完成"
            case .done: phase = task.progressPhase == "等待合入" ? "产出待验收/合入" : "已结束 · 非合入证明"
            }
        }
        var body = ["\(displayName(board)) · \(task.ownerRunnerID ?? task.platform?.displayName ?? "未分配 Agent")"]
        if let elapsed = task.elapsedSeconds {
            body.append("\(stale ? "记录耗时" : "本轮耗时") \(max(0, elapsed) / 60) 分钟")
        }
        if task.state == .running, let started = task.startedAt,
           task.progressPhase?.contains("无可证明进展") == true {
            // 自动 WIP 可以更新 progressUpdatedAt，却不能刷新 checkpoint 时钟。
            // 旧执行器没发这个新字段时，绝不复述它算错的“停滞八小时”。
            if let checkpoint = task.progressCheckpointAt {
                let minutes = max(0, Int(board.generatedAt.timeIntervalSince(max(started, checkpoint)) / 60))
                body.append("阶段：等待新的可核验里程碑")
                body.append("本轮未收到新里程碑已计时 \(minutes) 分钟")
            } else {
                body.append("阶段：里程碑时间待核对")
                body.append("任务板未提供可校验的 checkpoint 时间，等待刷新服务核对；不采用旧版停滞时长。")
            }
        } else if task.state == .running, let started = task.startedAt,
           let progressAt = task.progressUpdatedAt, progressAt < started {
            // 在飞的旧执行器可能继续发旧格式任务板；读端同样限制本轮时钟，
            // 不能为修展示而重启用户的模型进程。
            body.append("阶段：等待本轮里程碑")
            let minutes = max(0, Int(board.generatedAt.timeIntervalSince(started) / 60))
            body.append(minutes >= 20 ? "本轮已 \(minutes) 分钟未收到结构化里程碑"
                        : "已恢复，尚未收到本轮结构化里程碑")
            if task.progressPhase?.contains("无可证明进展") != true,
               let summary = task.progressSummary { body.append("上轮记录：\(summary)") }
        } else {
            if let milestone = task.progressPhase, !milestone.isEmpty { body.append("阶段：\(milestone)") }
            body.append(task.progressSummary ?? "尚无结构化里程碑汇报")
        }
        if let next = task.progressNextStep, !next.isEmpty { body.append("下一步：\(next)") }
        var detail = ["任务：\(task.id)", "任务板采样：\(stamp(board.generatedAt))"]
        if let branch = task.branch { detail.append("分支：\(branch)") }
        if let updated = task.progressUpdatedAt { detail.append("最近进展：\(stamp(updated))") }
        if let count = task.progressEvidenceCount { body.append("汇报证据 \(count) 项（不等于验收通过）") }
        detail += (task.progressEvidence ?? []).prefix(8).map { "证据：\($0)" }
        if stale { body.insert("这台机器超过刷新时限或时钟异常，以下为历史记录。", at: 0) }
        return ViewFeed.Card(id: "progress-\(board.machineID)-\(task.id)",
            title: "\(phase) · \(task.title)", body: body.joined(separator: "\n"),
            detail: detail.joined(separator: "\n"),
            tone: stale || task.state == .blocked || task.state == .failed ? .warn : .neutral,
            icon: "map", trailing: stamp(board.generatedAt), taskID: task.id)
    }
}
