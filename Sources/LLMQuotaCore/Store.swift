import Foundation

// MARK: - Snapshot store

/// 快照的读写。多机汇总就靠这一层：每台机器只写自己那个文件，
/// 谁都不会写别人的，所以不存在冲突合并的问题 —— iCloud 只负责搬运。
/// iCloud 同步的结果。
///
/// 单独抽出来是因为 iCloud Drive 归 macOS TCC 管：从终端跑能继承终端的
/// 完全磁盘访问权限，但双击启动的 App 默认没有，写入会直接被拒
/// （NSPOSIXErrorDomain Code=1 Operation not permitted）。
/// 这种失败绝不能让整次采集报废 —— 本机数据照样有用，只是多机汇总用不了。
public enum ICloudSyncStatus: Sendable, Equatable {
    case synced
    case unavailable
    case permissionDenied(String)
    /// 写进去了没回来 —— iCloud 的写入**可以永久阻塞**，不是慢，是不返回。
    ///
    /// 单独一个 case，不能并进 `.unavailable`。「iCloud 没配置」和
    /// 「iCloud 卡死把整条流水线冻住了」是两件严重程度差着数量级的事，
    /// 混成一个状态，人看到的就是「哦，没连 iCloud」，然后去查一个没坏的地方。
    case stalled(String)

    public var needsFullDiskAccess: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

public enum SnapshotStore {
    public static func fileName(machineID: String) -> String { "\(machineID).json" }

    /// 先保本地，再尽力同步 iCloud。
    @discardableResult
    public static func write(_ snapshot: MachineSnapshot) throws -> ICloudSyncStatus {
        try Paths.ensureDirectories()
        let data = try SnapshotCoding.encoder().encode(snapshot)
        let name = fileName(machineID: snapshot.machineID)

        // 本地目录不受 TCC 管，这一步必须成功，失败才算真的采集失败。
        // 走 ICloudSafe 只是为了统一规矩 —— 它认出这是本地路径就直接写，没有开销。
        guard ICloudSafe.write(data, to: Paths.localSnapshotsDir
            .appendingPathComponent(name)) else {
            throw NSError(domain: "SnapshotStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "本地快照写不进去"])
        }

        guard let icloudDir = Paths.iCloudSnapshotsDir else { return .unavailable }
        // 本地已经落盘了，下面这段是「尽力同步到 iCloud」——
        // 而 iCloud 的写入可以**永久阻塞**（`do/catch` 只接得住错误，接不住不返回）。
        // 关进看门狗，见 Watchdog。
        let outcome = Watchdog.run("snapshot.icloud", timeout: 12) { () -> ICloudSyncStatus in
            do {
                try FileManager.default.createDirectory(
                    at: icloudDir, withIntermediateDirectories: true)
                guard ICloudSafe.write(
                    data, to: icloudDir.appendingPathComponent(name)) else {
                    return .stalled("写 iCloud 快照超时")
                }
                return .synced
            } catch {
                let ns = error as NSError
                let denied = ns.domain == NSCocoaErrorDomain
                    && (ns.code == NSFileWriteNoPermissionError
                        || ns.code == NSFileReadNoPermissionError)
                return denied ? .permissionDenied(ns.localizedDescription) : .unavailable
            }
        }
        switch outcome {
        case .done(let s): return s
        case .timedOut: return .stalled("写 iCloud 快照 12 秒没返回")
        case .skipped: return .stalled("上一次写 iCloud 快照还卡着，这轮跳过")
        }
    }

    /// 把 iCloud 里**其他机器**的快照镜像一份到本地目录。
    ///
    /// 这一步是为了让菜单栏 App 不必申请「完全磁盘访问权限」：
    /// iCloud Drive 受 TCC 管，双击启动的 App 读不了，但从终端或 launchd 跑的
    /// `llmq` 可以。于是让 `llmq` 采集时顺手把别人的快照搬到本地（本地目录不受 TCC 管），
    /// App 只读本地就能看到所有机器的数据。
    ///
    /// 只镜像别人的：自己那份本来就是本地先写的，覆盖回来没有意义。
    @discardableResult
    public static func mirrorICloudToLocal(selfMachineID: String) -> Int {
        guard let icloudDir = Paths.iCloudSnapshotsDir else { return 0 }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: icloudDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var mirrored = 0
        for url in entries where url.pathExtension == "json" {
            let name = url.lastPathComponent
            guard name != fileName(machineID: selfMachineID) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            // 确认是能解出来的快照再落地，避免把同步到一半的半截文件搬过去。
            guard (try? SnapshotCoding.decoder().decode(MachineSnapshot.self, from: data)) != nil
            else { continue }
            let dest = Paths.localSnapshotsDir.appendingPathComponent(name)
            if ICloudSafe.write(data, to: dest) { mirrored += 1 }
        }
        return mirrored
    }

    /// 读取所有机器的快照。同一台机器（machineID 相同）只保留最新的一份。
    public static func loadAll() -> [MachineSnapshot] {
        var found: [String: MachineSnapshot] = [:]
        for dir in [Paths.snapshotsDir, Paths.localSnapshotsDir] {
            for snap in load(from: dir) {
                if let cur = found[snap.machineID], cur.generatedAt >= snap.generatedAt { continue }
                found[snap.machineID] = snap
            }
        }
        return found.values.sorted { $0.machineName < $1.machineName }
    }

    private static func load(from dir: URL) -> [MachineSnapshot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [MachineSnapshot] = []
        let decoder = SnapshotCoding.decoder()
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let snap = try? decoder.decode(MachineSnapshot.self, from: data)
            else { continue }
            out.append(snap)
        }

        // 别的机器写的快照，在本机可能还只是个未下载的占位符（.xxx.json.icloud）。
        // 触发下载，下次采集就能读到了。
        requestDownloadOfPlaceholders(in: dir)
        return out
    }

