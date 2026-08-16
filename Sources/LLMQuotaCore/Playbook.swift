import Foundation

/// 项目清单：**提前规划好、老板批过一次、之后可以反复自动执行**的活。
///
/// ## 它解决的矛盾
///
/// 老板要两件看起来打架的事：
/// - 「方案的确认还是要经过我」
/// - 「把浪费的 token 全用起来」
///
/// 如果每个任务都等他点头，他就是瓶颈，空窗照样过期；如果全自动，
/// 他就被架空 —— 实测 24 小时 53 个任务，分诊器判出高危 0 个，
/// `asks/` 目录空，没有任何一个环节会停下来等他。
///
/// 清单把确认**前移一次**：项目的方案（做什么、产出什么、怎么算合格）
/// 过他一眼，批了之后这个项目的日常任务就能自动取用。他保住方案权，
/// 系统保住填空窗的能力。
///
/// ## 和储备池的分工
///
/// - `ReservePool`：从**代码里**扫出来的事实（审查发现、TODO、缺测试）。
///   零碎、被动、只在已有仓库里打转。
/// - `Playbook`（这里）：**有产出价值的常态化项目**（资产包、内容生产）。
///   主动、可重复、能变现。
///
/// 填空窗时先看清单再看储备池 —— 一个能卖钱的资产包，价值高于补一条注释。
public enum Playbook {

    /// 一条可以反复执行的任务配方。
    public struct Recipe: Codable, Sendable {
        public var title: String
        /// 任务描述。`{{n}}` 会被替换成这条配方历史上执行过的次数 + 1，
        /// 让「再出一个包」这种任务每次都有不同的编号。
        public var prompt: String
        /// trivial / standard / complex
        public var tier: String
        /// 点名平台。比如出图的活点 MiniMax —— 它的生图额度基本闲着。
        public var platform: String?
        /// 这条配方跑完会产生对外可见的东西（上架、发布、投稿）吗。
        ///
        /// 是的话，**产出停在等确认**，绝不自动发出去。
        /// 老板的原话是对外发布必须他点头。
        public var publishes: Bool

        public init(title: String, prompt: String, tier: String = "standard",
                    platform: String? = nil, publishes: Bool = false) {
            self.title = title; self.prompt = prompt; self.tier = tier
            self.platform = platform; self.publishes = publishes
        }
    }

    public struct Project: Codable, Sendable {
        public var id: String
        public var name: String
        /// 方案：做什么、产出什么、怎么算合格。**这段就是要老板过目的东西。**
        public var brief: String
        /// 干活的仓库。空表示这个项目还没有落地的仓库。
        public var repo: String?
        public var recipes: [Recipe]
        /// 批准时间。**没批准的项目一条任务都不会被取用** ——
        /// 清单的意义就在这个闸上，去掉它就退回全自动了。
        public var approvedAt: Date?
        /// 这个项目一共被填过几次活。用来在配方之间轮转，别老跑同一条。
        public var runs: Int
        /// 暂停：不删除，只是这段时间不取用。
        public var paused: Bool
        /// 待做方向清单。
        ///
        /// **方向是人的决定，不是 agent 该自己拍的。** 第一版配方写的是
        /// 「挑一个和已有包不重样的主题，自己定」—— 老板的反馈是
        /// 「生图的任务没有任务内容方向」。让它自己挑，产出方向就是随机的，
        /// 而随机方向做出来的东西卖不掉。
        ///
        /// 清单空了这个项目就**不再出活**，转而提醒老板补方向 ——
        /// 宁可空窗，也不要一堆没人要的产出。
        public var backlog: [String]
        /// 已经做过的方向。留着是为了不重复，也为了看清做了多少。
        public var shipped: [String]

        public var isApproved: Bool { approvedAt != nil }

