import Foundation

// MARK: - 仓库别名

/// 仓库别名表。
///
/// 手机上不该输入 `/Users/<你>/Documents/<项目>` 这种路径 ——
/// 又长又容易打错，而且路径在不同机器上还不一样。
/// 用别名，让路径这件事留在 Mac 这边。
public struct RepoAlias: Codable, Sendable {
    public var alias: String
    public var path: String
    public var isDefault: Bool

    /// 怎么验证 agent 的改动没把这个仓库改坏。
    ///
    /// **这是整套无人值守方案里最要命的一个缺口**：在它之前，agent 改完
    /// 直接提交、任务判 done、`work review` 还说「能干净合入」——
    /// 全程没有任何一步验过代码编不编得过。人手工派几个活时靠自己 build
    /// 兜着，但一旦开始自动生成任务、一晚上跑几十个，就是几十个
    /// 没人验过的分支堆在那儿，而且合进 main 之后才发现是坏的，
    /// 还得从一堆合并点里反查是哪个。
    ///
    /// 留空表示不验（比如纯文档仓库）。
    public var verifyCommand: String?

    /// 验证的超时。构建可能比 agent 本身还慢。
    public var verifyTimeout: Int

    /// 每台机器上这个仓库在哪。
    ///
    /// ## 为什么路径必须按机器存
    ///
    /// 这份注册表放在 iCloud 共享配置里 —— 手机要靠它列出可选仓库，
    /// 别的机器要靠它把别名解析成本地路径。但**路径天生是每台机器不同的**：
    /// 一台在 ~/Documents/X，另一台可能在 ~/Developer/X。
    ///
    /// 只存一个全局 `path` 的后果是实测出来的：在 B 机器上改了一次路径，
    /// A 机器的 `work review` 立刻开始报「不是 git 仓库」——
    /// 因为它拿到了 B 的路径。别名机制本来就是为了解决这个，
    /// 却栽在注册表自己身上。
    ///
    /// `path` 保留作为兜底：没有本机条目时用它（老配置、或者别的机器
    /// 刚登记还没轮到这台）。
    public var pathByMachine: [String: String] = [:]

    /// 本机上的实际路径。
    public var localPath: String {
        pathByMachine[Paths.machineName()] ?? path
    }

    public init(alias: String, path: String, isDefault: Bool = false,
                verifyCommand: String? = nil, verifyTimeout: Int = 600) {
        self.alias = alias
        self.path = path
        self.isDefault = isDefault
        self.verifyCommand = verifyCommand
        self.verifyTimeout = verifyTimeout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        path = try c.decode(String.self, forKey: .path)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        verifyCommand = try c.decodeIfPresent(String.self, forKey: .verifyCommand)
        verifyTimeout = try c.decodeIfPresent(Int.self, forKey: .verifyTimeout) ?? 600
        pathByMachine = try c.decodeIfPresent([String: String].self,
                                              forKey: .pathByMachine) ?? [:]
    }
}

/// 在 agent 的工作区里跑一次验证。
public enum Verifier {

    public struct Outcome: Sendable {
        public var ran: Bool
        public var passed: Bool
        public var summary: String
        public var tail: String
    }

    /// 找这个仓库登记的验证命令。
    public static func command(for repoPath: String) -> (cmd: String, timeout: Int)? {
        let want = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        for r in RepoRegistry.all() {
            let have = URL(fileURLWithPath: r.localPath).standardizedFileURL.path
            if have == want, let c = r.verifyCommand, !c.isEmpty {
                return (c, r.verifyTimeout)
            }
        }
        return nil
    }

    /// 在 worktree 里跑验证。**在提交之前跑** ——
    /// 提交完再验的话，坏代码已经在分支上了，还得再回滚一次。
    public static func run(in worktree: String, repoPath: String) -> Outcome {
        guard let (cmd, timeout) = command(for: repoPath) else {
            return Outcome(ran: false, passed: true,
                           summary: "这个仓库没登记验证命令", tail: "")
        }
        let r = Proc.run("/bin/sh", ["-lc", cmd], cwd: worktree,
                         env: [:], timeout: TimeInterval(timeout))
        let out = r.stdout + "\n" + r.stderr
        if r.timedOut {
            return Outcome(ran: true, passed: false,
                           summary: "验证超时（\(timeout) 秒）",
                           tail: String(out.suffix(600)))
        }
        return Outcome(
            ran: true, passed: r.exitCode == 0,
            summary: r.exitCode == 0 ? "验证通过" : "验证没过（退出码 \(r.exitCode)）",
            tail: r.exitCode == 0 ? "" : String(out.suffix(600)))
    }
}

