import Foundation

/// 任务入队的**唯一**入口：查重 → 分诊 → 该拆就拆 → 落库。
///
/// # 为什么要抽出来
///
/// 这套流程原来整段写在 CLI 的 `work add` 里。手机放行计划任务的通道
/// 接进来之后，同样的流程需要第二个调用方（配置意图的摄入）——
/// 复制一遍的话，两边一定会漂移：早晚有一边的任务没过查重、
/// 或者没拆图就进了队列，而且没人知道。
///
/// CLI 负责打印，这里负责事实。返回值带足信息让调用方各自渲染。
public enum TaskIntake {

    public enum Outcome: Sendable {
        /// 单任务入队。
        case single(WorkTask)
        /// 拆成了图。
        case graph([WorkTask])
        /// 查重拦下 —— **没有入队**，匹配给调用方决定怎么呈现。
        case duplicate([DuplicateGuard.Match])
    }

    /// - Parameters:
    ///   - classify: 要不要分诊（会调用推理平台，花额度）。
    ///   - split: 复杂/高危任务要不要交给指挥拆图。
    ///   - force: 跳过查重（对应 CLI 的 --force）。
    public static func enqueue(
        prompt: String, repo: String,
        classify: Bool = true, split: Bool = true, force: Bool = false,
        origin: String? = nil,
        idempotencyKey: String? = nil,
        source: String = "local",
        preclassifiedProfile: TaskProfile? = nil,
        preferredPlatform: Platform? = nil,
        production requestedProduction: ProductionContext? = nil
    ) throws -> Outcome {
        var prompt = prompt
        if TaskKind.isReview(prompt), !TaskKind.isTesting(prompt),
           !TaskKind.isArchitectReview(prompt),
           !TaskKind.isTechnicalDisposition(prompt),
           !prompt.contains(ArchitectReview.contractMarker) {
            prompt += "\n\n" + ArchitectReview.contractMarker
        }
        let existing = TaskStore.all()
        if let idempotencyKey,
           let prior = existing.filter({
               $0.intakeKey == idempotencyKey
                   || $0.intakeKey?.hasPrefix(idempotencyKey + ":node:") == true
           }).sorted(by: { ($0.stepIndex ?? 0) < ($1.stepIndex ?? 0) }).nilIfEmpty {
            return prior.count == 1 ? .single(prior[0]) : .graph(prior)
        }
        if !force {
            let dups = DuplicateGuard.matches(prompt: prompt, repo: repo, in: existing)
            if !dups.isEmpty { return .duplicate(dups) }
        }

        var t = WorkTask(id: idempotencyKey.map(stableTaskID)
                            ?? String(UUID().uuidString.prefix(8)).lowercased(),
                         prompt: prompt, repo: repo)
        t.origin = origin
        t.intakeKey = idempotencyKey
        t.intakeSource = source
        let reviewTask = TaskKind.isReview(prompt)
        if let requestedProduction {
            t.production = try GoldenSampleGate.prepare(
                requestedProduction, repo: repo, tasks: existing)
            if t.production?.stage == .fanOut,
               let reason = GoldenSampleGate.blockReason(for: t, in: existing + [t]) {
                t.state = .blocked
                t.waitReason = .productionGate
                t.production?.blockedReason = reason
                t.note = "黄金样板闸：" + reason
            }
        }
        // 点名平台是**优先**不是命令：过不了岗位/风险/方向闸照样换人。
        t.preferredPlatform = preferredPlatform
            ?? ((TaskKind.isArchitectReview(prompt) || TaskKind.isTechnicalDisposition(prompt))
                ? AgentRoles.architectPlatform()
                : reviewTask ? .minimax
                : RepoExecutionPolicy.implementationOwner(for: repo, prompt: prompt))
        // 【媒体】任务档次写死 standard/safe，不进分诊：
        // 分诊的「复杂档」衡量的是推理难度，而媒体驱动只是逐行执行清单 ——
        // 13 张图被判成复杂档后，MiniMax（只验证到常规档）反而接不了
        // 自己唯一该接的活，媒体批当场 blocked。真实翻过车。
        // 【评审】同理：它是一个整体的推理动作，档次由内容长短决定不了。
        // 判成复杂档之后 MiniMax（只验证到常规档）就接不了自己唯一
        // 该接的活了 —— 和媒体任务当初翻的是同一辆车。
        if reviewTask {
            t.profile = TaskProfile(
                tier: .standard, risk: .safe, estimatedMinutes: 8,
                isSelfContained: true,
                rationale: "评审任务：读材料给判断，不改代码")
        }
        let mediaTask = TaskKind.isMedia(prompt)
        if mediaTask {
            t.profile = TaskProfile(
                tier: .standard, risk: .safe, estimatedMinutes: 15,
                isSelfContained: true,
                rationale: "媒体清单任务：档次固定，不按条目数升档")
        }
        if let preclassifiedProfile {
            t.profile = preclassifiedProfile
        } else if classify, !mediaTask, !reviewTask {
            t.profile = TaskClassifier.classify(
                prompt: prompt, repo: repo,
                history: TaskStore.all(), dashboard: LLMQuota.dashboard())
        }

        // 复杂档或高危的交给指挥拆图；拆不成一律退回单节点 ——
        // 新增能力不该变成新的单点故障（原注释，语义原样保留）。
        //
        // 【媒体】任务**永远不拆**：媒体驱动按整份 IMG/MUSIC 清单逐行执行，
        // 拆成图之后每个节点只剩一段散文描述，驱动一行 DSL 都解析不到，
        // 全部空跑；而且拆解器还会顺手编出「接入打包配置」这类代码步 ——
        // 那不是媒体执行器的事。真踩过：13 项资产批被拆成 8 步图当场作废。
        // 【评审】也永远不拆。实测：一个「评审 Greed 项目是否达标」的任务
        // 被拆成 7 步开发子任务（「模拟器实跑取证」「终审汇总与合入」）——
        // 拆解器把评审当成了开发计划。评审的产出是一份判断，不是一串动作。
        let isMedia = TaskKind.isMedia(prompt)
        if split, requestedProduction == nil, !isMedia, !reviewTask,
           TaskDecomposer.shouldDecompose(t),
           var nodes = TaskDecomposer.plan(t, dashboard: LLMQuota.dashboard()),
           nodes.count > 1 {
            // 逐节点分诊：整包判高危会让所有角色都够不着，
            // 逐节点判之后只有真碰高危路径的那步转人工，其余照跑。
            let dash = LLMQuota.dashboard()
            let hist = TaskStore.all()
            for i in nodes.indices {
                nodes[i].profile = TaskClassifier.classify(
                    prompt: nodes[i].prompt, repo: repo, history: hist, dashboard: dash)
                nodes[i].origin = origin
                nodes[i].preferredPlatform = preferredPlatform
                nodes[i].intakeSource = source
                nodes[i].intakeKey = idempotencyKey.map {
                    $0 + ":node:" + String(nodes[i].stepIndex ?? i)
                }
            }
            var savedNodes: [WorkTask] = []
            for n in nodes {
                savedNodes.append(try createIdempotently(
                    n, expectedIntakeKey: n.intakeKey,
                    reason: "统一入口创建任务图节点"))
            }
            return .graph(savedNodes)
        }

        let saved = try createIdempotently(
            t, expectedIntakeKey: idempotencyKey, reason: "统一入口创建单任务")
        return .single(saved)
    }