        public init(id: String, name: String, brief: String, repo: String? = nil,
                    backlog: [String] = [], shipped: [String] = [],
                    recipes: [Recipe] = [], approvedAt: Date? = nil,
                    runs: Int = 0, paused: Bool = false) {
            self.id = id; self.name = name; self.brief = brief; self.repo = repo
            self.recipes = recipes; self.approvedAt = approvedAt
            self.runs = runs; self.paused = paused
            self.backlog = backlog; self.shipped = shipped
        }

        // 老清单文件里没有这两个字段，解码时给默认值，别让整个清单读不出来。
        enum CodingKeys: String, CodingKey {
            case id, name, brief, repo, recipes, approvedAt, runs, paused, backlog, shipped
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            brief = try c.decode(String.self, forKey: .brief)
            repo = try c.decodeIfPresent(String.self, forKey: .repo)
            recipes = try c.decodeIfPresent([Recipe].self, forKey: .recipes) ?? []
            approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
            runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
            paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            backlog = try c.decodeIfPresent([String].self, forKey: .backlog) ?? []
            shipped = try c.decodeIfPresent([String].self, forKey: .shipped) ?? []
        }
    }

    /// **住在 sharedRoot，不是 appSupport。**
    ///
    /// 镜像服务只推 `sharedRoot` 下的东西（dashboard.json、office.json、
    /// repos.json 都在那儿）。写在 appSupport 的后果实测过：老板在手机上
    /// 批了，Mac 这边生效了，**手机上却永远显示「等你过目」** ——
    /// 因为手机读的是 iCloud 那份，而那份从来没被更新过。
    /// 同一个错误今天犯了两次（approvals 目录也是），记在这儿。
    static var path: URL {
        Paths.sharedRoot.appendingPathComponent("playbook.json")
    }

    public static func all() -> [Project] {
        SafeDecode.json(at: path, as: [Project].self) ?? []
    }

    public static func save(_ projects: [Project]) {
        try? FileManager.default.createDirectory(
            at: Paths.sharedRoot, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(projects) else { return }
        try? d.write(to: path)
    }

    public static func upsert(_ p: Project) {
        var list = all()
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p }
        else { list.append(p) }
        save(list)
    }

    @discardableResult
    public static func approve(_ id: String, now: Date = Date()) -> Project? {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id.hasPrefix(id) }) else { return nil }
        list[i].approvedAt = now
        save(list)
        return list[i]
    }

    /// 可以拿来填空窗的项目：批准了、没暂停、有配方。
    /// 可以拿来填空窗的项目：批准了、没暂停、有配方、**而且还有方向可做**。
    ///
    /// 配方里带 `{{topic}}` 的说明它需要一个方向；清单空了就别出活了 ——
    /// 让 agent 自己编方向，做出来的东西没人要，那不是省额度，
    /// 是把浪费从「窗口过期」换成「产出没人要」。
    public static func available() -> [Project] {
        all().filter { p in
            guard p.isApproved, !p.paused, !p.recipes.isEmpty else { return false }
            let needsTopic = p.recipes.contains { $0.prompt.contains("{{topic}}") }
            return !needsTopic || !p.backlog.isEmpty
        }
    }

    /// 清单快空了、需要老板补方向的项目。
    public static func needsDirection() -> [Project] {
        all().filter { p in
            guard p.isApproved, !p.paused else { return false }
            guard p.recipes.contains(where: { $0.prompt.contains("{{topic}}") })
            else { return false }
            return p.backlog.count <= 1
        }
    }

    /// 取下一个该干的活。
    ///
    /// 在项目之间按「跑得最少的优先」轮转，在配方之间也按次数轮转 ——
    /// 不然一个项目会把空窗全占了，别的清单条目永远轮不上。
    ///
    /// - Parameter platform: 空窗的是哪个平台。配方点名了别的平台就跳过 ——
    ///   点名是有理由的（出图的活给 MiniMax），拿 Codex 去跑只会白烧。
    public static func nextWork(for platform: Platform?,
                                projects: [Project] = available())
    -> (project: Project, recipe: Recipe, prompt: String)? {
        let sorted = projects.sorted { $0.runs < $1.runs }
        for p in sorted {
            let usable = p.recipes.filter { r in
                guard let want = r.platform, let have = platform else { return true }
                return want.lowercased() == have.rawValue.lowercased()
            }
            guard !usable.isEmpty else { continue }
            let r = usable[p.runs % usable.count]
            // 需要方向的配方，清单空了就跳过这个项目（available() 已经滤过，
            // 这里是传入自定义 projects 时的兜底）。
            if r.prompt.contains("{{topic}}"), p.backlog.isEmpty { continue }
            let n = p.runs + 1
            let prompt = r.prompt
                .replacingOccurrences(of: "{{n}}", with: "\(n)")
                .replacingOccurrences(of: "{{topic}}", with: p.backlog.first ?? "")
                .replacingOccurrences(of: "{{shipped}}",
                                      with: p.shipped.isEmpty ? "（还没有）"
                                          : p.shipped.joined(separator: "、"))
            return (p, r, prompt)
        }
        return nil
    }

    /// 记一次取用。**必须在真的入队之后调用** ——
    /// 提前记会让轮转跳过一条配方，那条就再也轮不上了。
    /// 记一次取用，并把用掉的方向从清单挪到「已做」。
    ///
    /// **必须在真的入队之后调用** —— 提前记会让轮转跳过一条配方，
    /// 更糟的是会白白吃掉一个方向。
    public static func recordRun(_ id: String, consumedTopic: Bool = false) {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].runs += 1
        if consumedTopic, !list[i].backlog.isEmpty {
            list[i].shipped.append(list[i].backlog.removeFirst())
        }
        save(list)
    }

    /// 往方向清单里补。老板在手机上或命令行加的。
    public static func addTopics(_ id: String, _ topics: [String]) -> Project? {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id.hasPrefix(id) }) else { return nil }
        let fresh = topics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !list[i].backlog.contains($0)
                        && !list[i].shipped.contains($0) }
        guard !fresh.isEmpty else { return list[i] }
        list[i].backlog.append(contentsOf: fresh)
        save(list)
        return list[i]
    }
}

