import Foundation

/// 什么时候该打扰人。
///
/// ## 为什么单独一个类型
///
/// 推送本身（`Push`）只管「怎么发」。**发不发是另一个问题**，而且是
/// 更难的那个：通知一多人就关掉，关掉之后等于回到「一次都收不到」的原点。
///
/// 老板点名要被打扰的四件事：新项目的方案、对外发布、产出验收、碰钱和账号。
/// 共同点是**它们都需要一个决定**，而不是「有事发生了」。
/// 所以这里的规则只有一条：**没有待决事项就不发**。
/// 「跑完了 3 个任务」不发，「有 3 份产出等你验收」才发。
public enum Nudge {

    /// 同类通知的最短间隔。人一天看几次手机，不需要每 30 秒被提醒一次
    /// 「还有 3 份待验收」—— 那和没通知是一样的效果（都会被忽略）。
    public static let quietFor: TimeInterval = 2 * 3600

    struct Sent: Codable {
        var key: String
        var at: Date
        /// 上次发出去的**正文指纹**。老记录没有这个字段 → nil。
        var body: String?
    }

    /// 内容没变化时，最久多久提一次。
    ///
    /// `quietFor`（2 小时）管的是「同类别别刷屏」，但它有个前提假设：
    /// 过了 2 小时情况就变了。**在一个人还没处理的待办上，这个假设是错的**
    /// —— 内容一模一样的提醒每 2 小时来一次，就是骚扰。
    ///
    /// 老板的原话（2026-08-17）：「出问题了，一直发消息，而且是重复发」。
    /// 实测 stranded-graph 一条消息发了 8 次，最近 4 次内容完全相同。
    ///
    /// 所以规则改成**变了才响**：正文和上次一字不差就不发，
    /// 只留这条兜底 —— 一天一次，保证一个持续存在的问题不会被彻底忘掉。
    public static let repeatSameAfter: TimeInterval = 24 * 3600

    static var path: URL {
        Paths.appSupport.appendingPathComponent("nudges.json")
    }

