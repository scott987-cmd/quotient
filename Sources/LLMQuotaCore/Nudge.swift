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

    /// 撤回本轮“准备发送”的账。只删同 key、正文和时间戳的最后一条，
    /// 不碰更早的真实投递历史。
    static func forgetFailedAttempt(_ key: String, body: String?, now: Date) {
        var h = history()
        guard let i = h.lastIndex(where: {
            $0.key == key && $0.body == body && abs($0.at.timeIntervalSince(now)) < 2
        }) else { return }
        h.remove(at: i)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(h).write(to: path)
    }

    /// 现在有什么值得打扰人的。**每条都对应一个待决事项。**
    /// `tasks` 可注入，只为让测试能造出「搁浅」这种状态 ——
    /// 它是靠多个任务的组合才成立的，不注入就没法在测试里表达。
    public static func pending(now: Date = Date(),
                               tasks: [WorkTask] = TaskStore.all(),
                               publishedAsks: [Ask]? = nil,
                               progressByTaskID: [String: WorkProgress]? = nil)
    -> [(key: String, kind: Push.Kind, body: String, badge: Int)] {
        var out: [(String, Push.Kind, String, Int)] = []

        // 0. **长任务到 20 分钟仍没有可核验里程碑。**
        //
        // 这不是让老板审批，也不能因此换掉有上下文的 owner；它只是兑现移动端
        // “20 分钟巡检”的承诺。badge 固定为 0：这是状态提醒，不是待办，不能再
        // 制造一个点进去找不到审批项的未读数字。
        let runningIDs = Set(tasks.filter { $0.state == .running }.map(\.id))
        let progress = progressByTaskID
            ?? WorkProgressStore.latestByTaskID(taskIDs: runningIDs)
        let stalled = WorkProgressSentinel.inspect(tasks, progressByTaskID: progress, now: now)
        if let first = stalled.first,
           let task = tasks.first(where: { $0.id == first.taskID }) {
            let body = stalled.count == 1
                ? "20 分钟巡检：\(TaskBrief.title(for: task).prefix(30)) 已 \(first.minutesWithoutProgress) 分钟无可证明进展"
                : "20 分钟巡检：\(stalled.count) 个运行中任务没有新的可证明进展"
            out.append(("progress-stalled-\(first.taskID)", .trouble, body, 0))
        }

        // 0. **agent / 调度器真的在等你回答。**
        //
        // 问题文件早就会出现在手机「问题」页，但之前完全没进提醒清单：
        // 人只有主动打开 App 才知道有人在等，等于这条提问通道没有通知。
        // 同时不能只扫 iCloud 文件 —— 任务人工结束后可能残留旧文件；必须
        // 和本机任务当前挂着的 pendingAsk 对上，且仍是 blocked，才算活问题。
        // approval 由下面的 blocked 卡片提醒，避免同一件高危放行弹两次。
        let visibleAsks = publishedAsks ?? AskStore.pending(machine: Paths.machineID())
        let visibleIDs = Set(visibleAsks.map(\.id))
        let questions = tasks.compactMap { task -> Ask? in
            guard task.state == .blocked,
                  let ask = task.pendingAsk,
                  ask.kind == .question,
                  visibleIDs.contains(ask.id) else { return nil }
            return ask
        }
        if !questions.isEmpty {
            let body: String
            if questions.count == 1 {
                let who = questions[0].platform?.displayName ?? "Agent"
                body = "\(who) 有问题等你回答："
                    + String((questions[0].questions.first?.text
                              ?? questions[0].taskPrompt).prefix(42))
            } else {
                body = "\(questions.count) 个问题等你回答，任务正在等你"
            }
            out.append(("question-\(questions.count)-\(questions.first?.id ?? "")",
                        .needsYou, body, questions.count))
        }

        // 1. **做出来的东西等你看。** 排在最前面 —— 这是老板最想被打扰的
        // 那件事(2026-08-22 原话:「关键成果产出需要找我确认」),
        // 而其余几条都是「出问题了」。带录屏的成果落地即入列,见 Milestone。
        // 成果现在并入现有动态验收页，手机能看证据，也能直接表态。
        // 不再用空数组关闭提醒：那会让记录、页面和通知三条链互相矛盾。
        let fresh = Milestone.unreviewed()
        if !fresh.isEmpty {
            let body: String
            if fresh.count == 1 {
                let evidence = Review.evidenceSummary(fresh[0].evidenceFiles)
                    ?? "可视证据"
                body = "新成果:\(fresh[0].subject.prefix(28)) —— \(evidence)已就绪,你看一眼"
            } else {
                body = "\(fresh.count) 件新成果做好了,截图/录屏已就绪,等你看"
            }
            out.append(("milestone-\(fresh.count)-\(fresh.last?.mergeSHA ?? "")",
                        .needsYou, body, fresh.count))
        }

        // 0.5 **做出来的东西被机器毙了 —— 这个必须让人知道。**
        //
        // 2026-08-22 凌晨:Bot AI(90 条测试全绿 + 交战录屏)和枪声混音
        // 双双被评审 agent 判不合入,而一票否决是终局 —— 产线卡了一夜,
        // 老板问「任务为啥又停了」才发现。成果被推给他看,成果被毙了
        // 却悄无声息,这不对称是错的。
        // **只数手机页面上真有的。** 这条规矩下面第 2 段写过一遍,我又犯了:
        // rejectedWithEvidence 自己跑一遍本地仓库算数,而手机读的是已发布的
        // reviews.json —— 2026-08-22 早老板点进推送,页面空的。
        // 数据源只能有一个:已发布的那份。
        let published = Review.publishedDigests()
        let killed = Review.publishedRejectedWithEvidence(published)
        if !killed.isEmpty {
            let body = killed.count == 1
                ? "「\(killed[0].subject.prefix(24))」被评审判了不合入 —— 你看看该不该翻案"
                : "\(killed.count) 件带录屏的产出被评审判了不合入,等你定夺"
            out.append(("rejected-\(killed.count)-\(killed.first?.branch ?? "")",
                        .needsYou, body, killed.count))
        }

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
        let awaiting = published
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
        // 口径必须和 blockedPage 一份(ViewFeed.awaitsBoss):归架构师处置的
        // 技术拦截不算「等你放行」,不然角标有数、页面没卡片。
        let blocked = tasks.filter { ViewFeed.awaitsBoss($0) }
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
        // **搁浅归 Claude,不推老板。**
        //
        // 上面那段理由(搁浅的活会整条躺一天没人知道)照旧成立,但**喊给谁**
        // 变了:老板 2026-08-22 的常设指示是「阻塞任务你来看处理,
        // 给我应该就是风险类或者验收类」。任务链搁浅是纯技术问题。
        //
        // 而且它一直没有对应的页面 —— 推送说「一条任务链卡住了」,
        // 他点进去是空的(2026-08-22 晚他第二次报这个)。
        // 现在它出现在 `llmq work blocked` 里,归我处置。

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
    /// 这条推送指向的页面上有东西可点吗。
    ///
    /// key 的前缀就是页面名(`review-3` → review 页),和菜单里的
    /// `badge(prefix)` 是同一套约定。认不出页面的(比如额度类提醒,
    /// 它落在原生看板上)一律放行 —— 这道闸只拦「明确指向某一页、
    /// 而那一页是空的」这种。
    static func targetPage(for key: String) -> String? {
        switch category(of: key) {
        case "milestone", "review", "rejected": return "review"
        case "blocked": return "blocked"
        case "playbook": return "playbook"
        default: return nil
        }
    }

    static func hasSomethingToShow(key: String, root: URL = Paths.sharedRoot) -> Bool {
        guard let page = targetPage(for: key) else { return true }
        guard let p = ViewFeed.published(page: page, root: root) else { return false }
        return p.sections.contains { !($0.cards ?? []).isEmpty }
    }

    /// 推送发出去前，手机实际读取的 iCloud 页面必须已经包含本机刚发布的卡片，
    /// 而且卡片引用的证据文件也已经到云端。只看本机页面会制造一个竞态：
    /// 横幅秒到，镜像还要几十秒，人点进去只能看到旧页或空页。
    static func mobileContentReady(key: String,
                                   localRoot: URL = Paths.sharedRoot,
                                   mobileRoot: URL = Push.mirrorDir) -> Bool {
        guard let page = targetPage(for: key) else { return true }
        guard let local = ViewFeed.published(page: page, root: localRoot),
              let mobile = ViewFeed.published(
                page: page, root: mobileRoot, read: { ICloudSafe.read($0) })
        else { return false }

        let allLocalCards = local.sections.flatMap { $0.cards ?? [] }
        let localCards: [ViewFeed.Card]
        if category(of: key) == "milestone",
           let mergeSHA = key.split(separator: "-").last.map(String.init) {
            localCards = allLocalCards.filter { $0.id.hasSuffix("|" + mergeSHA) }
        } else {
            localCards = allLocalCards
        }
        guard !localCards.isEmpty else { return false }
        let mobileCards = Dictionary(
            mobile.sections.flatMap { $0.cards ?? [] }.map { ($0.id, $0) },
            uniquingKeysWith: { newer, _ in newer })
        let evidence = mobileRoot.appendingPathComponent("evidence", isDirectory: true)
        for card in localCards {
            guard let mirrored = mobileCards[card.id],
                  Set(card.images).isSubset(of: Set(mirrored.images))
            else { return false }
            for image in card.images where
                !ICloudSafe.isRegularFile(evidence.appendingPathComponent(image)) {
                return false
            }
        }
        return true
    }

    /// 每条横幅都必须携带**全部**真实待办数。
    ///
    /// APNs 的 badge 是覆盖，不是累加。若两类待办各有 1 条，而横幅分别带 1，
    /// 最后一条会把刚同步好的总数 2 又覆盖回 1。把这段做成纯函数，测试可以
    /// 直接钉住「所有横幅都带总数」这个协议。
    static func notificationBadges(
        for items: [(key: String, kind: Push.Kind, body: String, badge: Int)]
    ) -> [Int] {
        let total = items.reduce(0) { $0 + $1.badge }
        return Array(repeating: total, count: items.count)
    }

    /// 先占去重位，避免网络已投递但进程在记账前被终止时反复轰炸；如果发送端
    /// 明确返回 0（缺配置、签名失败或所有设备被 APNs 拒绝），再撤回本轮占位，
    /// 让下一轮在配置恢复后补发。
    static func deliver(key: String, kind: Push.Kind, body: String, badge: Int,
                        now: Date,
                        contentReady: ((String) -> Bool)? = nil,
                        send: (Push.Kind, String, Int) -> Int) -> Bool {
        guard !recentlySent(key, body: body, now: now) else { return false }
        let ready = contentReady ?? { hasSomethingToShow(key: $0) }
        guard ready(key) else { return false }
        remember(key, body: body, now: now)
        guard send(kind, body, badge) > 0 else {
            forgetFailedAttempt(key, body: body, now: now)
            return false
        }
        return true
    }

    public static func run(now: Date = Date(), synchronizeBadge: Bool = true) -> Int {
        let items = pending(now: now)
        let notificationBadges = notificationBadges(for: items)
        let totalBadge = notificationBadges.first ?? 0
        // **角标要跟真实待办数同步，哪怕这一轮什么都不推。**
        //
        // 角标是持久的：设成 94 之后就一直挂着，而新推送被限流挡住时
        // 没人去改它。人盯着 94 找不到对应的东西，这个数就成了噪音。
        // 静默推送不响不弹，只把数字改对。
        if synchronizeBadge { Push.syncBadge(totalBadge) }

        var sent = 0
        for (item, appBadge) in zip(items, notificationBadges) {
            if deliver(key: item.key, kind: item.kind, body: item.body,
                       badge: appBadge, now: now,
                       contentReady: { mobileContentReady(key: $0) },
                       send: { Push.send($0, body: $1, badge: $2,
                                         page: targetPage(for: item.key)) }) {
                sent += 1
            }
        }
        return sent
    }
}
