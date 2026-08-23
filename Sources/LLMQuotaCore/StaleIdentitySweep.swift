import Foundation

/// **把过时机器身份留下的孤儿文件扫掉。**
///
/// 老板 2026-08-23 早,反复报「好几个 mac mini」「任务队列展示又问题」。
///
/// ## 为什么光改 machineID 不够
///
/// machineID 已经改成硬件派生,不再漂了(见 Paths.machineID)。但历史上
/// 漂移期间,每个身份都在 `snapshots/`、`taskboards/`、`presence/` 这些
/// **按机器一文件**的目录里留了一份 `<那次的ID>.json`。
///
/// 这些文件只增不减:同步会把它们在机器间来回传,dashboard 去重能挡住
/// 快照那一路,但**任务板、在线状态**是手机按文件直接读的 —— 于是手机上
/// 一台机器裂成十几个,有的显示在线、有的离线(旧文件的时间戳早就过期)。
///
/// 我逐个删了三轮、跨三个目录,每轮都被镜像同步回来。追着删是打地鼠;
/// 这里做成每轮自动扫:同一台机器(按 machineName)只留 generatedAt
/// 最新的那份,其余删掉。删本地的,镜像下一轮自然把远端的也收敛掉。
public enum StaleIdentitySweep {
    /// 按机器名分组、只留最新的目录。这些都是「一台机器一个文件」。
    static let perMachineDirs = ["snapshots", "taskboards", "presence"]

    /// 从一个 JSON 文件里读出 (机器名, 生成时间)。读不出就返回 nil。
    static func identity(of url: URL) -> (name: String, id: String, at: Date)? {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let name = obj["machineName"] as? String else { return nil }
        let mid = (obj["machineID"] as? String) ?? ""
        // 时间字段各目录叫法不一样:快照/任务板是 generatedAt,
        // 在线状态(presence)是 updatedAt。都认,认不到才退回 distantPast。
        // (2026-08-23:presence 只有 updatedAt,漏了它 → 12 个旧身份没被扫,
        // 老板手机上「还有脏数据」。)
        let iso = ISO8601DateFormatter()
        let stamp = (obj["generatedAt"] as? String) ?? (obj["updatedAt"] as? String)
        let at = stamp.flatMap { iso.date(from: $0) } ?? .distantPast
        return (name, mid, at)
    }

    /// 扫一个目录,同名机器只留最新。返回删掉的文件数。
    @discardableResult
    public static func sweepDir(_ dir: URL, selfID: String = Paths.machineID()) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil) else { return 0 }
        // 机器名 → (最新时间, 最新文件)
        var newest: [String: (Date, URL)] = [:]
        var byName: [String: [URL]] = [:]
        for f in files where f.pathExtension == "json" {
            guard let id = identity(of: f) else { continue }
            byName[id.name, default: []].append(f)
            if let cur = newest[id.name], cur.0 >= id.at { continue }
            newest[id.name] = (id.at, f)
        }
        var removed = 0
        for (name, urls) in byName {
            guard let keep = newest[name]?.1 else { continue }
            for u in urls where u != keep {
                // **当前机器的文件永不删。** 2026-08-23 复审(H2):去重按
                // machineName,两台真机重名(macOS 默认名不去重)时,镜像把对方
                // 文件拉到本地,sweep 每轮删掉「较旧」那台的活文件 —— 互删的删除战。
                // machineID 已是硬件派生、稳定,拿它自保:本机 ID 的文件绝不删。
                if identity(of: u)?.id == selfID { continue }
                if (try? fm.removeItem(at: u)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// 扫所有按机器分文件的共享目录。
    @discardableResult
    public static func run(sharedRoot: URL = Paths.sharedRoot) -> Int {
        var total = 0
        for sub in perMachineDirs {
            total += sweepDir(sharedRoot.appendingPathComponent(sub, isDirectory: true))
        }
        return total
    }
}