    static func history() -> [Sent] {
        guard let d = try? Data(contentsOf: path) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Sent].self, from: d)) ?? []
    }

    /// 这条通知最近发过没有。
    ///
    /// **按类别限流，key 里不能带数量。**
    ///
    /// 第一版让 key 带上数量（`review-92`），想法是「从 2 份变 3 份是新情况，
    /// 值得再响」。但在一个数字持续增长的场景里，每变一次就是一个新 key ——
    /// 限流形同虚设，实测连着推了 review-92 / 93 / 94。
    /// 数量变化写在正文里就够了，不该成为再响一次的理由。
    /// - Parameter body: 这次要发的正文。传了就做**内容比对** ——
    ///   和上次一字不差的，24 小时内一律不发（见 `repeatSameAfter`）。
    public static func recentlySent(_ key: String, body: String? = nil,
                                    now: Date = Date()) -> Bool {
        let cat = category(of: key)
        let mine = history().filter { category(of: $0.key) == cat }
        // ① 同类别刷屏闸
        if mine.contains(where: { now.timeIntervalSince($0.at) < quietFor }) {
            return true
        }
        // ② 内容没变闸：正文一字不差 → 24 小时内不再响。
        //    没有 body（老调用方）或历史里没记正文 → 退回只用 ①，
        //    行为和以前一致，不会因为缺数据而变得更吵。
        if let body, mine.contains(where: {
            $0.body == body && now.timeIntervalSince($0.at) < repeatSameAfter
        }) {
            return true
        }
        return false
    }

    /// 通知类别。`review-92` → `review`。
    static func category(of key: String) -> String {
        key.split(separator: "-").first.map(String.init) ?? key
    }

    static func remember(_ key: String, body: String? = nil,
                         now: Date = Date()) {
        // 留 48 小时：内容比对窗口是 24 小时，只留 24 小时的话，
        // 边界上那条刚好被清掉，于是「没变化」判不出来又响一次。
        var h = history().filter { now.timeIntervalSince($0.at) < 48 * 3600 }
        h.append(Sent(key: key, at: now, body: body))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(h).write(to: path)
    }

    /// 现在有什么值得打扰人的。**每条都对应一个待决事项。**
    /// `tasks` 可注入，只为让测试能造出「搁浅」这种状态 ——
    /// 它是靠多个任务的组合才成立的，不注入就没法在测试里表达。
    public static func pending(now: Date = Date(),
                               tasks: [WorkTask] = TaskStore.all())
    -> [(key: String, kind: Push.Kind, body: String, badge: Int)] {
        var out: [(String, Push.Kind, String, Int)] = []

        // 1. 新项目的方案等过目
        let unapproved = Playbook.all().filter { !$0.isApproved }
        if !unapproved.isEmpty {
            out.append(("playbook-\(unapproved.count)", .needsYou,
                        unapproved.count == 1
                            ? "「\(unapproved[0].name)」的方案等你过目"
                            : "\(unapproved.count) 个项目方案等你过目",
                        unapproved.count))
        }

        // 2. 产出等验收
        //
        // **必须问 git，不能只看任务状态。** 第一版判据是
        // 「done + 没丢弃 + 有分支」—— 那把历史上所有完成过的任务都算了进来，
        // 包括早就合入 main 的。实测推出去一条「92 份产出等你验收」，
        // 而 `llmq work review` 同时说「没有待审的 agent 分支」。
        // 一个假的 92 比不推更糟：人点开发现什么都没有，下次就不信这个数了。
        // **扣掉已经表过态的。** 人点了合入/丢弃之后，Mac 端可能还没执行完，
        // 或者执行失败了（比如合并冲突）—— 这两种情况那个分支都还在
        // Review.list 里。不扣的话就是「反复提醒人去做他已经做过的事」，
        // 而他打开一看列表是空的（App 端会过滤），于是这个数字彻底失信。
        // **推送必须和手机页面读同一份数据。**
        //
        // 原来这里自己跑一遍 Review.list 算「有几条待审」，而手机页面读的是
        // 已发布的 reviews.json —— 两份数据**在多机环境下必然不一致**：
        // 每台机器看得见的仓库不一样，各算各的。
        //
        // 实测（老板的原话「移动端老是弹出一个消息，但是点进去看里面又没有」）：
        // Mac mini 算出 1 条并推送，MacBook 上没有那两个游戏仓库、算出 0 条，
        // 页面被它清空 —— 于是消息弹了，点进去是空的。
        //
        // 现在直接读已发布的那份：**推送里说的数，就是人点进去能看到的数**。
        // 数据源只有一个，就不会有两套算法打架。
        let awaiting = Review.publishedDigests()
        // **只推「人一眼能看出成败」的那些，其余一律不打扰。**
        //
        // 老板的原话：「验收任务发给我的，怎么还有一堆合代码的，
        // 不是说过我只看人可阅读验证的成功，比如游戏截图、运行结果」。
        //
        // 这条批评是对的，而且指向的是**推送的框架本身错了**：
        // 「N 份产出等你验收」是一个「要不要合这条分支」的问题，
        // 而判断它要读 diff、要自己下场跑一遍 —— 那是这套系统里最贵的动作，
        // 把它推给人等于系统没干活。
        //
        // 所以分成两类：
        // - **交了证据的**（截图 / 录屏 / 实跑输出）→ 推给人，看图判断，
        //   问的是「手感对不对」，不是「代码合不合」；
        // - **没交证据的** → 不推。它要么该由机器自己验收合入（autoland），
        //   要么该派回给 agent 去跑一遍交图（EvidenceGate）。
        //   让人替 agent 补跑截图，是把成本装反了。
        let showable = awaiting.filter { !$0.evidence.isEmpty }
        if !showable.isEmpty {
            out.append(("review-\(showable.count)", .needsYou,
                        showable.count == 1
                            ? "1 份产出跑出来了，看图判断：" + showable[0].subject.prefix(34)
                            : "\(showable.count) 份产出跑出来了，看图判断",
                        showable.count))
        }

        // 3. 有活被拦下来等放行（高危 / 碰钱 / 碰账号）
        //
        // **必须排掉 frozenBy 那些。** blocked 有两种含义完全相反的来源：
        // 人工闸门拦下的（等人做决定）和上游失败连带冻结的
        //（等上游自愈，任务说明里就写着「上游恢复后会自动解冻」）。
        // 不分开的话，推送会喊人去「放行」两个根本不需要他做任何事的任务，
        // 而 App 里连操作入口都没有 —— 老板的原话是「还是能收到虚假的
        // 审批任务」。WorkTask.frozenBy 早就是为了区分这两者而存在的，
        // 这里漏用了。
        let blocked = tasks.filter { $0.state == .blocked && $0.frozenBy == nil }
        if !blocked.isEmpty {
            out.append(("blocked-\(blocked.count)", .needsYou,
                        "\(blocked.count) 个任务被拦下等你放行", blocked.count))
        }

        // 4. 有任务图搁浅了 —— 跑挂一步，剩下的不会自己恢复
        //
        // **这类东西原来一个字都不喊。** 上面第 3 条特意排掉了 frozenBy
        // 那些（「上游恢复后会自动解冻」），可上游要是 failed，
        // 根本没有任何东西会让它恢复 —— 于是这些任务既不进推送，
        // 分支也进不了待验收名单，彻底沉默。
        //
        // Greed 的 f2872114 完成了 4 步、19 个文件的产出（AudioManager、
        // 存档层、主菜单外壳），第 5 步挂了就整条躺了一整天，
        // 是人手工翻 git branch 才发现的。
        //
        // 搁浅和「等上游自愈」是两回事：后者该闭嘴，前者必须喊。
        let strands = TaskGraph.stranded(tasks)
        if !strands.isEmpty {
            let salvageable = strands.filter { $0.doneCount > 0 }
            let body = salvageable.count == 1
                ? "一条任务链卡住了，已完成 \(salvageable[0].doneCount) 步的产出还没落地"
                : "\(strands.count) 条任务链卡住了，跑挂一步就再也不会自己恢复"
            out.append(("stranded-graph", .needsYou, body, strands.count))
        }

        return out
    }

    /// 额度要浪费了 —— 空窗找不到活可干的时候才喊。
    ///
    /// 找到活自动填掉了就不用打扰人，那正是系统该自己解决的事。
    /// **喊的是「我没辙了」，不是「我在干活」。**
    /// **不再推送，只记账。**
    ///
    /// 这条原来会弹通知。实测 24 小时弹了 5 次，而它报的是一个
    /// **系统自己已经认可的状态**：储备池收紧之后的策略就是
    /// 「没有真需求就老实闲着」——「宁可闲着」和「闲着要报警」
    /// 是自相矛盾的两条规矩。
    ///
    /// 而且人收到之后能做的唯一动作是「想个活给它干」——
    /// 那是把工作推给人，正是这套系统存在的意义的反面。
    ///
    /// 空窗率该出现在**日报的一个数字**里（趋势有意义），
    /// 不该是一次打断（单点没意义）。所以这里只落盘，
    /// 由 `idleLog()` 供日报读。
    public static func nothingToFill(platform: Platform, reason: String,
                                     now: Date = Date()) {
        var log = idleLog().filter { now.timeIntervalSince($0.at) < 7 * 24 * 3600 }
        log.append(Idle(platform: platform.rawValue, reason: reason, at: now))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(log).write(to: idlePath)
    }

    /// 一次「有窗口但没活干」的记录。
    public struct Idle: Codable, Sendable {
        public var platform: String
        public var reason: String
        public var at: Date
    }

    static var idlePath: URL {
        Paths.appSupport.appendingPathComponent("idle-log.json")
    }

    /// 最近七天的空窗记录，给日报用。
    public static func idleLog() -> [Idle] {
        guard let d = try? Data(contentsOf: idlePath) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Idle].self, from: d)) ?? []
    }

    /// 跑一遍：该发的发掉。
    ///
    /// - Returns: 实际发出去的条数。
    @discardableResult
    public static func run(now: Date = Date()) -> Int {
        let items = pending(now: now)
        // **角标要跟真实待办数同步，哪怕这一轮什么都不推。**
        //
        // 角标是持久的：设成 94 之后就一直挂着，而新推送被限流挡住时
        // 没人去改它。人盯着 94 找不到对应的东西，这个数就成了噪音。
        // 静默推送不响不弹，只把数字改对。
        Push.syncBadge(items.reduce(0) { $0 + $1.badge })

        var sent = 0
        for item in items {
            guard !recentlySent(item.key, body: item.body, now: now) else { continue }
            guard Push.send(item.kind, body: item.body, badge: item.badge) > 0 else { continue }
            remember(item.key, body: item.body, now: now)
            sent += 1
        }
        return sent
    }
}
