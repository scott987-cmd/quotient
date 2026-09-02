import Foundation

/// 每台机器把自己的集群状态报到 iCloud 上。
///
/// ## 为什么需要这个
///
/// 排查跨机连不上的时候撞到一堵墙：唯一能拿到的信息就是「连不上」。
/// 是对方没起服务？IP 变了？防火墙挡了？不在一个网段？—— 全都得跑到
/// 那台机器上敲命令才知道，而那台机器往往不在手边。
///
/// 实际发生的一次：配置里记着对方的内网地址，ping 得通，
/// 但整个网段扫下来只有本机在听那个端口。到底是它没起服务、还是 DHCP
/// 把地址换给了别的设备，从这一头分不出来。
///
/// 而 iCloud 那条路一直是通的（两台机器的用量快照每分钟都在同步）。
/// 所以让每台机器顺着那条路把「我在哪、我在不在听、我的防火墙开没开」
/// 报出来，这类问题就从「跑过去查」变成「看一眼」。
///
/// 顺带解决 DHCP 换地址：对端地址不再靠手填，以自报的为准。
public struct ClusterPresence: Codable, Sendable, Identifiable {
    public var machineID: String
    public var machineName: String
    /// 集群里的节点名（和证书 CN 一致）。没入过集群就是 nil。
    public var nodeName: String?
    /// 它自己看到的局域网地址。**这是自报的，不是别人猜的** ——
    /// DHCP 换地址之后，对端照着这个就能找到它。
    public var lanIP: String?
    public var port: UInt16
    /// 此刻有没有在监听。
    public var serving: Bool
    /// **实际绑在哪个地址上**（从 lsof 读，不是现算的）。
    ///
    /// 和 `lanIP` 分开报，因为这两个真的会不一样：服务端绑的是它**启动那一刻**
    /// 的 IP，绑定不会跟着 DHCP 走。地址换了之后 lsof 照样显示 LISTEN
    /// —— 于是「在听」是真的，但听的是一个已经不存在的地址。
    /// 从对面看就是 connect 超时，和没起服务一模一样。
    public var boundAddress: String?
    /// 本机到**同网段**的流量走哪个网卡。
    ///
    /// 这一条是被一次真实故障逼出来的：两台机器都在听、防火墙都关、IP 都对，
    /// 但 TCP 就是超时。原因是代理客户端（Shadowsocks / Clash 这类）
    /// 开了 TUN 增强模式，用 `0/1` + `128.0/1` 两条路由压过真实默认路由，
    /// 把**所有** TCP 抓进虚拟网卡 —— 如果它没给局域网网段留例外，
    /// 回包就被送进隧道再也出不来。
    ///
    /// 而现象极具迷惑性：ping 通（很多客户端对 ICMP 和 TCP 用不同规则）、
    /// 服务在听、防火墙关着，看哪儿都正常。只有看路由才看得出来。
    ///
    /// 正常应该是 en0/en1 这类物理网卡；出现 utun* 就是被代理接管了。
    public var lanRouteInterface: String?

    /// macOS 应用防火墙开着没有。
    ///
    /// 开着且没放行 llmq 的话，入站连接会被**静默丢弃** ——
    /// 表现是 connect 超时（而不是 connection refused），
    /// 从对面看和「没起服务」一模一样。这是最难猜的一种。
    public var firewallOn: Bool
    /// 我能不能连上别人。节点名 → 能不能建立 TCP。
    ///
    /// **方向性是最后一块拼图。** 两台机器各自看都完全正常（在听、
    /// 防火墙关、路由走物理网卡），但就是连不上 —— 这时候要知道的是
    /// 「到底是双向不通，还是只有一个方向不通」。
    ///
    /// 双向不通指向网络本身（路由器的 AP 隔离、不在一个二层域）；
    /// 单向不通指向被探测那一端（回包路径、多网卡源地址不匹配）。
    /// 只从一头试，这两种永远分不开。
    public var canReach: [String: Bool]

    /// serve 没在听的时候，日志最后几行说了什么。
    ///
    /// ## 为什么要把日志搬进 presence
    ///
    /// 「在听 = 否」只说明结果，不说明原因。而原因有一堆完全不同的可能：
    /// 钥匙串不让读、端口被占、配置读不到、绑定地址不存在……
    /// 每一种的修法都不一样，光看结果只能靠猜。
    ///
    /// 排查一次跨机故障时，为了拿这几行日志来回折腾了好几轮 ——
    /// 而它就在对端机器上，presence 每轮采集都在往 iCloud 写东西，
    /// 顺手带上就完了。只在没在听的时候带，正常时不占空间。
    public var lastLogLines: [String]?