public enum RepoRegistry {
    /// 测试用。
    public static var fileOverride: URL?

    /// 放 iCloud 共享配置目录 —— 手机端要用它来列出可选的仓库。
    static var file: URL {
        fileOverride
            ?? Paths.iCloudConfigDir?.appendingPathComponent("repos.json")
            ?? Paths.appSupport.appendingPathComponent("repos.json")
    }

    public static func all() -> [RepoAlias] {
        guard let data = ICloudSafe.read(file),
              let list = try? SnapshotCoding.decoder().decode([RepoAlias].self, from: data)
        else { return [] }
        return list.sorted { $0.alias < $1.alias }
    }

    public static func save(_ list: [RepoAlias]) throws {
        try Paths.ensureDirectories()
        // **保住老版本不认识的字段。**
        //
        // 这份配置在 iCloud 上被多台机器共享，而各台的二进制版本不一定同步。
        // 旧版本读进来（合成解码器丢掉它不认识的键）、改一个字段、再写回去 ——
        // 新字段就被静默洗掉了，两边都不会有任何报错。
        //
        // 实际发生过：一台机器用旧二进制跑了 `llmq repo verify`，
        // 把刚写进去的 pathByMachine 整个抹掉，于是跨机派活又开始把
        // 本机路径发给对端。查了一圈才发现是「版本落后的客户端写了共享配置」。
        //
        // 做法是**按 alias 合并**：磁盘上那份里存在、而内存这份里为空的
        // 未知字段，原样保留。这里只能保护已知字段，真正彻底的做法是
        // 存原始 JSON 做深合并 —— 但那要引入一层通用容器，
        // 对一份十来行的配置不值得。至少把最容易丢的这个保住。
        var merged = list
        if let old = ICloudSafe.read(file),
           let prev = try? SnapshotCoding.decoder().decode([RepoAlias].self, from: old) {
            let byAlias = Dictionary(prev.map { ($0.alias, $0) }, uniquingKeysWith: { a, _ in a })
            for i in merged.indices {
                guard let p = byAlias[merged[i].alias] else { continue }
                for (machine, path) in p.pathByMachine where merged[i].pathByMachine[machine] == nil {
                    merged[i].pathByMachine[machine] = path
                }
            }
        }
        let data = try SnapshotCoding.prettyEncoder().encode(merged)
        // `file` 是 iCloud 配置目录（没有才退回本地），所以这里可能永久阻塞。
        guard ICloudSafe.write(data, to: file) else {
            throw NSError(domain: "RepoRegistry", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "写仓库清单超时 —— iCloud 没响应，改动没保存"])
        }
    }

    @discardableResult
    public static func add(alias: String, path: String, makeDefault: Bool = false) throws -> RepoAlias {
        let expanded = NSString(string: path).expandingTildeInPath
        guard GitWorkspace.isRepo(expanded) else {
            throw NSError(domain: "RepoRegistry", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(expanded) 不是 git 仓库"])
        }
        let existing = all().first { $0.alias == alias }
        var list = all().filter { $0.alias != alias }
        if makeDefault {
            // **只改 isDefault，别重建整条。** 原来这里用
            // `RepoAlias(alias:path:isDefault:)` 重建，把 verifyCommand、
            // verifyTimeout、pathByMachine 全丢了 —— 设一次默认仓库，
            // 别的仓库的验证命令就没了，而这件事不会有任何提示。
            list = list.map { var e = $0; e.isDefault = false; return e }
        }
        var entry = existing ?? RepoAlias(alias: alias, path: expanded)
        entry.path = expanded
        entry.isDefault = makeDefault || list.isEmpty
        // 路径按机器记。全局那个 path 只作兜底。
        entry.pathByMachine[Paths.machineName()] = expanded
        list.append(entry)
        try save(list)
        return entry
    }

    public static func resolve(_ nameOrPath: String?) -> String? {
        let list = all()
        guard let n = nameOrPath, !n.isEmpty else {
            return list.first(where: \.isDefault)?.localPath ?? list.first?.localPath
        }
        // 别名解析成**本机**路径 —— 跨机派活时别名一样、路径各不相同，
        // 这正是别名存在的理由。
        if let hit = list.first(where: { $0.alias == n }) { return hit.localPath }
        // 也允许直接给路径 —— 从 Mac 上派任务时更顺手。
        let expanded = NSString(string: n).expandingTildeInPath
        return GitWorkspace.isRepo(expanded) ? expanded : nil
    }
}

