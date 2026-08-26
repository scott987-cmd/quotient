import Foundation

/// 机器层面的家务:磁盘余量、验收残留。
///
/// ## 这东西对应的真实故障(2026-08-21 晚)
///
/// 磁盘剩 179MB(99%)时整条流水线无声地烂掉:worktree 建不出来(255)、
/// opencode 的 SQLite 写不进去、构建超时、交接链一个接一个倒 —— 队列排空成
/// 一地 failed,没有任何一层说「磁盘满了」。老板问「任务怎么停了」才查到。
///
/// 最大的一份垃圾是 **36 个 `llmq-verify-*` 临时目录,7GB**:verifyMerge
/// 有 defer 清理,但 worker 被 `launchctl kickstart -k` 杀掉时 defer 不会跑 ——
/// 每次装机撞上正在跑的验收就漏一个。
public enum Housekeeping {
    /// 验收临时目录的前缀,和 Review.verifyMerge 里的写法是一对。
    public static let verifyPrefix = "llmq-verify-"
    /// 超过这个年龄的验收目录一定是残留:验收上限 900 秒,给 3 倍余量。
    public static let verifyStaleAfter: TimeInterval = 45 * 60
    /// 低于这个余量就别派活了 —— 派了也只会失败,还把现场搞得更糟。
    public static let lowDiskBytes: Int64 = 2 * 1024 * 1024 * 1024

    public static func freeDiskBytes(at path: String = NSHomeDirectory()) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize] as? Int64
    }

    /// 扫掉过期的验收残留。返回删掉的目录数。
    /// - Parameter tempDir: 默认系统临时目录;测试传自己的。
    @discardableResult
    public static func sweepVerifyLeftovers(tempDir: String = NSTemporaryDirectory(),
                                            now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: tempDir) else { return 0 }
        var removed = 0
        for n in names where n.hasPrefix(verifyPrefix) {
            let p = (tempDir as NSString).appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: p)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            guard now.timeIntervalSince(mtime) > verifyStaleAfter else { continue }
            if (try? fm.removeItem(atPath: p)) != nil { removed += 1 }
        }
        return removed
    }

    /// 菜单栏 App 在不在。**它一死,这台机器的 iCloud 镜像就停** ——
    /// 本机数据照常更新,手机上却停在几十分钟前,看起来就像「任务停了」。
    /// 2026-08-22 一天里发生两次,两次都是老板先发现的。
    public static func menuBarAppAlive() -> Bool {
        Proc.run("/usr/bin/pgrep", ["-f", "LLMQuotaBar.app/Contents/MacOS"],
                 cwd: "/", env: [:], timeout: 5).exitCode == 0
    }

    /// 没在跑就拉起来,拉不起来就在日志里喊。返回给日志的一句话。
    static func reviveMenuBarApp() -> String? {
        guard FileManager.default.fileExists(atPath: "/Applications/LLMQuotaBar.app"),
              !menuBarAppAlive() else { return nil }
        _ = Proc.run("/usr/bin/open", ["-a", "LLMQuotaBar"], cwd: "/", env: [:], timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        return menuBarAppAlive()
            ? "菜单栏 App 之前不在,已拉起(它停着的时候手机看到的是旧快照)"
            : "⚠︎ 菜单栏 App 起不来 —— 手机上会一直看到旧数据,手动 open -a LLMQuotaBar"
    }

    /// 清掉没人再引用的证据文件。
    ///
    /// 共享证据目录只增不减:分支落地之后,它那几张图/几段录屏还留着。
    /// 实测 2026-08-22:64 个文件 46MB,而当前待审只引用 11 个 ——
    /// 53 个是垃圾,却每天在 iCloud 上来回同步,手机端也要为它们排队。
    /// 判据:不在任何一条待审记录里的,删。
    @discardableResult
    static func sweepOrphanEvidence() -> Int {
        let dir = Review.evidenceDir
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let live = Set(Review.publishedDigests().flatMap(\.evidenceFiles))
        var removed = 0
        for n in names where !live.contains(n) {
            // 刚抽出来还没发布的别删 —— 半小时宽限。
            let p = (dir.path as NSString).appendingPathComponent(n)
            let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            guard Date().timeIntervalSince(m ?? .distantPast) > 1800 else { continue }
            if (try? fm.removeItem(atPath: p)) != nil { removed += 1 }
        }
        return removed
    }

    /// 一轮开始时做的家务,返回给日志的一句话(没事就 nil)。
    /// `performMaintenance == false` 用于 `--dry-run`：只读磁盘余量，不做清理或拉起操作。
    public static func roundCheck(performMaintenance: Bool = true)
        -> (skipDispatch: Bool, note: String?) {
        var notes: [String] = []
        if performMaintenance {
            let swept = sweepVerifyLeftovers()
            if let n = reviveMenuBarApp() { notes.append(n) }
            if swept > 0 { notes.append("清掉 \(swept) 个过期验收目录") }
            let orphans = sweepOrphanEvidence()
            if orphans > 0 { notes.append("清掉 \(orphans) 个没人引用的证据文件") }
            // 过时机器身份留下的孤儿快照/任务板/在线状态 —— 同名机器只留最新的。
            // 详见 StaleIdentitySweep:machineID 漂移期留下的一堆旧身份文件,
            // 手机上一台机器裂成十几个(2026-08-23)。
            let staleIds = StaleIdentitySweep.run()
            if staleIds > 0 { notes.append("清掉 \(staleIds) 个过时机器身份的残留文件") }
        }
        if let free = freeDiskBytes(), free < lowDiskBytes {
            notes.append("⚠︎ 磁盘只剩 \(Format.bytes(Int(free))) —— 本轮不派活(派了也只会失败),请清理")
            return (true, notes.joined(separator: "；"))
        }
        return (false, notes.isEmpty ? nil : notes.joined(separator: "；"))
    }
}
