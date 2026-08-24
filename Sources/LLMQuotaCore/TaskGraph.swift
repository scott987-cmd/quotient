// TaskGraph.swift —— 多步任务的依赖图。
//
// 解决的问题：调度最初的模型是「一个任务 = 一段字符串，一次性打分选人」，
// 表达不了三件真实发生的事 —— 任务里只有一小步高危（却整体被拦死）、
// 贵活和便宜活混在一个包里（只能整包给一个平台）、跨厂商协作
// （两个 CLI 不共享会话，只能靠产物交接）。这些都需要节点和边，所以有了图。
// 本文件提供就绪判定、环/悬空依赖检测、阻塞对账、跨节点上下文拼接。
// 各设计决定的完整理由见下方 TaskGraph 的文档注释。

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

    public struct Owner: Sendable, Equatable {
        public var platform: Platform
        public var runnerID: String
        public var assignedAt: Date

        public init(platform: Platform, runnerID: String, assignedAt: Date) {
            self.platform = platform
            self.runnerID = runnerID
            self.assignedAt = assignedAt
        }
    }

    /// 同一张图只在同能力泳道继承 owner。媒体、评审、编码之间仍通过磁盘产物交接，
    /// 不伪装成能共享会话。
    public static func inheritedOwner(for task: WorkTask, in all: [WorkTask]) -> Owner? {
        guard let graphID = task.graphID else { return nil }
        let lane = TaskCapabilityLane.classify(task.prompt)
        return all.lazy
            .filter {
                $0.id != task.id && $0.graphID == graphID
                    && TaskCapabilityLane.classify($0.prompt) == lane
                    && $0.ownerPlatform != nil && $0.ownerRunnerID != nil
            }
            .sorted {
                let a = $0.ownerAssignedAt ?? $0.createdAt
                let b = $1.ownerAssignedAt ?? $1.createdAt
                if a != b { return a > b }
                return ($0.stepIndex ?? 0) > ($1.stepIndex ?? 0)
            }
            .first
            .flatMap { item in
                guard let platform = item.ownerPlatform,
                      let runnerID = item.ownerRunnerID else { return nil }
                return Owner(platform: platform, runnerID: runnerID,
                             assignedAt: item.ownerAssignedAt ?? item.createdAt)
            }
    }

    // MARK: - 就绪

    /// 这个节点现在能不能开跑。
    ///
    /// 判据是上游 `.done` 而不是 `landedAt != nil`：图内节点共用一个分支，
    /// 后一步是在前一步的提交上继续干，不需要等整张图合进 main。
    /// 落地是整张图完成之后的事。
    public static func isReady(_ t: WorkTask, in all: [WorkTask]) -> Bool {
        guard t.state == .queued else { return false }
        // 即使某条旧路径把 fan-out 手工改回 queued，派发前仍要重新核样板。
        guard GoldenSampleGate.blockReason(for: t, in: all) == nil else { return false }
        guard !t.dependsOn.isEmpty else { return true }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return t.dependsOn.allSatisfy { upstreamCleared(byID[$0]) }
    }

    /// 上游算不算「让开了」。
    ///
    /// **不能只认 `state == .done`。** 丢弃在这套系统里把状态置成 `.failed`
    /// （见 cmdDiscard），于是丢掉一个上游之后，下游的依赖永远满足不了：
    /// 它停在 `queued` 但 `isReady` 恒为假 —— 表现是**看得见却永远不跑**，
    /// 而且两处计数会互相矛盾（`brief` 数 queued 说「排队 2」，
    /// `readyQueue` 用 isReady 说「没有排队中的任务」）。
    ///
    /// 实况（2026-08-17）：Greed 两条图的上游步骤要做的事都已由人工合并
    /// 落地，把上游丢弃之后，剩下两步真验收就卡在这个状态 ——
    /// 队列里看得见，永远不会被派。
    ///
    /// 上一轮修冻结那条路（`blocker` 判定）时认了 `discardedAt`，
    /// 但**就绪这条路漏了**。同一件事两套判据，必须用同一个函数，
    /// 否则下次改一处又会分叉。
    static func upstreamCleared(_ up: WorkTask?) -> Bool {
        guard let up else { return false }        // 上游记录没了：不放行
        if up.discardedAt != nil { return true }  // 明确处置过了 —— 让开
        guard up.state == .done else { return false }

        // **「done 但一个文件都没改」不算干完了。**
        //
        // 图里的步骤是首尾相接的：s2 的提示词写着「依据上一步产出的
        // `reviews/privacy-api-audit.md`」。上一步零产出，那个文件就不存在，
        // s2 只能对着空气干活 —— 它也零产出，然后 s3、s4 接着空跑。
        //
        // 实测（2026-08-18）：Greed 隐私清单那张图**四步全跑完、全零产出**，
        // 烧掉 262 + 159 + 52 + 40 秒，产出一个文件都没有。
        // 而外面看起来每一步都是「完成」。
        //
        // **上游零产出,不冻死下游 —— 放它试跑。**
        //
        // 老板 2026-08-23 的头发图给出反例并纠正了原判据:s1 零产出(它是
        // 准备/空转步),但 s2 **不真依赖 s1 的产物**,自己就把 gen-hair.py、
        // 6 个发型、眉毛睫毛全写出来了。原来这里「上游零产出就不放行」把能
        // 独立干活的 s2 冻死,还害我把整条真成果误判成空跑作废掉(22 个文件
        // 差点白毁)。
        //
        // 系统在 s2 跑之前**无法知道**它依不依赖 s1 的产物文件 —— 那就该
        // 乐观放行让它试,而不是悲观冻死等人介入(老板最烦这个)。赌错的代价
        // 不对称:放行赌错 = 下游也零产出、多跑一步,由「整图零产出」的事后
        // 检测兜底(见 stranded);冻死赌错 = 能干的活被卡住、要人来救。
        //
        // 原来担心的 Greed「四步全零产出空烧」由**整图**零产出识别兜底,
        // 不该靠**单步**零产出冻死下游 —— 后者误伤面太大。
        return true
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
                let ap = RepoExecutionPolicy.queuePriority($0)
                let bp = RepoExecutionPolicy.queuePriority($1)
                if ap != bp { return ap < bp }
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
                // **丢弃过的上游不算挡着。**
                //
                // 丢弃在这套系统里把状态置成 .failed（见 cmdDiscard），
                // 而这里判「挡着」的条件是 blocked || failed —— 于是
                // **丢弃一个上游步骤，下游永远解不开**：丢弃之后的对账
                // 看到的还是 failed，照旧冻住，而且 note 还写着
                // 「上游恢复后会自动解冻」。
                //
                // 实况（2026-08-17）：Greed 两条图的上游步骤要做的事都已经
                // 由人工合并落地了，把上游丢弃之后，剩下两步真验收仍然冻着，
                // 谁也不会去动它们。
                //
                // 丢弃 ≠ 失败。失败是「没干成」，丢弃是「有人明确处置过了」——
                // 后者该放下游走，前提到底还成不成立由派活前的
                // PremiseCheck / BaselineFreshness 去判，不该在这儿一刀切。
                // 判据和 isReady 共用 upstreamCleared —— 两处分叉过一次，
                // 代价是任务「看得见却永远不跑」，不能再来一遍。
                let blocker = t.dependsOn.first {
                    guard let up = byID[$0], !upstreamCleared(up) else { return false }
                    return up.state == .blocked || up.state == .failed
                }

                if t.state == .queued, let b = blocker, let up = byID[b] {
                    var x = t
                    x.state = .blocked
                    x.frozenBy = b
                    // **两种上游状态的后果完全不同，不能说同一句话。**
                    //
                    // 上游 blocked（在等人 / 等重试）→ 它真的可能恢复，
                    // 「等着」是对的。
                    // 上游 failed → **没有任何东西会让它恢复**。这时候还写
                    // 「上游恢复后会自动解冻」是句假话，而且是最坏的那种假话：
                    // 它让日报、推送、任务列表全都显示成「在正常等待」，
                    // 于是这条图能躺一整天没人发现（Greed 的 f2872114 就是）。
                    //
                    // 说实话的版本要同时告诉人**接下来会发生什么** ——
                    // 已完成步骤的产出会走搁浅落地（Review.autoLand 认搁浅图），
                    // 所以人不需要动手，但也不该以为它还在跑。
                    let up0 = byID[b]
                    if up0?.state == .failed {
                        x.note = "上游「\(up.stepTitle ?? String(up.id.suffix(2)))」失败了，"
                            + "这一步冻住。**上游不会自己恢复** —— "
                            + "已完成步骤的产出会按搁浅图单独走审核和落地。"
                    } else {
                        x.note = "上游「\(up.stepTitle ?? String(up.id.suffix(2)))」在等人处理，"
                            + "这一步先冻住。上游恢复后会自动解冻。"
                    }
                    byID[t.id] = x; touched[t.id] = x; changed = true
                    continue
                }

                // **已经冻住的，note 要跟着上游状态刷新。**
                //
                // 原来只在 queued→blocked 那一刻写 note，所以上游从 blocked
                // 变成 failed 之后，下游还挂着旧那句「上游恢复后会自动解冻」——
                // 而那时候它已经是假话了。实测这 5 条冻了一整天，
                // 日报里一直显示成「在正常等待」。
                if t.state == .blocked, t.frozenBy != nil, let b = blocker,
                   let up = byID[b] {
                    let fresh = up.state == .failed
                        ? "上游「\(up.stepTitle ?? String(up.id.suffix(2)))」失败了，"
                            + "这一步冻住。**上游不会自己恢复** —— "
                            + "已完成步骤的产出会按搁浅图单独走审核和落地。"
                        : "上游「\(up.stepTitle ?? String(up.id.suffix(2)))」在等人处理，"
                            + "这一步先冻住。上游恢复后会自动解冻。"
                    if t.note != fresh {
                        var x = t
                        x.note = fresh
                        byID[t.id] = x; touched[t.id] = x; changed = true
                        continue
                    }
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
        // 生产质量闸和图依赖共用同一条“每轮对账”入口，避免新增一种 blocked
        // 却漏掉 retry / done / worker 启动等恢复路径。
        for task in GoldenSampleGate.reconcile(Array(byID.values)) {
            byID[task.id] = task
            touched[task.id] = task
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
        // **「已经做完」不等于「state == .done」。**
        //
        // 一个步骤可能是被丢弃的，而丢弃的理由恰恰是「这活已经由别的路径
        // 做完了」（人工合入、别的任务顺手做了、上游 agent 一并做了）。
        // 那种步骤的改动**真实存在于仓库里**，只是这条任务记录被关掉了。
        //
        // 只认 .done 的后果实测过：Greed 的 3f68707cs5 拿到的上下文是
        // 「你是第一步，前面没有人做过任何改动」—— 而 s2/s3/s4
        //（两个持久化开关、SettingsView、设置入口）全都已经在 main 上。
        // agent 照这个上下文干，就会把已经有的东西重做一遍。
        // 这正是「为啥已经在了还重复执行」的更深一层。
        let settled = siblings.filter {
            $0.state == .done || $0.discardedAt != nil
        }
        if settled.isEmpty {
            out.append("你是第一步，前面没有人做过任何改动。")
        } else {
            out.append("前面已经了结的步骤（它们的改动已经在仓库里，别重做）：")
            for d in settled {
                var line = "- \(d.stepTitle ?? d.prompt.prefix(50).description)"
                if let p = d.platform { line += "（\(p.displayName) 做的）" }
                if !d.outputs.isEmpty {
                    line += "，产出：" + d.outputs.joined(separator: "、")
                }
                // 丢弃的要说清是怎么了结的 —— agent 需要知道这活是**别人**
                // 做的（所以别重做），还是**真的没做**（那它可能得补）。
                if d.discardedAt != nil {
                    let why = d.discardReason ?? "已处置"
                    line += "（这一步的记录已关闭：" + why.prefix(90) + "）"
                }
                out.append(line)
            }
            out.append("**上面这些一律不要重做。** 如果你发现其中某一项其实"
                       + "并不在仓库里，说出来，不要默默替它补 —— "
                       + "那会让这一步的产出和它的描述对不上。")
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

// MARK: - 搁浅

public extension TaskGraph {

    /// 一张搁浅的图：跑挂了一步，剩下的全冻着，而且**不会有任何东西
    /// 把它推回去**。
    struct Stranded: Sendable {
        public var graphID: String
        /// 挂掉的那些步骤。
        public var failedTitles: [String]
        /// 被它冻住的步骤数。
        public var frozenCount: Int
        /// 完成了几步 —— 决定这条分支上有多少产出值得捞。
        public var doneCount: Int
        public var repo: String
        public var branch: String { "agent/graph/" + graphID }
    }

    /// 哪些图已经搁浅了。
    ///
    /// ## 为什么必须单独有这个概念
    ///
    /// 一步失败之后，`reconcile` 会把下游冻成 blocked —— 这是对的。
    /// 问题在于**没有任何东西会把那个 failed 推回 queued**（reconcile
    /// 自己的注释就写着这句），于是下游永远冻着。
    ///
    /// 而 `Review.list` 把「图里还有 blocked 节点」当成「图还在跑」，
    /// 直接跳过这条分支。三件事连起来就是一条完整的静默死亡链：
    ///
    ///     一步失败 → 下游 blocked → 整图算「还没跑完」
    ///     → 分支进不了待审名单 → 手机上永远看不见
    ///
    /// 实际代价（2026-08-16 的 Greed）：f2872114 的 s1–s4 全部完成，
    /// 产出 AudioManager、存档层、主菜单外壳共 19 个文件，s5 挂了，
    /// 于是整条分支躺了一整天，没有任何界面提过一个字。
    /// 是我手工翻 `git branch` 才发现的。
    ///
    /// **搁浅和「还在跑」必须分开。** 还在跑的不该打扰人；
    /// 搁浅的必须让人看见 —— 它已经不会自己好了。
    static func stranded(_ tasks: [WorkTask] = TaskStore.all()) -> [Stranded] {
        let graphs = Dictionary(grouping: tasks.compactMap { t -> (String, WorkTask)? in
            guard let g = t.graphID else { return nil }
            return (g, t)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        return graphs.compactMap { gid, steps -> Stranded? in
            // 还有活在动 → 不算搁浅，别打扰
            if steps.contains(where: { $0.state == .queued || $0.state == .running }) {
                return nil
            }
            // 没有挂掉的步骤 → 要么全完成，要么在等人，都不是搁浅。
            //
            // **丢弃的不算挂掉。** 丢弃把状态置成 .failed，而丢弃的含义是
            // 「有人明确处置过了」—— 处置完的图不是搁浅的图。
            //
            // 不排掉的后果实测过（2026-08-17，老板的原话「一直发消息，
            // 而且是重复发」）：Greed 两条图的失败步骤**全部**是丢弃的
            //（2/2 和 3/3），冻住的已经清零，可 stranded 照旧把它们算成搁浅，
            // 于是「任务链卡住了」这条推送每两小时来一次，永远停不下来。
            //
            // 判据用 upstreamCleared 的同一套语义 —— 这已经是这个概念的
            // 第四个判定点了（isReady / reconcile 的 blocker / briefing /
            // 这里），前三个上一轮统一过，这里漏了。
            let failed = steps.filter {
                $0.state == .failed && $0.discardedAt == nil
            }
            // **整张图全跑完却一个文件都没产出 = 空转,要提醒。**
            //
            // 不再靠「单步零产出冻死下游」(那条误伤能独立干活的下游,
            // 见 upstreamCleared 的头发反例)。改成事后看整图:所有步骤都
            // 结束了、没有一步在排/在跑,而**全部 done 步加起来 changedFiles
            // 也是 0** —— 这才是 Greed 那种「四步全空烧」的真空转,该被看见。
            // 单步零产出 + 下游有产出(头发)不命中这条,正常放过。
            let allEnded = !steps.contains { $0.state == .queued || $0.state == .running }
            let doneSteps = steps.filter { $0.state == .done }
            let totalOutput = doneSteps.reduce(0) { $0 + ($1.changedFiles ?? 0) }
            let idleGraph = allEnded && !doneSteps.isEmpty && totalOutput == 0
                && doneSteps.allSatisfy { $0.changedFiles != nil }   // 有记录才敢判
            guard !failed.isEmpty || idleGraph else { return nil }
            // **等人的不算搁浅。** frozenBy == nil 的 blocked 是人工闸门
            // 拦下的，人一放行就继续 —— 那是在等决定，不是卡死。
            let frozen = steps.filter { $0.state == .blocked && $0.frozenBy != nil }
            let waitingOnHuman = steps.contains {
                $0.state == .blocked && $0.frozenBy == nil
            }
            if waitingOnHuman { return nil }
            // 一步都没冻住、也没完成任何步骤 —— 那就是一张全挂的图，
            // 分支上没东西可捞，走失败重试那条路，不占「搁浅」这个名额。
            let done = steps.filter { $0.state == .done }
            guard !frozen.isEmpty || !done.isEmpty else { return nil }

            return Stranded(
                graphID: gid,
                failedTitles: failed.map { $0.stepTitle ?? String($0.id.suffix(2)) },
                frozenCount: frozen.count,
                doneCount: done.count,
                repo: steps.first?.repo ?? "")
        }.sorted { $0.doneCount > $1.doneCount }   // 产出多的排前面，最该先捞
    }
}