// MARK: - iCloud 收件箱

/// 从 iCloud 收任务、把结果写回去。
///
/// 为什么是 iCloud 而不是起个服务端：家里没有公网 IP，Mac mini 在 NAT 后面。
/// 常规解法是打洞或第三方中继，但快照和配置本来就已经在走 iCloud 同步了 ——
/// 复用它就不用开端口、不用管证书过期、不用依赖任何第三方中继。
/// 任务本来要跑十几分钟，iCloud 那点同步延迟无所谓。
///
/// iCloud 上的目录在 CloudDocs 下而不是 App 专属容器里，是为了**现在就能用**：
/// iOS 的「文件」App 和「快捷指令」都能写 iCloud Drive，
/// 不用等原生 App 做出来。
///
/// **CLI 这边看到的 root 现在是本地暂存**（`Paths.sharedRoot`，结构和
/// iCloud 那份完全一致）：launchd 进程碰 iCloud 会永久挂起，所以
/// 收件箱由菜单栏 App 的 MirrorService 抢占拉到本地，CLI 只消费本地。
public enum Inbox {
    public static var root: URL? {
        Paths.iCloudSnapshotsDir?.deletingLastPathComponent()
    }
    public static var inboxDir: URL? { root?.appendingPathComponent("inbox", isDirectory: true) }
    public static var doneDir: URL? { root?.appendingPathComponent("inbox/processed", isDirectory: true) }
    public static var outboxDir: URL? { root?.appendingPathComponent("outbox", isDirectory: true) }

    public static func ensureDirectories() {
        for d in [inboxDir, doneDir, outboxDir].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 手机端可以直接扔 .txt（整个文件就是提示词），也可以扔 .json 指定仓库。
    struct Envelope: Codable {
        var prompt: String
        var repo: String?
        /// 你在办公室里点了哪张桌子。
        ///
        /// **只是优先，不是命令。** 指定的人如果过不了岗位规则
        /// （比如把高危活交给只接低危的），照样会被拦下来换人 ——
        /// 否则手机上一点就能绕过刚定的所有规则，规则就成了摆设。
        var platform: String?
    }

    public struct Ingested: Sendable {
        public var taskID: String
        public var source: String
        public var repo: String
    }

    /// 扫一遍收件箱，把里面的东西变成任务。
    ///
    /// 处理过的文件移到 processed/ 而不是删掉：删了的话手机上会看到文件凭空消失，
    /// 让人怀疑是不是没送达。移走既能防重复摄入，又留了痕迹。
    @discardableResult
    public static func ingest() -> [Ingested] {
        guard let inboxDir, let doneDir else { return [] }
        ensureDirectories()
        let fm = FileManager.default

        // 别的设备刚写进来的文件，在本机可能还是没下载的占位符。
        requestDownloads(in: inboxDir)

        guard let entries = try? fm.contentsOfDirectory(
            at: inboxDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var out: [Ingested] = []
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ["txt", "json", "md"].contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }

            let env: Envelope
            if ext == "json" {
                guard let e = try? SnapshotCoding.decoder().decode(Envelope.self, from: data)
                else {
                    park(url, to: doneDir, suffix: "bad-json")
                    continue
                }
                env = e
            } else {
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { park(url, to: doneDir, suffix: "empty"); continue }
                env = Envelope(prompt: text, repo: nil)
            }

            guard let repo = RepoRegistry.resolve(env.repo) else {
                // 仓库解析不了就别静默丢掉 —— 写一条结果回去告诉手机端为什么。
                let why = env.repo.map { "找不到仓库别名「\($0)」" }
                    ?? "没有配置默认仓库，先在 Mac 上跑 llmq repo add"
                writeResult(taskID: url.deletingPathExtension().lastPathComponent,
                            state: "failed", note: why, prompt: env.prompt)
                park(url, to: doneDir, suffix: "no-repo")
                continue
            }

            var task = WorkTask(
                id: String(UUID().uuidString.prefix(8)).lowercased(),
                prompt: env.prompt, repo: repo)
            task.preferredPlatform = env.platform.flatMap(Platform.init(rawValue:))
            task.note = "来自 iCloud 收件箱 · \(url.lastPathComponent)"
            // 手机派来的任务同样要分诊 —— 而且更需要：
            // 在手机上打字更容易写出不自洽的描述。
            task.profile = TaskClassifier.classify(
                prompt: env.prompt, repo: repo,
                history: TaskStore.all(), dashboard: LLMQuota.dashboard())
            guard (try? TaskStore.append(task)) != nil else { continue }

            park(url, to: doneDir, suffix: task.id)
            writeResult(taskID: task.id, state: "queued", note: "已入队", prompt: env.prompt)
            out.append(Ingested(taskID: task.id, source: url.lastPathComponent, repo: repo))
        }
        return out
    }