    /// 最近一小时启动了几次。>3 基本就是崩溃重启循环。
    ///
    /// launchd 的 KeepAlive 会一直把失败的进程拉起来，
    /// 从外面看是「时好时坏」，而真相是它每 30 秒死一次。
    /// 没有这个计数，这种状态几乎看不出来。
    public var restartsLastHour: Int?

    /// 这台机器**实际装着**的 release sha（前 12 位）。
    ///
    /// ## 为什么必须自报，而且必须让主机看见
    ///
    /// 版本歪的后果不是「少个新功能」，是**两台机器按不同规则操作同一份
    /// 任务库**。2026-08-17 实测：主机装了当天的代码（仓库独占、基线核验、
    /// 产出核验、按证据分流推送），MacBook 还跑着前一天的二进制 ——
    /// 于是它照旧派主机会拦下的活，照旧发主机已经改掉的那种推送。
    /// **当天做的一半规则被静默绕过。**
    ///
    /// 而这件事原来没有任何地方会说：`SelfCheck` 的「有新版本没装」只比
    /// **本机** installed 和已发布，主机上跑永远是「已是最新」。
    /// 从机自己会报，但没人会去看从机的 doctor。
    ///
    /// 所以让它跟着 presence 一起自报 —— presence 本来就是「我是谁、
    /// 我在哪、我什么状态」的那份自述，版本属于状态。
    public var installedRelease: String?

    /// 本机实际验证为 Git 仓库的别名。路径永不跨机发布；对端只按别名选路。
    public var repoAliases: [String]
    /// 本机自动执行作用域允许的仓库别名。`manualOnly` 不会出现在这里，
    /// 防止中央调度绕过目标机器自己的项目隔离。
    public var automaticRepoAliases: [String]
    /// 工作循环实际生效的并发槽位，以及当前真实运行占用。
    public var maxConcurrentTasks: Int
    public var runningTaskCount: Int
    public var runningRepoAliases: [String]

    /// 自己连自己**的 LAN 地址**通不通。
    ///
    /// **这是区分「服务卡死」和「被过滤」的那把尺子。**
    /// 自连不出网卡（内核走 lo0），所以过滤器管不着：
    /// 自连通、外面不通 → 网络层被拦；自连也不通 → 服务自己没在 accept
    /// （监听队列满了内核就静默丢 SYN、不回 RST，从外面看就是「端口开着却超时」）。
    ///
    /// **别用 127.0.0.1。** 第一版就是这么写的，结果两台机器全被判成
    /// 「服务卡死」—— 因为服务绑的是具体的 LAN 地址而不是 0.0.0.0，
    /// 回环口上本来就没东西，连不上是**正确行为**。
    /// 一个会误报的诊断比没有诊断更糟：它会把人指向完全错误的方向。
    public var selfConnectOK: Bool?

    /// 应用防火墙原样的状态字符串，不做解析。
    ///
    /// 之前只存一个解析过的 Bool，结果这个 Bool 报「关」而现象却像被拦，
    /// 根本没法判断是真关了还是解析错了。原文留着，判断留给读的人。
    public var firewallRaw: String?

    public var updatedAt: Date
    public var version: String

    public var id: String { machineID }

