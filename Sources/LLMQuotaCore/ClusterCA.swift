import Foundation
import Security

/// 集群的私有 CA 与证书签发。
///
/// 为什么是 mTLS 而不是 SSH：要让**手机 App** 也能派任务。
/// iOS 上用 SSH 不现实，而客户端证书是原生 App 连自建服务端的标准做法。
///
/// 整套方案的成败只系于一件事：**校验有没有真的生效**。
/// 最经典的失败是验证回调无条件放行 —— 不报错、不崩溃、看起来一切正常，
/// 实际上谁都能连进来。所以 `TrustEvaluator` 的每一条判定都有对应的
/// 「必须被拒」测试，而不只有「应该通过」测试。
public enum ClusterCA {

    /// 测试用：把整个 CA 目录挪到临时位置，别碰真实安装。
    /// 只有测试会写它，产品代码里永远是 nil。
    public static var dirOverride: URL?

    public static var dir: URL {
        dirOverride ?? Paths.appSupport.appendingPathComponent("cluster", isDirectory: true)
    }
    static var caKey: URL { dir.appendingPathComponent("ca.key") }
    public static var caCert: URL { dir.appendingPathComponent("ca.crt") }
    static var serial: URL { dir.appendingPathComponent("ca.srl") }

    public static var exists: Bool {
        FileManager.default.fileExists(atPath: caCert.path)
    }

    /// 建一个只给这个集群用的根 CA。
    ///
    /// 用 openssl 而不是 Security.framework 生成：命令行产物是标准 PEM，
    /// 你可以用 `openssl x509 -text` 自己审一遍，而 Security.framework
    /// 建证书的那套 API 既难读也难验证。
    @discardableResult
    public static func initialize(force: Bool = false) throws -> Bool {
        if exists && !force { return false }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let genKey = Proc.run("/usr/bin/openssl",
            ["ecparam", "-genkey", "-name", "prime256v1", "-out", caKey.path],
            cwd: dir.path, env: [:], timeout: 30)
        guard genKey.exitCode == 0 else {
            throw err("生成 CA 私钥失败：\(genKey.stderr)")
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: caKey.path)

        // pathlen:0 —— 这个 CA 只签叶证书，不签中间 CA。
        // 少一层就少一类"中间 CA 泄露导致全盘失守"的可能。
        let mkCA = Proc.run("/usr/bin/openssl", [
            "req", "-x509", "-new", "-key", caKey.path, "-sha256",
            "-days", "3650", "-out", caCert.path,
            "-subj", "/CN=LLMQuotaBar Cluster CA",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        ], cwd: dir.path, env: [:], timeout: 30)
        guard mkCA.exitCode == 0 else {
            throw err("生成 CA 证书失败：\(mkCA.stderr)")
        }
        return true
    }

