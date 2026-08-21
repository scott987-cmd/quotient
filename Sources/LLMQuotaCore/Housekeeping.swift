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

    /// 一轮开始时做的家务,返回给日志的一句话(没事就 nil)。
    public static func roundCheck() -> (skipDispatch: Bool, note: String?) {
        let swept = sweepVerifyLeftovers()
        var notes: [String] = []
        if swept > 0 { notes.append("清掉 \(swept) 个过期验收目录") }
        if let free = freeDiskBytes(), free < lowDiskBytes {
            notes.append("⚠︎ 磁盘只剩 \(Format.bytes(Int(free))) —— 本轮不派活(派了也只会失败),请清理")
            return (true, notes.joined(separator: "；"))
        }
        return (false, notes.isEmpty ? nil : notes.joined(separator: "；"))
    }
}
