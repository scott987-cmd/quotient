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
        if classify {
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
        let isMedia = prompt.hasPrefix("【媒体】")
        if split, !isMedia, TaskDecomposer.shouldDecompose(t),
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
