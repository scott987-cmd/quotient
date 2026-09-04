import Foundation

/// 一台机器的自检：把「这台到底怎么了」一次说清楚。
///
/// # 为什么要有这个
///
/// 排查另一台机器时，我 SSH 过去挨个敲命令：看版本、看服务状态、
/// 看更新器日志、看集群日志、看地址配置、试 launchd 下能不能读 iCloud……
/// 花了很久才定位到「它两天没更新，因为更新器把『读不到证书』报成了
/// 『有人篡改』」。
///
/// **那次排查的结论留在了会话里，命令没留下。** 下次同样的问题，
/// 得从头摸一遍。所以固化成这个：知识写进代码，不写进对话。
///
/// 它只读、不改任何东西，跑起来是安全的。
public enum SelfCheck {

    public struct Finding: Sendable {
        public enum Level: String, Sendable { case ok, warn, bad }
        public var level: Level
        public var title: String
        public var detail: String
    }

    public struct Report: Sendable {
        public var machineName: String
        public var nodeName: String?
        public var binaryPath: String
        public var installedSHA: String?
        public var findings: [Finding]

        public var worst: Finding.Level {
            findings.contains { $0.level == .bad } ? .bad
                : findings.contains { $0.level == .warn } ? .warn : .ok
        }
    }

    public static func run() -> Report {
        var f: [Finding] = []
        let cfg = ClusterConfigStore.load()

        f.append(contentsOf: binaryChecks())
        f.append(contentsOf: serviceChecks())
        f.append(contentsOf: updateChannelChecks())
        f.append(contentsOf: clusterChecks(cfg))
        f.append(contentsOf: icloudChecks())

        return Report(
            machineName: Paths.machineName(),
            nodeName: cfg?.nodeName,
            binaryPath: Bundle.main.executablePath ?? "?",
            installedSHA: ReleaseChannel.installedSHA,
            findings: f)
    }

    // MARK: - 二进制

    static func binaryChecks() -> [Finding] {
        var out: [Finding] = []
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/llmq").path

        // 常驻服务跑的是不是发布装的那一份。
        //
        // 真出过：worker 的 plist 指向 app bundle 里的一份 llmq，
        // 而 publish 只更新 ~/.local/bin —— 两份分道扬镳，
        // worker 安静地跑了几小时旧代码，最后那个文件没了直接 EX_CONFIG 退出。
        for label in ["com.llmquotabar.worker", "com.llmquotabar.projector", "com.llmquotabar.cluster",
                      "com.llmquotabar.updater", "com.llmquotabar.collector"] {
            guard let exe = launchdProgram(label) else { continue }
            if !FileManager.default.fileExists(atPath: exe) {
                out.append(Finding(level: .bad, title: "\(label) 要跑的程序不存在",
                    detail: exe + " —— launchd 会以 EX_CONFIG(78) 退出，"
                        + "而且不写任何日志，从外面看就是「这个服务不动了」"))
            } else if exe != installed {
                out.append(Finding(level: .warn, title: "\(label) 跑的不是发布装的那份",
                    detail: "它在跑 \(exe)，发布装的是 \(installed) —— 前者会一直是旧代码"))
            }
        }

        let team = CodeSigning.describe(installed).team
        if team == nil {
            out.append(Finding(level: .warn, title: "llmq 是 adhoc 签名",
                detail: "没有 Team ID，系统只能拿 cdhash 认身份，而它每次重建都变 —— "
                    + "意味着每发布一次，用户给的完全磁盘访问就作废一次。"
                    + "配一次：llmq release sign-with \"<证书名>\""))
        }
        return out
    }