    /// 容错解码。
    ///
    /// **这个坑在这个项目里踩到第四次了**：TaskProfile 缺 classifiedAt、
    /// OfficeEvent 缺 excluded、PlatformReport 缺 role，现在是这里缺 canReach。
    /// 每一次的表现都一样 —— 加了个非可选字段，老数据整条解不出来，
    /// 然后**静默消失**：任务退回旧状态、事件不见了、这次是整台机器
    /// 从集群列表里蒸发。而排查时看到的现象是「文件明明在那儿」。
    ///
    /// 凡是跨版本、跨机器传的结构，一律手写 decodeIfPresent。
    /// 合成解码器对新增字段是零容忍的，而这类数据天生就会新旧混跑。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try c.decode(String.self, forKey: .machineID)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? "?"
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName)
        lanIP = try c.decodeIfPresent(String.self, forKey: .lanIP)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8443
        serving = try c.decodeIfPresent(Bool.self, forKey: .serving) ?? false
        boundAddress = try c.decodeIfPresent(String.self, forKey: .boundAddress)
        lanRouteInterface = try c.decodeIfPresent(String.self, forKey: .lanRouteInterface)
        firewallOn = try c.decodeIfPresent(Bool.self, forKey: .firewallOn) ?? false
        canReach = try c.decodeIfPresent([String: Bool].self, forKey: .canReach) ?? [:]
        selfConnectOK = try c.decodeIfPresent(Bool.self, forKey: .selfConnectOK)
        firewallRaw = try c.decodeIfPresent(String.self, forKey: .firewallRaw)
        lastLogLines = try c.decodeIfPresent([String].self, forKey: .lastLogLines)
        restartsLastHour = try c.decodeIfPresent(Int.self, forKey: .restartsLastHour)
        // 老版本不报这个字段 —— 读不到就是 nil，正好说明「它太老了」。
        installedRelease = try c.decodeIfPresent(String.self, forKey: .installedRelease)
        repoAliases = try c.decodeIfPresent([String].self, forKey: .repoAliases) ?? []
        automaticRepoAliases = try c.decodeIfPresent(
            [String].self, forKey: .automaticRepoAliases) ?? []
        maxConcurrentTasks = try c.decodeIfPresent(
            Int.self, forKey: .maxConcurrentTasks) ?? 0
        runningTaskCount = try c.decodeIfPresent(Int.self, forKey: .runningTaskCount) ?? 0
        runningRepoAliases = try c.decodeIfPresent(
            [String].self, forKey: .runningRepoAliases) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "?"
    }

    public init(machineID: String, machineName: String, nodeName: String?,
                lanIP: String?, port: UInt16, serving: Bool, boundAddress: String?,
                lanRouteInterface: String?, firewallOn: Bool,
                canReach: [String: Bool], updatedAt: Date, version: String,
                selfConnectOK: Bool? = nil, firewallRaw: String? = nil,
                lastLogLines: [String]? = nil, restartsLastHour: Int? = nil,
                installedRelease: String? = nil,
                repoAliases: [String] = [], automaticRepoAliases: [String] = [],
                maxConcurrentTasks: Int = 0, runningTaskCount: Int = 0,
                runningRepoAliases: [String] = []) {
        self.lastLogLines = lastLogLines
        self.restartsLastHour = restartsLastHour
        self.installedRelease = installedRelease
        self.repoAliases = repoAliases
        self.automaticRepoAliases = automaticRepoAliases
        self.maxConcurrentTasks = maxConcurrentTasks
        self.runningTaskCount = runningTaskCount
        self.runningRepoAliases = runningRepoAliases
        self.machineID = machineID
        self.machineName = machineName
        self.nodeName = nodeName
        self.lanIP = lanIP
        self.port = port
        self.serving = serving
        self.boundAddress = boundAddress
        self.lanRouteInterface = lanRouteInterface
        self.firewallOn = firewallOn
        self.canReach = canReach
        self.updatedAt = updatedAt
        self.version = version
        self.selfConnectOK = selfConnectOK
        self.firewallRaw = firewallRaw
    }

    /// 局域网被代理隧道接管了没有。物理网卡是 en*，出现 utun* 就是被抓了。
    public var lanHijackedByTunnel: Bool {
        guard let i = lanRouteInterface else { return false }
        return i.hasPrefix("utun") || i.hasPrefix("tun") || i.hasPrefix("ppp")
    }

    /// 报告是不是已经过期。采集每 5 分钟一轮，15 分钟没更新就当它下线了。
    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > 15 * 60
    }
}

public enum ClusterPresenceStore {

    /// 测试用。
    public static var dirOverride: URL?

    static var dir: URL? {
        dirOverride ?? Paths.iCloudConfigDir?
            .deletingLastPathComponent()
            .appendingPathComponent("presence", isDirectory: true)
    }