    static func park(_ url: URL, to dir: URL, suffix: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let dest = dir.appendingPathComponent(
            "\(stamp)-\(suffix)-\(url.lastPathComponent)")
        ICloudSafe.move(url, to: dest)
    }

    static func requestDownloads(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        for url in entries where url.pathExtension == "icloud" {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    // MARK: - 回写结果

    public struct Result: Codable, Sendable {
        public var taskID: String
        public var state: String
        public var note: String
        public var prompt: String
        public var platform: String?
        public var branch: String?
        public var changedFiles: Int?
        public var updatedAt: Date
    }

    /// 把任务状态写回 outbox，手机端读它就知道跑得怎么样了。
    public static func writeResult(
        taskID: String, state: String, note: String, prompt: String,
        platform: String? = nil, branch: String? = nil, changedFiles: Int? = nil
    ) {
        guard let outboxDir else { return }
        ensureDirectories()
        let r = Result(
            taskID: taskID, state: state, note: note,
            prompt: String(prompt.prefix(500)),
            platform: platform, branch: branch, changedFiles: changedFiles,
            updatedAt: Date())
        guard let data = try? SnapshotCoding.prettyEncoder().encode(r) else { return }
        ICloudSafe.write(data, to: outboxDir.appendingPathComponent("\(taskID).json"))
    }

    public static func writeResult(for task: WorkTask) {
        writeResult(
            taskID: task.id, state: task.state.rawValue, note: task.note ?? "",
            prompt: task.prompt, platform: task.platform?.displayName,
            branch: task.branch, changedFiles: task.changedFiles)
    }

    /// 把算好的看板写进 iCloud，给手机端读。
    ///
    /// 手机端**不重算额度**。QuotaEngine 依赖的采集逻辑要用 Process 扫本地日志，
    /// iOS 上根本跑不了；而把整个引擎移植过去，只为了重算一遍 Mac 已经算过的东西，
    /// 是纯粹的重复劳动。Mac 算、iCloud 送、手机显示 —— 和快照、配置同一套模式。
    public static func publishDashboard(_ dash: Dashboard) {
        guard let outboxDir else { return }
        ensureDirectories()
        guard let data = try? SnapshotCoding.prettyEncoder().encode(dash) else { return }
        ICloudSafe.write(
            data,
            to: outboxDir.deletingLastPathComponent().appendingPathComponent("dashboard.json"))
    }

    /// 手机端要用的仓库别名清单（去掉本机绝对路径，手机上看着没意义）。
    public static func publishRepos() {
        guard let outboxDir else { return }
        struct Item: Codable { var alias: String; var isDefault: Bool }
        let items = RepoRegistry.all().map { Item(alias: $0.alias, isDefault: $0.isDefault) }
        guard let data = try? SnapshotCoding.prettyEncoder().encode(items) else { return }
        ICloudSafe.write(
            data,
            to: outboxDir.deletingLastPathComponent().appendingPathComponent("repos.json"))
    }

    /// 清掉太旧的结果，别让 outbox 无限膨胀。
    public static func pruneResults(olderThan days: Int = 14) {
        guard let outboxDir else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: outboxDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        for url in entries {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, m < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
