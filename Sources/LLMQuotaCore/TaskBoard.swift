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
/// 所以范围是固定的：**所有还活着的主任务**（running / queued / blocked）
/// 加上**最近 15 条主任务终态**，总数封顶 60。自动评审、证据、架构处置
/// 是主任务的协作事件；冻结旧任务属于历史。它们都保留在审计/协作数据中，
/// 但不再与主任务平铺在手机“当前任务”页。
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
        platformReports: [PlatformReport] = [],
        progressByTaskID: [String: WorkProgress] = [:],
        executionScope: ProjectExecutionScope? = nil,
        now: Date = Date()
    ) -> Result {
        let primaryTasks = tasks.filter {
            !TaskKind.isSupportingTask($0) && !TaskKind.isFrozenArchive($0)
        }
        // 一张图有几步：**按 graphID 数出来**，不是从记录里读。
        // 拆解时没有把总数写进每个节点，而且节点还可能被单独删掉，
        // 现数一遍才是当下的事实。
        var stepTotals: [String: Int] = [:]
        for t in primaryTasks {
            guard let g = t.graphID else { continue }
            stepTotals[g, default: 0] += 1
        }

        let aliasByPath = aliasIndex(repoAliases)

        // 专注某项目时，其他项目已暂停/排队的任务属于历史，不应继续占据
        // 手机“当前任务”页。若真的出现跨项目 running，仍保留展示，方便直接
        // 暴露执行边界失守，而不是用过滤把事故藏起来。
        let live = primaryTasks.filter {
            !isFinished($0.state)
                && (executionScope?.includesForDisplay($0.repo) != false
                    || $0.state == .running)
        }
        // 终态只留最近的：先按结束时间倒序，再切。没有 endedAt 的
        // （老记录、被外力改过的）退回 createdAt，总比丢掉强。
        let finished = primaryTasks.filter {
            isFinished($0.state)
                && executionScope?.includesForDisplay($0.repo) != false
        }
            .sorted { endTime($0) > endTime($1) }
            .prefix(recentFinishedCount)

        let picked = (live + finished).sorted(by: order)
        let truncated = picked.count > maxTasks

        let briefs = picked.prefix(maxTasks).map {
            brief(for: $0, machineName: machineName,
                  stepTotals: stepTotals, aliasByPath: aliasByPath,
                  platformReports: platformReports,
                  progress: progressByTaskID[$0.id], now: now)
        }
        return Result(tasks: Array(briefs), truncated: truncated)
    }

    // MARK: - 一条任务

    private static func brief(
        for t: WorkTask,
        machineName: String,
        stepTotals: [String: Int],
        aliasByPath: [String: String],
        platformReports: [PlatformReport],
        progress: WorkProgress?,
        now: Date
    ) -> TaskBrief {
        // 重启后的旧 checkpoint 仍可作为历史证据，但不能冒充本轮进度。
        let priorRun = t.state == .running && progress != nil
            && (progress?.updatedAt ?? .distantPast) < (t.startedAt ?? .distantPast)
        // queued 的任务身上可能还挂着**上一轮**的 startedAt（重排、接力过的）。
        // 照发的话手机上会显示「已经跑了 3 天」——一个排队中的任务。
        // 排队就是没在跑，这两个字段一起按下。
        let running = t.state != .queued
        let started = running ? t.startedAt : nil
        let productionPhase = t.production?.stage.displayName
        let stalled = WorkProgressSentinel.finding(for: t, progress: progress, now: now)
        let paused = t.pausedAt != nil
        let technicalBlock = TechnicalDisposition.isBlocked(t)
        let humanBlock = t.state == .blocked && t.waitReason == .humanApproval
        let presentationBlock = paused || technicalBlock || humanBlock
        let ownerQuotaWait = ownerQuotaWait(for: t, reports: platformReports, now: now)
        let delivery: (phase: String, summary: String, next: String?)? = {
            if t.landedAt != nil {
                return ("已合入 main", t.note ?? "已合入 main", nil)
            }
            if t.discardedAt != nil {
                return ("已丢弃", t.discardReason ?? t.note ?? "该版产出未采用", nil)
            }
            if t.state == .failed {
                return ("未完成", t.note ?? "任务执行失败", nil)
            }
            if t.state == .done, (t.changedFiles ?? 0) > 0, t.branch != nil {
                return ("等待合入", t.note ?? "Agent 已完成隔离分支产出",
                        "完成评审后合入 main")
            }
            if t.state == .done {
                return ("已完成 · 无新改动", t.note ?? "任务已完成，没有新的代码改动", nil)
            }
            return nil
        }()
        let visiblePhase: String?
        if let delivery {
            visiblePhase = delivery.phase
        } else if paused, t.architectureReviewRequestedAt != nil {
            visiblePhase = (t.note ?? "").contains("结论为保持暂停")
                ? "架构重审完成 · 保持暂停"
                : "架构重审进行中"
        } else if paused {
            visiblePhase = "已暂停 · 等待架构决策"
        } else if technicalBlock {
            visiblePhase = "等待架构师技术处置"
        } else if humanBlock {
            visiblePhase = "等待你的确认"
        } else if t.state == .blocked, let waitReason = t.waitReason {
            visiblePhase = switch waitReason {
            case .humanAnswer: "等待你的答复"
            case .humanApproval: "等待你的确认"
            case .dependency: "等待上游任务"
            case .ownerUnavailable: "等待原 Owner 恢复或人工处置"
            case .productionGate: "等待生产质量门"
            case .paused: "已暂停"
            case .architectureReview: "等待架构重审"
            }
        } else if let ownerQuotaWait {
            visiblePhase = ownerQuotaWait.phase
        } else if stalled != nil, let productionPhase {
            visiblePhase = productionPhase + " · 无可证明进展"
        } else if stalled != nil {
            visiblePhase = "无可证明进展"
        } else if let productionPhase, let livePhase = progress?.phase, !livePhase.isEmpty {
            visiblePhase = productionPhase + " · " + livePhase
        } else {
            visiblePhase = progress?.phase ?? productionPhase
        }
        let productionSummary = t.production.map {
            $0.stage == .goldenSample
                ? "样板 \($0.goldenSampleID) · \($0.deliverableKind)"
                : "扩张自样板 \($0.goldenSampleID) · \($0.deliverableKind)"
        }
        let stalledSummary = stalled.map {
            "已 \($0.minutesWithoutProgress) 分钟没有结构化里程碑；系统仍保留当前 Agent 与会话"
        }
        // 只覆盖真正的处置状态。黄金样板、上游冻结等 blocked 自己有精确的
        // production/graph 语义，不能被一个笼统“已阻塞”抹掉。
        let blockedSummary = presentationBlock ? t.note : nil
        let blockedNextStep: String? = {
            guard presentationBlock else { return nil }
            if paused, t.architectureReviewRequestedAt != nil {
                let ownerName = (t.ownerPlatform ?? t.preferredPlatform ?? t.platform)?.displayName
                    ?? "Agent"
                return "独立架构评审完成前置设计并给出允许恢复结论后，原 \(ownerName) 任务自动续作"
            }
            if paused {
                return "架构明确放行后再恢复；系统不会自动重开"
            }
            if technicalBlock {
                return "架构师只复核隔离分支；实现 Owner 和项目会话保持不变"
            }
            return t.note
        }()
        let visibleSummary = delivery?.summary ?? blockedSummary ?? ownerQuotaWait?.summary
            ?? stalledSummary ?? progress?.summary ?? productionSummary
        let visibleNextStep: String? = if let delivery {
            delivery.next
        } else {
            blockedNextStep ?? ownerQuotaWait?.nextStep
                ?? t.production?.blockedReason ?? progress?.nextStep
        }
        return TaskBrief(
            id: t.id,
            title: TaskBrief.title(for: t),
            state: t.state,
            waitReason: t.waitReason,
            platform: t.platform,
            machineName: machineName,
            startedAt: started,
            elapsedSeconds: started.flatMap { elapsed(from: $0, to: t.endedAt ?? now) },
            graphID: t.graphID,
            stepIndex: t.stepIndex,
            stepTotal: t.graphID.flatMap { stepTotals[$0] },
            repoAlias: aliasByPath[standardized(t.repo)],
            progressPhase: priorRun && stalled == nil ? "已恢复 · 等待本轮里程碑" : visiblePhase,
            progressSummary: priorRun && stalled == nil
                ? "上轮进展：\(visibleSummary ?? "暂无汇报")" : visibleSummary,
            progressNextStep: visibleNextStep,
            progressUpdatedAt: delivery == nil ? progress?.updatedAt : (t.landedAt ?? t.endedAt),
            progressEvidenceCount: progress?.evidence.count,
            productionStage: t.production?.stage.rawValue,
            deliverableKind: t.production?.deliverableKind,
            productionBlockedReason: t.production?.blockedReason,
            ownerRunnerID: t.ownerRunnerID,
            branch: t.branch, landedAt: t.landedAt,
            progressEvidence: progress.map { Array($0.evidence.prefix(8)) },
            progressCheckpointAt: progress?.checkpointAt
        )
    }

    private struct OwnerQuotaWait {
        var phase: String
        var summary: String
        var nextStep: String
    }

    /// 排队任务已经有 owner 时，其他平台恢复额度并不等于应该抢走会话。
    /// 把这个调度事实直接发给手机，避免“Qwen 明明恢复了但系统停了”的假象。
    private static func ownerQuotaWait(for task: WorkTask,
                                       reports: [PlatformReport], now: Date)
        -> OwnerQuotaWait? {
        guard task.state == .queued,
              let owner = task.ownerPlatform ?? task.preferredPlatform,
              let report = reports.first(where: { $0.platform == owner }) else { return nil }
        let exhausted = report.statuses.filter { !$0.advisory && $0.health == .exhausted }
        guard !exhausted.isEmpty else { return nil }
        let reset = exhausted.compactMap(\.resetsAt).filter { $0 > now }.min()
        let resetText = reset.map { Format.duration($0.timeIntervalSince(now)) + "后" }
            ?? "平台恢复后"
        let ownerName = owner.displayName
        let runner = task.ownerRunnerID.map { "（\($0)）" } ?? ""
        let qwen = reports.first { $0.platform == .qwen }
        let qwenAvailable = qwen.map {
            $0.enabled && $0.installed && $0.detected
                && !$0.statuses.contains { !$0.advisory && $0.health == .exhausted }
        } ?? false
        let affinity = qwenAvailable && owner != .qwen
            ? "；Qwen 额度已恢复，但不自动抢占已有会话"
            : ""
        return OwnerQuotaWait(
            phase: "排队 · 等待 \(ownerName) 额度恢复",
            summary: "\(ownerName) 当前额度已用尽，预计 \(resetText)恢复；"
                + "任务保持原 Owner \(runner)\(affinity)",
            nextStep: "额度恢复后自动重试原 Owner；需要换人时必须显式交接")
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
