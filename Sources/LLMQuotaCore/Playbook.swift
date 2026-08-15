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

        public var isApproved: Bool { approvedAt != nil }

        public init(id: String, name: String, brief: String, repo: String? = nil,
                    recipes: [Recipe] = [], approvedAt: Date? = nil,
                    runs: Int = 0, paused: Bool = false) {
            self.id = id; self.name = name; self.brief = brief; self.repo = repo
            self.recipes = recipes; self.approvedAt = approvedAt
            self.runs = runs; self.paused = paused
        }
    }

    static var path: URL {
        Paths.appSupport.appendingPathComponent("playbook.json")
    }

    public static func all() -> [Project] {
        guard let d = try? Data(contentsOf: path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Project].self, from: d)) ?? []
    }

    public static func save(_ projects: [Project]) {
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
    public static func available() -> [Project] {
        all().filter { $0.isApproved && !$0.paused && !$0.recipes.isEmpty }
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
            let n = p.runs + 1
            let prompt = r.prompt.replacingOccurrences(of: "{{n}}", with: "\(n)")
            return (p, r, prompt)
        }
        return nil
    }

    /// 记一次取用。**必须在真的入队之后调用** ——
    /// 提前记会让轮转跳过一条配方，那条就再也轮不上了。
    public static func recordRun(_ id: String) {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].runs += 1
        save(list)
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

    static func builtins() -> [Project] {
        [
            Project(
                id: "itch-asset-packs",
                name: "itch.io 素材包",
                brief: """
                **做什么**：用 MiniMax 的生图额度做游戏素材包，上架 itch.io 卖 $4.99。

                **为什么是这个**：MiniMax 的生图额度基本闲着（周窗按当前速度会剩 85% \
                未用就清零），而产线已经跑通 —— 两个包在卖，五阶段手册在 \
                AssetPacks/PIPELINE.md。

                **一个包长什么样**：一个主题（深渊/龙穴/森林），20-30 张 \
                1024×1024 透明底 PNG，风格统一，附 README 和授权说明。

                **怎么算合格**（终审这关不能省，实测漏过会上架废品）：
                1. 每张图裁掉底部 8% —— 生成图必带伪造画师签名，负面提示词无效
                2. 全部过 sips 归一化，否则 Xcode/引擎那边会静默丢文件
                3. 抽验四个角落和中心，看清晰度和风格一致性
                4. 同一包内不能混风格 —— 混了就是废品，退回重做

                **人要做的两件事**：终审时看几张图、上架时点一次封面选文件。\
                其余全自动（生成、裁签名、打包、建商品页、butler 传包、定价）。

                **产出去哪**：~/dev/AssetPacks/pack-NN-<主题>/，上架前停下来等确认。
                """,
                repo: "~/dev/AssetPacks",
                recipes: [
                    Recipe(
                        title: "出一个新主题包",
                        prompt: """
                        【素材包】在 ~/dev/AssetPacks 出第 {{n}} 个新主题包。

                        先读 PIPELINE.md 全文和 AGENTS.md，按五阶段做。挑一个和已有包\
                        （深渊、龙穴、森林）不重样的主题，自己定，理由写进 STATUS.md。

                        用 genart image 生成 20-30 张 1024×1024，走 tools/strip-signature.sh \
                        裁签名 + 归一化。**同一包内风格必须统一** —— 生成前先定死风格描述词，\
                        每张都带上它。

                        交活时附：包目录路径、张数、抽验的 4 张图（角落 + 中心裁切）、\
                        以及你自己判断"这包能不能卖钱"的结论。**不要上架** —— \
                        上架要老板点头。
                        """,
                        tier: "complex", platform: "minimax", publishes: true),
                    Recipe(
                        title: "给已有包补图",
                        prompt: """
                        【素材包】给 ~/dev/AssetPacks 里图最少的那个包补 8-10 张同风格图。

                        先看各包的图数和 STATUS.md，挑最单薄的那个。**风格必须和\
                        已有图一致** —— 先读那个包里现有的图和当初的风格描述词，\
                        对不上就别补，宁可换一个包。

                        同样走 strip-signature.sh。交活附抽验图和"补前补后各几张"。
                        """,
                        tier: "standard", platform: "minimax", publishes: false),
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

    static var approvalsDir: URL {
        Paths.appSupport.appendingPathComponent("approvals", isDirectory: true)
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
            guard let d = try? Data(contentsOf: f),
                  let a = try? dec.decode(Approval.self, from: d) else { continue }
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
            // 不管有没有生效都删：留着只会每轮重复读一次
            try? fm.removeItem(at: f)
        }
        if dirty { save(list) }
        return applied
    }
}