    private static func requestDownloadOfPlaceholders(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: []
        ) else { return }
        for url in entries where url.pathExtension == "icloud" {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// 快照文件里有没有别的机器。用来提示"另一台电脑还没接进来"。
    public static func knownMachines() -> [String] {
        loadAll().map(\.machineName)
    }
}

// MARK: - Plans config store

public enum PlansStore {
    /// 配置的权威副本在 iCloud（可用时）。
    ///
    /// 但菜单栏 App 读不了 iCloud（TCC 限制），所以沿用快照那套：
    /// **iCloud 是权威，本地是镜像**，CLI 每次采集时把 iCloud 同步到本地，
    /// App 只读本地。
    ///
    /// 冲突处理是最后写入者胜。配置是人手工改的、频率极低，
    /// 而且不会两台机器同时改，这个取舍可以接受 —— 换成真正的合并
    /// 需要引入版本向量，为一个几乎不发生的场景不值得。
    static var canonicalFile: URL {
        Paths.iCloudConfigDir?.appendingPathComponent("plans.json") ?? Paths.plansFile
    }

    /// 实际读到的是哪个文件。**给诊断用** ——
    /// 之前 `llmq plan` 打印的是写死的本地路径，而它可能读的是 iCloud 那份，
    /// 也可能两份都读不到用了模板。路径印错等于把人往错方向带。
    public static func loadedFrom() -> URL? {
        for url in [canonicalFile, Paths.plansFile] {
            if let data = try? Data(contentsOf: url),
               (try? SnapshotCoding.decoder().decode(PlansConfig.self, from: data)) != nil {
                return url
            }
        }
        return nil
    }

    public static func load() -> PlansConfig {
        let dec = SnapshotCoding.decoder()
        // 优先读 iCloud 权威副本；读不到（App 无权限 / 没开 iCloud）就退回本地镜像。
        for url in [canonicalFile, Paths.plansFile] {
            if let data = try? Data(contentsOf: url),
               let cfg = try? dec.decode(PlansConfig.self, from: data) {
                return reconcileWindows(cfg)
            }
        }
        return PlansConfig.template()
    }

