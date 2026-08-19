import Foundation

/// 常驻工作循环的运行时约束。
///
/// 这些闸门不是可选的保险，是这个功能能不能存在的前提。
/// 一个无人看管、会自动派 agent 的循环，跑飞的后果是把额度烧光、
/// 或者在一个坏掉的任务上无限重试。所以每一条闸门都对应一种具体的跑飞方式。
public struct LoopPolicy: Codable, Sendable {
    /// 两次检查队列的间隔。
    public var tickSeconds: TimeInterval = 30
    /// 多久重新采集一次用量。比 tick 长得多 —— 采集要扫日志，没必要每次都跑。
    public var collectSeconds: TimeInterval = 300
    /// 每小时最多派多少个任务。
    ///
    /// 防的是"任务瞬间失败 → 循环立刻取下一个 → 一分钟烧掉几十次调用"。
    /// 失败很快的场景（比如认证坏了）恰恰是最容易跑飞的。
    public var maxTasksPerHour: Int = 12
    /// 连续失败多少次就停下来等人。
    ///
    /// 全部平台都坏了的时候，继续跑只是把每个任务都失败一遍，
    /// 还会给你刷一堆飞书通知。
    public var stopAfterConsecutiveFailures: Int = 5
    /// 空闲多久打印一次心跳。太频繁会把日志刷满。
    public var heartbeatSeconds: TimeInterval = 1800

    public init() {}
}

/// 单实例锁。
///
/// 两个循环同时跑会把同一个任务派两遍 —— 任务状态是"取出即标记 running"，
/// 但两个进程可能在同一瞬间都读到 queued。与其做复杂的原子取任务，
/// 不如从根上保证只有一个循环存在。
public final class SingleInstanceLock {
    private let url: URL
    private var handle: FileHandle?

    public init(name: String) {
        self.url = Paths.appSupport.appendingPathComponent("\(name).lock")
    }

    /// 拿锁。拿不到说明已经有一个实例在跑。
    public func acquire() -> Bool {
        try? Paths.ensureDirectories()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return false }
        // flock 是内核级的，进程被 kill -9 也会自动释放 ——
        // 比"写 PID 文件再检查进程活着没"可靠得多，后者会留下僵尸锁。
        guard flock(fh.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? fh.close()
            return false
        }
        try? fh.truncate(atOffset: 0)
        try? fh.write(contentsOf: Data("\(getpid())\n".utf8))
        handle = fh
        return true
    }

    public func release() {
        guard let fh = handle else { return }
        flock(fh.fileDescriptor, LOCK_UN)
        try? fh.close()
        handle = nil
    }

    /// 锁被谁占着。
    public func holderPID() -> Int32? {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }
}

/// 派发速率闸门。
public struct RateGate: Sendable {
    private var recent: [Date] = []
    private let limit: Int
    private let window: TimeInterval = 3600

    public init(maxPerHour: Int) { self.limit = maxPerHour }

    public mutating func allow(now: Date = Date()) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) > window }
        guard recent.count < limit else { return false }
        recent.append(now)
        return true
    }

    /// **退回刚才那一槽 —— 那次派发根本没花额度。**
    ///
    /// `allow()` 必须在真跑之前调用（它是闸），可有些结局一个字都没发出去：
    /// 所有平台都在冷却时 `runOneTask` 返回 `.noPlatform`，
    /// 任务原样留在队列里，什么都没消耗。这种情况扣一槽就是纯亏。
    ///
    /// 实测（2026-08-19）：队列里一条钉在 qwen 的证据任务，
    /// 而 **qwen 冷却还有 5 天** —— 每小时 12 个槽**全部**烧在它身上，
    /// 20 分钟耗光（日志里 12 次「取到任务」、0 个任务创建、0 个完成），
    /// 然后上限把所有真活挡在门外，剩下 40 分钟整台机器空转。
    ///
    /// **调用契约**：紧跟在 `allow()` 返回 true 的那次之后调用，中间不能
    /// 再有别的 `allow()`。这个循环是单线程顺序执行的，满足这个前提。
    public mutating func refund() {
        if !recent.isEmpty { recent.removeLast() }
    }

    public mutating func nextAllowed(now: Date = Date()) -> Date? {
        recent.removeAll { now.timeIntervalSince($0) > window }
        guard recent.count >= limit, let oldest = recent.min() else { return nil }
        return oldest.addingTimeInterval(window)
    }

    public var usedInWindow: Int { recent.count }
}
