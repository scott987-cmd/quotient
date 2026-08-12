import Foundation

/// 任务图：依赖、就绪判定、阻塞传播、环检测。
///
/// ## 为什么把任务从一个字符串变成一张图
///
/// 今天的模型是「一次性打分选人」：任务 → 过滤掉接不了的 → 剩下按额度排序 →
/// 选第一个。它表达不了三件已经真实发生的事：
///
/// 1. **一个任务里只有一小步是高危的。**「在 build-app.sh 末尾加一行注释」
///    整体被判高危，所有角色都够不着，整个任务卡死。拆开之后只有碰构建脚本
///    的那一步转人工，其余照跑。
/// 2. **贵的活和便宜的活混在一起。**「重构 + 补测试 + 更新文档」只能整包
///    给一个平台。拆开之后机械的步骤给便宜的、难的那步给贵的 ——
///    这直接就是「一分不浪费」。
/// 3. **协作。** 「MiniMax 出图 → Qwen 用它写代码」跨的是两个厂商的两个
///    CLI、两个进程，**不可能共享一个会话**。能传递的只有产物，
///    而产物要挂在边上，所以必须有边。
public enum TaskGraph {

    // MARK: - 就绪

    /// 这个节点现在能不能开跑。
    ///
    /// 判据是上游 `.done` 而不是 `landedAt != nil`：图内节点共用一个分支，
    /// 后一步是在前一步的提交上继续干，不需要等整张图合进 main。
    /// 落地是整张图完成之后的事。
    public static func isReady(_ t: WorkTask, in all: [WorkTask]) -> Bool {
        guard t.state == .queued else { return false }
        guard !t.dependsOn.isEmpty else { return true }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return t.dependsOn.allSatisfy { byID[$0]?.state == .done }
    }

