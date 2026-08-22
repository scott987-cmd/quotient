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

        public init(id: String, title: String, body: String? = nil,
                    detail: String? = nil, tone: Tone = .neutral,
                    icon: String? = nil, trailing: String? = nil,
                    images: [String] = [], actions: [Action] = []) {
            self.id = id; self.title = title; self.body = body
            self.detail = detail; self.tone = tone; self.icon = icon
            self.trailing = trailing; self.images = images; self.actions = actions
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
            tone = (try? c.decodeIfPresent(Tone.self, forKey: .tone)) as? Tone ?? .neutral
            text = try c.decodeIfPresent(String.self, forKey: .text)
            meters = try c.decodeIfPresent([Meter].self, forKey: .meters)
            cards = try c.decodeIfPresent([Card].self, forKey: .cards)
            facts = try c.decodeIfPresent([Fact].self, forKey: .facts)
            actions = try c.decodeIfPresent([Action].self, forKey: .actions)
        }
    }

    // MARK: - 写出去

    static var dir: URL {
        Paths.sharedRoot.appendingPathComponent("views", isDirectory: true)
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
        if contentCount(page) > 0 { return true }   // 自己有内容 —— 照常发
        guard let previous else { return true }     // 还没有过 —— 建立初始页面
        return contentCount(previous) > 0           // 自己清空了自己 —— 该发
    }

    public static func publish(_ page: Page) -> Bool {
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
        return (try? d.write(to: url)) != nil
    }

    // MARK: - 收动作

    /// 手机点了动作之后写来的东西。
    public struct Invocation: Codable, Sendable {
        public var id: String
        public var at: Date
        public var device: String?
        public var note: String?
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
        for n in names.sorted() where n.hasSuffix(".json") {
            guard let inv = SafeDecode.json(
                at: actionsDir.appendingPathComponent(n), as: Invocation.self)
            else { continue }
            let key = inv.id + "@" + ISO8601DateFormatter().string(from: inv.at)
            if done.contains(key) { continue }
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
        let key = inv.id + "@" + ISO8601DateFormatter().string(from: inv.at)
        let n = (m[key] ?? 0) + 1
        m[key] = n
        // 只留最近 200 条，和 .done 一个道理：这是防重试的账，不是审计日志。
        if m.count > 200 {
            m = Dictionary(uniqueKeysWithValues: m.sorted { $0.key < $1.key }
                .suffix(200).map { ($0.key, $0.value) })
        }
        if let d = try? JSONEncoder().encode(m) {
            try? ICloudSafe.write(d, to: failuresFile)
        }
        return n
    }

    /// 试够了没有。够了就该收口，别再重试。
    public static func exhausted(_ inv: Invocation) -> Bool {
        let key = inv.id + "@" + ISO8601DateFormatter().string(from: inv.at)
        return (failureCounts()[key] ?? 0) >= maxAttempts
    }

    public static func markDone(_ inv: Invocation) {
        let f = actionsDir.appendingPathComponent(".done")
        let key = inv.id + "@" + ISO8601DateFormatter().string(from: inv.at)
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
                guard let f = s.usedFraction, let reset = s.resetsAt else { return false }
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
                             + " · +\(d.insertions)/−\(d.deletions)",
                         detail: d.prompt,
                         tone: d.mergesCleanly ? .neutral : .warn,
                         icon: d.mergesCleanly ? "checkmark.seal" : "exclamationmark.triangle",
                         trailing: d.evidenceFiles.isEmpty ? nil
                             : "\(d.evidenceFiles.count) 张证据",
                         images: d.evidenceFiles,
                         actions: d.mergesCleanly
                             ? [Action(id: "review:merge:" + d.repo + "|" + d.branch,
                                       label: "合入", style: "primary"),
                                Action(id: "review:discard:" + d.repo + "|" + d.branch,
                                       label: "丢弃", style: "destructive", needsNote: true)]
                             : [Action(id: "review:discard:" + d.repo + "|" + d.branch,
                                       label: "丢弃", style: "destructive", needsNote: true)])
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
        let machines = SnapshotStore.loadAll()
        if !machines.isEmpty {
            sections.append(Section(
                kind: "facts", title: "机器心跳",
                facts: machines.map { m in
                    let age = now.timeIntervalSince(m.generatedAt)
                    return Fact(key: m.machineName,
                                value: Format.duration(age) + "前",
                                tone: age > stale ? .warn : .good)
                }))
        }

        // 额度窗口，按「最该看」排：已用尽 > 快过期还空着 > 其余
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
        if !ranked.isEmpty {
            sections.append(Section(
                kind: "meters", title: "额度窗口", note: "按「最该看」排序",
                meters: ranked.prefix(10).map { platform, s in
                    Meter(label: platform.displayName + " · " + s.label,
                          fraction: s.usedFraction ?? 0,
                          tone: s.health == .exhausted ? .danger
                              : (s.health == .wasting ? .warn
                                 : (s.health == .atRisk ? .warn : .good)),
                          right: s.resetsAt.map {
                              Format.duration($0.timeIntervalSince(now)) + "后重置" })
                }))
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
        let pending = Nudge.pending(now: now)
        func badge(_ prefix: String) -> Int? {
            let n = pending.first { $0.key.hasPrefix(prefix) }?.badge ?? 0
            return n > 0 ? n : nil
        }
        return Menu(entries: [
            MenuEntry(page: "review", title: "等你验收",
                      icon: "checkmark.seal", badge: badge("review"), group: "要你拍板"),
            // 高危改动等人放行。**必须有这个入口** —— 在它之前,通知说
            // 「1 个任务被拦下等你放行」,而手机上只有一个「卡住 N 件」的
            // 计数,点了也没用(老板 2026-08-22:「我确认了,但是手机端一直
            // 在重复弹出来让我确认」)。下面那段注释说「能点但什么都没有的
            // 入口比没有更糟」—— 而「有提醒却没有入口」比这还糟。
            MenuEntry(page: "blocked", title: "等你放行",
                      icon: "exclamationmark.shield", badge: badge("blocked"),
                      group: "要你拍板"),
            MenuEntry(page: "playbook", title: "项目清单",
                      icon: "list.bullet.rectangle.portrait",
                      badge: badge("playbook"), group: "要你拍板"),
            // 「看板」不列在这里：它有自己的标签页，而且原生那版更全。
            // 菜单里指向一个不再下发的页面，点进去只会是「这一页还没有内容」——
            // 一个能点但什么都没有的入口，比没有这个入口更糟。
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
    /// 只列「等人确认」这一种被拦(碰高危路径)。上游没完成而冻住的那些
    /// 不该出现在这里 —— 人对它们无事可做,上游一好就自动解冻。
    public static func blockedPage(now: Date = Date(),
                                   tasks: [WorkTask] = TaskStore.all()) -> Page {
        var latest: [String: WorkTask] = [:]
        for t in tasks { latest[t.id] = t }
        let waiting = latest.values
            .filter { $0.state == .blocked && ($0.note ?? "").contains("等你确认") }
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
                                Action(id: "task:approve:" + t.id,
                                       label: "放行", style: "primary"),
                                Action(id: "task:discard:" + t.id,
                                       label: "不做了", style: "destructive",
                                       needsNote: true)])
                    })
        ], now: now)
    }

    public static func reviewPage(now: Date = Date()) -> Page {
        let items = Review.publishDigests()
        guard !items.isEmpty else {
            return Page(page: "review", sections: [
                Section(kind: "text", title: "没有等验收的产出", tone: .good,
                        text: "agent 交的活都已经合入或丢弃了。")
            ], now: now)
        }
        // 按仓库分组，每组一个区块 —— 分组规则也在服务端。
        let byRepo = Dictionary(grouping: items, by: \.repoName)
        return Page(page: "review", sections: byRepo.keys.sorted().map { name in
            let group = byRepo[name] ?? []
            return Section(
                kind: "cards", title: name + "（\(group.count)）",
                cards: group.map { d in
                    Card(id: d.repo + "|" + d.branch,
                         title: d.subject,
                         body: d.platform + " · \(d.files.count) 个文件"
                             + " · +\(d.insertions)/−\(d.deletions)"
                             + (d.mergesCleanly ? "" : " · 有冲突，要去电脑上处理"),
                         detail: d.prompt,
                         tone: d.mergesCleanly ? .neutral : .warn,
                         icon: d.mergesCleanly ? "checkmark.seal" : "exclamationmark.triangle",
                         trailing: d.evidenceFiles.isEmpty ? "没交证据"
                             : "\(d.evidenceFiles.count) 张证据",
                         images: d.evidenceFiles,
                         actions: (d.mergesCleanly
                             ? [Action(id: "review:merge:" + d.repo + "|" + d.branch,
                                       label: "合入", style: "primary")] : [])
                             + [Action(id: "review:discard:" + d.repo + "|" + d.branch,
                                       label: "丢弃", style: "destructive", needsNote: true)])
                })
        }, now: now)
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
                         actions: [Action(id: "playbook:approve:" + p.id,
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
