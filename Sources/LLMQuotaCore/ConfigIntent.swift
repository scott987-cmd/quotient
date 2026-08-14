import Foundation

// MARK: - 手机递上来的配置改动请求

/// 手机想改一条配置时写下的**意图**，不是配置本身。
///
/// ## 为什么手机不直接改 config/roles.json
///
/// 那份配置在 iCloud 上被多台机器共享，而**写它的每一方都必须认识它的全部字段**。
/// 手机端的 `AgentRole` 只是个子集（除了 `maxTier`、`dispatcherOn` 之外的字段
/// 它根本没有），合成编码器写回去的时候，不认识的键不是报错，是**静默消失**。
///
/// 这个坑这个项目已经踩过一次，而且症状极难反查：一台机器用旧二进制写了
/// 共享配置，把另一台刚写进去的 `pathByMachine` 整个抹掉 ——
/// 两边都没有任何报错，只是跨机派活开始把本机路径发给对端。
/// 手机永远是那个「版本落后的客户端」：它的模型永远比 Mac 端窄。
///
/// 所以手机只写「我想把 minimax 的留白设成 20%」这句话，
/// 由 Mac 用 `AgentRoles.save`（diff-based，保得住其他字段）真正落地。
/// 一条意图能改坏的上限，就是它自己描述的那一个字段。
public struct ConfigIntent: Codable, Sendable {

    /// 意图 id。手机生成，Mac 只拿来做日志和回执，不做去重 ——
    /// 去重靠「处理完就移走文件」，比在内存里记 id 可靠。
    public var id: String
    public var createdAt: Date

    /// 去重用的键：同一轮里同一个目标只让最后一条生效。
    ///
    /// 不用 id（每条都不同），也不能只用 platform ——
    /// 以后加别的 kind 时，「改留白」和「改难度上限」是两件独立的事，
    /// 合并成一个键会让其中一条被无声吃掉。
    var target: String { "\(kind)|\(platform)" }
    /// 谁提的。目前只有 "phone"，留着是为了以后 Mac 之间也能用这条通路。
    public var source: String

    /// 要改哪一类配置。
    ///
    /// **故意存字符串而不是枚举。** 枚举遇到不认识的取值会让整条记录
    /// 解不出来，于是一条「新版手机写的、老版 Mac 不认识的」意图
    /// 会表现成「格式错误」——那是一句假话，它格式好得很，
    /// 只是这台 Mac 太老。诊断说错方向比没有诊断更耽误事。
    public var kind: String

    /// `Platform` 的 rawValue，和看板里那个一致。
    public var platform: String

    /// kind == "reserve" 时的留白比例。
    ///
    /// 可选是为了把「没填」和「填了个越界的」分开报 —— 合并成一个
    /// 「参数不对」的话，用户不知道该补一个字段还是该改一个数。
    public var fraction: Double?

    public init(id: String = UUID().uuidString, createdAt: Date = Date(),
                source: String = "phone", kind: String = ConfigIntent.kindReserve,
                platform: String, fraction: Double? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.kind = kind
        self.platform = platform
        self.fraction = fraction
    }

    /// 跨版本、跨设备传的结构一律手写 —— 合成解码器缺一个键就整条丢，
    /// 而这条通路上「手机比 Mac 新」和「Mac 比手机新」两个方向都会发生。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        // **不能让日期格式把整条意图带走。**
        //
        // `decodeIfPresent(Date.self)` 在格式不符时抛 typeMismatch，
        // 而调用方是 `try?` —— 于是一条完全合法的意图会被判成「不是 JSON」
        // 归档掉，用户那边只看到设置没生效、文件不见了。
        // 解不出来就退回「现在」：顺序可能不准，但意图不会丢。
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
    }

    public static let kindReserve = "reserve"

    /// 留白的合法区间。
    ///
    /// 上界是 0.95 而不是 1：留白 100% 等于「永远不许调度用它」，
    /// 那件事有专门的表达（`mutedOn`），用留白去表达它会让平台在
    /// 界面上显示成「可用但永远选不中」，是最难查的那种故障。
    public static let minFraction: Double = 0
    public static let maxFraction: Double = 0.95
}

// MARK: - 摄入

/// 把 `config-intents/` 里的意图落到配置上。
///
/// 目录结构和收件箱一样：
///
///     config-intents/<uuid>.json        待处理
///     config-intents/processed/…        处理完的（**移走，不删**）
///
/// 处理完移走而不是删掉：删了的话手机上会看到自己刚写的文件凭空消失，
/// 分不清是「送达并生效了」还是「压根没同步上去」。移走既防重复摄入，
/// 又让文件名里那段判定结果留在原地可以翻。
public enum ConfigIntentIngest {

