import Foundation

// MARK: - 一台机器的任务板

/// 一台机器发给手机的「我这儿有哪些活」。
///
/// # 为什么它必须按机器一台一个文件
///
/// 在它之前，任务是塞在 `dashboard.json` 里发的 —— 而 `dashboard.json`
/// 在 iCloud 上**只有一份，每台机器都往里写**。于是虽然每条任务身上都带着
/// `machineName`，实际内容永远是「最后一台采集完的机器」那一刻的全部任务。
/// 两台机器同时干活时，手机上的任务列表会随着谁最后采集而**整批切换**：
/// 一会儿全是 A 的活，一会儿全是 B 的活，从来没有同时看到过两台。
///
/// 快照（`snapshots/<machineID>.json`）从第一天起就是按机器分文件、
/// 读的时候再合并 —— 每台只写自己那个文件，谁都不会写别人的，
/// 所以根本不存在合并冲突，iCloud 只负责搬运。任务这条路照抄这个模式。
///
/// # 为什么 `generatedAt` 是这份结构里最要紧的字段
///
/// 一份很旧的任务板里挂着的 `running`，多半早就不在跑了 ——
/// 机器可能已经关机、睡眠、或者 worker 挂了。手机把它照原样混进
/// 「正在干」里显示，就是在撒谎，而且是那种看起来特别可信的谎。
/// `generatedAt` 存在的唯一理由，就是让手机有能力说
/// 「这是那台机器 N 分钟前的状态」而不是「它正在跑」。
public struct MachineTaskBoard: Codable, Sendable {
    public var machineID: String
    public var machineName: String
    /// 这份任务板是什么时候采下来的。手机靠它判断新鲜度，见类型说明。
    public var generatedAt: Date
    /// 字段和 `dashboard.tasks` 里的完全一样 —— 就是同一个 `TaskBrief`。
    public var tasks: [TaskBrief]
    /// 被 `TaskBoard.maxTasks` 截掉过。静默截断会让手机上的条数变成假话。
    public var tasksTruncated: Bool

    /// 这台机器的**计划清单**（人排的、还没放行的）。
    ///
    /// 发出去手机才能看到「有哪些可以安排」，也才有东西可以点「放行」。
    /// 放行走 config-intents 通道回来（kind=plan-go，带 targetMachineID）。
    public var planned: [PlannedBrief]

    public struct PlannedBrief: Codable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var repoAlias: String?
        public init(id: String, title: String, repoAlias: String?) {
            self.id = id
            self.title = title
            self.repoAlias = repoAlias
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            repoAlias = try c.decodeIfPresent(String.self, forKey: .repoAlias)
        }
    }

    public init(machineID: String, machineName: String, generatedAt: Date,
                tasks: [TaskBrief], tasksTruncated: Bool = false,
                planned: [PlannedBrief] = []) {
        self.machineID = machineID
        self.machineName = machineName
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.tasksTruncated = tasksTruncated
        self.planned = planned
    }

    /// 手写解码，**每一个字段都走 `decodeIfPresent`**。
    ///
    /// 合成解码器对缺键零容忍：缺一个键抛 `keyNotFound`，整份任务板解不出来，
    /// 于是那台机器在手机上「一条任务都没有」—— 而它明明在干活。
    /// 给属性写默认值救不了合成解码器，这个坑在这个项目里翻过五次车。
    ///
    /// 两个兜底值是特意选的，不是随手填的：
    /// - `machineID` 缺了退回空串，由读取方用**文件名**补上（文件名就是 machineID）。
    /// - `generatedAt` 缺了退回 `distantPast`，也就是「非常旧」。
    ///   反过来兜底成 `Date()` 的话，一份说不清什么时候采的板子会被当成刚采的，
    ///   手机上那些早就死掉的 `running` 会被当成实时状态显示 —— 正是本文件要防的事。
    ///   注意 `prune` 不会因为这个把它删掉：那边还要看文件的 mtime，见 `lastActivity`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? ""
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        tasks = try c.decodeIfPresent([TaskBrief].self, forKey: .tasks) ?? []
        tasksTruncated = try c.decodeIfPresent(Bool.self, forKey: .tasksTruncated) ?? false
        planned = try c.decodeIfPresent([PlannedBrief].self, forKey: .planned) ?? []
    }
}

// MARK: - 读写

/// `<root>/taskboards/<machineID>.json` 的读写和清理。
///
/// 手机端只读这个目录；**写和清理都在 Mac 侧**。
public enum TaskBoardStore {

