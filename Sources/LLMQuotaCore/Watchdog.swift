import Foundation

/// 把可能**永久阻塞**的操作关进看门狗。
///
/// # 为什么需要这个
///
/// `llmq work loop` 的每一轮都会调 `LLMQuota.collect`，而它一口气做六件
/// iCloud 上的读写：写快照、镜像回本地、同步配置、发布看板、发布仓库清单、
/// 上报集群状态。**这六件事全都没有超时。**
///
/// 实测出过什么后果：`Inbox.publishDashboard` 的
/// `Data.write(to:options:.atomic)` 卡在 `rename()` 上，`sample` 显示
/// 2633/2633 采样全停在那一帧，工作循环 70 秒零输出 —— 进程活着，
/// 但整条自动化流水线**永久停摆**。iCloud 目录里还留下四个孤儿临时文件
/// （`.atomic` 是先写临时文件再 rename），时间戳正好对应四次启动后卡死。
///
/// 根因是另一回事（见 doctor 里那条受保护目录的检查），但**无论根因是什么，
/// 一个只是「给手机看一眼」的写入，都不该有能力冻住整条流水线**。
/// 这就是这个文件存在的理由：把「尽力而为」的事情降级成真的尽力而为。
///
/// # 它做什么、不做什么
///
/// 做：在后台线程跑，到点就让调用方继续走。
/// 不做：它**杀不掉**那个卡住的线程 —— 阻塞在内核 `rename()`/`open()` 里的
/// 线程没法从用户态取消。所以超时之后那个线程仍然挂着。
///
/// 正因为杀不掉，才必须防止线程堆积：同一个 key 上一次还没回来时，
/// 后面的调用直接跳过，不再派新线程。否则每 30 秒一轮、每轮泄漏一个线程，
/// 一小时就是 120 个 —— 那四个孤儿临时文件就是这么来的。
public enum Watchdog {
    private static let lock = NSLock()
    private static var inFlight: Set<String> = []
    private static var skipped: [String: Int] = [:]
    private static var operationGenerations: [String: UUID] = [:]