    /// 测试用，产品代码里永远是 nil。
    public static var rootOverride: URL?

    /// 和 `Inbox.root` 同一个目录 —— 手机端认的就是这一个根。
    public static var root: URL? {
        rootOverride ?? Inbox.root
    }

    public static var dir: URL? {
        root?.appendingPathComponent("config-intents", isDirectory: true)
    }
    public static var doneDir: URL? {
        root?.appendingPathComponent("config-intents/processed", isDirectory: true)
    }

    public struct Result: Sendable {
        public var id: String
        public var accepted: Bool
        public var note: String
    }

    /// 扫一遍，能落地的落地，落不了的移走并写明原因。
    ///
    /// **一条坏意图不能拖住后面的**：每条独立判定、独立归档。
    /// 也**不能把坏意图留在原地** —— 留着就是每 30 秒重试同一个坏文件，
    /// 日志里每轮一条同样的红字，真正的新意图淹在里面。
    @discardableResult
    public static func run() -> [Result] {
        guard let dir, let doneDir else { return [] }
        ensureDirectories()
        requestDownloads(in: dir)

        var out: [Result] = []

        // **先全部读出来，按 createdAt 排序，再决定谁生效。**
        //
        // 第一版是边读边应用，顺序按文件名 —— 而文件名是 UUID，
        // 也就是**随机顺序**。`createdAt` 解出来了却从没被用过。
        //
        // 后果不是理论上的：手机每次滑动提交写一个 UUID 文件，
        // 一轮攒到多条是常态（循环 30 秒一跳，没有可用平台时睡 300 秒，
        // 跑一个 agent 任务本身就是几分钟到几十分钟；Mac 睡着时手机写的
        // 意图会在恢复后一次性到齐 —— 而这个功能的场景恰恰就是
        // 「人在外面、Mac 在忙」）。
        // 实测：11:00 设 0.6、10:00 设 0.2，生效的是 **0.2**，
        // 而两份回执都写着「已应用」。用户把 MiniMax 从 20% 改到 60%，
        // Mac 继续按 20% 拦，**两边都不报错**。
        var pending: [(url: URL, intent: ConfigIntent)] = []
        // 列目录也可能永久阻塞（实测栈顶 access），走 ICloudSafe。
        for url in ICloudSafe.contentsOfDirectory(dir) {
            guard url.pathExtension.lowercased() == "json" else { continue }
            guard let data = ICloudSafe.read(url), !data.isEmpty else { continue }
            guard let intent = try? SnapshotCoding.decoder()
                .decode(ConfigIntent.self, from: data) else {
                out.append(park(url, to: doneDir, id: url.deletingPathExtension().lastPathComponent,
                                verdict: "bad-json", note: "这个文件不是能解的 JSON 意图"))
                continue
            }
            pending.append((url, intent))
        }

        // 时间相同才拿文件名当兜底 —— 只是为了让顺序确定，不是判据。
        pending.sort {
            $0.intent.createdAt == $1.intent.createdAt
                ? $0.url.lastPathComponent < $1.url.lastPathComponent
                : $0.intent.createdAt < $1.intent.createdAt
        }

        // 同一轮里同一个「作用目标」只让最后一条生效。
        //
        // 不去重的话，前面几条会**依次真的写进配置**，最后一条覆盖掉 ——
        // 结果虽然对，但 processed/ 里会留下好几条都说「已应用」，
        // 事后查「这个值是怎么变成现在这样的」会得到互相矛盾的记录。
        var lastIndex: [String: Int] = [:]
        for (i, p) in pending.enumerated() { lastIndex[p.intent.target] = i }

        for (i, p) in pending.enumerated() {
            let (url, intent) = (p.url, p.intent)
            if lastIndex[intent.target] != i {
                out.append(park(url, to: doneDir, id: intent.id, verdict: "superseded",
                                note: "同一轮里有更晚的一条改了同一个目标，这条不生效"))
                continue
            }

            switch apply(intent) {
            case .applied(let note):
                out.append(park(url, to: doneDir, id: intent.id,
                                verdict: "applied", note: note, accepted: true))
            case .rejected(let why):
                out.append(park(url, to: doneDir, id: intent.id,
                                verdict: "rejected", note: why))
            case .retry(let why):
                // **原地不动。** 这是「这次没写成」，不是「这条不合法」——
                // 移走等于把一条合法意图永久吞掉，而用户那边只看到
                // 文件不见了、配置没变，无从判断发生了什么。
                out.append(Result(id: intent.id, accepted: false,
                                  note: why + "（意图留着，下一轮再试）"))
            }
        }
        return out
    }