    /// 超过这么久没更新，就不能再把里面的任务当成实时状态。
    ///
    /// 采集默认 15 分钟一轮，所以 30 分钟是「整整两轮没到」——
    /// 一轮没到可能只是这次慢了点，两轮没到就该说话了。
    /// 这个常量是给 doctor 和手机端共用的口径，别在两边各写一个数。
    public static let staleAfter: TimeInterval = 30 * 60

    /// 多久没更新的任务板算废弃、可以删。
    ///
    /// 比 `staleAfter` 大两个数量级是故意的：「不能当实时看」和
    /// 「这台机器已经不在了」完全是两回事。一台机器出差带走一周、
    /// 或者停机修了几天，回来之后它自己会重新写这个文件。
    public static let discardAfter: TimeInterval = 7 * 86400

    /// 测试用。产品代码里永远是 nil。
    public static var dirOverride: URL?

    /// 和 `dashboard.json`、`snapshots/` 同一个根。
    public static var dir: URL? {
        if let dirOverride { return dirOverride }
        return Inbox.root?.appendingPathComponent("taskboards", isDirectory: true)
    }

    public static func fileName(machineID: String) -> String { "\(machineID).json" }

    // MARK: 发布

    /// 把本机的任务板写进 iCloud。
    ///
    /// 数据直接取自刚算好的 `Dashboard` —— 不重新组装一遍。
    /// 重算的话两份就有机会不一致，而 `dashboard.tasks`（老手机在读）
    /// 和 `taskboards/<本机>.json`（新手机在读）说的必须是同一件事。
    ///
    /// `machineID` 默认取 `Paths.machineID()`，和 `snapshots/` 用的是同一个 ——
    /// 手机要靠它把任务板和快照里的那台机器对上号，取错了就永远对不上。
    @discardableResult
    public static func publish(
        _ dash: Dashboard,
        machineID: String = Paths.machineID(),
        machineName: String = Paths.machineName()
    ) -> Bool {
        let planned = PlannedStore.all().map {
            MachineTaskBoard.PlannedBrief(
                id: $0.id,
                title: TaskBrief.clampTitle($0.prompt),
                repoAlias: $0.repoAlias)
        }
        let board = MachineTaskBoard(
            machineID: machineID, machineName: machineName,
            generatedAt: dash.generatedAt,
            tasks: dash.tasks, tasksTruncated: dash.tasksTruncated,
            planned: planned)
        return publish(board)
    }

    @discardableResult
    public static func publish(_ board: MachineTaskBoard) -> Bool {
        guard let dir else { return false }
        // 建目录本身在 iCloud 上也可能挂住，但整个 publish 已经被调用方
        // （`LLMQuota.collect`）关进 `Watchdog.run("publish.taskboard")` 里了，
        // 挂住的是那条后台线程，不是工作循环。和 Inbox 的做法一致。
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? SnapshotCoding.prettyEncoder().encode(board) else { return false }
        return ICloudSafe.write(data, to: dir.appendingPathComponent(
            fileName(machineID: board.machineID)))
    }

    // MARK: 读

    /// 目录里都有些什么。
    ///
    /// **「读不动」和「没有」是两个字段，不是同一个空数组。**
    /// 一台机器的任务板读不出来时，调用方必须有能力说「这台不知道」，
    /// 而不是显示成「这台没有任务」—— 后者是一句会被当真的假话。
    public struct Listing: Sendable {
        public var boards: [MachineTaskBoard]
        /// 列到了、但读不出来或解不出来的文件名。
        public var unreadable: [String]
        /// 连目录都没列成（iCloud 没响应）。此时 `boards` 空**不代表**没有任务板。
        public var directoryStalled: Bool
        /// 目录不存在（还没有任何一台机器发过，或者本机没配 iCloud）。
        public var directoryMissing: Bool

        /// 这份清单是不是完整的。false 的时候界面不许说「一共 N 台」。
        public var isComplete: Bool {
            !directoryStalled && unreadable.isEmpty
        }
    }

