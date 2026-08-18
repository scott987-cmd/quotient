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
        preferredPlatform: Platform? = nil
    ) throws -> Outcome {
        if !force {
            let dups = DuplicateGuard.matches(prompt: prompt, repo: repo, in: TaskStore.all())
            if !dups.isEmpty { return .duplicate(dups) }
        }

        var t = WorkTask(id: String(UUID().uuidString.prefix(8)).lowercased(),
                         prompt: prompt, repo: repo)
        t.origin = origin
        // 点名平台是**优先**不是命令：过不了岗位/风险/方向闸照样换人。
        t.preferredPlatform = preferredPlatform
        // 【媒体】任务档次写死 standard/safe，不进分诊：
        // 分诊的「复杂档」衡量的是推理难度，而媒体驱动只是逐行执行清单 ——
        // 13 张图被判成复杂档后，MiniMax（只验证到常规档）反而接不了
        // 自己唯一该接的活，媒体批当场 blocked。真实翻过车。
        // 【评审】同理：它是一个整体的推理动作，档次由内容长短决定不了。
        // 判成复杂档之后 MiniMax（只验证到常规档）就接不了自己唯一
        // 该接的活了 —— 和媒体任务当初翻的是同一辆车。
        let reviewTask = TaskKind.isReview(prompt)
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
        if classify, !mediaTask, !reviewTask {
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
        if split, !isMedia, !reviewTask, TaskDecomposer.shouldDecompose(t),
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
            }
            for n in nodes { try TaskStore.append(n) }
            return .graph(nodes)
        }

        try TaskStore.append(t)
        return .single(t)
    }
}
