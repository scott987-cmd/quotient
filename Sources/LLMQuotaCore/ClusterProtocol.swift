import Foundation

/// 集群节点配置。
///
/// `allowedNodes` 是**授权名单**，跟"这张证书签得对不对"是两件事：
/// 证书验的是"你确实是 CA 签过的某个节点"，名单验的是"这个节点现在还准不准进来"。
/// 少了名单，一张发给已下线机器的证书在到期前（825 天）一直有效 ——
/// 私有 CA 没有吊销列表，名单就是唯一的撤销手段。
public struct ClusterConfig: Codable, Sendable {
    /// 本机的节点名。必须和 `<name>.p12` 里那张证书的 CN 一致。
    public var nodeName: String
    /// 允许连进来的节点。**不含自己**也没关系，自己不会连自己。
    public var allowedNodes: [String]
    /// 节点名 → "host:port"。dispatch 靠它找到对端。
    public var peers: [String: String]
    /// 监听端口。只在跑 `llmq cluster serve` 时才会真的绑上。
    public var port: UInt16
    /// 绑哪个地址。nil = 自动挑局域网地址（默认）。
    ///
    /// 之所以能配：默认是用 `requiredLocalEndpoint` 绑到具体的局域网地址上，
    /// 理由是多插一张网卡或开个热点都不会把服务意外带到别的网段。
    /// 但实测遇到过一台机器上这么绑之后 SYN 被静默丢弃，而同一端口用
    /// `nc -l`（绑 0.0.0.0）却完全正常。绑 0.0.0.0 不构成安全降级 ——
    /// 门槛在 mTLS 和那个封闭动词集上，不在绑定地址上。
    public var bindAddress: String?

    public init(nodeName: String, allowedNodes: [String] = [],
                peers: [String: String] = [:], port: UInt16 = 8443,
                bindAddress: String? = nil) {
        self.nodeName = nodeName
        self.allowedNodes = allowedNodes
        self.peers = peers
        self.bindAddress = bindAddress
        self.port = port
    }

    public var allowedSet: Set<String> { Set(allowedNodes) }
}

public enum ClusterConfigStore {
    static var file: URL { ClusterCA.dir.appendingPathComponent("node.json") }

    public static func load() -> ClusterConfig? {
        guard let data = try? Data(contentsOf: file),
              let c = try? SnapshotCoding.decoder().decode(ClusterConfig.self, from: data)
        else { return nil }
        return c
    }

    public static func save(_ c: ClusterConfig) throws {
        try FileManager.default.createDirectory(
            at: ClusterCA.dir, withIntermediateDirectories: true)
        let data = try SnapshotCoding.prettyEncoder().encode(c)
        guard ICloudSafe.write(data, to: file) else {
            throw NSError(domain: "ClusterProtocol", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "写集群配置超时（iCloud 没响应）"])
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - 请求与响应

/// 对端能让本机做的事，**穷举**在这里。
///
/// 这是整个跨机方案里最重要的一处设计：认证解决"你是谁"，
/// 这个封闭枚举解决"你能干什么"。没有 `exec`、没有 `shell`、
/// 没有"跑这条命令"，所以一张被偷走的客户端证书拿不到任意代码执行 ——
/// 它能做的最坏的事，和能往你 iCloud 收件箱丢文件的人一样：投一个任务。
/// 那条路径的爆炸半径已经在 SECURITY.md 第五节里写清楚了，这里不新增。
public enum ClusterRequest: Codable, Sendable {
    /// 探活。回一个节点名，用来确认双向证书真的通了。
    case ping
    /// 拉对端的额度看板。只读。
    case status
    /// 投一个任务。
    ///
    /// `repo` 是**别名**不是路径 —— 解析交给本机的 RepoRegistry。
    /// 这条是硬性的：允许对端指定绝对路径，等于允许它在任意目录里跑 agent。
    case submit(prompt: String, repo: String?, profile: TaskProfile?)
    /// 查一个任务现在什么状态。
    case task(id: String)
}

public enum ClusterResponse: Codable, Sendable {
    case pong(node: String, version: String)
    case status(Dashboard)
    case accepted(taskID: String, repo: String)
    case task(WorkTask)
    case failed(reason: String)

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - 分帧

/// 4 字节大端长度 + JSON。
///
/// 不用 HTTP：省掉一整套解析器，也就省掉了它那一整套解析歧义
/// （分块编码、走私、头部大小写、重复头）。这条链路两端都是我们自己的代码，
/// 没有任何理由背上通用协议的复杂度。
public enum Frame {
    /// 单帧上限。没有这条，对端发一个声称 4GB 的长度前缀就能把内存打爆 ——
    /// 而且这发生在**握手之后**，所以身份认证拦不住它。
    public static let maxSize = 1 << 20   // 1 MiB

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try SnapshotCoding.encoder().encode(value)
        guard body.count <= maxSize else {
            throw ClusterCA.err("消息太大：\(body.count) 字节，上限 \(maxSize)")
        }
        var out = Data(capacity: body.count + 4)
        var be = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// 从前缀里读出长度。数据不足 4 字节返回 nil。
    public static func length(of header: Data) -> Int? {
        guard header.count >= 4 else { return nil }
        let n = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(n)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try SnapshotCoding.decoder().decode(type, from: body)
    }
}

// MARK: - 处理请求

/// 服务端逻辑。和网络层分开，是为了能不开端口就把它测干净。
public enum ClusterService {

    public static func handle(_ req: ClusterRequest, from node: String) -> ClusterResponse {
        switch req {
        case .ping:
            return .pong(node: ClusterConfigStore.load()?.nodeName ?? "unknown",
                         version: ClusterNet.protocolVersion)

        case .status:
            return .status(LLMQuota.dashboard())

        case .task(let id):
            guard let t = TaskStore.all().first(where: { $0.id == id }) else {
                return .failed(reason: "没有这个任务：\(id)")
            }
            return .task(t)

        case .submit(let prompt, let repo, let profile):
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 8 else {
                return .failed(reason: "任务描述太短")
            }
            // 别名解析走和 iCloud 收件箱同一个闸门。对端给的是别名，
            // 本机决定它指向哪个目录 —— 对端无法指定路径。
            guard let path = RepoRegistry.resolve(repo) else {
                return .failed(reason: repo.map { "找不到仓库别名「\($0)」" }
                    ?? "没有配置默认仓库")
            }
            var t = WorkTask(id: "pending", prompt: trimmed, repo: path)
            t.note = "来自节点 \(node)"
            // 画像由派发方在它自己那台机器上算好带过来，本机不再算一遍 ——
            // 分诊要花一次调用，让发起的人出这笔钱。
            //
            // 对端可以在这里撒谎（把复杂任务标成 trivial），但它反正已经能提交
            // 任意提示词了，谎报难度并不会让它拿到多的权限，只会让活派得更差。
            t.profile = profile
            do {
                let requestKey = "cluster:\(node):\(repo ?? "default"):\(trimmed)"
                let outcome = try TaskIntake.enqueuePrepared(
                    t, idempotencyKey: requestKey, source: "cluster-submit")
                if case .single(let saved) = outcome { t = saved }
            } catch {
                return .failed(reason: "写入任务队列失败：\(error.localizedDescription)")
            }
            return .accepted(taskID: t.id, repo: path)
        }
    }
}