    /// 下一个该跑的节点。
    ///
    /// **同一时刻只跑一个，即使图里有多个节点就绪。**
    /// 图内节点共用一个 worktree，并行写必然打架。反正 worker 本来就是
    /// 一个 tick 跑一个任务，这个限制现在不花任何代价 ——
    /// 但它必须被**说出来**（见 `readyCount`），
    /// 静默串行化会让人以为并行在工作。
    public static func nextReady(_ all: [WorkTask]) -> WorkTask? {
        all.filter { isReady($0, in: all) }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    /// 现在有几个节点同时就绪。用来在日志里说明「我知道有 N 个，但按顺序来」。
    public static func readyCount(_ all: [WorkTask]) -> Int {
        all.filter { isReady($0, in: all) }.count
    }

    // MARK: - 环

    /// 找出图里的环。空数组 = 无环。
    ///
    /// **有环不会报错，只会静默停摆** —— 环上的节点永远等不到上游 done，
    /// 「就绪」恒为假，表现是任务全都不动而且没有任何错误信息。
    /// 所以建图时必须先验，而且这条要配测试。
    public static func cycles(_ nodes: [WorkTask]) -> [String] {
        let ids = Set(nodes.map { $0.id })
        var deps: [String: [String]] = [:]
        for n in nodes { deps[n.id] = n.dependsOn.filter { ids.contains($0) } }

        var state: [String: Int] = [:]   // 0 未访问 1 在栈上 2 完成
        var onCycle: Set<String> = []

        func visit(_ id: String) -> Bool {
            switch state[id] ?? 0 {
            case 1: onCycle.insert(id); return true
            case 2: return false
            default: break
            }
            state[id] = 1
            var hit = false
            for d in deps[id] ?? [] where visit(d) {
                onCycle.insert(id)
                hit = true
            }
            state[id] = 2
            return hit
        }
        for n in nodes { _ = visit(n.id) }
        return onCycle.sorted()
    }

    /// 依赖了图外不存在的节点 —— 同样会导致永远不就绪，而且更隐蔽：
    /// 环至少还能在图里看出来，指向虚空的边看起来完全正常。
    public static func danglingDeps(_ nodes: [WorkTask]) -> [String] {
        let ids = Set(nodes.map { $0.id })
        return Array(Set(nodes.flatMap { $0.dependsOn }).subtracting(ids)).sorted()
    }

    /// 建图前的校验。返回 nil 表示可以入库。
    public static func validate(_ nodes: [WorkTask]) -> String? {
        if nodes.isEmpty { return "图里一个节点都没有" }
        let dangling = danglingDeps(nodes)
        if !dangling.isEmpty {
            return "依赖了不存在的节点：" + dangling.joined(separator: "、")
        }
        let cyc = cycles(nodes)
        if !cyc.isEmpty {
            return "依赖成环：" + cyc.joined(separator: " → ")
                + "。有环的图不会报错，只会全体不动，所以直接拒绝建图。"
        }
        return nil
    }

    // MARK: - 阻塞传播

    /// 上游转 blocked 之后，下游要跟着冻结。
    ///
    /// 不处理的话它们会一直躺在 queued 里等一个永远不会 done 的上游 ——
    /// 那正是刚修好的那个死锁，只是换到了图这一层。
    ///
    /// **只传播 blocked，不传播 failed。** 失败允许换个平台重试，
    /// 重试成功下游就能跑；而 blocked 是在等人，人处理完上游会重新触发，
    /// 下游自然解冻。
    public static func propagateBlocked(_ all: [WorkTask]) -> [WorkTask] {
        var byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = true
        var touched: [String: WorkTask] = [:]
        while changed {
            changed = false
            for t in byID.values where t.state == .queued {
                guard let upstream = t.dependsOn.first(where: {
                    byID[$0]?.state == .blocked
                }), let up = byID[upstream] else { continue }
                var x = t
                x.state = .blocked
                x.note = "上游 \(up.stepTitle ?? String(up.id.prefix(8))) 在等人处理"
                byID[t.id] = x
                touched[t.id] = x
                changed = true
            }
        }
        return touched.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - 上下文

    /// 给某个节点拼一段「前情提要」。
    ///
    /// 换了平台的 agent 对前面发生了什么一无所知 —— 这正是「上下文丢失」
    /// 在图这一层的样子。所以每个节点的 briefing 都要带上：
    /// 这张图要做什么、前面几步分别做了什么、**它们产出了哪些文件**。
    ///
    /// 产物那一段是「MiniMax 出图 → Qwen 用图写代码」能成立的关键：
    /// 两个 CLI 不共享会话，能交接的只有磁盘上的东西。
    public static func briefing(for node: WorkTask, in all: [WorkTask]) -> String? {
        guard node.graphID != nil else { return nil }
        let siblings = all.filter { $0.graphID == node.graphID && $0.id != node.id }
            .sorted { $0.createdAt < $1.createdAt }
        guard !siblings.isEmpty else { return nil }

        var out = ["这是一个多步任务里的一步。"]
        let done = siblings.filter { $0.state == .done }
        if done.isEmpty {
            out.append("你是第一步，前面没有人做过任何改动。")
        } else {
            out.append("前面已经完成的步骤（它们的改动已经提交在当前分支上）：")
            for d in done {
                var line = "- \(d.stepTitle ?? d.prompt.prefix(50).description)"
                if let p = d.platform { line += "（\(p.displayName) 做的）" }
                if !d.outputs.isEmpty {
                    line += "，产出：" + d.outputs.joined(separator: "、")
                }
                out.append(line)
            }
        }
        let later = siblings.filter { $0.dependsOn.contains(node.id) }
        if !later.isEmpty {
            out.append("你做完之后，下一步是："
                       + later.map { $0.stepTitle ?? "（未命名）" }.joined(separator: "、")
                       + "。**别顺手把它们也做了** —— 那会让下一步的 agent"
                       + "面对一个和描述对不上的仓库。")
        }
        return out.joined(separator: "\n")
    }
}
