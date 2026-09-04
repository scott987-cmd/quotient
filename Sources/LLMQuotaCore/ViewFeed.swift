import Foundation

/// 下发给手机的「这一页显示什么」。
///
/// ## 为什么要有这层
///
/// iOS App 上架之后，改一个字、调一个排序、加一条提示都要走一遍审核。
/// 而这套系统的判断逻辑变得很快 —— 一天之内就改过三次「什么算待验收」。
/// 让客户端跟着这些认知一起发版是不现实的。
///
/// 所以：**Mac 端算什么该显示、怎么排、写什么文案；App 只负责画出来。**
/// App 不需要知道「什么是待验收」，它只需要知道「这是一组进度条，
/// 第二条是警告色」。
///
/// 设计取舍写在 `docs/服务端驱动.md`。这里只强调最要紧的一条：
///
/// **未知的区块类型必须被跳过，不是解码失败。** 这是整个方案能成立的
/// 前提 —— 只要老客户端遇到新 kind 会静静跳过，服务端就可以先发新东西。
/// 反之，服务端就被客户端的版本锁死了。
public enum ViewFeed {

    /// 结构版本。**只在做出破坏性改变时才加** ——
    /// 加字段、加 kind 都不算破坏性（客户端会忽略不认识的）。
    public static let schema = 1

    public struct Page: Codable, Sendable {
        public var schema: Int
        public var page: String
        public var generatedAt: Date
        public var sections: [Section]

        public init(page: String, sections: [Section], now: Date = Date()) {
            self.schema = ViewFeed.schema
            self.page = page
            self.generatedAt = now
            self.sections = sections
        }
    }

    /// 语气。**不是颜色** —— 颜色由客户端按自己的主题决定，
    /// 服务端只说这条是「好消息/该注意/出事了」。
    /// 直接下发颜色会让 App 的深浅色主题失效。
    public enum Tone: String, Codable, Sendable {
        case neutral, good, warn, danger
    }

    public struct Action: Codable, Sendable {
        /// 动作标识。**App 不理解它的含义**，只负责原样写回。
        /// 形如 `review:merge:/path|branch`、`playbook:approve:id`。
        /// 加一种新动作不用动 App。
        public var id: String
        public var label: String
        /// primary / normal / destructive。样式，不是行为。
        public var style: String
        /// 需要人补一句话（丢弃理由这类）。
        public var needsNote: Bool

        public init(id: String, label: String,
                    style: String = "normal", needsNote: Bool = false) {
            self.id = id; self.label = label
            self.style = style; self.needsNote = needsNote
        }
    }

    public struct Meter: Codable, Sendable {
        public var label: String
        /// 0…1。超出范围由客户端夹紧 —— 服务端算错不该让界面炸掉。
        public var fraction: Double
        public var tone: Tone
        /// 右侧那行小字（「35 分钟后清零」）。
        public var right: String?

        public init(label: String, fraction: Double,
                    tone: Tone = .neutral, right: String? = nil) {
            self.label = label; self.fraction = fraction
            self.tone = tone; self.right = right
        }
    }

    public struct Card: Codable, Sendable {
        public var id: String
        public var title: String
        public var body: String?
        /// 展开后才显示的详情。收起时不占地方。
        public var detail: String?
        public var tone: Tone
        /// SF Symbols 名字。客户端认不出就用默认图标。
        public var icon: String?
        /// 右上角的小字（时间、数量）。
        public var trailing: String?
        /// 图片文件名，在共享目录的 `evidence/` 下。
        public var images: [String]
        public var actions: [Action]
        /// 结构化事件类型。老客户端忽略，新客户端据此显示“认领/提问/回复”。
        public var eventKind: String?
        /// 问答或确认所回复的事件 ID。
        public var replyTo: String?
        /// 所属任务，便于手机把同一条工作链串起来。
        public var taskID: String?

        public init(id: String, title: String, body: String? = nil,
                    detail: String? = nil, tone: Tone = .neutral,
                    icon: String? = nil, trailing: String? = nil,
                    images: [String] = [], actions: [Action] = [],
                    eventKind: String? = nil, replyTo: String? = nil,
                    taskID: String? = nil) {
            self.id = id; self.title = title; self.body = body
            self.detail = detail; self.tone = tone; self.icon = icon
            self.trailing = trailing; self.images = images; self.actions = actions
            self.eventKind = eventKind; self.replyTo = replyTo; self.taskID = taskID
        }
    }

    public struct Fact: Codable, Sendable {
        public var key: String
        public var value: String
        public var tone: Tone
        public init(key: String, value: String, tone: Tone = .neutral) {
            self.key = key; self.value = value; self.tone = tone
        }
    }

    /// 一个区块。
    ///
    /// 用「一个结构 + kind 字段」而不是 enum with associated values：
    /// enum 编码出来的 JSON 里，未知 case 会直接解码失败 —— 而我们要的
    /// 恰恰是**老客户端遇到新 kind 时静静跳过**。
    /// 所以所有可能的负载都是可选字段，客户端按 kind 取它认识的那些。
    public struct Section: Codable, Sendable {
        /// banner / meters / cards / facts / text
        public var kind: String
        public var title: String?
        public var note: String?
        public var tone: Tone
        public var text: String?
        public var meters: [Meter]?
        public var cards: [Card]?
        public var facts: [Fact]?
        public var actions: [Action]?

        public init(kind: String, title: String? = nil, note: String? = nil,
                    tone: Tone = .neutral, text: String? = nil,
                    meters: [Meter]? = nil, cards: [Card]? = nil,
                    facts: [Fact]? = nil, actions: [Action]? = nil) {
            self.kind = kind; self.title = title; self.note = note
            self.tone = tone; self.text = text
            self.meters = meters; self.cards = cards
            self.facts = facts; self.actions = actions
        }