    static func launchdProgram(_ label: String) -> String? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard let data = try? Data(contentsOf: p),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let args = obj["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    // MARK: - 服务

    static func serviceChecks() -> [Finding] {
        var out: [Finding] = []
        let list = Proc.run("/bin/launchctl", ["list"],
                            cwd: NSTemporaryDirectory(), env: [:], timeout: 15).stdout
        for label in ["com.llmquotabar.worker", "com.llmquotabar.projector", "com.llmquotabar.cluster",
                      "com.llmquotabar.updater", "com.llmquotabar.collector"] {
            guard let line = list.split(separator: "\n").first(where: { $0.contains(label) })
            else {
                out.append(Finding(level: .warn, title: "\(label) 没装",
                                   detail: "这台机器上没有这个服务"))
                continue
            }
            let cols = line.split(separator: "\t")
            let status = cols.count > 1 ? String(cols[1]) : "?"
            // 退出码 78 = EX_CONFIG，launchd 的「配置错误」，**不写日志**。
            if status == "78" {
                out.append(Finding(level: .bad, title: "\(label) 配置错误退出（78）",
                    detail: "多半是 plist 指向的程序不存在。它不会写任何日志。"))
            } else if let n = Int(status), n > 0, n != 78 {
                out.append(Finding(level: .warn, title: "\(label) 上次非正常退出（\(n)）",
                                   detail: "看它的日志"))
            }
        }
        return out
    }

    // MARK: - 更新通道

    /// 别的机器装的版本和已发布版对不对得上。
    ///
    /// **这条必须在主机上也能看见。** 原来只有 `本机 installed vs 已发布`
    /// 这一条 —— 主机刚发完版永远显示「已是最新」，而从机落后没人知道。
    ///
    /// 版本歪的后果不是少个新功能，是**两台机器按不同规则操作同一份任务库**：
    /// 2026-08-17 实测，主机装了当天的派活规则（仓库独占、基线核验、
    /// 产出核验），MacBook 还跑前一天的二进制，照旧派主机会拦下的活、
    /// 照旧发已经改掉的那种推送 —— 当天做的一半规则被静默绕过。
    static func peerVersionChecks() -> [Finding] {
        // 已发布版本：upToDate 时本机就是最新，available 时清单里写着。
        let want: String
        switch ReleaseChannel.check() {
        case .upToDate(let sha): want = String(sha.prefix(12))
        case .available(let m, _): want = String(m.sha256.prefix(12))
        case .noChannel, .rejected: return []   // 没通道就没什么可比的
        }
        let me = Paths.machineID()
        var out: [Finding] = []
        for p in ClusterPresenceStore.all() where p.machineID != me {
            let who = p.nodeName ?? p.machineName
            guard let has = p.installedRelease else {
                out.append(Finding(level: .warn, title: "从机版本不明：" + who,
                    detail: "它上报的状态里没有版本字段 —— 说明它装的 llmq "
                          + "老到还不会报版本。在它上面跑 llmq update。"))
                continue
            }
            if has != want {
                out.append(Finding(level: .warn, title: "从机版本落后：" + who,
                    detail: "它装的是 \(has)，已发布 \(want) —— "
                          + "两台机器在按**不同的派活规则**操作同一份任务库，"
                          + "新加的闸门会被它绕过。在它上面跑 llmq update，"
                          + "或者等自动更新器（每 30 分钟一次）。"))
            }
        }
        return out
    }

    static func updateChannelChecks() -> [Finding] {
        var out: [Finding] = peerVersionChecks()
        switch ReleaseChannel.check() {
        case .upToDate:
            break
        case .noChannel:
            out.append(Finding(level: .warn, title: "没有发布通道",
                               detail: "读不到 releases/current.json"))
        case .available(let m, _):
            out.append(Finding(level: .warn, title: "有新版本没装",
                detail: "已发布 \(m.sha256.prefix(12))，本机 "
                    + (ReleaseChannel.installedSHA?.prefix(12).description ?? "未知")
                    + " —— 自动更新器每 30 分钟跑一次，一直没装上就是它出问题了"))
        case .rejected(let why):
            // **这条要标成 bad。** 它意味着这台机器**永远不会**自动更新，
            // 而且只写在没人看的日志里。真发生过：连报两天，停在旧版本。
            out.append(Finding(level: .bad, title: "更新被拒绝，这台机器不会自动更新",
                               detail: why))
        }
        return out
    }

    // MARK: - 集群

    static func clusterChecks(_ cfg: ClusterConfig?) -> [Finding] {
        var out: [Finding] = []
        guard let cfg else { return out }

        let actual = ClusterNet.lanAddress()
        if let actual {
            // 别人记的我，和我真实的地址对不对得上。
            //
            // DHCP 换地址之后没人更新登记，对面就一直连一个死地址 ——
            // 而日志里只看得到 TLS 握手错误，会把人引向证书。
            if let mine = cfg.peers[cfg.nodeName] {
                let host = mine.split(separator: ":").first.map(String.init) ?? mine
                if host != actual {
                    out.append(Finding(level: .bad, title: "集群里登记的本机地址是错的",
                        detail: "登记 \(host)，实际 \(actual) —— 对面会一直连一个连不上的地址，"
                            + "而日志里只看得到 TLS 握手错误。"
                            + "两边都改：llmq cluster peer \(cfg.nodeName) \(actual):\(cfg.port)"))
                }
            }
        } else {
            out.append(Finding(level: .warn, title: "拿不到局域网地址",
                               detail: "没有可用的私有地址，集群互联用不了"))
        }
        return out
    }

    // MARK: - iCloud

    static func icloudChecks() -> [Finding] {
        var out: [Finding] = []

        // CLI 不再直接碰 iCloud —— 它只写本地暂存，搬运靠菜单栏 App 的镜像。
        // 所以「多机/手机端还通不通」这个问题，唯一的证据就是镜像心跳。
        // 三态的修法完全不同，必须分开报。
        switch MirrorHealth.check() {
        case .ok(let st):
            _ = st
        case .neverSynced:
            out.append(Finding(level: .warn, title: "菜单栏 App 没在同步（从未授权）",
                detail: MirrorHealth.describe(.neverSynced)
                    + " —— 在授权之前，快照、配置、手机端全都只在本机。"))
        case .appNotRunning(let st):
            out.append(Finding(level: .warn, title: "菜单栏 App 没在同步（App 没在跑）",
                detail: MirrorHealth.describe(.appNotRunning(st))))
        case .failing(let st):
            // 标 bad：App 在跑、看起来一切正常，但数据实际上没出本机。
            out.append(Finding(level: .bad, title: "菜单栏 App 没在同步（镜像在报错）",
                detail: MirrorHealth.describe(.failing(st))))
        }

        guard let root = Inbox.root else {
            out.append(Finding(level: .warn, title: "没有共享暂存目录",
                               detail: "多机同步和手机端都用不了"))
            return out
        }

        // **真去读一次，别只判「存在」。**
        //
        // 实测：launchd 下 `[ -r file ]` 返回真，真去 fopen 才 EPERM。
        // 所以任何「先检查可读性」的写法都会给出错误的结论。
        let probe = root.appendingPathComponent("dashboard.json")
        if FileManager.default.fileExists(atPath: probe.path) {
            let r = Proc.run("/bin/cat", [probe.path],
                             cwd: NSTemporaryDirectory(), env: [:], timeout: 10)
            if r.exitCode != 0 {
                out.append(Finding(level: .bad, title: "读不到 iCloud 上的文件",
                    detail: "这个进程没权限读 \(probe.lastPathComponent)。"
                        + "注意：文件存在、看起来也可读，真读才失败。"
                        + "凡是依赖 iCloud 的功能（更新、多机同步、手机端）都会以"
                        + "各种奇怪的方式失败。原始错误："
                        + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)))
            }
        }

        let debris = Debris.scan(root: root)
        if !debris.isEmpty {
            out.append(Finding(level: .warn, title: "iCloud 上有 \(debris.files.count) 个半成品文件",
                detail: "\(debris.sizeText)，原子写卡在 rename 留下的。清掉：llmq doctor --tidy"))
        }
        return out
    }

    // MARK: - 渲染

    public static func render(_ r: Report) -> String {
        var lines: [String] = []
        lines.append("机器  \(r.machineName)" + (r.nodeName.map { "（节点 \($0)）" } ?? ""))
        lines.append("版本  " + (r.installedSHA?.prefix(12).description ?? "未知"))
        lines.append("程序  " + r.binaryPath)
        if r.findings.isEmpty {
            lines.append("")
            lines.append("没查出问题。")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        for f in r.findings.sorted(by: { rank($0.level) < rank($1.level) }) {
            let mark = f.level == .bad ? "✗" : (f.level == .warn ? "⚠" : "·")
            lines.append("\(mark) \(f.title)")
            lines.append("    \(f.detail)")
        }
        return lines.joined(separator: "\n")
    }

    static func rank(_ l: Finding.Level) -> Int {
        switch l { case .bad: return 0; case .warn: return 1; case .ok: return 2 }
    }
}