    /// 已经由业务层构造完整 owner/profile/production 关系的任务仍必须走统一
    /// 摄入入口。这里不重新分诊、不拆图，只补稳定身份并做原子幂等创建。
    public static func enqueuePrepared(
        _ candidate: WorkTask,
        idempotencyKey: String,
        source: String
    ) throws -> Outcome {
        if let prior = TaskStore.all().first(where: { $0.intakeKey == idempotencyKey }) {
            return .single(prior)
        }
        var task = candidate
        // 预构造入口可能已经带有业务稳定 ID（例如里程碑整改 m<sha>、
        // 远端请求 ID）。它是外部关联的一部分，不能为了幂等再改名。
        // 只有摄入方明确留下 `pending` 占位符时才由统一入口派生 ID。
        if task.id.isEmpty || task.id == "pending" {
            task.id = stableTaskID(idempotencyKey)
        }
        task.intakeKey = idempotencyKey
        task.intakeSource = source
        do {
            let saved = try TaskStore.create(
                task, actor: "task-intake", reason: "统一入口创建预分诊任务")
            return .single(saved)
        } catch is DuplicateTask {
            // 两个摄入进程同时看到“不存在”时，稳定 ID 让 TaskStore 的跨进程
            // 创建锁成为最终裁决；输掉竞态的一方返回同一个事实，不报假失败。
            guard let prior = TaskStore.all().first(where: {
                $0.id == task.id && $0.intakeKey == idempotencyKey
            }) else { throw DuplicateTask(id: task.id) }
            return .single(prior)
        }
    }

    public static func stableTaskID(_ idempotencyKey: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in idempotencyKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "i" + String(format: "%016llx", hash).prefix(15)
    }

    private static func createIdempotently(
        _ task: WorkTask,
        expectedIntakeKey: String?,
        reason: String
    ) throws -> WorkTask {
        do {
            return try TaskStore.create(task, actor: "task-intake", reason: reason)
        } catch is DuplicateTask {
            guard let expectedIntakeKey,
                  let prior = TaskStore.all().first(where: {
                      $0.id == task.id && $0.intakeKey == expectedIntakeKey
                  }) else { throw DuplicateTask(id: task.id) }
            return prior
        }
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
