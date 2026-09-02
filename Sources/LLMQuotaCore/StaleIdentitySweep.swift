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
/// 这些文件只增不减:同步会把它们在机器间来回传。清理必须以稳定 machineID
/// 和长期失联期限为依据，绝不能按 machineName 猜身份；两台真 MacBook Pro
/// 可以同名，按名字“只留最新”会把暂时离线的那台当脏数据删掉。
public enum StaleIdentitySweep {
    /// 真机器即使关机几天也应该留在看板里；只有连续 30 天没有心跳的稳定 ID
    /// 才进入孤儿回收。调用方测试可以传更短期限验证边界。
    public static let staleMachineRetention: TimeInterval = 30 * 86400

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

    /// 历史兼容入口。按名字去重在同名真机场景不安全，因此不再删除任何文件。
    /// 真正的回收统一走 `sweepOrphanNames` 的稳定 ID + TTL 规则。
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
        _ = dir
        _ = selfID
        return []
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
        "presence", "office", "reviews", "taskboards", "snapshots", "probes",
        "agent-registry",
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
                                        olderThan: TimeInterval = staleMachineRetention,
                                        now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let presenceDir = sharedRoot.appendingPathComponent("presence", isDirectory: true)
        let live = retainedPresenceIDs(
            presenceDir: presenceDir, selfID: selfID, olderThan: olderThan, now: now)
        var removed: [String] = []
        for sub in orphanDirs {
            let dir = sharedRoot.appendingPathComponent(sub, isDirectory: true)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where f.hasSuffix(".json") && !f.hasPrefix(".") {
                let id = String(f.dropLast(5))
                if live.contains(id) { continue }
                let url = dir.appendingPathComponent(f)
                guard isOlderThanRetention(url, olderThan: olderThan, now: now) else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed.append(sub + "/" + f) }
            }
        }
        return removed
    }

    /// `questions/<machineID>/` 是每机一个目录（里面再放问题文件），不能被上面的
    /// `<id>.json` 扫描覆盖。只清理无 presence 且已稳定超过宽限期的整目录。
    static func sweepOrphanQuestionDirectories(
        sharedRoot: URL, selfID: String = Paths.machineID(),
        olderThan: TimeInterval = staleMachineRetention, now: Date = Date()
    ) -> [String] {
        let fm = FileManager.default
        let presenceDir = sharedRoot.appendingPathComponent("presence", isDirectory: true)
        let live = retainedPresenceIDs(
            presenceDir: presenceDir, selfID: selfID, olderThan: olderThan, now: now)
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

    private static func retainedPresenceIDs(
        presenceDir: URL, selfID: String, olderThan: TimeInterval, now: Date
    ) -> Set<String> {
        let fm = FileManager.default
        var retained: Set<String> = [selfID]
        for file in (try? fm.contentsOfDirectory(
            at: presenceDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? [] where file.pathExtension == "json" {
            guard !isOlderThanRetention(file, olderThan: olderThan, now: now) else { continue }
            retained.insert(file.deletingPathExtension().lastPathComponent)
        }
        return retained
    }

    private static func isOlderThanRetention(
        _ url: URL, olderThan: TimeInterval, now: Date
    ) -> Bool {
        if let record = identity(of: url), record.at != .distantPast {
            return now.timeIntervalSince(record.at) > olderThan
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                        as? Date) ?? now
        return now.timeIntervalSince(modified) > olderThan
    }

    private static func sweepIdentityFiles(
        in directory: URL, retaining machineIDs: Set<String>,
        olderThan: TimeInterval, now: Date
    ) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var removed = 0
        for file in files where file.pathExtension == "json" {
            let machineID = file.deletingPathExtension().lastPathComponent
            guard !machineIDs.contains(machineID),
                  isOlderThanRetention(file, olderThan: olderThan, now: now) else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// 扫所有按机器分文件的共享目录。
    @discardableResult
    public static func run(sharedRoot: URL = Paths.sharedRoot,
                           iCloudRoot: URL? = defaultICloudRoot,
                           localSnapshotsDir: URL? = Paths.localSnapshotsDir,
                           olderThan: TimeInterval = staleMachineRetention,
                           selfID: String = Paths.machineID()) -> Int {
        var total = 0
        let now = Date()
        if let localSnapshotsDir {
            let retained = retainedPresenceIDs(
                presenceDir: sharedRoot.appendingPathComponent("presence", isDirectory: true),
                selfID: selfID, olderThan: olderThan, now: now)
            total += sweepIdentityFiles(
                in: localSnapshotsDir, retaining: retained,
                olderThan: olderThan, now: now)
        }
        // 先按 presence 判死活,清没有身份可读的那几类目录(事件流/验收摘要/任务板/快照)。
        // 老板 2026-08-23:「办公室出现了一台未知的机器」—— 旧 ID 的 reviews/office 文件
        // 一直没人清,presence 一清它们就成了无名氏。云端孪生同样要删。
        let orphans = sweepOrphanNames(
            sharedRoot: sharedRoot, selfID: selfID,
            olderThan: olderThan, now: now)
        total += orphans.count
        let orphanQuestionDirs = sweepOrphanQuestionDirectories(
            sharedRoot: sharedRoot, selfID: selfID,
            olderThan: olderThan, now: now)
        total += orphanQuestionDirs.count
        if let root = iCloudRoot {
            for rel in orphans + orphanQuestionDirs {
                _ = ICloudSafe.remove(root.appendingPathComponent(rel))
            }
        }
        total += sanitizeOfficeShards(sharedRoot: sharedRoot)
        return total
    }
}