    public static func loadAll(timeout: TimeInterval = 8) -> Listing {
        guard let dir else {
            return Listing(boards: [], unreadable: [],
                           directoryStalled: false, directoryMissing: true)
        }
        let entries: [URL]
        switch ICloudSafe.list(dir, timeout: timeout) {
        case .ok(let list): entries = list
        case .failed:
            // 拿到了确定答案：目录不在（或读不了）。
            return Listing(boards: [], unreadable: [],
                           directoryStalled: false, directoryMissing: true)
        case .stalled:
            return Listing(boards: [], unreadable: [],
                           directoryStalled: true, directoryMissing: false)
        }

        var boards: [MachineTaskBoard] = []
        var unreadable: [String] = []
        let decoder = SnapshotCoding.decoder()
        for url in entries where url.pathExtension == "json" {
            guard let data = ICloudSafe.readProbe(url, timeout: timeout).value else {
                unreadable.append(url.lastPathComponent); continue
            }
            guard var board = try? decoder.decode(MachineTaskBoard.self, from: data) else {
                // 同步到一半的半截文件也落这儿。它会在下一轮被重新读到，
                // 所以只报不删 —— 删除的判断在 prune 里，那边更保守。
                unreadable.append(url.lastPathComponent); continue
            }
            // 文件名就是 machineID。老版本或者手改过的文件里可能没有这个键，
            // 用文件名补上 —— 手机要靠 (machineID, task.id) 去重，
            // machineID 空掉会让两台机器的任务互相覆盖。
            if board.machineID.isEmpty {
                board.machineID = url.deletingPathExtension().lastPathComponent
            }
            boards.append(board)
        }
        return Listing(boards: boards.sorted { $0.machineName < $1.machineName },
                       unreadable: unreadable.sorted(),
                       directoryStalled: false, directoryMissing: false)
    }

    // MARK: 清理

    public struct PruneReport: Sendable {
        public var removed: [String]
        /// 判不出年龄所以**没敢删**的：读不动、或者一个时间信号都没有。
        public var skipped: [String]
        /// 目录本身没列成 —— 这一轮什么都没检查。
        public var directoryStalled: Bool
    }

    /// 删掉太久没更新的任务板，别让 iCloud 上无限堆积。
    ///
    /// # 只删「确定是旧的」
    ///
    /// 判断年龄的前提是**先把文件读出来**。读不出来的一律留着 ——
    /// iCloud 没响应不等于那台机器没了，而删除是不可逆的。
    /// 这个项目已经栽在「把读不到当成没有」上三次，其中一次
    /// （新机器 mirror 失败被当成「iCloud 上没有」）覆盖掉了整份配置，
    /// 无法恢复。这里宁可多留几个几 KB 的 json。
    ///
    /// # 为什么要看两个时间
    ///
    /// `generatedAt` 是内容里写的，mtime 是文件系统上的。取**较新**的那个：
    /// 只要有任何一个信号说「它最近有动静」，就不删。
    /// 老版本写的板子可能没有 `generatedAt` 键（解码兜底成 `distantPast`），
    /// 只看内容的话它一被写出来就够格被删了。
    @discardableResult
    public static func prune(
        olderThan maxAge: TimeInterval = discardAfter,
        now: Date = Date(),
        timeout: TimeInterval = 8
    ) -> PruneReport {
        guard let dir else {
            return PruneReport(removed: [], skipped: [], directoryStalled: false)
        }
        let entries: [URL]
        switch ICloudSafe.list(dir, timeout: timeout) {
        case .ok(let list): entries = list
        case .failed: return PruneReport(removed: [], skipped: [], directoryStalled: false)
        case .stalled:
            return PruneReport(removed: [], skipped: [], directoryStalled: true)
        }

        var removed: [String] = []
        var skipped: [String] = []
        let decoder = SnapshotCoding.decoder()
        for url in entries where url.pathExtension == "json" {
            let name = url.lastPathComponent
            // 读不动（超时、没权限、文件不在了）—— 什么都不知道，不删。
            guard let data = ICloudSafe.readProbe(url, timeout: timeout).value else {
                skipped.append(name); continue
            }
            let generated = (try? decoder.decode(MachineTaskBoard.self, from: data))?.generatedAt
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let last = lastActivity(generatedAt: generated, mtime: mtime) else {
                skipped.append(name); continue
            }
            guard now.timeIntervalSince(last) > maxAge else { continue }
            if ICloudSafe.remove(url, timeout: timeout) {
                removed.append(name)
            } else {
                skipped.append(name)
            }
        }
        return PruneReport(removed: removed.sorted(), skipped: skipped.sorted(),
                           directoryStalled: false)
    }

    /// 「最后一次有动静」= 内容里的时间和文件 mtime 里**更新**的那个。
    /// 两个都没有就返回 nil —— 调用方不许猜，只能留着。
    static func lastActivity(generatedAt: Date?, mtime: Date?) -> Date? {
        let g = (generatedAt == .distantPast) ? nil : generatedAt
        return [g, mtime].compactMap { $0 }.max()
    }
}
