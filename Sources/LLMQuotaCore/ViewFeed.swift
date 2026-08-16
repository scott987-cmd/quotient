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
    public static func publish(_ page: Page) -> Bool {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let d = try? enc.encode(page) else { return false }
        return (try? d.write(to: dir.appendingPathComponent(page.page + ".json"))) != nil
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
    /// 靠 `.done` 记已执行的。执行失败不记 —— 下一轮会重试。
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
    public static func markDone(_ inv: Invocation) {
        let f = actionsDir.appendingPathComponent(".done")
        let key = inv.id + "@" + ISO8601DateFormatter().string(from: inv.at)
        var lines = (try? String(contentsOf: f, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        guard !lines.contains(key) else { return }
        lines.append(key)
        // 只留最近 500 条：这个文件只用来防重复执行，不是审计日志。
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        try? lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
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