    /// 让模板里的**窗口定义**能到达已经存在的配置，同时保住用户填的数值。
    ///
    /// ## 为什么需要这个
    ///
    /// 窗口定义（哪几个窗口、多长、什么口径）是**我们查出来的知识**，
    /// 会随着对各家套餐了解的加深而修正；而 limit 里的数字是**用户填的**，
    /// 一个个从订阅页抄来的，丢了要全部重来。两者的归属不同，
    /// 却存在同一个文件里 —— 于是原来只要用户存过一次配置，
    /// 后续所有窗口修正都到不了他那儿。
    ///
    /// 实际后果：查出 Kimi 和 GLM 的额度是**每 7 天**刷新（官方原文
    /// 「以订阅日为起点每 7 天刷新」「周积分」），把模板从每月改成每周，
    /// 而用户的配置纹丝不动，作废预警继续按 30 天算剩余 ——
    /// 实际每 7 天就清零一次，「还早着呢」这个判断整整错了四倍，
    /// 正好把这个工具最该抓的那种浪费漏掉。
    ///
    /// 所以：窗口以模板为准，数值按 id 从旧配置搬过来。
    /// 旧配置里有、模板里没有的窗口保留 —— 那可能是用户自己加的，
    /// 替他删掉是越权。
    static func reconcileWindows(_ saved: PlansConfig) -> PlansConfig {
        let tpl = PlansConfig.template()
        var out = saved
        for i in out.plans.indices {
            guard let t = tpl.plan(for: out.plans[i].platform) else { continue }
            let savedLimits = out.plans[i].limits
            let byID = Dictionary(savedLimits.map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
            var merged: [QuotaLimit] = t.limits.map { def in
                var l = def
                // 只搬数值和锚点，其余（窗口长度、口径、说明）以模板为准。
                l.limit = byID[def.id]?.limit
                l.anchor = byID[def.id]?.anchor
                return l
            }
            let templateIDs = Set(t.limits.map(\.id))
            merged += savedLimits.filter { !templateIDs.contains($0.id) && $0.limit != nil }
            out.plans[i].limits = merged
        }
        return out
    }

    public static func save(_ config: PlansConfig, force: Bool = false) throws {
        try Paths.ensureDirectories()
        let data = try SnapshotCoding.prettyEncoder().encode(config)
        _ = ICloudSafe.write(data, to: Paths.plansFile)   // 本地镜像

        guard canonicalFile != Paths.plansFile else { return }

        // 第二道保险：不许用一份**一个上限都没有**的配置，
        // 去盖掉一份填过上限的。
        //
        // 上限是人一个个去各家用量页面查出来填的，丢了就得全部重来；
        // 而「空配置」几乎总是模板或解码失败的产物，不是本意。
        // 两者相撞时按「有内容的赢」处理，比按「后写的赢」安全得多。
        if !force, config.filledLimitCount == 0,
           let old = try? Data(contentsOf: canonicalFile),
           let prev = try? SnapshotCoding.decoder().decode(PlansConfig.self, from: old),
           prev.filledLimitCount > 0 {
            return
        }

        // 覆盖前留一份。上一次真丢了之后发现无处可捞 ——
        // iCloud 的版本历史命令行读不到，Time Machine 也未必开着。
        if let old = try? Data(contentsOf: canonicalFile) {
            ICloudSafe.write(old, to: canonicalFile.deletingLastPathComponent()
                .appendingPathComponent("plans.backup.json"))
        }
        ICloudSafe.write(data, to: canonicalFile)     // iCloud 权威副本
    }

    /// 把 iCloud 上的配置同步到本地镜像，供菜单栏 App 读取。
    @discardableResult
    public static func mirrorFromICloud() -> Bool {
        guard canonicalFile != Paths.plansFile,
              let data = try? Data(contentsOf: canonicalFile),
              (try? SnapshotCoding.decoder().decode(PlansConfig.self, from: data)) != nil
        else { return false }
        return ICloudSafe.write(data, to: Paths.plansFile)
    }

    /// 首次运行时落一份模板出来给用户填。已存在则不动。
    @discardableResult
    /// iCloud 上那份配置**存不存在** —— 和「读不读得出来」是两回事。
    ///
    /// 没下载下来的 iCloud 文件在本地是一个叫 `.plans.json.icloud` 的占位符，
    /// 真名那个路径 `fileExists` 为假。把这种情况当成「iCloud 上没有」，
    /// 就会走上覆盖分支。
    static func canonicalPresent() -> Bool {
        guard canonicalFile != Paths.plansFile else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: canonicalFile.path) { return true }
        let placeholder = canonicalFile.deletingLastPathComponent()
            .appendingPathComponent("." + canonicalFile.lastPathComponent + ".icloud")
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: canonicalFile)
            return true
        }
        return false
    }