// MARK: - 内置起手项目

extension Playbook {
    /// 放入内置项目（已存在的不覆盖）。
    ///
    /// 都是**未批准**状态放进来的 —— 方案要先过老板一眼，这是清单存在的意义。
    @discardableResult
    public static func seedBuiltins() -> [Project] {
        var list = all()
        var added: [Project] = []
        for p in builtins() where !list.contains(where: { $0.id == p.id }) {
            list.append(p); added.append(p)
        }
        if !added.isEmpty { save(list) }
        return added
    }

    /// 内置的**示例**项目。
    ///
    /// 这是一份模板，不是配置 —— 它示范一条常态化项目该长什么样：
    /// 方案说清「做什么/产出什么/怎么算合格」、方向清单由人给、
    /// 会对外发布的配方标出来。用的人应该改掉它或者删掉重写。
    ///
    /// **不预置任何真实项目路径。** 早先这里写死了作者自己的资产包仓库
    ///（连定价和五个主题方向都在），别人 clone 下来第一条内置项目
    /// 就是别人的私事 —— 那不是模板，是没清理干净。
    static func builtins() -> [Project] {
        [
            Project(
                id: "example-project",
                name: "示例：常态化产出项目",
                brief: """
                这是一条**示例方案**，用来说明清单里的项目该怎么写。\
                改成你自己的，或者删掉（编辑 shared/playbook.json）。

                **做什么**：一句话说清这个项目产出什么。

                **为什么是这个**：哪个平台的额度在闲置、为什么这件事值得用它做。\
                空窗填活会优先派给配方里点名的那个平台。

                **怎么算合格**：写成能判定通过/不通过的条件。\
                「做得好看」不算标准 ——「同一批产出风格一致，抽验 4 张都没有\
                明显跑偏」才算。判定不了的标准等于没有标准，评审会指出来。

                **产出去哪**：具体目录。标了「对外发布」的配方跑完会停下来\
                等你确认，不会自己发出去。
                """,
                repo: nil,
                // 方向清单：**人给方向，agent 只负责做好。**
                // 清单空了这个项目就停止出活，转而提醒你补 ——
                // 宁可空窗，也不要一堆没人要的产出。
                backlog: [
                    "把这里换成你想要的第一个方向",
                    "第二个方向",
                ],
                shipped: [],
                recipes: [
                    Recipe(
                        title: "示例配方",
                        prompt: """
                        这是第 {{n}} 次执行。**主题已经定了：{{topic}}**。\
                        别自己换题 —— 方向由人定，你负责把它做好。\
                        已经做过的（别重复）：{{shipped}}。

                        在这里写清楚具体要做什么、按什么步骤、交活时要附什么证据。\
                        模板里可以用 {{n}}（第几次）、{{topic}}（这次的方向）、\
                        {{shipped}}（做过的方向）。
                        """,
                        tier: "standard", platform: nil, publishes: false),
                ]),
        ]
    }
}

