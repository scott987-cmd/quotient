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
        sweepDirNames(dir, selfID: selfID).count
    }

    /// 同上,但返回**删掉的文件名**,给调用方去删 iCloud 上的孪生。
    ///
    /// 对账实锤(2026-08-23):这里只删本地,而镜像对「别人的文件」只拉不删
    /// (Mirror.syncPerMachine)—— 删掉的旧身份文件下一轮又从 iCloud 拉回来,
    /// 云端永远收敛不掉;手机的计划清单页因此一直有两个「MacBook Pro」。
    public static func sweepDirNames(_ dir: URL, selfID: String = Paths.machineID()) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil) else { return [] }
        // 机器名 → (最新时间, 最新文件)
        var newest: [String: (Date, URL)] = [:]
        var byName: [String: [URL]] = [:]
        for f in files where f.pathExtension == "json" {
            guard let id = identity(of: f) else { continue }
            byName[id.name, default: []].append(f)
            if let cur = newest[id.name], cur.0 >= id.at { continue }
            newest[id.name] = (id.at, f)
        }
        var removed: [String] = []
        for (name, urls) in byName {
            guard let keep = newest[name]?.1 else { continue }
            for u in urls where u != keep {
                // **当前机器的文件永不删。** 2026-08-23 复审(H2):去重按
                // machineName,两台真机重名(macOS 默认名不去重)时,镜像把对方
                // 文件拉到本地,sweep 每轮删掉「较旧」那台的活文件 —— 互删的删除战。
                // machineID 已是硬件派生、稳定,拿它自保:本机 ID 的文件绝不删。
                if identity(of: u)?.id == selfID { continue }
                if (try? fm.removeItem(at: u)) != nil { removed.append(u.lastPathComponent) }
            }
        }
        return removed
    }

    /// 云端孪生所在的 iCloud 根(`~/Library/Mobile Documents/com~apple~CloudDocs/LLMQuotaBar`)。
    ///
    /// **不能写成 `Paths.iCloudSnapshotsDir?.deletingLastPathComponent()`。** 那个属性
    /// 名字里还带 iCloud,指向早就改成了本地暂存 `sharedRoot/snapshots`(「属性名保留,
    /// 指向变了」)。于是第一版「删云端孪生」删的还是本地那份,真正的 iCloud 文件一直在,
    /// 镜像下一轮又拉回来:worker.log 里每轮「家务 清掉 3 个过时机器身份」循环往复,
    /// 手机上一直两个 MacBook(2026-08-23 实锤:D127CAB4 的 presence 在 iCloud 里
    /// 躺到下午)。名字会骗人,路径要拿真的。
    public static var defaultICloudRoot: URL { Push.mirrorDir }

    /// 没有 JSON 内部身份可读的每机目录(事件流是数组、验收摘要是数组):
    /// 按「有没有对应的 presence」判死活 —— 一台活着的机器每轮都写 presence。
    static let orphanDirs = [
        "office", "reviews", "taskboards", "snapshots", "probes", "agent-registry",
    ]

    /// `office/<machineID>.json` 是数组，不能用 `identity(of:)` 判断内部身份。
    /// 机器 ID 漂移后，当前分片可能还夹着旧 ID 的历史；如果不按文件名收口，
    /// 旧事件会在每次镜像和合并时重新进入办公室。
    @discardableResult
    static func sanitizeOfficeShards(sharedRoot: URL) -> Int {
        let fm = FileManager.default
        let dir = sharedRoot.appendingPathComponent("office", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        let decoder = SnapshotCoding.decoder()
        let encoder = SnapshotCoding.prettyEncoder()
        var changed = 0
        for file in files where file.pathExtension == "json" {
            let ownerID = file.deletingPathExtension().lastPathComponent
            guard !ownerID.isEmpty,
                  let data = try? Data(contentsOf: file),
                  let events = try? decoder.decode([OfficeEvent].self, from: data)
            else { continue }
            let filtered = events.filter {
                $0.machineID.isEmpty || $0.machineID == ownerID
            }
            guard filtered.count != events.count,
                  let clean = try? encoder.encode(filtered),
                  ICloudSafe.write(clean, to: file)
            else { continue }
            changed += 1
        }
        return changed
    }

    /// 删掉这些目录里 `<id>.json` 的 id 已经没有 presence、且文件超过 `olderThan` 没更新的。
    /// 返回删掉的文件名(带目录)。新机器刚起来还没写 presence 的那一两轮,文件是新的,不会被误删。
    public static func sweepOrphanNames(sharedRoot: URL, selfID: String = Paths.machineID(),
                                        olderThan: TimeInterval = 2 * 3600, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let presenceDir = sharedRoot.appendingPathComponent("presence", isDirectory: true)
        var live: Set<String> = [selfID]
        for f in (try? fm.contentsOfDirectory(atPath: presenceDir.path)) ?? [] where f.hasSuffix(".json") {
            live.insert(String(f.dropLast(5)))
        }
        var removed: [String] = []
        for sub in orphanDirs {
            let dir = sharedRoot.appendingPathComponent(sub, isDirectory: true)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where f.hasSuffix(".json") && !f.hasPrefix(".") {
                let id = String(f.dropLast(5))
                if live.contains(id) { continue }
                let url = dir.appendingPathComponent(f)
                let mod = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
                guard now.timeIntervalSince(mod) > olderThan else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed.append(sub + "/" + f) }
            }
        }
        return removed
    }

    /// `questions/<machineID>/` 是每机一个目录（里面再放问题文件），不能被上面的
    /// `<id>.json` 扫描覆盖。只清理无 presence 且已稳定超过宽限期的整目录。
    static func sweepOrphanQuestionDirectories(
        sharedRoot: URL, selfID: String = Paths.machineID(),
        olderThan: TimeInterval = 2 * 3600, now: Date = Date()
    ) -> [String] {
        let fm = FileManager.default
        let presenceDir = sharedRoot.appendingPathComponent("presence", isDirectory: true)
        var live: Set<String> = [selfID]
        for file in (try? fm.contentsOfDirectory(atPath: presenceDir.path)) ?? []
        where file.hasSuffix(".json") && !file.hasPrefix(".") {
            live.insert(String(file.dropLast(5)))
        }
        let questions = sharedRoot.appendingPathComponent("questions", isDirectory: true)
        let directories = (try? fm.contentsOfDirectory(
            at: questions, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var removed: [String] = []
        for directory in directories {
            let id = directory.lastPathComponent
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !live.contains(id) else { continue }
            let modified = (try? fm.attributesOfItem(atPath: directory.path)[.modificationDate]
                            as? Date) ?? now
            guard now.timeIntervalSince(modified) > olderThan else { continue }
            if (try? fm.removeItem(at: directory)) != nil {
                removed.append("questions/" + id)
            }
        }
        return removed
    }

    /// 扫所有按机器分文件的共享目录。
    @discardableResult
    public static func run(sharedRoot: URL = Paths.sharedRoot,
                           iCloudRoot: URL? = defaultICloudRoot,
                           localSnapshotsDir: URL? = Paths.localSnapshotsDir) -> Int {
        var total = 0
        // dashboard() 同时读取 shared/snapshots 和 appSupport/snapshots。后者是
        // MirrorService 的本地副本，旧身份即使已经从共享区和 iCloud 删除，仍会
        // 从这里被汇总成第二台机器。过去的清理器漏了这条真实读路径。
        if let localSnapshotsDir {
            total += sweepDirNames(localSnapshotsDir).count
        }
        // presence 是其它每机文件的唯一存活依据，必须先收敛它。旧顺序先扫
        // orphan，再淘汰重复 presence，导致刚确认死亡的身份还要再等一轮。
        let presenceNames = sweepDirNames(
            sharedRoot.appendingPathComponent("presence", isDirectory: true))
        total += presenceNames.count
        if let root = iCloudRoot {
            for name in presenceNames {
                try? FileManager.default.removeItem(
                    at: root.appendingPathComponent("presence").appendingPathComponent(name))
            }
        }
        // 先按 presence 判死活,清没有身份可读的那几类目录(事件流/验收摘要/任务板/快照)。
        // 老板 2026-08-23:「办公室出现了一台未知的机器」—— 旧 ID 的 reviews/office 文件
        // 一直没人清,presence 一清它们就成了无名氏。云端孪生同样要删。
        let orphans = sweepOrphanNames(sharedRoot: sharedRoot)
        total += orphans.count
        let orphanQuestionDirs = sweepOrphanQuestionDirectories(sharedRoot: sharedRoot)
        total += orphanQuestionDirs.count
        if let root = iCloudRoot {
            for rel in orphans + orphanQuestionDirs {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(rel))
            }
        }
        total += sanitizeOfficeShards(sharedRoot: sharedRoot)
        for sub in perMachineDirs where sub != "presence" {
            let names = sweepDirNames(sharedRoot.appendingPathComponent(sub, isDirectory: true))
            total += names.count
            // **云端的孪生也要删。** 镜像对「别人的文件」只拉不删:只删本地,
            // 下一轮就被从 iCloud 拉回来,云端永远收敛不掉,手机上一直两个 MacBook。
            // 这些文件早就同步到本地了(是 ~/Library/Mobile Documents 里的普通文件),
            // removeItem 不触发下载,不会卡。
            if let root = iCloudRoot {
                for n in names {
                    try? FileManager.default.removeItem(
                        at: root.appendingPathComponent(sub).appendingPathComponent(n))
                }
            }
        }
        return total
    }
}