    /// 报一次。跟着 collect 走，不单独起定时器。
    public static func publish() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = ClusterConfigStore.load()
        let repos = RepoRegistry.all().filter { GitWorkspace.isRepo($0.localPath) }
        let scope = ProjectExecutionScope.current(repos: repos)
        let running = TaskStore.all().filter { task in
            guard task.state == .running else { return false }
            guard let pid = task.runnerPID, pid > 0 else { return false }
            return kill(pid, 0) == 0
        }
        func alias(for path: String) -> String? {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            return repos.first {
                URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == normalized
            }?.alias
        }
        // 没有真实、近期心跳的 work loop 就没有执行容量。不能用机型默认值
        // 冒充在线 worker，否则协调机可能把任务派给一台根本没人消费队列的机器。
        let slots = WorkerCapacityStore.current() ?? 0
        let p = ClusterPresence(
            machineID: Paths.machineID(),
            machineName: Paths.machineName(),
            nodeName: cfg?.nodeName,
            lanIP: ClusterNet.lanAddress(),
            port: cfg?.port ?? 8443,
            serving: listenAddress(port: cfg?.port ?? 8443) != nil,
            boundAddress: listenAddress(port: cfg?.port ?? 8443),
            lanRouteInterface: lanRouteInterface(),
            firewallOn: firewallEnabled(),
            canReach: probePeers(cfg),
            updatedAt: Date(),
            version: ClusterNet.protocolVersion,
            // 连自己的 LAN 地址，不是 127.0.0.1 —— 服务绑的就是 LAN 地址。
            selfConnectOK: ClusterNet.lanAddress().map {
                tcpReachable(host: $0, port: cfg?.port ?? 8443)
            },
            firewallRaw: firewallRawState(),
            // 只在没在听的时候带日志：正常时它没有信息量，白占空间。
            lastLogLines: listenAddress(port: cfg?.port ?? 8443) == nil
                ? serveLogTail() : nil,
            restartsLastHour: serveRestartCount(),
            installedRelease: ReleaseChannel.installedSHA.map { String($0.prefix(12)) },
            repoAliases: repos.map(\.alias).sorted(),
            automaticRepoAliases: repos.filter { scope.allows($0.localPath) }
                .map(\.alias).sorted(),
            maxConcurrentTasks: slots,
            runningTaskCount: running.count,
            runningRepoAliases: Array(Set(running.compactMap { alias(for: $0.repo) })).sorted())
        guard let data = try? SnapshotCoding.prettyEncoder().encode(p) else { return }
        ICloudSafe.write(data, to: dir.appendingPathComponent("\(p.machineID).json"))
    }

    static var serveLog: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/llmquotabar-cluster.log")
    }

    /// 日志最后几行。只取尾部，日志再大也不吃内存。
    static func serveLogTail(_ n: Int = 6) -> [String]? {
        guard let s = try? String(contentsOf: serveLog, encoding: .utf8) else { return nil }
        let lines = s.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? nil : Array(lines.suffix(n))
    }

    /// 最近一小时的启动次数。
    ///
    /// 数的是 serve 每次启动打的那行「启动 ——」。时间戳格式是 `MM-dd HH:mm:ss`，
    /// 没有年份 —— 对「最近一小时」这个用途够了，跨年那一天多算几次无所谓，
    /// 反正它只是用来判断「是不是在崩溃循环里」。
    static func serveRestartCount(within: TimeInterval = 3600) -> Int? {
        guard let s = try? String(contentsOf: serveLog, encoding: .utf8) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        var n = 0
        for line in s.split(separator: "\n") where line.contains("启动 ——") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            guard var t = f.date(from: stamp) else { continue }
            // DateFormatter 缺年份时会落到 1970，补成今年。
            var c = cal.dateComponents([.month, .day, .hour, .minute, .second], from: t)
            c.year = year
            t = cal.date(from: c) ?? t
            if now.timeIntervalSince(t) <= within, t <= now { n += 1 }
        }
        return n
    }

    public static func all() -> [ClusterPresence] {
        guard let dir else { return [] }
        requestDownloads(in: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let dec = SnapshotCoding.decoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(ClusterPresence.self, from: Data(contentsOf: $0)) }
            .sorted { $0.machineName < $1.machineName }
    }

    /// 按节点名找它自报的地址。
    ///
    /// 用它而不是配置里手填的那个：手填的会因为 DHCP 换地址而失效，
    /// 而且失效的表现是 connect 超时 —— 和「对方没起服务」长得一模一样，
    /// 极难分辨。自报的地址每 5 分钟刷新一次。
    public static func address(forNode node: String) -> String? {
        guard let p = all().first(where: { $0.nodeName == node }),
              !p.isStale(), let ip = p.lanIP else { return nil }
        return "\(ip):\(p.port)"
    }

    // MARK: - 探测

    /// llmq 到底绑在哪个地址上。返回 nil 表示没在听。
    /// `process` 参数是给测试用的 —— 测试进程叫 xctest 不叫 llmq，
    /// 写死进程名的话这个函数根本没法验证。
    static func listenAddress(port: UInt16, process: String = "llmq") -> String? {
        let r = Proc.run("/usr/sbin/lsof",
                         ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
                         cwd: "/tmp", env: [:], timeout: 15)
        for line in r.stdout.split(separator: "\n")
        where line.localizedCaseInsensitiveContains(process) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if let addr = f.first(where: { $0.contains(":\(port)") }) { return String(addr) }
        }
        return nil
    }

    /// 监听到底健不健康。
    public enum ServeHealth: Equatable, Sendable {
        /// 在听，地址也是本机现有的。
        case ok(String)
        /// **进程活着但根本没在监听。**
        case notListening
        /// 在听，但绑的地址已经不是本机地址了（DHCP 换过 IP）。
        case staleAddress(String)
    }

    /// 检查监听状态。
    ///
    /// ## 为什么要区分「没在听」和「绑了旧地址」
    ///
    /// 老版本只查后者，前者被 `guard ... else { return false }` 当成健康放行了。
    /// 于是真实发生的故障是：`llmq cluster serve` 进程活得好好的、
    /// launchd 看着一切正常、`ps` 里有它，但 `lsof -iTCP:8443` 空空如也 ——
    /// **没有任何人发现**。对端连过来只能得到 RST，查了半天以为是网络问题。
    ///
    /// 根因是 NWListener 绑不上时进的是 `.waiting` 而不是 `.failed`，
    /// 而 `.waiting` 当时没被处理。但更值得记的是这里：
    /// 一个健康检查把「完全没在工作」判成健康，比没有健康检查更糟。
    public static func serveHealth(port: UInt16, process: String = "llmq") -> ServeHealth {
        guard let bound = listenAddress(port: port, process: process) else {
            return .notListening
        }
        guard let host = bound.split(separator: ":").first.map(String.init),
              host != "*", host != "0.0.0.0" else { return .ok(bound) }
        return localAddresses().contains(host) ? .ok(bound) : .staleAddress(bound)
    }

    /// 绑的那个地址现在还是本机地址吗。
    ///
    /// 只答「绑了旧地址」这一问。**别拿它当健康检查** —— 没在监听时它也返回
    /// false，那是「没有旧地址问题」，不是「一切正常」。用 `serveHealth`。
    public static func boundAddressIsStale(port: UInt16) -> Bool {
        if case .staleAddress = serveHealth(port: port) { return true }
        return false
    }

    static func localAddresses() -> Set<String> {
        var out: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return out }
        defer { freeifaddrs(head) }
        for p in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let f = p.pointee
            guard f.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len),
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.insert(String(cString: buf))
            }
        }
        return out
    }

    /// 到同网段另一台主机走哪个网卡。
    static func lanRouteInterface() -> String? {
        guard let ip = ClusterNet.lanAddress() else { return nil }
        // 拿同网段的 .1（通常是网关）当探针 —— 它一定和局域网同一条路由。
        var parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return nil }
        parts[3] = parts[3] == "1" ? "2" : "1"
        let probe = parts.joined(separator: ".")
        let r = Proc.run("/sbin/route", ["-n", "get", probe],
                         cwd: "/tmp", env: [:], timeout: 15)
        for line in r.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 挨个探一遍已知对端的 TCP 端口。
    ///
    /// 只探 TCP 建连，不做 TLS —— 这里要区分的是「网络通不通」，
    /// 握手层面的问题另有别的地方在报。超时给 3 秒：采集本身每 5 分钟
    /// 一轮，探测不该拖慢它。
    static func probePeers(_ cfg: ClusterConfig?) -> [String: Bool] {
        guard let cfg else { return [:] }
        var out: [String: Bool] = [:]
        for (node, addr) in cfg.peers where node != cfg.nodeName {
            // 对端地址优先用它自报的，配置里那个可能已经过期
            let target = address(forNode: node) ?? addr
            let parts = target.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
            out[node] = tcpReachable(host: String(parts[0]), port: port)
        }
        return out
    }

    static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval = 3) -> Bool {
        // 用 nc 而不是自己写 socket：这段代码在采集路径上，
        // 卡住会拖垮整轮采集，而 nc 的超时行为是确定的。
        let r = Proc.run("/usr/bin/nc",
                         ["-z", "-G", String(Int(timeout)), "-w", String(Int(timeout)),
                          host, String(port)],
                         cwd: "/tmp", env: [:], timeout: timeout + 5)
        return r.exitCode == 0
    }

    /// 应用防火墙的原始输出。全局开关 + 隐身模式一起取。
    static func firewallRawState() -> String {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.fileExists(atPath: fw) else { return "无此文件" }
        let r = Proc.run(fw, ["--getglobalstate", "--getstealthmode"],
                         cwd: "/tmp", env: [:], timeout: 15)
        let s = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "（读不到，退出码 \(r.exitCode)）"
            : s.replacingOccurrences(of: "\n", with: "；")
    }

    static func firewallEnabled() -> Bool {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.fileExists(atPath: fw) else { return false }
        let s = Proc.run(fw, ["--getglobalstate"], cwd: "/tmp", env: [:], timeout: 15).stdout
        return !(s.contains("disabled") || s.contains("State = 0"))
    }

    static func requestDownloads(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        for url in entries where url.pathExtension == "icloud" {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }
}