    public static func ensureExists() throws -> Bool {
        // iCloud 上已经有了就拉下来 —— 新机器接入时直接继承已填好的上限，
        // 不用重新查一遍各家套餐数值。
        if mirrorFromICloud() { return false }

        // **这里曾经把整个账号的配置抹掉过。**
        //
        // 原来的判断是「mirror 失败 = iCloud 上没有」，然后把本机那份推上去。
        // 但 mirror 失败最常见的原因根本不是「没有」，而是**还没下载下来** ——
        // 刚接入的新机器上，iCloud 目录里只有一个 `.plans.json.icloud` 占位符。
        // 于是新机器把自己那份空模板推上去，覆盖掉你手填的全部上限、
        // 套餐名和计量单位，而且同步到所有设备，没有任何提示。
        //
        // 这不是假想：给第二台 Mac 做入职之后，真的发生了，配置无法恢复。
        // 所以现在只要 iCloud 上**存在**那个文件（哪怕还是占位符），
        // 就一步都不写，等它下载下来。
        if canonicalPresent() {
            return false
        }

        guard !FileManager.default.fileExists(atPath: Paths.plansFile.path) else {
            // 本地有、iCloud 确实没有：把本地的推上去当权威副本。
            try? save(load())
            return false
        }
        try save(PlansConfig.template())
        return true
    }
}

// MARK: - Facade

/// CLI 和菜单栏 App 共用的入口，保证两边跑的是同一套逻辑。
public enum LLMQuota {
    /// 采集本机数据并写出快照。
    @discardableResult
    public static func collect(now: Date = Date()) throws -> CollectResult {
        try PlansStore.ensureExists()

        // 覆盖之前先看看上一份是谁写的。菜单栏 App 和 llmq 是两个独立二进制、
        // 写同一个文件，只更新其中一个就会互相覆盖，症状是新接的平台数据时有时无。
        let previous = SnapshotStore.loadAll().first { $0.machineID == Paths.machineID() }

        var result = try Collector().collect(now: now)
        if let prev = previous, !prev.collectorAdapters.isEmpty {
            let mine = Set(result.snapshot.collectorAdapters)
            result.staleBinaryWarning = prev.collectorAdapters.filter { !mine.contains($0) }.sorted()
        }

        result.iCloudSync = try SnapshotStore.write(result.snapshot)

        // ↓ 下面全是 iCloud 上的事，**每一件都关进看门狗**。
        //
        // 采集本身到上面这行就已经完成了（本地快照已落盘）。剩下的都是
        // 「发布出去给别人看」：镜像别人的快照、同步配置、给手机的看板、
        // 集群状态。全是尽力而为的事。
        //
        // 而实测过它们能干出什么：`publishDashboard` 里的
        // `Data.write(.atomic)` 卡死在 `rename()`，`llmq work loop` 每一轮都调
        // `collect`，于是**整条自动化流水线停摆**，进程还活着、日志一个字节不长。
        // 连续四次重启、四次都停在同一行，iCloud 目录里留下四个孤儿临时文件。
        //
        // 一个只是给手机看一眼的写入，不该有能力做到这件事。
        result.mirroredMachines = Watchdog.run("snapshot.mirror", timeout: 12) {
            SnapshotStore.mirrorICloudToLocal(selfMachineID: result.snapshot.machineID)
        }.valueOr(0)
        Watchdog.run("plans.mirror", timeout: 8) { PlansStore.mirrorFromICloud() }
        let dash = dashboard(now: now)
        Watchdog.run("publish.dashboard", timeout: 8) { Inbox.publishDashboard(dash) }
        Watchdog.run("publish.repos", timeout: 8) { Inbox.publishRepos() }
        Watchdog.run("presence.publish", timeout: 8) { ClusterPresenceStore.publish() }
        return result
    }

    /// 需要授予完全磁盘访问权限时给用户看的说明。
    public static let fullDiskAccessHint = """
    多机汇总需要读写 iCloud Drive，而 iCloud Drive 受 macOS 隐私保护。
    请到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里把 LLMQuotaBar 打开。
    不授权也不影响本机统计，只是别的电脑的用量汇总不进来。
    """

    /// 直达「完全磁盘访问权限」设置面板。
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// 读取所有机器的快照，算出仪表盘。不触发采集，所以很快 —— 菜单栏刷新用这个。
    public static func dashboard(now: Date = Date()) -> Dashboard {
        let engine = QuotaEngine(config: PlansStore.load())
        return engine.buildDashboard(snapshots: SnapshotStore.loadAll(), now: now)
    }

    /// 先采集再出仪表盘。
    public static func refresh(now: Date = Date()) throws -> Dashboard {
        _ = try collect(now: now)
        return dashboard(now: now)
    }
}