        // 手写解码：**缺字段一律给默认值，不抛错。**
        // 老客户端读新服务端写的东西时，多出来的字段被忽略；
        // 新客户端读老服务端写的东西时，缺的字段有默认值。
        // 两个方向都不能失败 —— 这正是跨版本演进的全部要求。
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            tone = (try? c.decodeIfPresent(Tone.self, forKey: .tone)) ?? .neutral
            text = try c.decodeIfPresent(String.self, forKey: .text)
            meters = try c.decodeIfPresent([Meter].self, forKey: .meters)
            cards = try c.decodeIfPresent([Card].self, forKey: .cards)
            facts = try c.decodeIfPresent([Fact].self, forKey: .facts)
            actions = try c.decodeIfPresent([Action].self, forKey: .actions)
        }
    }

    // MARK: - 写出去

    static var dir: URL { dir(at: Paths.sharedRoot) }

    static func dir(at root: URL) -> URL {
        root.appendingPathComponent("views", isDirectory: true)
    }

    @discardableResult
    /// 这一页有多少条**真内容** —— 只数卡片和仪表。
    ///
    /// ## 为什么 text 不算
    ///
    /// 空状态的提示语本身就是一个 text 段：
    ///
    /// ```json
    /// { "kind": "text", "title": "没有等验收的产出",
    ///   "text": "agent 交的活都已经合入或丢弃了。" }
    /// ```
    ///
    /// 这句话**恰恰证明这一页没有内容**。把它算成内容，
    /// 「空页面不许盖掉有内容的页面」这条守卫就整个失效 ——
    /// 第一版就是这么写的，实测（2026-08-19）MacBook 照样把
    /// Mac mini 那份 3 张卡的页面盖成了这个 268 字节的提示语。
    ///
    /// banner / 标题同理：空页面上它们照样在。拿字节数或 section 数
    /// 判「有没有内容」也会被骗 —— 那份一张卡都没有的页面
    /// 仍有 2 个 section、6032 字节。
    ///
    /// 只有卡片和仪表是「这台机器真的看见了东西」的证据。
    public static func contentCount(_ page: Page) -> Int {
        page.sections.reduce(0) { n, s in
            n + (s.cards?.count ?? 0) + (s.meters?.count ?? 0)
        }
    }

    /// **空页面不许盖掉有内容的页面。**
    ///
    /// `views/` 是「只推不拉」的：每台机器整份推到 iCloud 同一路径，
    /// 后推的盖先推的。而**每台机器看得见的东西不一样** ——
    /// MacBook 上根本没有 Greed 和 Maw 两个目录，它生成的待审页
    /// 只有 268 字节、一张卡都没有，推上去就把 Mac mini 那份
    /// 3 张卡的盖掉。人看到的就是「弹了消息，点进去是空的」。
    ///
    /// 和 `Review.worthWriting` 是同一条规则，只是换了个文件 ——
    /// 上一轮只堵了 `reviews.json`，可**手机真正读的是 `views/review.json`**，
    /// 于是同一个病换个位置继续犯。
    ///
    /// 但别把「不发」做成「永远不发」：真要清掉最后一条时得发得出去，
    /// 否则已经合掉的分支会永远挂在手机上。判据是**本机自己上一份**
    /// 有没有内容 —— views 只推不拉，本地那份就是本机最后写出去的东西。
    public static func worthPublishing(_ page: Page, over previous: Page?) -> Bool {
        // roadmap 已是单发布者的三机汇总；空状态/读取失败也必须持续更新时间。
        if page.page == "roadmap" { return true }
        if contentCount(page) > 0 { return true }   // 自己有内容 —— 照常发
        guard let previous else { return true }     // 还没有过 —— 建立初始页面
        return contentCount(previous) > 0           // 自己清空了自己 —— 该发
    }

    /// 读回已经发出去的那一页 —— 推送前要拿它核对「点进去有没有东西」。
    public static func published(
        page: String, root: URL = Paths.sharedRoot,
        read: ((URL) -> Data?)? = nil
    ) -> Page? {
        let url = dir(at: root).appendingPathComponent(page + ".json")
        let data: Data?
        if let read { data = read(url) }
        else { data = try? Data(contentsOf: url) }
        guard let d = data else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Page.self, from: d)
    }

    public static func publish(_ page: Page, root: URL = Paths.sharedRoot) -> Bool {
        var page = page
        let machineID = Paths.machineID()
        func routed(_ actions: [Action]) -> [Action] {
            actions.compactMap { action in
                guard let id = MobileAction.scoped(action.id, machineID: machineID) else { return nil }
                var copy = action; copy.id = id; return copy
            }
        }
        page.sections = page.sections.map { section in
            var copy = section
            copy.actions = section.actions.map(routed)
            copy.cards = section.cards?.map { card in
                var copy = card; copy.actions = routed(card.actions); return copy
            }
            return copy
        }
        let scopedName = NotificationDetail.sourcePage(page.page, machineID: Paths.machineID())
        if scopedName != page.page {
            var scoped = page; scoped.page = scopedName
            let label = ClusterConfigStore.load()?.nodeName ?? String(Paths.machineID().prefix(8))
            scoped.sections = page.sections.map { section in
                var copy = section
                copy.title = label + " · " + (section.title ?? "事项")
                return copy
            }
            guard publishSingle(scoped, root: root) else { return false }
        }
        return publishSingle(page, root: root)
    }

    private static func publishSingle(_ page: Page, root: URL) -> Bool {
        let dir = dir(at: root)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(page.page + ".json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let previous = (try? Data(contentsOf: url))
            .flatMap { try? dec.decode(Page.self, from: $0) }
        // 跳过不算失败：这一页本来就没有任何要说的。
        guard worthPublishing(page, over: previous) else { return true }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let d = try? enc.encode(page) else { return false }
        return ICloudSafe.write(d, to: url)
    }

    // MARK: - 收动作

    /// 手机点了动作之后写来的东西。
    public struct Invocation: Codable, Sendable {
        public var id: String
        /// 新手机每次点击生成一个。缺失时按旧版 id+at 兼容。
        public var invocationID: String?
        public var at: Date
        public var device: String?
        public var note: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            invocationID = try c.decodeIfPresent(String.self, forKey: .invocationID)
            at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
            device = try c.decodeIfPresent(String.self, forKey: .device)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }

        public var key: String {
            if let invocationID, !invocationID.isEmpty { return "invocation@" + invocationID }
            return id + "@" + ISO8601DateFormatter().string(from: at)
        }
    }

    static var actionsDir: URL {
        Paths.sharedRoot.appendingPathComponent("actions", isDirectory: true)
    }

    /// 收手机点过的动作。
    ///
    /// **不删文件**（和 approvals 一样的理由：双向同步下删了会被拉回来），
    /// 靠 `.done` 记已执行的。
    ///
    /// ## 失败必须收口，不能无限重试
    ///
    /// 这里原来写的是「执行失败不记 —— 下一轮会重试」。想法没错
    ///（网络抖一下不该让人白点一次），错在**没有上限**。
    ///
    /// 实况（2026-08-17，老板的原话「已经到构建 38 了」）：
    /// 手机上点了合入 `agent/codex/74c79d4b`，那条分支和 main 有冲突、
    /// 永远合不上。于是循环每转一圈就重试一次，**每次都跑一遍 Maw 的
    /// 全量 Xcode 构建** —— 从 10:36 一直重试到 18:0x，日志里数出 380 次。
    ///
    /// 一个必然失败的动作，重试一次和重试三百八十次得到的信息一样多，
    /// 而后者把机器烧了七个小时。所以：**失败也要收口**，
    /// 记下试了几次、最后为什么失败，让人看得见。
    public static func pendingInvocations() -> [Invocation] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: actionsDir.path)
        else { return [] }
        let done = Set((try? String(
            contentsOf: actionsDir.appendingPathComponent(".done"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
        var out: [Invocation] = []
        for n in names.sorted() where n.hasSuffix(".json") && !n.hasPrefix(".") {
            guard let inv = SafeDecode.json(
                at: actionsDir.appendingPathComponent(n), as: Invocation.self),
                  !inv.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if let route = MobileAction.route(inv.id) {
                let machineID = Paths.machineID()
                guard route.scope == MobileAction.digest(machineID),
                      !MobileAction.hasTerminalReceipt(for: inv, machineID: machineID)
                else { continue }
            } else if done.contains(inv.key) { continue }
            out.append(inv)
        }
        return out
    }

    /// 记一个动作已经执行成功。**只有成功才记** ——
    /// 失败留着下一轮重试，这是从「验收结论悄悄失败」那次事故里学到的。
    /// 一个动作最多试几次。
    ///
    /// 3 次：够扛住网络抖动、iCloud 还没同步完这类真·瞬时故障，
    /// 又不至于让一个必然失败的动作把机器烧掉。
    ///
    /// 上限的存在本身比数字重要 —— 没有上限时，
    /// 「合不上的分支」和「烧七个小时」之间没有任何东西挡着。
    public static let maxAttempts = 3

    static var failuresFile: URL {
        actionsDir.appendingPathComponent(".failures.json")
    }

    static func failureCounts() -> [String: Int] {
        guard let d = try? Data(contentsOf: failuresFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: d)) ?? [:]
    }

    /// 记一次失败。返回**这个动作已经失败了几次**。
    ///
    /// key 用 id + 时间戳：同一个动作人点两次是两条，各自计数 ——
    /// 人重点一次的意思就是「再试一轮」，不该被上一条的计数拖累。
    @discardableResult
    public static func recordFailure(_ inv: Invocation, reason: String) -> Int {
        var m = failureCounts()
        let key = inv.key
        let n = (m[key] ?? 0) + 1
        m[key] = n
        // 只留最近 200 条，和 .done 一个道理：这是防重试的账，不是审计日志。
        if m.count > 200 {
            m = Dictionary(uniqueKeysWithValues: m.sorted { $0.key < $1.key }
                .suffix(200).map { ($0.key, $0.value) })
        }
        if let d = try? JSONEncoder().encode(m) {
            _ = ICloudSafe.write(d, to: failuresFile)
        }
        return n
    }

    /// 试够了没有。够了就该收口，别再重试。
    public static func exhausted(_ inv: Invocation) -> Bool {
        return (failureCounts()[inv.key] ?? 0) >= maxAttempts
    }

    public static func markDone(_ inv: Invocation) {
        let f = actionsDir.appendingPathComponent(".done")
        let key = inv.key
        // **写之前紧挨着重读一次。**
        //
        // 这是「读 → 改 → 写」，本身已经是合并语义，但**两台机器并发时
        // 照样会丢**：A 读完 → B 写入 → A 再写，B 那次就被盖掉了。
        // 而这个文件在 iCloud 上，mac-mini 和 macbook-pro-intel
        // 两边都在跑 llmq work loop（实测两边都有进程）。
        //
        // 丢一条收口记录的后果不是「少记一笔」，是**那个动作复活并永远重试**
        // —— 实测同一条合并重试了 380 次、每次跑一遍全量构建。
        // 窗口缩到最小挡不住全部竞争，但能把绝大多数消掉；
        // 真正的根治是别让两台机器抢同一个文件，那是另一件事。
        var lines = Set((try? String(contentsOf: f, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])
        guard !lines.contains(key) else { return }
        lines.insert(key)
        // 只留最近 500 条：这个文件只用来防重复执行，不是审计日志。
        let keep = lines.sorted().suffix(500)
        try? keep.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    }
}

// MARK: - 组装「现在」页

extension ViewFeed {
    /// 「现在」页：按**在漏什么**排，不按平台罗列。
    ///
    /// 这些判断以前都在客户端：哪条算「在漏」、怎么排序、写什么提示语。
    /// 搬到这里之后，改它们不需要重新上架 —— 这正是这一层存在的理由。
    public static func nowPage(dashboard: Dashboard = LLMQuota.dashboard(),
                               now: Date = Date()) -> Page {
        var sections: [Section] = []

        // 快过期又没用够的窗口。排序规则在这里，不在客户端。
        let leaking = dashboard.reports
            .flatMap { r in r.statuses.map { (r.platform, $0) } }
            .filter { _, s in
                guard s.isFresh(now: now),
                      let f = s.usedFraction, let reset = s.resetsAt else { return false }
                return f < 0.5 && reset.timeIntervalSince(now) < 12 * 3600
            }
            .sorted { a, b in
                // 越快过期、用得越少的排越前 —— 那是最接近作废的
                let ra = a.1.resetsAt?.timeIntervalSince(now) ?? .infinity
                let rb = b.1.resetsAt?.timeIntervalSince(now) ?? .infinity
                return ra < rb
            }
            .prefix(6)

        if !leaking.isEmpty {
            sections.append(Section(
                kind: "meters",
                title: "在漏的",
                note: "快过期了还没用够的窗口，最接近作废的排最前",
                meters: leaking.map { platform, s in
                    let left = s.resetsAt.map { Format.duration($0.timeIntervalSince(now)) }
                    return Meter(
                        label: platform.displayName + " · " + s.label,
                        fraction: s.usedFraction ?? 0,
                        tone: (s.usedFraction ?? 0) < 0.2 ? .warn : .neutral,
                        right: left.map { $0 + "后清零" })
                }))
        }

        // 等验收的产出
        let awaiting = Review.publishDigests()
        if !awaiting.isEmpty {
            sections.append(Section(
                kind: "cards",
                title: "等你验收",
                note: "\(awaiting.count) 份产出跑完了在等你",
                cards: awaiting.prefix(5).map { d in
                    Card(id: d.repo + "|" + d.branch,
                         title: d.subject,
                         body: d.platform + " · " + "\(d.files.count) 个文件"
                             + " · +\(d.insertions)/−\(d.deletions)"
                             + (d.landingBlockReason.map { " · " + $0 } ?? ""),
                         detail: d.prompt,
                         tone: d.mergesCleanly && d.landingBlockReason == nil ? .neutral : .warn,
                         icon: d.mergesCleanly && d.landingBlockReason == nil
                             ? "checkmark.seal" : "exclamationmark.triangle",
                         trailing: Review.evidenceSummary(d.evidenceFiles),
                         images: d.evidenceFiles,
                         actions: d.mergesCleanly && d.landingBlockReason == nil
                             ? [Action(id: "review:merge:" + d.actionResource,
                                       label: "合入", style: "primary"),
                                Action(id: "review:discard:" + d.actionResource,
                                       label: Review.rejectionLabel(branch: d.branch),
                                       style: "destructive", needsNote: true)]
                             : [Action(id: "review:discard:" + d.actionResource,
                                       label: Review.rejectionLabel(branch: d.branch),
                                       style: "destructive", needsNote: true)])
                }))
        }

        if sections.isEmpty {
            sections.append(Section(
                kind: "text", title: "没有要你做的事",
                tone: .good,
                text: "没有额度在连续空窗，也没有产出等着验收。"))
        }
        return Page(page: "now", sections: sections, now: now)
    }
}

// MARK: - 看板页

extension ViewFeed {
    /// 看板：各平台窗口 + 任务吞吐 + 机器心跳。
    ///
    /// 排序规则（「最该看」）在这里，不在客户端 ——
    /// 以前改一次排序就要重新上架。
    public static func boardPage(dashboard: Dashboard = LLMQuota.dashboard(),
                                 now: Date = Date()) -> Page {
        var sections: [Section] = []

        // 机器心跳。超过两轮采集没到就算掉线 —— 一轮可能只是 iCloud 慢了半拍。
        let stale: TimeInterval = 30 * 60
        let machines = dashboard.machines
        if !machines.isEmpty {
            sections.append(Section(
                kind: "facts", title: "机器心跳",
                facts: machines.map { m in
                    let age = now.timeIntervalSince(m.lastSeen)
                    return Fact(key: m.displayName,
                                value: Format.duration(age) + "前",
                                tone: age > stale ? .warn : .good)
                }))
        }

        // 额度事实、估算、未知和冷却是四层不同的东西，不能再塞进一组仪表。
        let all = dashboard.reports.flatMap { r in r.statuses.map { (r.platform, $0) } }
        let ranked = all.sorted { a, b in
            func rank(_ s: QuotaStatus) -> Int {
                if s.health == .exhausted { return 0 }
                if s.health == .wasting { return 1 }
                if s.health == .atRisk { return 2 }
                return 3
            }
            if rank(a.1) != rank(b.1) { return rank(a.1) < rank(b.1) }
            return (a.1.resetsAt ?? .distantFuture) < (b.1.resetsAt ?? .distantFuture)
        }

        func meters(_ rows: [(Platform, QuotaStatus)]) -> [Meter] {
            rows.prefix(10).compactMap { platform, s in
                guard s.isFresh(now: now), let fraction = s.usedFraction else { return nil }
                var detail: [String] = []
                if let remaining = s.remaining {
                    detail.append("剩 " + Format.compact(remaining))
                }
                if let observedAt = s.observedAt {
                    detail.append("观测于 " + Format.relative(observedAt, now: now))
                }
                if let reset = s.resetsAt {
                    detail.append(Format.duration(reset.timeIntervalSince(now)) + "后重置")
                }
                if let expiry = s.expiresAt, expiry != s.resetsAt {
                    detail.append(Format.duration(expiry.timeIntervalSince(now)) + "后失效")
                }
                return Meter(
                    label: platform.displayName + " · " + s.label,
                    fraction: fraction,
                    tone: s.health == .exhausted ? .danger
                        : (s.health == .wasting || s.health == .atRisk ? .warn : .good),
                    right: detail.isEmpty ? nil : detail.joined(separator: " · "))
            }
        }

        let facts = meters(ranked.filter { $0.1.sourceKind == .officialFact })
        if !facts.isEmpty {
            sections.append(Section(
                kind: "meters", title: "额度事实",
                note: "平台直接回报；每条都带观测时间和失效时间",
                meters: facts))
        }

        let estimates = meters(ranked.filter { $0.1.sourceKind == .localEstimate })
        if !estimates.isEmpty {
            sections.append(Section(
                kind: "meters", title: "额度估算",
                note: "由本地日志和已配置上限推算，不冒充平台事实",
                meters: estimates))
        }

        let unknown = ranked.filter {
            !$0.1.isFresh(now: now) || $0.1.usedFraction == nil
        }
        if !unknown.isEmpty {
            sections.append(Section(
                kind: "facts", title: "额度未知",
                note: "未知不会按 0% 或可用展示",
                facts: unknown.prefix(10).map { platform, s in
                    Fact(
                        key: platform.displayName + " · " + s.label,
                        value: s.isFresh(now: now) ? s.sourceNote : "数据已过期",
                        tone: .warn)
                }))
        }

        let cooldowns = dashboard.reports.compactMap { report -> Fact? in
            guard let until = report.cooldownUntil, until > now else { return nil }
            return Fact(
                key: report.platform.displayName,
                value: (report.cooldownReason ?? "冷却中") + " · "
                    + Format.duration(until.timeIntervalSince(now)) + "后重试",
                tone: .warn)
        }
        if !cooldowns.isEmpty {
            sections.append(Section(
                kind: "facts", title: "调度冷却",
                note: "服务拒绝/认证/环境事实；不伪造成额度百分比",
                facts: cooldowns))
        }

        // 任务吞吐
        let tasks = TaskStore.all()
        let day = tasks.filter { now.timeIntervalSince($0.createdAt) < 86400 }
        sections.append(Section(
            kind: "facts", title: "24 小时",
            facts: [
                Fact(key: "跑完", value: "\(day.filter { $0.state == .done }.count)",
                     tone: .good),
                Fact(key: "失败", value: "\(day.filter { $0.state == .failed }.count)",
                     tone: day.contains { $0.state == .failed } ? .warn : .neutral),
                Fact(key: "在跑", value: "\(tasks.filter { $0.state == .running }.count)"),
                Fact(key: "排队", value: "\(tasks.filter { $0.state == .queued }.count)"),
            ]))

        return Page(page: "board", sections: sections, now: now)
    }
}

// MARK: - 动态入口

extension ViewFeed {
    /// 「更多」页的入口列表。
    ///
    /// ## 为什么这个比迁页面更值钱
    ///
    /// 迁一个已有页面，省下的是「改那一页要发版」。
    /// 而下发入口列表省下的是**「加一个全新功能要发版」** ——
    /// Mac 端加一个 `views/新东西.json`，在这里加一个入口指过去，
    /// 手机上就多了一页，客户端一行都不用改。
    ///
    /// 代价是客户端要有一个「按 page 名字渲染任意一页」的通用路由，
    /// 那正是 FeedView 已经做到的事。
    public struct MenuEntry: Codable, Sendable {
        public var page: String
        public var title: String
        /// SF Symbols。认不出就用默认图标。
        public var icon: String?
        /// 右边那个数字。**服务端算好** —— 以前是客户端自己数的。
        public var badge: Int?
        /// 分组标题。同一个 group 的排在一起。
        public var group: String?

        public init(page: String, title: String, icon: String? = nil,
                    badge: Int? = nil, group: String? = nil) {
            self.page = page; self.title = title
            self.icon = icon; self.badge = badge; self.group = group
        }
    }

    public struct Menu: Codable, Sendable {
        public var schema: Int
        public var generatedAt: Date
        public var entries: [MenuEntry]

        public init(entries: [MenuEntry], now: Date = Date()) {
            self.schema = ViewFeed.schema
            self.generatedAt = now
            self.entries = entries
        }
    }

    @discardableResult
    public static func publishMenu(_ menu: Menu) -> Bool {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let d = try? enc.encode(menu) else { return false }
        return (try? d.write(to: dir.appendingPathComponent("menu.json"))) != nil
    }

    /// 当前该有哪些入口。
    ///
    /// 数字在这里算（以前是客户端数的）—— 「等你验收 2」这个 2
    /// 要跟 Nudge 的口径一致，两处各算一次迟早会对不上。
    public static func menu(now: Date = Date()) -> Menu {
        return Menu(entries: [
            // 各仓库的计划和进度 —— 老板随时能翻,不用问「还在做吗」。
            // 审批、验收和项目批准都有原生入口并集中在「现在」页；通用页面
            // 只承担低风险的只读扩展，不能再生成第二套操作流程。
            MenuEntry(page: "roadmap", title: "计划进度",
                      icon: "map", badge: nil, group: "看进展"),
            MenuEntry(page: "collaboration", title: "Agent 协作",
                      icon: "arrow.triangle.branch", badge: nil, group: "看进展"),
        ], now: now)
    }

    /// Agent 协作页。只下发显式结论/问题/证据，不暴露模型隐藏推理。
    /// 页面完全走通用渲染，已有客户端不需要发版。
    public static func collaborationPage(now: Date = Date(),
                                         tasks: [WorkTask]? = nil) -> Page {
        let all = CollaborationStore.all()
        let taskSnapshot = tasks ?? TaskStore.all()
        let tasksByID = Dictionary(uniqueKeysWithValues: taskSnapshot.map { ($0.id, $0) })
        let activeTaskIDs = Set(taskSnapshot.compactMap { task -> String? in
            guard task.pausedAt == nil, task.discardedAt == nil else { return nil }
            switch task.state {
            case .queued, .running, .blocked: return task.id
            case .done, .failed: return nil
            }
        })
        let unresolved = CollaborationStore.unresolved()
        let unresolvedIDs = Set(unresolved.map(\.id))
        // 当前看板先回答“现在谁在和谁协作”。历史失败仍留在 append-only
        // 协作账里，但不能因为发生得晚就把正在运行的任务挤出手机首屏。
        // 没有活跃任务时退回最近历史，空闲时仍然可以复盘。
        let focused = all.filter { event in
            if let taskID = event.taskID, activeTaskIDs.contains(taskID),
               let repo = tasksByID[taskID]?.repo,
               URL(fileURLWithPath: repo).standardizedFileURL.path == event.project { return true }
            return event.kind == .question && unresolvedIDs.contains(event.id)
                && event.recipientRunnerID != nil
        }
        let recent = Array((focused.isEmpty ? all : focused).suffix(30))
        let pendingIDs = unresolvedIDs.intersection(Set((focused.isEmpty ? all : focused).map(\.id)))
        let claims = recent.filter { $0.kind == .claim }.count
        func presentation(_ kind: CollaborationEvent.Kind) -> (String, String) {
            switch kind {
            case .claim: return ("主动认领", "hand.raised.fill")
            case .started: return ("开始执行", "play.fill")
            case .question: return ("提问", "questionmark.bubble.fill")
            case .answer: return ("回复", "bubble.left.and.bubble.right.fill")
            case .decision: return ("决定", "signpost.right.fill")
            case .finding: return ("发现", "lightbulb.fill")
            case .checkpoint: return ("检查点", "checkmark.circle.fill")
            case .result: return ("结果", "shippingbox.fill")
            case .handoff: return ("交接", "arrow.right.circle.fill")
            case .ack: return ("确认反馈", "checkmark.bubble.fill")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        func parent(of event: CollaborationEvent) -> CollaborationEvent? {
            guard let id = event.replyTo, let parent = byID[id],
                  parent.project == event.project, parent.taskID == event.taskID else { return nil }
            return parent
        }
        func root(of event: CollaborationEvent) -> CollaborationEvent {
            var current = event
            var visited = Set([event.id])
            while let parent = parent(of: current), !visited.contains(parent.id) {
                visited.insert(parent.id)
                current = parent
            }
            return current
        }
        func chainKey(_ event: CollaborationEvent) -> String {
            let root = root(of: event)
            if root.id != event.id || root.kind == .question {
                return "event:" + root.id
            }
            return event.taskID.map { "task:" + event.project + ":" + $0 } ?? "event:" + root.id
        }
        func newestFirst(_ lhs: [CollaborationEvent], _ rhs: [CollaborationEvent]) -> Bool {
            let left = lhs.map(\.createdAt).max() ?? .distantPast
            let right = rhs.map(\.createdAt).max() ?? .distantPast
            return left == right ? (lhs.first?.id ?? "") < (rhs.first?.id ?? "") : left > right
        }
        // 按问题限量，而不是先按事件截断：40 个新检查点也不能冲掉一组问答。
        // 普通工作链仍只取近期动作；问答单独保留最近 8 组的原题、最新答复和反馈。
        let selectedKeys = Set((focused.isEmpty ? all : focused).map(chainKey))
        let conversations = Dictionary(grouping: all, by: chainKey).filter {
            selectedKeys.contains($0.key) && $0.value.first.map { root(of: $0).kind == .question } == true
        }.values.sorted(by: newestFirst).prefix(8)
        let ordinary = Dictionary(grouping: recent, by: chainKey).values.filter {
            $0.first.map { root(of: $0).kind != .question } == true
        }.sorted(by: newestFirst).prefix(12)
        let orderedChains = (Array(conversations) + Array(ordinary)).sorted(by: newestFirst)
        func answersQuestion(_ event: CollaborationEvent, _ question: CollaborationEvent) -> Bool {
            guard event.kind == .answer, event.replyTo == question.id,
                  event.project == question.project, event.taskID == question.taskID,
                  event.senderRunnerID == question.recipientRunnerID else { return false }
            // 老记录可能没有接收者，但显式 replyTo 和答题者仍能证明这条关联。
            return event.recipientRunnerID == nil || event.recipientRunnerID == question.senderRunnerID
        }
        var agentQuestions: [CollaborationEvent] = []
        let nonAgents: Set<String> = ["human", "orchestrator"]
        for chain in conversations {
            guard let first = chain.first else { continue }
            let question = root(of: first)
            guard let recipient = question.recipientRunnerID,
                  !nonAgents.contains(question.senderRunnerID), !nonAgents.contains(recipient) else { continue }
            agentQuestions.append(question)
        }
        let answeredQuestions = agentQuestions.filter { question in
            all.contains { answersQuestion($0, question) }
        }
        func actor(_ runnerID: String) -> String {
            let lower = runnerID.lowercased()
            if lower.contains("minimax") { return "MiniMax" }
            if lower.contains("claude") { return "Claude" }
            if lower.contains("kimi") { return "Kimi" }
            if lower.contains("qwen") { return "Qwen" }
            if lower.contains("openrouter") { return "OpenRouter" }
            if lower.contains("volc") || lower.contains("glm") { return "火山 GLM" }
            if lower.contains("codex") { return "Codex" }
            if lower == "human" { return "用户" }
            if lower.contains("orchestrator") { return "调度器" }
            return runnerID
        }
        func shortTask(_ taskID: String?) -> String? {
            taskID.map { String($0.prefix(8)) }
        }
        func concise(_ raw: String) -> String {
            var value = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
            for prefix in ["主动认领：", "开始执行：", "主动认领:", "开始执行:"]
                where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count)
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.count > 80 ? String(value.prefix(77)) + "…" : value
        }
        func eventTitle(_ event: CollaborationEvent, pending: Bool) -> String {
            let sender = actor(event.senderRunnerID)
            let recipient = event.recipientRunnerID.map(actor)
            let parent = parent(of: event)
            let task = shortTask(event.taskID)
            let action: String
            switch event.kind {
            case .claim:
                if let parent {
                    action = sender + " 认领了 " + actor(parent.senderRunnerID) + " 的"
                        + presentation(parent.kind).0
                } else if let task {
                    action = sender + " 认领任务 " + task
                } else {
                    action = sender + " 主动认领"
                }
            case .started:
                action = sender + (task.map { " 开始执行任务 " + $0 } ?? " 开始执行")
            case .question:
                action = sender + (recipient.map { " 向 " + $0 + " 提问" } ?? " 提出问题")
            case .answer:
                action = sender + " 回复 "
                    + (parent.map { actor($0.senderRunnerID) } ?? recipient ?? "协作事项")
            case .finding:
                action = sender + (recipient.map { " 向 " + $0 + " 提交发现" } ?? " 发布发现")
            case .decision:
                action = sender + " 记录决定"
            case .checkpoint:
                action = sender + (task.map { " 更新任务 " + $0 + " 检查点" } ?? " 更新检查点")
            case .result:
                action = sender + (task.map { " 提交任务 " + $0 + " 结果" } ?? " 提交结果")
            case .handoff:
                action = sender + (recipient.map { " 将工作交给 " + $0 } ?? " 发起交接")
            case .ack:
                action = sender + " 反馈了 "
                    + (parent.map { actor($0.senderRunnerID) + " 的事项" } ?? "协作事项")
            }
            return (pending ? "待回应 · " : "") + action + " · " + concise(event.summary)
        }
        func chainLabel(_ event: CollaborationEvent) -> String {
            let root = root(of: event)
            if root.kind == .question { return "问题链：" + concise(root.summary) }
            if let task = shortTask(event.taskID) { return "任务链：" + task }
            return "事件链：" + presentation(root.kind).0
        }
        func owner(of task: WorkTask?) -> String? {
            guard let task else { return nil }
            if let runner = task.ownerRunnerID { return actor(runner) }
            return task.ownerPlatform?.displayName ?? task.platform?.displayName
        }
        func derivedSource(of task: WorkTask?)
            -> (actor: String, label: String)? {
            guard let origin = task?.origin else { return nil }
            let relations: [(prefix: String, label: String)] = [
                ("architect-review:", "架构复核"),
                ("technical-disposition:", "技术处置"),
                ("quality-architecture-review:", "质量架构复核"),
            ]
            guard let relation = relations.first(where: { origin.hasPrefix($0.prefix) })
            else { return nil }
            let remainder = origin.dropFirst(relation.prefix.count)
            let sourceID = String(remainder.split(separator: ":", maxSplits: 1).first ?? "")
            guard !sourceID.isEmpty else { return nil }
            let source = owner(of: tasksByID[sourceID]) ?? "任务 " + String(sourceID.prefix(8))
            return (source, relation.label + " " + String(sourceID.prefix(8)))
        }
        func failedLooking(_ event: CollaborationEvent) -> Bool {
            let value = event.summary.lowercased()
            return value.contains("额度") || value.contains("quota")
                || value.contains("exhausted") || value.contains("失败")
                || value.contains("未完成") || value.contains("timed out")
                || value.contains("超时")
        }
        func eventDirection(_ event: CollaborationEvent) -> String {
            let sender = actor(event.senderRunnerID)
            let task = event.taskID.flatMap { tasksByID[$0] }
            let source = derivedSource(of: task)?.actor ?? "调度器"
            let currentOwner = owner(of: task) ?? sender
            let parent = parent(of: event)
            let recipient = event.recipientRunnerID.map(actor)
            switch event.kind {
            case .claim:
                return "认领　" + (parent.map { actor($0.senderRunnerID) } ?? source)
                    + " → " + sender
            case .started:
                return "执行　" + sender
            case .question:
                return "提问　" + sender + " → " + (recipient ?? "待认领")
            case .answer:
                return "回复　" + sender + " → "
                    + (parent.map { actor($0.senderRunnerID) } ?? recipient ?? source)
            case .decision:
                return "决定　" + sender + " → " + (recipient ?? source)
            case .finding:
                return "发现　" + sender + " → " + (recipient ?? source)
            case .checkpoint:
                return "验证　" + sender + " → " + currentOwner
            case .result:
                return "交付　" + sender + " → " + (recipient ?? source)
            case .handoff:
                return "交接　" + sender + " → " + (recipient ?? "调度器")
            case .ack:
                return "确认　" + sender + " → "
                    + (parent.map { actor($0.senderRunnerID) } ?? recipient ?? source)
            }
        }
        let relationshipCards = orderedChains.compactMap { unordered -> Card? in
            let chain = unordered.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
            guard let first = chain.first else { return nil }
            let rootEvent = root(of: first)
            let taskID = chain.compactMap(\.taskID).first
            let task = taskID.flatMap { tasksByID[$0] }
            let claimant = chain.first(where: { $0.kind == .claim })
                .map { actor($0.senderRunnerID) }
            let currentOwner = owner(of: task) ?? claimant
                ?? actor(chain.last?.senderRunnerID ?? first.senderRunnerID)
            let sourceRelation = derivedSource(of: task)
            let source = sourceRelation?.actor ?? "调度器"
            let title: String
            if rootEvent.kind == .question {
                let asker = actor(rootEvent.senderRunnerID)
                let responder = rootEvent.recipientRunnerID.map(actor)
                    ?? chain.first(where: { $0.senderRunnerID != rootEvent.senderRunnerID })
                        .map { actor($0.senderRunnerID) }
                    ?? "待认领"
                title = asker + " ⇄ " + responder + "｜问题 · " + concise(rootEvent.summary)
            } else {
                let label = sourceRelation?.label
                    ?? taskID.map { "任务 " + String($0.prefix(8)) }
                    ?? chainLabel(first)
                title = source + " → " + currentOwner + "｜" + label
            }
            func target(for event: CollaborationEvent, fallback: String) -> String {
                event.recipientRunnerID.map(actor) ?? fallback
            }
            func relationshipLine(_ event: CollaborationEvent) -> String {
                let sender = actor(event.senderRunnerID)
                let parent = parent(of: event)
                switch event.kind {
                case .claim:
                    let from = parent.map { actor($0.senderRunnerID) } ?? source
                    return "认领　" + from + " → " + sender
                case .started:
                    return "执行　" + sender
                case .question:
                    return "提问　" + sender + " → " + target(for: event, fallback: "待认领")
                case .answer:
                    return "回复　" + sender + " → "
                        + (parent.map { actor($0.senderRunnerID) } ?? target(for: event, fallback: source))
                case .decision:
                    return "决定　" + sender + " → " + target(for: event, fallback: source)
                case .finding:
                    return "发现　" + sender + " → " + target(for: event, fallback: source)
                case .checkpoint:
                    return "验证　" + sender + " → " + currentOwner
                case .result:
                    return "交付　" + sender + " → " + target(for: event, fallback: source)
                case .handoff:
                    return "交接　" + sender + " → " + target(for: event, fallback: "调度器")
                case .ack:
                    return "确认　" + sender + " → "
                        + (parent.map { actor($0.senderRunnerID) } ?? target(for: event, fallback: source))
                }
            }
            let answer = chain.last { answersQuestion($0, rootEvent) }
            let feedback = answer.flatMap { answer in chain.last {
                $0.kind == .ack && $0.replyTo == answer.id && $0.senderRunnerID == rootEvent.senderRunnerID
            } }
            let questionChain = rootEvent.kind == .question
            var visible: [CollaborationEvent]
            if questionChain {
                visible = [rootEvent]
                if let claim = chain.last(where: { $0.kind == .claim && $0.replyTo == rootEvent.id }) {
                    visible.append(claim)
                }
                if let answer { visible.append(answer) }
                if let feedback { visible.append(feedback) }
                if answer == nil, let failure = chain.last(where: {
                    $0.id.hasPrefix("consultation-failure:") && $0.replyTo == rootEvent.id
                }) { visible.append(failure) }
            } else {
                visible = chain.count <= 6 ? chain : [chain[0]] + chain.suffix(5)
            }
            var body = visible.map(relationshipLine).joined(separator: "\n")
            // “有回答”不等于“提问方已经采用”。移动端必须把最后一跳也展示
            // 出来，否则用户只能看到 Agent 说过话，却看不出结论有没有进入实现。
            if questionChain, let answer {
                let adopter = actor(answer.recipientRunnerID ?? rootEvent.senderRunnerID)
                body += "\n采用反馈　" + (feedback != nil ? adopter + " 已确认（见详情）" : "待 " + adopter + " 确认")
            }
            let detail = (questionChain ? visible : Array(chain.suffix(10))).map { event in
                var text = Format.dateTime(event.createdAt) + "　" + relationshipLine(event)
                    + "\n" + event.summary
                if let details = event.details, !details.isEmpty { text += "\n" + details }
                if let branch = event.branch { text += "\n分支：" + branch }
                if let commit = event.commitSHA { text += "\n提交：" + commit }
                if !event.artifacts.isEmpty { text += "\n材料：" + event.artifacts.joined(separator: "、") }
                return text
            }.joined(separator: "\n\n")
            let pending = chain.contains { pendingIDs.contains($0.id) }
            let unhealthy = chain.contains(where: failedLooking)
            return Card(
                id: "chain:" + chainKey(first), title: title, body: body,
                detail: detail.isEmpty ? nil : detail,
                tone: pending || unhealthy ? .warn : .neutral,
                icon: rootEvent.kind == .question
                    ? "bubble.left.and.bubble.right.fill" : "arrow.triangle.branch",
                trailing: URL(fileURLWithPath: first.project).lastPathComponent,
                eventKind: questionChain ? "conversation" : "chain", taskID: taskID)
        }
        let registeredAgents = AgentRegistry.all(now: now)
        let presenceNames = Dictionary(uniqueKeysWithValues:
            ClusterPresenceStore.all().map { ($0.machineID, $0.displayName) })
        let agentCards = registeredAgents.map { registration in
            let fallback = Paths.privacySafeMachineLabel(
                registration.machineName, machineID: registration.machineID)
            return Card(
                id: "agent:\(registration.machineID):\(registration.runnerID)",
                title: actor(registration.runnerID),
                body: (presenceNames[registration.machineID] ?? fallback)
                    + "\n" + registration.machineID,
                detail: registration.platform.displayName + " · "
                    + (registration.canConsult ? "可接收咨询" : "仅执行任务"),
                tone: registration.canConsult ? .good : .neutral,
                icon: registration.canConsult
                    ? "bubble.left.and.bubble.right.fill" : "cpu",
                trailing: Format.dateTime(registration.updatedAt),
                eventKind: "agent")
        }
        return Page(page: "collaboration", sections: [
            Section(kind: "facts", title: "协作状态", facts: [
                Fact(key: "待回应", value: "\(pendingIDs.count)",
                     tone: pendingIDs.isEmpty ? .good : .warn),
                Fact(key: "在线 Agent", value: "\(registeredAgents.count)",
                     tone: registeredAgents.isEmpty ? .warn : .good),
                Fact(key: "工作关系", value: "\(relationshipCards.count)", tone: .neutral),
                Fact(key: "主动认领", value: "\(claims)", tone: .neutral),
                Fact(key: "Agent 互问", value: "\(agentQuestions.count)/\(answeredQuestions.count)", tone: .neutral),
                Fact(key: "最近记录", value: "\(min(recent.count, 12))", tone: .neutral),
            ]),
            Section(kind: "cards", title: "交互关系",
                    note: "问答保留最近 8 组原题、最新答复与确认反馈；工作链和单向决定不算问答",
                    cards: relationshipCards),
            Section(kind: "cards", title: "可用 Agent",
                    note: agentCards.isEmpty
                        ? "当前没有新鲜注册；不会按名字猜测接收方"
                        : "同名 Agent 按机器 ID 分开；标明谁能接收异步咨询",
                    cards: agentCards),
            Section(kind: "cards", title: "最近记录",
                    note: "关系卡的原始动作，仅保留最近 12 条",
                    cards: recent.suffix(12).reversed().map { event in
                        let repo = URL(fileURLWithPath: event.project).lastPathComponent
                        let pending = pendingIDs.contains(event.id)
                        var detail = event.details ?? ""
                        if let parent = parent(of: event) {
                            let context = "回应：" + actor(parent.senderRunnerID) + " 的"
                                + presentation(parent.kind).0 + " · " + concise(parent.summary)
                            detail = context + (detail.isEmpty ? "" : "\n" + detail)
                        }
                        if let branch = event.branch { detail += "\n分支：" + branch }
                        if let sha = event.commitSHA { detail += "\n提交：" + sha }
                        if !event.artifacts.isEmpty {
                            detail += "\n材料：" + event.artifacts.joined(separator: "、")
                        }
                        if detail.count > 1_200 { detail = String(detail.prefix(1_197)) + "…" }
                        let display = presentation(event.kind)
                        return Card(
                            id: event.id,
                            title: eventTitle(event, pending: pending),
                            body: chainLabel(event) + "\n" + eventDirection(event),
                            detail: detail.isEmpty ? nil : detail,
                            tone: pending || failedLooking(event) ? .warn
                                : (event.kind == .result ? .good : .neutral),
                            icon: pending ? "bubble.left.and.exclamationmark.bubble.right"
                                : display.1,
                            trailing: repo,
                            images: event.artifacts.filter(EvidenceGate.isEvidenceFile),
                            eventKind: event.kind.rawValue,
                            replyTo: event.replyTo,
                            taskID: event.taskID)
                    })
        ], now: now)
    }

    /// 验收页（走通用渲染，不再需要客户端专门实现）。
    /// **被拦下等人放行的高危任务。**
    ///
    /// 老板 2026-08-22:「刚刚高危拦截,我确认了,但是手机端一直在重复
    /// 弹出来让我确认」。查下来是**推送要求了一个手机做不到的动作**:
    /// 通知说「1 个任务被拦下等你放行」,而 App 那边只把 blocked 当成
    /// 一个计数显示(「卡住 N 件」),没有任何按钮会写出放行指令 ——
    /// 于是他点了也没用,任务永远卡着,提醒永远在。
    ///
    /// 和成果推送那次一模一样的形状:**别推人做不到的事**。
    /// 修法也一样 —— 把动作补上,而不是把提醒关掉。
    /// 客户端不用改:它把服务端发来的 action id 原样回写。
    ///
    /// 只列**真要他拍板**的:碰了签名/密钥/发布/付费这类风险配置的。
    ///
    /// 老板 2026-08-22 常设指示:「阻塞任务,你来看处理,这种问题都你来处理,
    /// 给我应该就是风险类或者验收类」。碰构建脚本、工具链这类纯技术拦截
    /// 归架构师(记成「等架构师处置」),不进这一页 —— 见 BossGate。
    ///
    /// 上游没完成而冻住的那些也不列 —— 人对它们无事可做,上游一好就自动解冻。
    /// 「等老板放行」的**唯一判定**。角标(Nudge)、推送、这一页三处共用。
    ///
    /// 契约评审实锤(2026-08-23):Nudge 数的是 `blocked && frozenBy == nil`(含
    /// 「等架构师处置」的技术拦截),这一页只列 note 含「等你确认」的 —— 角标
    /// 「等你放行 1」点进去是空页、长期不消,看起来像「确认了还在弹」。
    public static func awaitsBoss(_ t: WorkTask) -> Bool {
        t.state == .blocked && t.frozenBy == nil && (t.note ?? "").contains("等你确认")
    }

    public static func blockedPage(now: Date = Date(),
                                   tasks: [WorkTask] = TaskStore.all()) -> Page {
        var latest: [String: WorkTask] = [:]
        for t in tasks { latest[t.id] = t }
        let waiting = latest.values
            .filter { awaitsBoss($0) }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        guard !waiting.isEmpty else {
            return Page(page: "blocked", sections: [
                Section(kind: "text", title: "没有等你放行的", tone: .good,
                        text: "碰高危路径的改动都已经处理过了。")
            ], now: now)
        }
        return Page(page: "blocked", sections: [
            Section(kind: "cards", title: "等你放行（\(waiting.count)）",
                    cards: waiting.map { t in
                        Card(id: t.id,
                             title: String(t.prompt.prefix(60)),
                             body: (t.note ?? "碰到高危路径,等你确认"),
                             detail: t.prompt,
                             tone: .warn, icon: "exclamationmark.shield",
                             trailing: URL(fileURLWithPath: t.repo).lastPathComponent,
                             images: [],
                             actions: [
                                Action(id: "task:approve:" + MobileAction.taskResource(t),
                                       label: "放行", style: "primary"),
                                Action(id: "task:discard:" + MobileAction.taskResource(t),
                                       label: "不做了", style: "destructive",
                                       needsNote: true)])
                    })
        ], now: now)
    }

    public static func reviewPage(now: Date = Date()) -> Page {
        let items = Review.publishDigests()
        let milestones = Milestone.unreviewed()
        guard !items.isEmpty || !milestones.isEmpty else {
            return Page(page: "review", sections: [
                Section(kind: "text", title: "没有等验收的产出", tone: .good,
                        text: "agent 交的活都已经合入或丢弃了。")
            ], now: now)
        }
        var sections: [Section] = []
        if !milestones.isEmpty {
            sections.append(Section(
                kind: "cards", title: "待你复核成果（\(milestones.count)）",
                note: "看实际截图或录屏；运行中成果的意见直接回到原任务，不另拆任务",
                cards: milestones.sorted { $0.landedAt > $1.landedAt }.map { item in
                    Card(id: item.id,
                         title: item.subject,
                         body: item.repoName + (item.isCheckpoint
                            ? " · 阶段成果未合入，等你看阶段效果（不代表最终验收）"
                            : " · 已合入 main，等你看实际效果"),
                         detail: "来源分支：\(item.branch)\n"
                            + (item.isCheckpoint ? "阶段提交：" : "提交：")
                            + item.mergeSHA,
                         tone: .neutral, icon: "play.rectangle",
                         trailing: Review.evidenceSummary(item.evidenceFiles),
                         images: item.evidenceFiles,
                         actions: [
                            Action(id: "milestone:approve:" + item.repo + "|" + item.mergeSHA,
                                   label: "满意", style: "primary"),
                            Action(id: "milestone:reject:" + item.repo + "|" + item.mergeSHA,
                                   label: item.isCheckpoint
                                    ? "不通过，反馈原任务" : "不满意，交回整改",
                                   style: "destructive",
                                   needsNote: true),
                         ])
                }))
        }
        // 按仓库分组，每组一个区块 —— 分组规则也在服务端。
        let byRepo = Dictionary(grouping: items, by: \.repoName)
        sections.append(contentsOf: byRepo.keys.sorted().map { name in
            let group = byRepo[name] ?? []
            return Section(
                kind: "cards", title: name + "（\(group.count)）",
                cards: group.map { d in
                    Card(id: d.repo + "|" + d.branch,
                         title: d.subject,
                         body: d.platform + " · \(d.files.count) 个文件"
                             + " · +\(d.insertions)/−\(d.deletions)"
                             + (d.mergesCleanly ? "" : " · 有冲突，要去电脑上处理")
                             + (d.landingBlockReason.map { " · " + $0 } ?? ""),
                         detail: d.prompt,
                         tone: d.mergesCleanly ? .neutral : .warn,
                         icon: d.mergesCleanly ? "checkmark.seal" : "exclamationmark.triangle",
                         trailing: Review.evidenceSummary(d.evidenceFiles) ?? "没交证据",
                         images: d.evidenceFiles,
                         actions: (d.mergesCleanly && d.landingBlockReason == nil
                             ? [Action(id: "review:merge:" + d.actionResource,
                                       label: "合入", style: "primary")] : [])
                             + [Action(id: "review:discard:" + d.actionResource,
                                       label: Review.rejectionLabel(branch: d.branch),
                                       style: "destructive", needsNote: true)])
                })
        })
        return Page(page: "review", sections: sections, now: now)
    }

    /// 项目清单页。
    public static func playbookPage(now: Date = Date()) -> Page {
        let all = Playbook.all()
        guard !all.isEmpty else {
            return Page(page: "playbook", sections: [
                Section(kind: "text", title: "还没有项目清单",
                        text: "清单里是提前规划好、批过一次方案之后，"
                            + "就能在额度快浪费时自动执行的项目。")
            ], now: now)
        }
        var sections: [Section] = []
        let pending = all.filter { !$0.isApproved }
        if !pending.isEmpty {
            sections.append(Section(
                kind: "cards", title: "\(pending.count) 个方案等你过目",
                note: "批了才会在空窗时自动取活",
                cards: pending.map { p in
                    Card(id: p.id, title: p.name,
                         body: p.brief.split(separator: "\n").first.map(String.init)?
                            .replacingOccurrences(of: "**", with: ""),
                         detail: p.brief.replacingOccurrences(of: "**", with: ""),
                         tone: .warn, icon: "hand.raised",
                         actions: [Action(id: "playbook:approve:" + MobileAction.playbookResource(p),
                                          label: "批准", style: "primary", needsNote: true)])
                }))
        }
        let live = all.filter(\.isApproved)
        if !live.isEmpty {
            sections.append(Section(
                kind: "cards", title: "已批准",
                cards: live.map { p in
                    Card(id: p.id, title: p.name,
                         body: "跑过 \(p.runs) 次"
                             + (p.backlog.isEmpty ? " · 方向清单空了，补一条才会继续出活"
                                : " · 还有 \(p.backlog.count) 个方向"),
                         detail: p.brief.replacingOccurrences(of: "**", with: ""),
                         tone: p.backlog.isEmpty ? .warn : .neutral,
                         icon: "checkmark.circle")
                }))
        }
        return Page(page: "playbook", sections: sections, now: now)
    }
}