// MARK: - 手机批准

extension Playbook {
    /// 手机写来的批准。
    ///
    /// 手机不直接改 `playbook.json`：那个文件两边都会写
    ///（Mac 改 `runs`、手机改 `approvedAt`），整文件同步必然丢一边。
    /// 改成手机往 `approvals/` 放一个小文件，Mac 端读到就应用。
    /// 和 agent 提问走 `answers/` 是同一套路子。
    public struct Approval: Codable, Sendable {
        public var projectID: String
        public var approvedAt: Date
        /// 谁批的。多设备时能看出是从哪台手机批的。
        public var device: String?
        /// 批注。老板可能想在批准时附一句要求。
        public var note: String?
    }

    /// **必须是 sharedRoot，不是 appSupport。**
    ///
    /// 镜像服务同步的本地根是 `Paths.sharedRoot`（= appSupport/shared），
    /// 手机写来的东西全落在那儿。写成 appSupport/approvals 的后果实测过：
    /// 老板在手机上批了，文件也确实同步下来了，程序却一直在另一个目录找，
    /// 清单上永远显示「等你过目」—— 批准像是没生效。
    /// answers/ inbox/ 这些也都在 sharedRoot 下，别再另开一处。
    static var approvalsDir: URL {
        Paths.sharedRoot.appendingPathComponent("approvals", isDirectory: true)
    }

    /// 收手机批准：应用到清单，然后删掉那个文件（已经生效了，留着只会重复应用）。
    ///
    /// - Returns: 这一轮真正生效的项目。
    @discardableResult
    public static func ingestApprovals() -> [Project] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: approvalsDir.path)
        else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var applied: [Project] = []
        var list = all()
        var dirty = false
        for name in names where name.hasSuffix(".json") {
            let f = approvalsDir.appendingPathComponent(name)
            guard let a = SafeDecode.json(at: f, as: Approval.self) else { continue }
            if let i = list.firstIndex(where: { $0.id == a.projectID }) {
                // 已经批过就别改时间 —— 那会让「什么时候批的」这件事失真
                if list[i].approvedAt == nil {
                    list[i].approvedAt = a.approvedAt
                    if let note = a.note, !note.isEmpty {
                        list[i].brief += "\n\n**老板批注**：" + note
                    }
                    applied.append(list[i])
                    dirty = true
                }
            }
            // **不删文件。**
            //
            // approvals 是双向同步的：本地删掉，下一轮镜像就从云端把它
            // 拉回来（syncBidirectional 见到「云端有、本地没有」就 pull）。
            // 于是「删了又回来」每轮循环一次，日志里反复出现同一条批准。
            //
            // 幂等就够了：上面那个 `approvedAt == nil` 判据保证只生效一次。
            // 文件留着无害，超过 30 天的在这里顺手清掉 ——
            // 那时候两边都早过期了，删了不会再被拉回来。
            if let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
               Date().timeIntervalSince(mod) > 30 * 86400 {
                try? fm.removeItem(at: f)
            }
        }
        if dirty { save(list) }
        return applied
    }
}