    /// 被跳过的次数，按 key。给 doctor 用 —— 「一直在跳过」本身就是要报的故障。
    public static func skipCounts() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return skipped
    }

    public static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        inFlight.removeAll(); skipped.removeAll(); operationGenerations.removeAll()
    }

    /// 结果三态。**别把「超时」和「上一次还卡着」合并成一个 nil** ——
    /// 前者是这次慢，后者是已经病了一段时间了，报给人看时的含义完全不同。
    public enum Outcome<T> {
        case done(T)
        /// 跑了，但超过 `timeout` 还没回来。线程还挂着。
        case timedOut
        /// 同一个 key 上一次还没回来，这次直接没派。
        case skipped
    }

    /// 在后台线程跑 `body`，最多等 `timeout` 秒。
    ///
    /// - Parameter key: 同一个 key 同时只会有一个在飞。用调用点能认出来的名字。
    @discardableResult
    public static func run<T>(
        _ key: String,
        timeout: TimeInterval = 8,
        _ body: @escaping () -> T
    ) -> Outcome<T> {
        lock.lock()
        if inFlight.contains(key) {
            skipped[key, default: 0] += 1
            lock.unlock()
            return .skipped
        }
        inFlight.insert(key)
        lock.unlock()

        let sem = DispatchSemaphore(value: 0)
        // `box` 只在两处被碰：后台线程写一次，主线程在 sem 放行后读一次。
        // 中间隔着信号量，有 happens-before，所以不需要额外加锁。
        let box = Box<T>()
        DispatchQueue.global(qos: .utility).async {
            let v = body()
            box.value = v
            lock.lock(); inFlight.remove(key); lock.unlock()
            sem.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            // 注意：这里**不能**把 key 从 inFlight 里拿掉。
            // 那个线程还挂着，拿掉就等于允许下一轮再派一个 —— 正是要防的事。
            return .timedOut
        }
        return box.value.map { Outcome.done($0) } ?? .timedOut
    }

    /// 两阶段看门狗：后台只计算 `prepare`，真正的状态/视图提交在确认本次
    /// operation generation 仍有效后执行。调用方超时会立刻废弃 generation；
    /// 旧线程日后恢复，只能丢掉结果，不能幽灵回写。
    @discardableResult
    public static func runLatest<T>(
        _ key: String,
        timeout: TimeInterval = 8,
        prepare: @escaping () -> T,
        commit: @escaping (T) -> Void
    ) -> Outcome<T> {
        lock.lock()
        if inFlight.contains(key) {
            skipped[key, default: 0] += 1
            lock.unlock()
            return .skipped
        }
        let generation = UUID()
        inFlight.insert(key)
        operationGenerations[key] = generation
        lock.unlock()

        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        DispatchQueue.global(qos: .utility).async {
            let value = prepare()
            lock.lock()
            let current = operationGenerations[key] == generation
            if current { operationGenerations.removeValue(forKey: key) }
            inFlight.remove(key)
            lock.unlock()
            if current { commit(value) }
            box.value = value
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            if operationGenerations[key] == generation {
                operationGenerations.removeValue(forKey: key)
            }
            lock.unlock()
            return .timedOut
        }
        return box.value.map { Outcome.done($0) } ?? .timedOut
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

/// 往 iCloud 上写东西的统一入口。
///
/// # 为什么必须是一个收口点，而不是在每个调用点包一层
///
/// 第一版我手工把 `collect()` 里那六处 iCloud 操作包进了看门狗，跑起来
/// 循环确实活了 —— 然后 worker 又冻住了，这次栈是
/// `runOneTask → OfficeLog.publish → Data.write(.atomic) → rename()`。
/// 另一条路径，同一个病。**手工枚举调用点这件事，我第一次做就漏了。**
///
/// 所以判断放进函数里：目标在 iCloud 下就进看门狗，不在就直接写、零开销。
/// 以后新增的写入只要走这个函数，就自动是安全的。
public enum ICloudSafe {
    /// iCloud Drive 在磁盘上的固定前缀。判路径而不是判调用点，
    /// 这样漏一个调用点的代价是「没保护」而不是「保护错了对象」。
    public static func isICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    /// 原子写。iCloud 上的写入永远不会阻塞调用方超过 `timeout` 秒。
    ///
    /// - Returns: 真的写进去了吗。**超时返回 false** ——
    ///   那个线程可能几小时后才回来，甚至永远不回来，不能当成功。
    @discardableResult
    public static func write(_ data: Data, to url: URL, timeout: TimeInterval = 8) -> Bool {
        guard PublicationGeneration.allowsPublication() else { return false }
        guard isICloud(url) else {
            return (try? data.write(to: url, options: .atomic)) != nil
        }
        // key 用完整路径：不同文件互不牵连，同一个文件卡住时后续直接跳过。
        return Watchdog.run("icloud.write:" + url.path, timeout: timeout) {
            (try? data.write(to: url, options: .atomic)) != nil
        }.valueOr(false)
    }

    /// 带超时的读。
    ///
    /// **读和写一样会永久阻塞** —— 这一条我漏过一次，代价是菜单栏 App 整个卡死：
    /// ```
    /// QuotaEngine:129 → CooldownLedger.load() → Data(contentsOf:) → open()
    /// ```
    /// 当时我刚把所有写操作收进这里，以为扫干净了。
    /// **阻塞的是「碰这条路径」，不是「往这条路径写」。**
    public static func read(_ url: URL, timeout: TimeInterval = 8) -> Data? {
        guard isICloud(url) else { return try? Data(contentsOf: url) }
        return Watchdog.run("icloud.read:" + url.path, timeout: timeout) {
            try? Data(contentsOf: url)
        }.valueOr(nil)
    }

    /// 带超时的列目录。
    public static func contentsOfDirectory(
        _ dir: URL, timeout: TimeInterval = 8
    ) -> [URL] {
        list(dir, timeout: timeout).value ?? []
    }

    /// 一次「碰 iCloud」的三种结局。
    ///
    /// **`failed` 和 `stalled` 绝不能压成同一个 nil。**
    /// 前者是拿到了确定的答案（文件不在、没权限、内容是坏的），
    /// 后者是**根本不知道那里有没有东西**（iCloud 没响应）。
    /// 把后者当成前者，就是把「读不到」说成「没有」——
    /// 这个项目已经为此犯过三次错，其中一次直接覆盖掉了整份配置。
    ///
    /// `read` / `contentsOfDirectory` 把两者都压成 nil / 空数组，
    /// 「读出来显示一下」用它们没问题；但凡要拿读的结果去**删东西**、
    /// 或者去断言「那台机器没有任务」，都必须用下面这两个带结局的版本。
    public enum Probe<T> {
        case ok(T)
        /// 跑完了，但没成。这是一个**确定的**答案。
        case failed
        /// 超时，或者同一个 key 上一次还卡着。什么都不知道。
        case stalled

        public var value: T? {
            if case .ok(let v) = self { return v }
            return nil
        }

        /// 没拿到确定答案 —— 调用方**不许**据此断言「没有」。
        public var isStalled: Bool {
            if case .stalled = self { return true }
            return false
        }
    }

    /// 带超时的读，区分「读了、没有」和「读不动」。
    public static func readProbe(_ url: URL, timeout: TimeInterval = 8) -> Probe<Data> {
        let body = { () -> Data? in try? Data(contentsOf: url) }
        guard isICloud(url) else { return body().map { .ok($0) } ?? .failed }
        switch Watchdog.run("icloud.read:" + url.path, timeout: timeout, body) {
        case .done(let d): return d.map { .ok($0) } ?? .failed
        case .timedOut, .skipped: return .stalled
        }
    }

    /// 带超时的列目录，区分「目录是空的」和「目录读不动」。
    public static func list(_ dir: URL, timeout: TimeInterval = 8) -> Probe<[URL]> {
        let body = { () -> [URL]? in
            try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }
        guard isICloud(dir) else { return body().map { .ok($0) } ?? .failed }
        switch Watchdog.run("icloud.ls:" + dir.path, timeout: timeout, body) {
        case .done(let l): return l.map { .ok($0) } ?? .failed
        case .timedOut, .skipped: return .stalled
        }
    }

    /// 带超时的删除。iCloud 上的 unlink 同样会挂死。
    ///
    /// 删除是不可逆的那一类 —— 调用方在删之前基本都得先读一遍，
    /// 那一步务必用 `readProbe`，别用会把「读不动」变成「没有」的 `read`。
    @discardableResult
    public static func remove(_ url: URL, timeout: TimeInterval = 8) -> Bool {
        let body = { (try? FileManager.default.removeItem(at: url)) != nil }
        guard isICloud(url) else { return body() }
        return Watchdog.run("icloud.rm:" + url.path, timeout: timeout, body).valueOr(false)
    }

    /// 带超时的建目录。iCloud 上的 mkdir 一样会挂死
    /// （ConfigIntentIngest 原来是在调用点手工包看门狗 —— 收进来，
    /// 免得下一个调用点忘了包）。
    @discardableResult
    public static func ensureDir(_ dir: URL, timeout: TimeInterval = 8) -> Bool {
        let body = {
            (try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)) != nil
        }
        guard isICloud(dir) else { return body() }
        return Watchdog.run("icloud.mkdir:" + dir.path, timeout: timeout, body).valueOr(false)
    }

    /// 带超时的 mtime 读取。镜像的「新者胜」全靠它 ——
    /// 而 stat 一个没下载的 iCloud 文件同样可能挂起。
    /// 读不到返回 nil；调用方不许把 nil 当「文件很旧」去覆盖，只能当「不知道」。
    public static func modificationDate(_ url: URL, timeout: TimeInterval = 8) -> Date? {
        let body = { () -> Date? in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        guard isICloud(url) else { return body() }
        return Watchdog.run("icloud.stat:" + url.path, timeout: timeout, body).valueOr(nil)
    }

    /// 带超时的「是不是普通文件」。
    ///
    /// stat 一个 iCloud URL 和 open 一样会永久挂起 —— 这条是审查抓出来的：
    /// 镜像里两处对云端 URL 做裸 resourceValues，而同一份改动自己的注释
    /// 就写着「云端 stat 会挂」。守卫测试只扫原子写，扫不到 stat，
    /// 所以这类洞只能靠审查和这里的收口。
    public static func isRegularFile(_ url: URL, timeout: TimeInterval = 6) -> Bool {
        let probe = {
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        }
        guard isICloud(url) else { return probe() }
        return Watchdog.run("icloud.stat:" + url.path, timeout: timeout, probe)
            .valueOr(false)
    }

    /// 带超时的 `moveItem`。iCloud 上 move 同样会挂死（实测栈顶是 `access`）。
    @discardableResult
    public static func move(_ from: URL, to dest: URL, timeout: TimeInterval = 8) -> Bool {
        guard isICloud(from) || isICloud(dest) else {
            return (try? FileManager.default.moveItem(at: from, to: dest)) != nil
        }
        return Watchdog.run("icloud.move:" + dest.path, timeout: timeout) {
            (try? FileManager.default.moveItem(at: from, to: dest)) != nil
        }.valueOr(false)
    }
}

extension Watchdog.Outcome {
    /// 超时或跳过时退回一个兜底值。
    public func valueOr(_ fallback: T) -> T {
        if case .done(let v) = self { return v }
        return fallback
    }

    /// 没正常跑完（超时或被跳过）。
    public var stalled: Bool {
        if case .done = self { return false }
        return true
    }
}
