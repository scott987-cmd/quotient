import Foundation

// MARK: - 共享暂存的目录契约

/// 本地暂存 `Paths.sharedRoot` 的目录结构 —— 和 iCloud 的 LLMQuotaBar/ 完全一致。
///
/// CLI 只读写本地暂存；菜单栏 App 的 `MirrorService` 每 30 秒做一次
/// 本地暂存 ↔ iCloud 的镜像。两边靠这一份清单对话，别在两处各写一份。
public enum SharedLayout {
    /// 根下的子目录。`answers/<machineID>/` 按机器建，不在这张静态表里
    /// （`ensure` 不能调 `Paths.machineID()` —— 它会反过来调
    /// `ensureDirectories`，无限递归）。
    public static let dirs = [
        "snapshots", "taskboards", "presence", "config",
        "inbox", "inbox/processed",
        "answers", "questions", "outbox",
        "config-intents", "config-intents/processed",
        "releases",
    ]

    public static func ensure(at root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for d in dirs {
            try? fm.createDirectory(
                at: root.appendingPathComponent(d, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }
}

// MARK: - 心跳

/// App 每轮镜像后写进 `shared/.mirror-state.json` 的心跳。
///
/// CLI（collect / doctor / SelfCheck）靠它回答「共享暂存有没有人在往
/// iCloud 搬」—— CLI 自己永远不碰 iCloud，所以这是它唯一的知情渠道。
public struct MirrorState: Codable, Sendable {
    public var schemaVersion: Int
    /// 上一轮镜像**开始尝试**的时刻。App 在跑，这个值就一直在刷新。
    public var lastAttemptAt: Date
    /// 上一次**零错误**跑完的时刻。出错的轮次不动它。
    public var lastOKAt: Date?
    /// 上一轮的错误摘要；成功轮清成 nil。
    public var lastError: String?
    public var pushed: Int
    public var pulled: Int
    public var claimed: Int

    public init(schemaVersion: Int = 1, lastAttemptAt: Date, lastOKAt: Date? = nil,
                lastError: String? = nil, pushed: Int = 0, pulled: Int = 0,
                claimed: Int = 0) {
        self.schemaVersion = schemaVersion
        self.lastAttemptAt = lastAttemptAt
        self.lastOKAt = lastOKAt
        self.lastError = lastError
        self.pushed = pushed
        self.pulled = pulled
        self.claimed = claimed
    }

    /// 跨版本读写的结构一律手写 decodeIfPresent ——
    /// 合成解码器缺一个键就整条丢，这个坑在本项目翻过五次以上。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt) ?? .distantPast
        lastOKAt = try c.decodeIfPresent(Date.self, forKey: .lastOKAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        pushed = try c.decodeIfPresent(Int.self, forKey: .pushed) ?? 0
        pulled = try c.decodeIfPresent(Int.self, forKey: .pulled) ?? 0
        claimed = try c.decodeIfPresent(Int.self, forKey: .claimed) ?? 0
    }
}

// MARK: - 统计

public struct MirrorStats: Sendable {
    public var pushed = 0
    public var pulled = 0
    public var claimed = 0
    public var errors: [String] = []
    public init() {}
}

// MARK: - 镜像

/// 本地暂存 ↔ iCloud 的镜像。**只有菜单栏 App 调它**，CLI 永远不调 ——
/// 整个进程模型里 App 是唯一碰真 iCloud 的进程。
///
/// # 每个目录的语义都不一样，别一把梭
///
/// | 路径 | 方向 | 规则 |
/// |---|---|---|
/// | snapshots/ taskboards/ presence/ | 按文件 | 文件名==本机 machineID → 推（新者胜）；其他 → 拉（新者胜） |
/// | dashboard.json office.json repos.json | 推 | 本地新就推（last-writer-wins，和旧行为一致） |
/// | config/ releases/ | 双向 | 每文件新者胜 |
/// | questions/<本机ID>/ | 精确推 | 本机子目录里本地是唯一真相：云端 := 本地（含删除） |\n/// | outbox/ | 只推不删 | 多机共写的扁平目录，「本地没有」可能是别人的东西 |
/// | inbox/ config-intents/ answers/<本机ID>/ | 抢占拉 | 先读内容、再把云端文件 move 进云端 processed/，抢到才落地 |
///
/// # 两条铁律
///
/// 1. **所有云端操作走 `ICloudSafe`**（read/write/move/list/remove/
///    ensureDir/modificationDate）。本地操作直接 FileManager。
/// 2. **「读不到」≠「没有」**。云端目录列不动（`.stalled`）时整个目录
///    这一轮跳过并记进 lastError —— 绝不能当成空目录去执行精确推的删除，
///    那会把云端的问题/结果文件全删光。
public enum MirrorService {

    public static let stateFileName = ".mirror-state.json"
    /// mtime 比较容差。iCloud 搬运会轻微抖动 mtime，1 秒内的差别不算新。
    public static let tolerance: TimeInterval = 2

    static let perMachineDirs = ["snapshots", "taskboards", "presence"]
    static let rootPushFiles = ["dashboard.json", "office.json", "repos.json"]
    static let bidirectionalDirs = ["config", "releases"]

    /// 永不搬的文件：`.sb-` 半成品（原子写卡在 rename 留下的）、
    /// 心跳文件、一切点开头的文件。
    static func excluded(_ name: String) -> Bool {
        name.hasPrefix(".") || name.contains(Debris.marker) || name == stateFileName
    }

    /// 跑一轮镜像。
    ///
    /// - Parameters:
    ///   - local: 本地暂存根（产品代码里是 `Paths.sharedRoot`）。
    ///   - cloud: iCloud 里的 LLMQuotaBar/ 根（App 用书签解出来的那个）。
    ///   - cloudList / cloudMove: 测试注入口。产品代码永远不传 ——
    ///     默认走 `ICloudSafe`。测试用它模拟「云端列不动」和「抢占输了」，
    ///     这两种情况在纯本地的临时目录上造不出来。
    @discardableResult
    public static func sync(
        local: URL, cloud: URL, selfMachineID: String, now: Date = Date(),
        cloudList: ((URL) -> ICloudSafe.Probe<[URL]>)? = nil,
        cloudMove: ((URL, URL) -> Bool)? = nil
    ) -> MirrorStats {
        let list = cloudList ?? { ICloudSafe.list($0) }
        let move = cloudMove ?? { ICloudSafe.move($0, to: $1) }
        var stats = MirrorStats()

        SharedLayout.ensure(at: local)
        try? FileManager.default.createDirectory(
            at: local.appendingPathComponent("answers/\(selfMachineID)", isDirectory: true),
            withIntermediateDirectories: true)

        // snapshots/ taskboards/ presence/：本机的推、别人的拉，各自新者胜。
        for d in perMachineDirs {
            syncPerMachine(
                localDir: local.appendingPathComponent(d, isDirectory: true),
                cloudDir: cloud.appendingPathComponent(d, isDirectory: true),
                label: d, selfMachineID: selfMachineID, list: list, stats: &stats)
        }

        // 根下三个单文件：本地新就推。
        for name in rootPushFiles {
            pushIfNewer(localFile: local.appendingPathComponent(name),
                        cloudFile: cloud.appendingPathComponent(name),
                        label: name, stats: &stats)
        }

        // config/ releases/：双向，每文件新者胜。
        for d in bidirectionalDirs {
            syncBidirectional(
                localDir: local.appendingPathComponent(d, isDirectory: true),
                cloudDir: cloud.appendingPathComponent(d, isDirectory: true),
                label: d, list: list, stats: &stats)
        }

        // questions/<本机ID>/：精确推。**只动本机那个子目录** ——
        // 云端 questions/ 下还有别的机器的子目录，它们的真相在别的机器上，
        // 拿本机的「没有」去删别人的问题就是删数据。
        exactPush(
            localDir: local.appendingPathComponent("questions/\(selfMachineID)", isDirectory: true),
            cloudDir: cloud.appendingPathComponent("questions/\(selfMachineID)", isDirectory: true),
            label: "questions/\(selfMachineID)", list: list, stats: &stats)

        // outbox/：**只推不删**。
        //
        // 第一版契约把它写成了「精确推含删除」——审查抓出这是双机互删：
        // 云端 outbox 是两台机器共写的**扁平目录**，A 的「云端 := 本地」
        // 会把 B 的任务结果从云端删掉，B 下一轮推回来，A 再删……
        // 来回拍打，手机上的任务结果时有时无。
        //
        // 而旧架构里（CLI 直写 iCloud）从来没有任何东西删过 outbox ——
        // 结果文件按 taskID 覆盖、只增不删。「只推不删」才是原语义。
        pushDirNoDelete(
            localDir: local.appendingPathComponent("outbox", isDirectory: true),
            cloudDir: cloud.appendingPathComponent("outbox", isDirectory: true),
            label: "outbox", stats: &stats)

        // 抢占拉：消费类目录。旧架构里「move 到 processed」发生在 iCloud 上，
        // 先移者赢，天然仲裁两台 Mac 不把同一个任务执行两遍 —— 必须保住。
        for spec in claimSpecs(selfMachineID: selfMachineID) {
            claimPull(
                localDir: local.appendingPathComponent(spec.dir, isDirectory: true),
                cloudDir: cloud.appendingPathComponent(spec.dir, isDirectory: true),
                cloudProcessed: cloud.appendingPathComponent(spec.processed, isDirectory: true),
                label: spec.dir, now: now, list: list, move: move, stats: &stats)
        }

        writeHeartbeat(local: local, stats: stats, now: now)
        return stats
    }

    // MARK: - 心跳

    /// App 起来了但用户还没授权时写的心跳。
    ///
    /// 没有它，CLI 那侧只能看到「没有心跳文件」，而那个状态和
    /// 「App 压根没在跑」长得一模一样 —— 两者的提示完全不同：
    /// 一个是「去点授权」，一个是「把 App 打开」。
    public static func writeUnauthorizedHeartbeat(local: URL, now: Date = Date()) {
        var stats = MirrorStats()
        stats.errors = ["未授权：还没在菜单栏 App 里选择 iCloud 文件夹"]
        writeHeartbeat(local: local, stats: stats, now: now)
    }

    static func writeHeartbeat(local: URL, stats: MirrorStats, now: Date) {
        let url = local.appendingPathComponent(stateFileName)
        let prev = ICloudSafe.read(url).flatMap {
            try? SnapshotCoding.decoder().decode(MirrorState.self, from: $0)
        }
        let state = MirrorState(
            schemaVersion: 1,
            lastAttemptAt: now,
            // 出错的轮次不动 lastOKAt —— 它的语义是「上一次完整成功」，
            // 拿一次半残的轮次去刷新它，doctor 就会把病说成健康。
            lastOKAt: stats.errors.isEmpty ? now : prev?.lastOKAt,
            lastError: stats.errors.isEmpty
                ? nil : stats.errors.prefix(3).joined(separator: "；"),
            pushed: stats.pushed, pulled: stats.pulled, claimed: stats.claimed)
        guard let data = try? SnapshotCoding.prettyEncoder().encode(state) else { return }
        ICloudSafe.write(data, to: url)
    }

    // MARK: - 规则实现

    /// snapshots/ 那一类：文件名（去扩展名）== 本机 machineID 的推，其他的拉。
    static func syncPerMachine(
        localDir: URL, cloudDir: URL, label: String, selfMachineID: String,
        list: (URL) -> ICloudSafe.Probe<[URL]>, stats: inout MirrorStats
    ) {
        guard let cloudFiles = listOrSkip(cloudDir, label: label, list: list, stats: &stats)
        else { return }
        _ = ICloudSafe.ensureDir(cloudDir)
        let localFiles = regularFiles(in: localDir)
        let cloudByName = Dictionary(cloudFiles.map { ($0.lastPathComponent, $0) },
                                     uniquingKeysWith: { a, _ in a })
        let localByName = Dictionary(localFiles.map { ($0.lastPathComponent, $0) },
                                     uniquingKeysWith: { a, _ in a })

        for name in Set(cloudByName.keys).union(localByName.keys) where !excluded(name) {
            let mine = (name as NSString).deletingPathExtension == selfMachineID
            let localURL = localDir.appendingPathComponent(name)
            let cloudURL = cloudDir.appendingPathComponent(name)
            if mine {
                guard localByName[name] != nil else { continue }   // 本机文件只从本地流出
                pushIfNewer(localFile: localURL, cloudFile: cloudURL,
                            label: "\(label)/\(name)", stats: &stats)
            } else {
                guard cloudByName[name] != nil else { continue }   // 别人的文件只从云端流入
                pullIfNewer(cloudFile: cloudURL, localFile: localURL,
                            label: "\(label)/\(name)", stats: &stats)
            }
        }
    }

    /// config/ releases/：双向，每文件新者胜。
    static func syncBidirectional(
        localDir: URL, cloudDir: URL, label: String,
        list: (URL) -> ICloudSafe.Probe<[URL]>, stats: inout MirrorStats
    ) {
        guard let cloudFiles = listOrSkip(cloudDir, label: label, list: list, stats: &stats)
        else { return }
        _ = ICloudSafe.ensureDir(cloudDir)
        let localFiles = regularFiles(in: localDir)
        let cloudNames = Set(cloudFiles.map(\.lastPathComponent))
        let localNames = Set(localFiles.map(\.lastPathComponent))

        for name in cloudNames.union(localNames) where !excluded(name) {
            let localURL = localDir.appendingPathComponent(name)
            let cloudURL = cloudDir.appendingPathComponent(name)
            switch (localNames.contains(name), cloudNames.contains(name)) {
            case (true, false):
                pushIfNewer(localFile: localURL, cloudFile: cloudURL,
                            label: "\(label)/\(name)", stats: &stats)
            case (false, true):
                pullIfNewer(cloudFile: cloudURL, localFile: localURL,
                            label: "\(label)/\(name)", stats: &stats)
            case (true, true):
                let lm = localMTime(localURL)
                guard let cm = ICloudSafe.modificationDate(cloudURL) else {
                    // stat 不动 ≠ 云端很旧。这一条只能跳过，不能拿本地去盖。
                    stats.errors.append("\(label)/\(name)：云端 mtime 读不动，这一轮跳过")
                    continue
                }
                if let lm, lm > cm + tolerance {
                    pushIfNewer(localFile: localURL, cloudFile: cloudURL,
                                label: "\(label)/\(name)", stats: &stats)
                } else if lm == nil || cm > lm! + tolerance {
                    pullIfNewer(cloudFile: cloudURL, localFile: localURL,
                                label: "\(label)/\(name)", stats: &stats)
                }
            case (false, false):
                break
            }
        }
    }

    /// 只推不删：本地有的、比云端新的推上去；云端多出来的**一个不碰**。
    ///
    /// 给多机共写的扁平目录用（outbox）。这种目录里「本地没有」不代表
    /// 「不该存在」—— 那可能是另一台机器的东西。
    static func pushDirNoDelete(
        localDir: URL, cloudDir: URL, label: String, stats: inout MirrorStats
    ) {
        let localFiles = regularFiles(in: localDir)
        guard !localFiles.isEmpty else { return }
        _ = ICloudSafe.ensureDir(cloudDir)
        for f in localFiles where !excluded(f.lastPathComponent) {
            pushIfNewer(localFile: f,
                        cloudFile: cloudDir.appendingPathComponent(f.lastPathComponent),
                        label: "\(label)/\(f.lastPathComponent)", stats: &stats)
        }
    }

    /// 精确推：云端 := 本地，**含删除**。
    ///
    /// 删除只发生在「云端列表拿到了确定答案」之后 ——
    /// `.stalled`（列不动）时整个目录跳过。把「列不动」当「空的」，
    /// 就是把云端的问题/结果文件全删光，这是本项目那类错误里后果最重的变体。
    static func exactPush(
        localDir: URL, cloudDir: URL, label: String,
        list: (URL) -> ICloudSafe.Probe<[URL]>, stats: inout MirrorStats
    ) {
        guard let cloudFiles = listOrSkip(cloudDir, label: label, list: list, stats: &stats)
        else { return }
        _ = ICloudSafe.ensureDir(cloudDir)
        let localFiles = regularFiles(in: localDir)
        let localNames = Set(localFiles.map(\.lastPathComponent))

        for f in localFiles where !excluded(f.lastPathComponent) {
            pushIfNewer(localFile: f,
                        cloudFile: cloudDir.appendingPathComponent(f.lastPathComponent),
                        label: "\(label)/\(f.lastPathComponent)", stats: &stats)
        }
        for c in cloudFiles {
            let name = c.lastPathComponent
            // 云端的 .sb- 半成品和点文件不归镜像管（doctor --tidy 才管），
            // 子目录（processed/）也不动。
            guard !excluded(name), !localNames.contains(name),
                  ICloudSafe.isRegularFile(c) else { continue }
            if ICloudSafe.remove(c) {
                stats.pushed += 1
            } else {
                stats.errors.append("\(label)/\(name)：该删没删掉（iCloud 没响应）")
            }
        }
    }

    struct ClaimSpec { var dir: String; var processed: String }

    static func claimSpecs(selfMachineID: String) -> [ClaimSpec] {
        [
            ClaimSpec(dir: "inbox", processed: "inbox/processed"),
            ClaimSpec(dir: "config-intents", processed: "config-intents/processed"),
            ClaimSpec(dir: "answers/\(selfMachineID)",
                      processed: "answers/\(selfMachineID)/processed"),
        ]
    }

    /// 抢占拉。
    ///
    /// 1. 先 `ICloudSafe.read` 云端内容，写到本地临时文件
    /// 2. **抢占**：把云端文件 move 进云端 processed/
    /// 3. 抢到 → 临时文件落到本地对应目录，等 CLI 消费
    /// 4. 没抢到（另一台先抢了，或 iCloud 没响应）→ 删临时文件，下轮再看
    ///
    /// processed 里的命名照抄 CLI 的习惯（`Inbox.park` /
    /// `ConfigIntentIngest.park` / `AskStore.archive` 都是
    /// `<stamp>-<verdict>-<原名>`）—— 手机端靠「文件从 inbox 消失了没有」
    /// 判断送达，样子必须和原来 CLI 直接操作 iCloud 时一致。
    static func claimPull(
        localDir: URL, cloudDir: URL, cloudProcessed: URL, label: String, now: Date,
        list: (URL) -> ICloudSafe.Probe<[URL]>,
        move: (URL, URL) -> Bool, stats: inout MirrorStats
    ) {
        guard let cloudFiles = listOrSkip(cloudDir, label: label, list: list, stats: &stats)
        else { return }
        try? FileManager.default.createDirectory(
            at: localDir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "")

        for url in cloudFiles {
            let name = url.lastPathComponent
            // 别的设备刚写的文件可能还是没下载的占位符 —— 触发下载，下轮再收。
            if url.pathExtension == "icloud" {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard !excluded(name), name != "processed",
                  ICloudSafe.isRegularFile(url) else { continue }

            // ① 内容先到手。读不到（没下载完/卡住）就不抢 —— 抢到一个空壳，
            //    文件从手机上消失了、内容却永远没进任何机器，等于弄丢任务。
            guard let data = ICloudSafe.read(url), !data.isEmpty else { continue }
            let tmp = localDir.appendingPathComponent(".claim-\(UUID().uuidString).tmp")
            guard ICloudSafe.write(data, to: tmp) else { continue }

            // ② 抢占：move 是原子的，先移者赢。
            _ = ICloudSafe.ensureDir(cloudProcessed)
            let parked = cloudProcessed.appendingPathComponent("\(stamp)-claimed-\(name)")
            if move(url, parked) {
                // ③ 抢到了：落到本地，等 CLI 消费。
                let dest = localDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil {
                    stats.claimed += 1
                } else {
                    try? FileManager.default.removeItem(at: tmp)
                    stats.errors.append("\(label)/\(name)：抢到了但落不了地")
                }
            } else {
                // ④ 没抢到：另一台先抢了，或 iCloud 没响应。都不是错，下轮再看。
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    // MARK: - 底层搬运

    /// 本地 → 云端，本地新才动。成功后把本地 mtime 触新到「现在」，
    /// 让两边落在容差内 —— 否则云端 mtime 变成刚写入的「现在」、比本地新，
    /// 下一轮双向规则会把同样的内容拉回来，再下一轮又推回去，永远打乒乓。
    static func pushIfNewer(localFile: URL, cloudFile: URL, label: String,
                            stats: inout MirrorStats) {
        guard let lm = localMTime(localFile) else { return }   // 本地没有就没什么可推
        if let cm = ICloudSafe.modificationDate(cloudFile), lm <= cm + tolerance { return }
        guard let data = try? Data(contentsOf: localFile) else {
            stats.errors.append("\(label)：本地读不出来")
            return
        }
        _ = ICloudSafe.ensureDir(cloudFile.deletingLastPathComponent())
        if ICloudSafe.write(data, to: cloudFile) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: localFile.path)
            stats.pushed += 1
        } else {
            stats.errors.append("\(label)：推不上去（iCloud 没响应）")
        }
    }

    /// 云端 → 本地，云端新才动。落地后把本地 mtime 对齐云端的 ——
    /// 不对齐的话本地 mtime 是「现在」、比云端新，下一轮会被当成本地改动推回去。
    static func pullIfNewer(cloudFile: URL, localFile: URL, label: String,
                            stats: inout MirrorStats) {
        guard let cm = ICloudSafe.modificationDate(cloudFile) else {
            stats.errors.append("\(label)：云端 mtime 读不动，这一轮跳过")
            return
        }
        if let lm = localMTime(localFile), cm <= lm + tolerance { return }
        guard let data = ICloudSafe.read(cloudFile) else {
            stats.errors.append("\(label)：云端读不动，这一轮跳过")
            return
        }
        try? FileManager.default.createDirectory(
            at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if ICloudSafe.write(data, to: localFile) {
            try? FileManager.default.setAttributes(
                [.modificationDate: cm], ofItemAtPath: localFile.path)
            stats.pulled += 1
        } else {
            stats.errors.append("\(label)：本地写不进去")
        }
    }

    /// 列云端目录。`.stalled` → 记错误、整个目录这一轮跳过（返回 nil）；
    /// `.failed` → 目录确实不存在，当空目录处理（这是**确定的**答案）。
    static func listOrSkip(
        _ dir: URL, label: String, list: (URL) -> ICloudSafe.Probe<[URL]>,
        stats: inout MirrorStats
    ) -> [URL]? {
        switch list(dir) {
        case .ok(let files): return files
        case .failed: return []
        case .stalled:
            stats.errors.append("\(label)/：云端目录列不动（iCloud 没响应），这一轮跳过")
            return nil
        }
    }

    static func regularFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .filter { isLocalRegularFile($0) }
    }

    /// 只给**本地** URL 用。云端一律走 `ICloudSafe.isRegularFile` ——
    /// 对云端 URL 做裸 stat 会永久挂起（审查抓出来过）。
    static func isLocalRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
    }

    static func localMTime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date
    }
}

// MARK: - 心跳三态

/// CLI 侧对心跳的判读。**三态措辞必须分开** ——
/// 「从未授权」「App 没在跑」「镜像在报错」的修法完全不同，
/// 混成一句「没同步」会让人查错方向。
public enum MirrorHealth {

    /// 超过这么久没有镜像尝试，就当 App 不在跑。
    /// App 的镜像周期是 30 秒，5 分钟等于整整十轮没到。
    public static let staleAfter: TimeInterval = 5 * 60

    public enum Status: Sendable {
        /// 心跳新鲜且上一轮零错误。
        case ok(MirrorState)
        /// 没有心跳文件：App 从来没跑过镜像 —— 多半是还没授权 iCloud 目录。
        case neverSynced
        /// 心跳存在但太旧：App 没在跑（或被卡死）。
        case appNotRunning(MirrorState)
        /// App 在跑（lastAttemptAt 新鲜），但镜像在报错。
        case failing(MirrorState)
    }

    public static func check(root: URL = Paths.sharedRoot, now: Date = Date()) -> Status {
        let url = root.appendingPathComponent(MirrorService.stateFileName)
        guard let data = try? Data(contentsOf: url),
              let st = try? SnapshotCoding.decoder().decode(MirrorState.self, from: data)
        else { return .neverSynced }
        if now.timeIntervalSince(st.lastAttemptAt) > staleAfter {
            return .appNotRunning(st)
        }
        if st.lastError == nil, let ok = st.lastOKAt,
           now.timeIntervalSince(ok) <= staleAfter {
            return .ok(st)
        }
        return .failing(st)
    }

    /// 一句给人看的话。措辞区分三态，并直接说下一步该干什么。
    public static func describe(_ s: Status, now: Date = Date()) -> String {
        switch s {
        case .ok(let st):
            let when = st.lastOKAt.map { Format.relative($0, now: now) } ?? "刚刚"
            return "菜单栏 App 在同步（上次成功 \(when)，推 \(st.pushed) 拉 \(st.pulled)"
                + (st.claimed > 0 ? " 领 \(st.claimed)" : "") + "）"
        case .neverSynced:
            return "菜单栏 App 从未同步过（没有心跳文件）—— 多半是还没授权："
                + "打开 LLMQuotaBar，在里面选择 iCloud Drive 的 LLMQuotaBar 文件夹完成授权"
        case .appNotRunning(let st):
            return "菜单栏 App 没在跑（上次镜像尝试是 "
                + Format.relative(st.lastAttemptAt, now: now)
                + "）—— 打开 LLMQuotaBar，它在跑镜像才会同步"
        case .failing(let st):
            let ok = st.lastOKAt.map { "上次成功 " + Format.relative($0, now: now) }
                ?? "还没成功过"
            return "菜单栏 App 在跑，但镜像在报错：" + (st.lastError ?? "未知错误")
                + "（\(ok)）"
        }
    }
}
