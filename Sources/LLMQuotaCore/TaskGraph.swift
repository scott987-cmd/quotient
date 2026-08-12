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
            // 图内按 stepIndex 排，不靠 createdAt —— 后者编码成 ISO8601
            // 之后秒以下被抹平，同一批节点读回来时间戳完全相同，
            // 「第一步」会变成随机的哪一步。
            .sorted {
                if let a = $0.stepIndex, let b = $1.stepIndex, a != b { return a < b }
                return $0.createdAt < $1.createdAt
            }
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

    /// 根据上游状态，把下游该冻的冻上、该解的解开。
    ///
    /// ## 为什么是「对账」而不是「传播」
    ///
    /// 第一版只做单向传播：上游 blocked 就冻结下游。审查指出两个洞，
    /// 而且两个都会导致**整张图永久死掉**：
    ///
    /// 1. **没有解冻路径。** 人在手机上放行了上游，下游还冻着 ——
    ///    没有任何代码会把它放回队列。
    /// 2. **上游 failed 时下游根本不被冻。** 它们停在 queued，
    ///    而 `isReady` 要求上游 `.done`，于是永远不就绪、也永远没有 note ——
    ///    从任何界面看都像「还没轮到它」。同时储备池看见 queued > 0
    ///    就拒绝生成新活，「一个跑不了的任务堵死整条流水线」
    ///    这个修过一次的故障在图这层原样复现。
    ///
    /// 单向传播补不出解冻，所以改成每轮重新对账：下游状态**由上游推导**，
    /// 冻和解走同一段逻辑，不可能只实现一半。
    ///
    /// 判据是 `frozenBy` 而不是 `.blocked`：人工闸门拦下的 blocked 也是
    /// blocked，但那是在等人做决定 —— 解冻逻辑碰它就等于替人放行。
    public static func reconcile(_ all: [WorkTask]) -> [WorkTask] {
        var byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var touched: [String: WorkTask] = [:]
        var changed = true

        while changed {
            changed = false
            for t in byID.values {
                // 谁挡着它。上游 blocked（等人）或 failed（跑挂了，且没有任何
                // 重试路径会自动把它推回 queued）都算挡着。
                let blocker = t.dependsOn.first {
                    let st = byID[$0]?.state
                    return st == .blocked || st == .failed
                }

                if t.state == .queued, let b = blocker, let up = byID[b] {
                    var x = t
                    x.state = .blocked
                    x.frozenBy = b
                    let why = up.state == .failed ? "失败了" : "在等人处理"
                    x.note = "上游「\(up.stepTitle ?? String(up.id.suffix(2)))」\(why)，"
                        + "这一步先冻住。上游恢复后会自动解冻。"
                    byID[t.id] = x; touched[t.id] = x; changed = true
                    continue
                }

                // 解冻：只解我们自己冻的（frozenBy 非空），而且挡路的已经让开。
                if t.state == .blocked, t.frozenBy != nil, blocker == nil {
                    var x = t
                    x.state = .queued
                    x.frozenBy = nil
                    x.note = "上游恢复了，重新排队"
                    byID[t.id] = x; touched[t.id] = x; changed = true
                }
            }
        }
        return touched.values.sorted {
            ($0.stepIndex ?? 0, $0.createdAt) < ($1.stepIndex ?? 0, $1.createdAt)
        }
    }

    /// 旧名字，保留给已有调用点。
    @available(*, deprecated, renamed: "reconcile")
    public static func propagateBlocked(_ all: [WorkTask]) -> [WorkTask] {
        reconcile(all)
    }

    // MARK: - 完成

    /// 这张图跑完了吗 —— 所有节点都到终态，且**至少有一个真的做成了**。
    ///
    /// 「至少一个 done」这条不能省：全部 failed / 全部被丢弃的图，分支上
    /// 一个提交都没有，把它当「完成」送去合并，review 那边会得到一个空 diff，
    /// 然后按「无改动」丢掉 —— 中间那几步日志会让人以为产出被吃了。
    public static func isComplete(graphID: String, in all: [WorkTask]) -> Bool {
        let nodes = all.filter { $0.graphID == graphID }
        guard !nodes.isEmpty else { return false }
        guard nodes.allSatisfy({ $0.state == .done || $0.state == .failed }) else {
            return false
        }
        return nodes.contains { $0.state == .done }
    }

    /// 图里还没到终态的节点数。给日志用 —— 「还差 2 步」比「没完成」有用。
    public static func remaining(graphID: String, in all: [WorkTask]) -> Int {
        all.filter {
            $0.graphID == graphID && $0.state != .done && $0.state != .failed
        }.count
    }

    /// 所有已经跑完、可以送审的图。
    public static func completeGraphs(_ all: [WorkTask]) -> [String] {
        Array(Set(all.compactMap { $0.graphID })
            .filter { isComplete(graphID: $0, in: all) }).sorted()
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
