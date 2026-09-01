import Foundation

/// **手机看到的那几页,必须和「有没有活在跑」无关。**
///
/// 主循环是单线程的:`runOneTask` 一进去就同步等 agent 跑完 —— 复杂档上限 90 分钟。
/// 而办公室/任务板/在线状态/下发页全都在「一轮的末尾」发布,于是这一两小时里
/// 手机上什么都不动。老板 2026-08-23 一天里反复说「手机端显示半小时没有更新状态了」
/// 「手机端看不到进行中的任务」「点进去就没有了」—— 根子在这:**系统在正常干活,
/// 而橱窗是锁死的**。实锤:19:07 之后主循环一直在跑一条 Kimi 任务,
/// views/review.json 就停在 19:07,期间新产出的待验收分支手机上一条都看不到。
///
/// 所以把「刷新橱窗」这件事从循环节奏里拆出来:一个独立的定时器,不管主线程在忙什么,
/// 每隔 `interval` 自己刷一次。发布本身是读多写少 + 原子写文件,和 agent 执行没有共享可变状态。
public enum Showcase {
    /// 刷新间隔。比循环 tick(30s)慢一点就够 —— 这几页的内容不是秒级变化的,
    /// 而 reviewPage 要跑 git,太密会和 agent 抢仓库。
    public static let interval: TimeInterval = 60

    nonisolated(unsafe) private static var lastAt: Date = .distantPast
    nonisolated(unsafe) private static var busy = false
    private static let lock = NSLock()

    /// 到点了没有。到点就顺手把「上次刷新时间」推进(取用即占位),
    /// 这样定时器和轮末尾两个调用点不会在同一秒各刷一遍。
    public static func due(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(lastAt) >= interval else { return false }
        lastAt = now
        return true
    }

    /// 强制下一次调用一定刷(轮末尾/状态刚变时用)。
    public static func markStale() {
        lock.lock(); lastAt = .distantPast; lock.unlock()
    }

    /// 从主循环/定时器发起刷新，但绝不让 Git、证据抽取或共享目录 I/O
    /// 阻塞调度线程。`refresh` 仍保留同步入口给测试和后台调用。
    public static func trigger(force: Bool = false) {
        if force { markStale() }
        DispatchQueue.global(qos: .utility).async {
            _ = refresh()
        }
    }

    /// 真正发布。`publishers` 只给测试注入;产品代码走默认那套。
    ///
    /// **同一时刻只允许一个在跑**:定时器和主线程可能同时到点,而 reviewPage
    /// 会跑 git、抽证据图,重入只是白花时间,还可能两份内容互相覆盖。
    @discardableResult
    public static func refresh(force: Bool = false, now: Date = Date(),
                              publishers: [() -> Void]? = nil) -> Bool {
        if force { markStale() }
        guard due(now: now) else { return false }
        lock.lock()
        if busy { lock.unlock(); return false }
        busy = true
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        for p in publishers ?? defaultPublishers { p() }
        return true
    }

    /// 手机真正读的那几份。少一份,那一页就会停在旧内容上。
    public static var defaultPublishers: [() -> Void] {
        [
            { OfficeLog.publish() },
            { TaskBoardStore.publishNow() },
            { ClusterPresenceStore.publish() },
            { _ = ViewFeed.publish(ViewFeed.reviewPage()) },
            { _ = ViewFeed.publish(ViewFeed.blockedPage()) },

            { _ = ViewFeed.publish(RoadmapPage.page()) },
            { _ = ViewFeed.publish(ViewFeed.playbookPage()) },
            { _ = ViewFeed.publish(ViewFeed.collaborationPage()) },
            { _ = ViewFeed.publishMenu(ViewFeed.menu()) },
        ]
    }
}