    /// 给一个节点签发证书，产出可直接分发的 .p12。
    ///
    /// - Parameter node: 节点名。会同时写进 CN 和 SAN ——
    ///   校验时按 SAN 匹配，CN 只是为了 `openssl x509 -subject` 好读。
    /// - Parameter password: .p12 的导出口令。分发 .p12 时口令要走另一个渠道，
    ///   跟文件本身分开传。
    public static func issue(node: String, password: String) throws -> URL {
        guard exists else { throw err("CA 还没建，先跑 llmq cluster init") }
        guard node.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$", options: .regularExpression) != nil
        else { throw err("节点名只能是字母数字和 . _ -，且不超过 63 字符：\(node)") }

        let tmp = dir.appendingPathComponent("issue-\(node)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let key = tmp.appendingPathComponent("node.key")
        let csr = tmp.appendingPathComponent("node.csr")
        let crt = tmp.appendingPathComponent("node.crt")

        guard Proc.run("/usr/bin/openssl",
            ["ecparam", "-genkey", "-name", "prime256v1", "-out", key.path],
            cwd: tmp.path, env: [:], timeout: 30).exitCode == 0
        else { throw err("生成节点私钥失败") }

        guard Proc.run("/usr/bin/openssl",
            ["req", "-new", "-key", key.path, "-out", csr.path, "-subj", "/CN=\(node)"],
            cwd: tmp.path, env: [:], timeout: 30).exitCode == 0
        else { throw err("生成 CSR 失败") }

        // serverAuth + clientAuth 都给：同一张证书既当服务端也当客户端，
        // 因为节点之间是对等的 —— A 可以派活给 B，B 也可以派给 A。
        let ext = tmp.appendingPathComponent("ext.cnf")
        try """
        subjectAltName=DNS:\(node)
        extendedKeyUsage=serverAuth,clientAuth
        keyUsage=critical,digitalSignature,keyEncipherment
        basicConstraints=critical,CA:FALSE
        """.write(to: ext, atomically: true, encoding: .utf8)

        let sign = Proc.run("/usr/bin/openssl", [
            "x509", "-req", "-in", csr.path,
            "-CA", caCert.path, "-CAkey", caKey.path, "-CAcreateserial",
            "-out", crt.path, "-days", "825", "-sha256",
            "-extfile", ext.path,
        ], cwd: tmp.path, env: [:], timeout: 30)
        guard sign.exitCode == 0 else { throw err("签发失败：\(sign.stderr)") }

        // 必须显式指定加密算法。/usr/bin/openssl 是 LibreSSL，
        // 它 pkcs12 -export 的证书默认用 RC2-40（40 位！），MAC 默认 SHA-1。
        // 证书是公开信息，40 位无所谓，但 OpenSSL 3 已经默认拒绝解 RC2 ——
        // 将来在别的机器上排查会莫名其妙地卡住。
        //
        // 只改证书那一项，MAC 和私钥都保持默认。两次尝试都撞了墙：
        //
        // - AES-256：macOS 的 SecPKCS12Import 直接读不了（-26275）。
        // - MAC 换 SHA-256：本机能导入，但**老一点的 macOS 不行**
        //   （-25264，errSecPkcs12VerifyFailure）。实际发到一台 Intel Mac
        //   上就炸了 —— 我当时只在本机探过算法支持，那台没探。
        //
        // 结论：p12 是要跨机器跨系统版本走的，只能取所有目标机器的交集，
        // 而本机能导入什么说明不了别的机器能导入什么。SHA-1 的 MAC 保住
        // 兼容性；真正的保护来自那个 32 位随机口令（约 144 位熵），
        // 离线爆破在这个前提下不是威胁。
        let out = dir.appendingPathComponent("\(node).p12")
        let pack = Proc.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-out", out.path,
            "-inkey", key.path, "-in", crt.path, "-certfile", caCert.path,
            "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES",
            "-name", node, "-passout", "pass:\(password)",
        ], cwd: tmp.path, env: [:], timeout: 30)
        guard pack.exitCode == 0 else { throw err("打包 p12 失败：\(pack.stderr)") }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: out.path)
        return out
    }

    /// 已签发过的节点。
    public static func issuedNodes() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".p12") }
            .map { String($0.dropLast(4)) }
            .sorted() ?? []
    }

    /// 读出 CA 证书对象，供信任校验用。
    public static func loadCACertificate() -> SecCertificate? {
        guard let pem = try? String(contentsOf: caCert, encoding: .utf8) else { return nil }
        return Self.certificate(fromPEM: pem)
    }

    public static func certificate(fromPEM pem: String) -> SecCertificate? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let der = Data(base64Encoded: body) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    public static func err(_ msg: String) -> NSError {
        NSError(domain: "ClusterCA", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - 信任校验

/// 校验对端证书。
///
/// 这里是整个 mTLS 方案唯一真正重要的地方。三条判定缺一不可，
/// 每一条漏掉都会让整套认证静默失效：
///
/// 1. **只信我们自己的 CA** —— 必须调 `SecTrustSetAnchorCertificatesOnly(true)`。
///    不调的话系统根证书**也**被信任，任何一张公网 CA 签的证书都能通过校验，
///    等于完全没有认证。这是最隐蔽也最致命的一条。
/// 2. **链要真的验过** —— `SecTrustEvaluateWithError` 的返回值必须用，
///    不能只调不看。
/// 3. **身份要在白名单里** —— 光验签不够，还得确认这张证书对应的节点
///    是我们批准过的。否则一张被吊销、或者发给已下线机器的证书仍然畅通。
public enum TrustEvaluator {

    public enum Verdict: Equatable {
        case trusted(node: String)
        case rejected(reason: String)

        public var isTrusted: Bool {
            if case .trusted = self { return true }
            return false
        }
    }

    public static func evaluate(
        peerCertificates: [SecCertificate],
        caCertificate: SecCertificate,
        allowedNodes: Set<String>
    ) -> Verdict {
        guard let leaf = peerCertificates.first else {
            return .rejected(reason: "对端没有提供证书")
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates(peerCertificates as CFArray, policy, &trust)
                == errSecSuccess, let trust else {
            return .rejected(reason: "无法构造信任对象")
        }

        // 只把我们的 CA 当锚点。
        guard SecTrustSetAnchorCertificates(trust, [caCertificate] as CFArray) == errSecSuccess
        else { return .rejected(reason: "设置锚点证书失败") }

        // 关键的一行：不加它，系统根证书也算数，任何公网 CA 签的证书都能进来。
        guard SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return .rejected(reason: "限定锚点失败") }

        // **禁止联网取证书。**
        //
        // SecTrustEvaluateWithError 默认允许为了补全证书链去联网（AIA），
        // 也可能去查吊销状态（OCSP/CRL）。我们这条链是自签私有 CA，
        // 证书里根本没有可抓的 URL，这种尝试**永远不可能成功** ——
        // 但系统会真的去试。
        //
        // 后果不是慢一点，是整个握手挂死：这台机器配了系统代理，
        // 抓取卡在那儿不返回，验证回调就不会调 complete()，
        // TLS 握手永远停在半路。表现是客户端等满 30 秒超时，
        // 而服务端**日志里一个字都没有**（它只在 .ready / .failed 记录，
        // 卡在 .preparing 的连接两个都不是）。
        //
        // 这个现象极难往应用层想：lsof 显示端口好好听着、防火墙关着、
        // 换端口、换绑定地址都没用，连 nc 探测都是通的（内核三次握手不需要
        // 应用参与）。真正定位它靠的是让那台机器**自己 ping 自己** ——
        // 一旦不经过网络还是同样的症状，网络就被彻底排除了。
        _ = SecTrustSetNetworkFetchAllowed(trust, false)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let detail = (error as Error?)?.localizedDescription ?? "未知原因"
            return .rejected(reason: "证书链校验不通过：\(detail)")
        }

        guard let node = commonName(of: leaf) else {
            return .rejected(reason: "证书里没有可识别的节点名")
        }
        guard allowedNodes.contains(node) else {
            return .rejected(reason: "节点 \(node) 不在允许列表里")
        }
        return .trusted(node: node)
    }

    public static func commonName(of cert: SecCertificate) -> String? {
        var cn: CFString?
        guard SecCertificateCopyCommonName(cert, &cn) == errSecSuccess else { return nil }
        return cn as String?
    }
}