    enum Outcome {
        case applied(String)
        /// 这条永远不会被接受，别再重试。
        case rejected(String)
        /// 这次没落成，但下次可能行（比如 iCloud 没响应）。
        case retry(String)
    }

    static func apply(_ intent: ConfigIntent) -> Outcome {
        guard intent.kind == ConfigIntent.kindReserve else {
            return .rejected("不认识的意图类型「\(intent.kind)」"
                + "——这台 Mac 的版本可能比手机旧")
        }
        guard let p = Platform(rawValue: intent.platform) else {
            return .rejected("不认识的平台「\(intent.platform)」")
        }
        guard let f = intent.fraction else {
            return .rejected("reserve 意图没带 fraction")
        }
        // **越界就拒，不静默钳制。**
        //
        // 钳到 0.95 的话，用户在手机上设了 99%、界面回读也说 95%，
        // 但他记得自己设的是 99 —— 于是「为什么这个平台还在被调度」
        // 这个问题会带着一个错误的前提去查。宁可让他看见一条拒绝。
        guard f >= ConfigIntent.minFraction, f <= ConfigIntent.maxFraction else {
            return .rejected("留白 \(fmt(f)) 超出允许范围 "
                + "\(fmt(ConfigIntent.minFraction))–\(fmt(ConfigIntent.maxFraction))，没有改动")
        }

        var all = AgentRoles.all()
        var role = all[p] ?? AgentRole(platform: p, title: "未分配", maxRisk: .safe)
        let before = role.reserveFraction
        role.reserveFraction = f
        all[p] = role
        do {
            // **必须走 save**：它是 diff-based 的，只写和出厂默认不一样的那些，
            // 别的字段（maxTier、dispatcherOn、mutedOn…）原样保住。
            // 手机端的模型认不全这些字段，这正是它不能自己写配置的原因。
            try AgentRoles.save(Array(all.values))
        } catch {
            return .retry("写角色配置没成功：\(error.localizedDescription)")
        }
        let from = before.map(fmt) ?? "默认"
        return .applied("\(p.displayName) 留白 \(from) → \(fmt(f))")
    }

    static func fmt(_ f: Double) -> String {
        String(format: "%.0f%%", f * 100)
    }

    // MARK: - 归档

    /// 移到 processed/，并在旁边留一份回执。
    ///
    /// 回执是单独一个文件而不是塞回原文件：原文件是用户写的，
    /// 改它就等于让人怀疑自己写的东西被动过。
    static func park(_ url: URL, to done: URL, id: String, verdict: String,
                     note: String, accepted: Bool = false) -> Result {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let base = "\(stamp)-\(verdict)-\(url.deletingPathExtension().lastPathComponent)"
        if !ICloudSafe.move(url, to: done.appendingPathComponent(
            "\(base).\(url.pathExtension)")) {
            // 移不动就删。留着更糟 —— 它已经生效了，留着会被反复消费，
            // 一条「设成 20%」的意图重放不痛不痒，但下一种意图未必幂等。
            // 这一步也在 iCloud 上，同样可能永久阻塞。
            // （ICloudWriteGuardTests 只扫原子写，扫不到 removeItem，
            //   所以这条得靠人记着 —— 记下来免得下次又漏。）
            _ = Watchdog.run("icloud.rm:" + url.path, timeout: 8) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        writeReceipt(to: done.appendingPathComponent("\(base).result.json"),
                     id: id, accepted: accepted, note: note)
        return Result(id: id, accepted: accepted, note: note)
    }

    struct Receipt: Codable {
        var id: String
        var accepted: Bool
        var note: String
        var processedAt: Date
        var machine: String
    }

    static func writeReceipt(to url: URL, id: String, accepted: Bool, note: String) {
        let r = Receipt(id: id, accepted: accepted, note: note,
                        processedAt: Date(), machine: Paths.machineName())
        guard let data = try? SnapshotCoding.prettyEncoder().encode(r) else { return }
        ICloudSafe.write(data, to: url)
    }

    public static func ensureDirectories() {
        for d in [dir, doneDir].compactMap({ $0 }) {
            // createDirectory 在 iCloud 上同样可能永久阻塞，而它没有
            // ICloudSafe 版本 —— 直接关进看门狗。
            _ = Watchdog.run("icloud.mkdir:" + d.path, timeout: 8) {
                try? FileManager.default.createDirectory(
                    at: d, withIntermediateDirectories: true)
            }
        }
    }

    /// 别的设备刚写进来的文件，在本机可能还是个没下载的占位符。
    static func requestDownloads(in dir: URL) {
        let fm = FileManager.default
        for url in ICloudSafe.contentsOfDirectory(dir) where url.pathExtension == "icloud" {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }
}
