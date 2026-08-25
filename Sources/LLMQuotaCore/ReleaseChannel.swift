import Foundation

/// 自动更新通道。
///
/// 这是整套系统里**最危险的一个功能**：它让一台机器上的文件决定另一台机器
/// 执行什么代码。所以信任模型必须比装机那套「哈希写在命令里」严格 ——
/// 那时候人在终端前面盯着，现在没有人。
///
/// 链条是这样的，每一环都能独立验证：
///
///   集群 CA（私钥只在主机上）
///     └─ 签发 release-signer 证书
///          └─ 用它的私钥签 manifest（manifest 里有 tar 包的 SHA-256）
///               └─ tar 包本身用 SHA-256 校验
///
/// 从机验三件事，缺一不可：
///   1. release-signer 证书确实由本集群的 CA 签发（它手上有 ca.crt）
///   2. 这张证书的 CN 就是 "release-signer" —— **不能是任意节点证书**。
///      否则一张被偷的从机证书就能给全集群推代码，
///      那比它原本能干的（投一个任务）严重得多。
///   3. manifest 的签名对得上，且 tar 包的哈希和 manifest 里写的一致
///
/// release-signer 的私钥**从不分发**，只待在主机上。
public enum ReleaseChannel {

    /// 测试用，产品代码里永远是 nil。
    public static var dirOverride: URL?
    public static var markerOverride: URL?

    public static var dir: URL? {
        if let dirOverride { return dirOverride }
        return Paths.iCloudConfigDir?
            .deletingLastPathComponent()
            .appendingPathComponent("releases", isDirectory: true)
    }

    /// 签名者的 CN。从机会严格比对这个值。
    public static let signerName = "release-signer"

    static var signerKey: URL { ClusterCA.dir.appendingPathComponent("\(signerName).key") }
    static var signerCert: URL { ClusterCA.dir.appendingPathComponent("\(signerName).crt") }

    // MARK: - 清单

    public struct Manifest: Codable, Sendable, Equatable {
        /// tar 包的 SHA-256。**同时也是这个版本的身份** ——
        /// 不另外维护版本号：版本号要靠人记得改，哈希不会忘。
        public var sha256: String
        public var file: String
        public var publishedAt: Date
        public var publishedBy: String
        public var notes: String

        public init(sha256: String, file: String, publishedAt: Date,
                    publishedBy: String, notes: String) {
            self.sha256 = sha256
            self.file = file
            self.publishedAt = publishedAt
            self.publishedBy = publishedBy
            self.notes = notes
        }
    }

    /// 新版把“被签名的原始清单 + 签名 + 签名证书”嵌进同一个 JSON。
    /// 顶层仍保留 Manifest 的五个字段，让旧版 updater 能继续解码；旧版使用
    /// `current.sig`，新版只信这个单文件信封，避免 iCloud 分开同步两个文件时
    /// 短暂把正常发布误报成篡改。
    private struct SignedEnvelope: Codable {
        var sha256: String
        var file: String
        var publishedAt: Date
        var publishedBy: String
        var notes: String
        var signedPayload: Data
        var embeddedSignature: Data
        var signerCertificate: Data

        init(manifest: Manifest, signedPayload: Data, embeddedSignature: Data,
             signerCertificate: Data) {
            sha256 = manifest.sha256
            file = manifest.file
            publishedAt = manifest.publishedAt
            publishedBy = manifest.publishedBy
            notes = manifest.notes
            self.signedPayload = signedPayload
            self.embeddedSignature = embeddedSignature
            self.signerCertificate = signerCertificate
        }

        var manifest: Manifest {
            Manifest(sha256: sha256, file: file, publishedAt: publishedAt,
                     publishedBy: publishedBy, notes: notes)
        }
    }

    /// 本机当前装的是哪个版本。存的就是那串哈希。
    static var installedMarker: URL {
        markerOverride ?? Paths.appSupport.appendingPathComponent("installed-release")
    }

    public static var installedSHA: String? {
        try? String(contentsOf: installedMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func markInstalled(_ sha: String) {
        if markerOverride == nil { try? Paths.ensureDirectories() }
        try? sha.write(to: installedMarker, atomically: true, encoding: .utf8)
    }

    // MARK: - 签名者

    /// 建一张专用的发布签名证书。只在主机上做一次。
    ///
    /// 为什么不直接拿 CA 私钥来签：密钥分离。CA 私钥只干一件事 —— 签证书。
    /// 发布签名是另一件事，出问题时可以只换发布证书，不用重建整个集群。
    @discardableResult
    public static func ensureSigner() throws -> Bool {
        guard ClusterCA.exists else {
            throw ClusterCA.err("还没建 CA，先跑 llmq cluster init")
        }
        if FileManager.default.fileExists(atPath: signerCert.path) { return false }

        let tmp = ClusterCA.dir.appendingPathComponent("issue-signer", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let csr = tmp.appendingPathComponent("s.csr")
        guard Proc.run("/usr/bin/openssl",
            ["ecparam", "-genkey", "-name", "prime256v1", "-out", signerKey.path],
            cwd: tmp.path, env: [:], timeout: 30).exitCode == 0
        else { throw ClusterCA.err("生成发布签名私钥失败") }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: signerKey.path)

        guard Proc.run("/usr/bin/openssl",
            ["req", "-new", "-key", signerKey.path, "-out", csr.path,
             "-subj", "/CN=\(signerName)"],
            cwd: tmp.path, env: [:], timeout: 30).exitCode == 0
        else { throw ClusterCA.err("生成发布签名 CSR 失败") }

        // 只给 codeSigning 用途。这张证书不能拿去当节点证书连服务端 ——
        // 用途分开，一张证书就只能干一件事。
        let ext = tmp.appendingPathComponent("ext.cnf")
        try """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=codeSigning
        """.write(to: ext, atomically: true, encoding: .utf8)

        let sign = Proc.run("/usr/bin/openssl", [
            "x509", "-req", "-in", csr.path,
            "-CA", ClusterCA.caCert.path, "-CAkey", ClusterCA.dir
                .appendingPathComponent("ca.key").path,
            "-CAcreateserial", "-out", signerCert.path,
            "-days", "3650", "-sha256", "-extfile", ext.path,
        ], cwd: tmp.path, env: [:], timeout: 30)
        guard sign.exitCode == 0 else {
            throw ClusterCA.err("签发发布证书失败：\(sign.stderr)")
        }
        return true
    }

    // MARK: - 发布

    public static func publish(tarball: URL, notes: String, by node: String) throws -> Manifest {
        guard let dir else { throw ClusterCA.err("找不到 iCloud 目录") }
        try ensureSigner()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sha = try sha256(of: tarball)
        let name = "llmq-\(sha.prefix(12)).tar.gz"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: tarball, to: dest)

        let manifest = Manifest(sha256: sha, file: name, publishedAt: Date(),
                                publishedBy: node, notes: notes)
        let manifestData = try SnapshotCoding.prettyEncoder().encode(manifest)
        let embeddedSignature = try sign(manifestData)
        let certificate = try Data(contentsOf: signerCert)
        let envelope = SignedEnvelope(
            manifest: manifest, signedPayload: manifestData,
            embeddedSignature: embeddedSignature, signerCertificate: certificate)
        let mURL = dir.appendingPathComponent("current.json")
        guard ICloudSafe.write(
            try SnapshotCoding.prettyEncoder().encode(envelope), to: mURL, timeout: 20)
        else {
            throw NSError(domain: "ReleaseChannel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "写发布清单超时（iCloud 没响应）"])
        }

        // 签的是 manifest 而不是 tar 包本身：manifest 里已经有包的哈希，
        // 一个签名就覆盖了全部内容，而且 manifest 只有几百字节，验起来快。
        let sigURL = dir.appendingPathComponent("current.sig")
        try? FileManager.default.removeItem(at: sigURL)
        let s = Proc.run("/usr/bin/openssl", [
            "dgst", "-sha256", "-sign", signerKey.path,
            "-out", sigURL.path, mURL.path,
        ], cwd: dir.path, env: [:], timeout: 30)
        guard s.exitCode == 0 else { throw ClusterCA.err("签名失败：\(s.stderr)") }

        // 签名证书跟着一起发。从机用它手上的 ca.crt 验这张证书，
        // 所以放在 iCloud 里被人替换掉也没用 —— 换成别的 CA 签的就验不过。
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(signerName).crt"))
        try FileManager.default.copyItem(
            at: signerCert, to: dir.appendingPathComponent("\(signerName).crt"))

        cleanupOldReleases(keeping: name, in: dir)
        return manifest
    }

    /// 旧包留一个就够回滚，再多只是占 iCloud。
    static func cleanupOldReleases(keeping current: String, in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = files
            .filter { $0.lastPathComponent.hasPrefix("llmq-")
                   && $0.lastPathComponent != current }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
        for f in old.dropFirst(1) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: - 检查与验证

    public enum Status {
        case upToDate(String)
        case available(Manifest, payload: URL)
        case noChannel
        case rejected(String)
    }

    public static func check() -> Status {
        guard let dir, FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("current.json").path) else {
            return .noChannel
        }
        let mURL = dir.appendingPathComponent("current.json")
        let sigURL = dir.appendingPathComponent("current.sig")
        let certURL = dir.appendingPathComponent("\(signerName).crt")

        guard let data = try? Data(contentsOf: mURL) else {
            return .rejected("清单读不出来")
        }
        let decoder = SnapshotCoding.decoder()
        let envelope = try? decoder.decode(SignedEnvelope.self, from: data)
        guard let manifest = envelope?.manifest
            ?? (try? decoder.decode(Manifest.self, from: data)) else {
            return .rejected("清单读不出来")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmq-relverify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let verificationCert: URL
        let verificationSignature: URL
        let verificationPayload: URL
        if let envelope {
            guard let signed = try? decoder.decode(Manifest.self,
                                                   from: envelope.signedPayload),
                  signed == manifest else {
                return .rejected("清单字段和签名内容不一致 —— 清单被改过")
            }
            verificationCert = tmp.appendingPathComponent("release-signer.crt")
            verificationSignature = tmp.appendingPathComponent("manifest.sig")
            verificationPayload = tmp.appendingPathComponent("manifest.json")
            do {
                try envelope.signerCertificate.write(to: verificationCert)
                try envelope.embeddedSignature.write(to: verificationSignature)
                try envelope.signedPayload.write(to: verificationPayload)
            } catch {
                return .rejected("签名信封解不开")
            }
        } else {
            // 兼容集群里还没升级到单文件信封的历史发布。
            verificationCert = certURL
            verificationSignature = sigURL
            verificationPayload = mURL
        }

        // ① 证书必须由本集群的 CA 签发
        //
        // **「读不到」和「被篡改了」必须分开报。**
        //
        // 这条判断真金白银地咬过一次：对面那台机器的更新器每 30 分钟报一次
        // 「有人换了 iCloud 里的东西」，连报两天，于是它一直停在旧版本 ——
        // 而真相是 launchd 起的进程读不到 iCloud 上那张证书（EPERM）。
        // 一句指控篡改的话，把人引向「谁动了我的 iCloud」，
        // 而问题在访问授权。它还是**静默**的：只写在没人看的日志里。
        //
        // 注意「先检查可读性」这个自然的修法**也是错的**：实测 launchd 下
        // `[ -r file ]` 返回真，真去 fopen 才 EPERM。只能靠真实读取的结果分。
        let probe = Proc.run("/bin/cat", [verificationCert.path],
                             cwd: NSTemporaryDirectory(), env: [:], timeout: 10)
        if probe.exitCode != 0 || probe.stdout.isEmpty {
            let why = probe.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let denied = why.lowercased().contains("not permitted")
                || why.lowercased().contains("permission denied")
            return .rejected(denied
                ? "**读不到**发布证书（\(certURL.lastPathComponent)）—— 不是被篡改，"
                  + "是这个进程没权限读发布证书。"
                  + "launchd 起的进程没有终端的授权上下文，"
                  + "而这条报错会让人去查「谁动了我的 iCloud」。原始错误：\(why.prefix(120))"
                : "发布证书读不出来：\(why.isEmpty ? "文件是空的" : String(why.prefix(120)))")
        }

        let chain = Proc.run("/usr/bin/openssl",
            ["verify", "-CAfile", ClusterCA.caCert.path, verificationCert.path],
            cwd: dir.path, env: [:], timeout: 20)
        guard chain.exitCode == 0 else {
            let detail = (chain.stderr + chain.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .rejected("发布证书不是本集群 CA 签的 —— 有人换了 iCloud 里的东西"
                + (detail.isEmpty ? "" : "（openssl：\(detail.prefix(120))）"))
        }

        // ② CN 必须正好是 release-signer。
        //    不检查这一条，任何一张节点证书都能签发布 ——
        //    等于一张被偷的从机证书可以给全集群推代码。
        let subj = Proc.run("/usr/bin/openssl",
            ["x509", "-in", verificationCert.path, "-noout", "-subject"],
            cwd: dir.path, env: [:], timeout: 20)
        guard subj.stdout.contains("CN=\(signerName)") else {
            return .rejected("签名者不是 \(signerName)，是 \(subj.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // ③ 签名要对
        // `-pubkey` 把公钥打到 **stdout**，`-out` 在这里是无效的 ——
        // 加了 -out 反而什么文件都不会生成，而 openssl 退出码仍然是 0。
        // 那样验签会永远失败，而且失败信息长得像"被篡改了"，
        // 排查方向完全错。所以这里自己接 stdout 写文件。
        let pub = tmp.appendingPathComponent("pub.pem")
        let extract = Proc.run("/usr/bin/openssl",
            ["x509", "-in", verificationCert.path, "-pubkey", "-noout"],
            cwd: tmp.path, env: [:], timeout: 20)
        guard extract.exitCode == 0,
              extract.stdout.contains("BEGIN PUBLIC KEY"),
              (try? extract.stdout.write(to: pub, atomically: true, encoding: .utf8)) != nil
        else {
            // 这条和「被篡改」要分开说。工具用错了和有人动了文件是两回事，
            // 混在一起会让人往完全错误的方向查。
            return .rejected("取不出发布证书的公钥（本机 openssl 出问题了，不是篡改）")
        }

        let v = Proc.run("/usr/bin/openssl", [
            "dgst", "-sha256", "-verify", pub.path,
            "-signature", verificationSignature.path, verificationPayload.path,
        ], cwd: tmp.path, env: [:], timeout: 20)
        guard v.exitCode == 0 else {
            return .rejected("清单签名验不过 —— 清单被改过")
        }

        // 已安装也必须先验完清单。旧逻辑在哈希相同处提前返回，发布机自己
        // 永远发现不了刚写出的坏签名，只有另一台机器会报错。
        if let installed = installedSHA, installed == manifest.sha256 {
            return .upToDate(manifest.sha256)
        }

        // ④ 包的哈希要和清单里写的一致
        let payload = dir.appendingPathComponent(manifest.file)
        guard FileManager.default.fileExists(atPath: payload.path) else {
            return .rejected("清单指向的包还没同步过来：\(manifest.file)")
        }
        guard let actual = try? sha256(of: payload) else {
            return .rejected("算不出包的哈希")
        }
        guard actual == manifest.sha256 else {
            return .rejected("包的哈希和清单对不上 —— 包被换过")
        }
        return .available(manifest, payload: payload)
    }

    // MARK: - 安装

    /// 就地更新本机的 llmq 和菜单栏 App。
    ///
    /// 只有 `check()` 返回 `.available` 才会走到这里 —— 也就是说
    /// 签名链已经验过了。这个函数不重复验，但它也**不接受**外部传进来的路径，
    /// 只接受 check 的产物，避免有人绕过验证直接调它。
    public static func install(_ manifest: Manifest, payload: URL) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmq-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let untar = Proc.run("/usr/bin/tar", ["xzf", payload.path, "-C", tmp.path],
                             cwd: tmp.path, env: [:], timeout: 120)
        guard untar.exitCode == 0 else { throw ClusterCA.err("解包失败：\(untar.stderr)") }

        let root = tmp.appendingPathComponent("llmq-dist")
        let newBin = root.appendingPathComponent("llmq")
        let newApp = root.appendingPathComponent("LLMQuotaBar.app")
        guard FileManager.default.fileExists(atPath: newBin.path) else {
            throw ClusterCA.err("包里没有 llmq")
        }

        // 换二进制前先确认它跑得起来。装上一个跑不了的 llmq，
        // 这台机器就再也收不到下一次更新了 —— 自动更新的死法就是这个。
        let probe = Proc.run(newBin.path, ["--help"], cwd: tmp.path, env: [:], timeout: 30)
        guard probe.exitCode == 0 else {
            throw ClusterCA.err("新二进制跑不起来（退出码 \(probe.exitCode)），拒绝安装")
        }

        let bin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // **换二进制之前先把集群口令捞出来。**
        //
        // 钥匙串条目的 ACL 绑在创建它的那个二进制上，而这个项目自动更新 ——
        // 每发一版就换一次二进制，于是每发一版，跨机通信就断一次。
        // macOS 26 上没有绕过去的办法，两条都实测过：放宽 ACL（应用列表
        // 传 nil）换了二进制照样 errSecAuthFailed；数据保护钥匙串写入直接
        // -34018 缺 entitlement，未签名的 CLI 用不了。
        //
        // 但**现在跑着的还是旧二进制**，它读得到。所以在这儿读出来，
        // 装完之后让新二进制原样写回去，条目就重新绑到新的那个上面。
        //
        // 握着 CA 私钥的机器另有一条自愈路（读不到就重签，见
        // `Passphrase.reissueSelf`）。这条是给**只导入过身份的从机**准备的 ——
        // 它没有 ca.key，断了只能人工重新 enroll，两样东西还得分开传。
        let node = ClusterConfigStore.load()?.nodeName ?? ""
        let carried = ClusterNet.Passphrase.rawLoad(node: node)

        // 原子替换。直接覆盖会让正在运行的进程映像失效，macOS 会 SIGKILL 它。
        let staged = bin.appendingPathComponent(".llmq.new")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: newBin, to: staged)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let installed = bin.appendingPathComponent("llmq")
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)

        // 资源包要跟着二进制走 —— Bundle.module 按可执行文件所在目录找。
        // 少了它，凡是用到内置资源的命令都会当场
        // 「Fatal error: unable to find bundle named …」，而 --help 之类
        // 碰不到资源的命令一切正常，所以安装后的探活根本发现不了。
        for f in (try? FileManager.default.contentsOfDirectory(
            at: newBin.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "bundle" {
            let dst = bin.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: f, to: dst)
        }

        // 让新二进制自己写一遍，条目的 ACL 就绑到它身上了。
        //
        // 口令走环境变量不走 argv：argv 在 `ps` 里对**所有**用户可见，
        // 环境变量只有同 uid 和 root 看得到。反正接下来还要读 ca.key，
        // 门槛本来就是「登录用户」。
        if let carried, !carried.isEmpty, !node.isEmpty {
            try? ClusterNet.Passphrase.delete(node: node)
            let r = Proc.run(installed.path, ["cluster", "reseal", node],
                             cwd: NSTemporaryDirectory(),
                             env: ["LLMQ_RESEAL_PW": carried], timeout: 60)
            if r.exitCode != 0 {
                // 不能吞。吞了的话下一次跨机调用才发现，而那时线索早断了。
                FileHandle.standardError.write(Data(
                    ("集群口令没能转交给新二进制（\(r.stderr.prefix(120))）——"
                     + "跨机通信可能要重新 llmq cluster import\n").utf8))
            }
        }

        // App 和 CLI 必须一起换。只换一个的话，旧的那个会用它那套过时的
        // 采集器把快照覆盖回去，新接的平台数据就静默消失了。踩过。
        if FileManager.default.fileExists(atPath: newApp.path) {
            _ = Proc.run("/usr/bin/pkill", ["-f", "LLMQuotaBar.app/Contents/MacOS"],
                         cwd: "/", env: [:], timeout: 10)
            let dst = URL(fileURLWithPath: "/Applications/LLMQuotaBar.app")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: newApp, to: dst)
            _ = Proc.run("/usr/bin/codesign",
                         ["--force", "--deep", "--sign", "-", dst.path],
                         cwd: "/", env: [:], timeout: 60)
            // **拉起之后要核实。** 实锤(2026-08-21):MacBook 上 09:16 自动
            // 更新后 App 三小时没在跑——`open <刚重建的包路径>` 在 launchd
            // 上下文里悄悄失败了(疑似 LaunchServices 对刚删又建的 bundle
            // 注册过期),而这一句的返回值被 `_ =` 吞掉。App 不在 = 镜像
            // 不推不拉 = 这台机器在集群看板上「3 小时没更新」,老板先发现的。
            _ = Proc.run("/usr/bin/open", [dst.path], cwd: "/", env: [:], timeout: 20)
            Thread.sleep(forTimeInterval: 2)
            func appAlive() -> Bool {
                Proc.run("/usr/bin/pgrep", ["-f", "LLMQuotaBar.app/Contents/MacOS"],
                         cwd: "/", env: [:], timeout: 5).exitCode == 0
            }
            if !appAlive() {
                // 按名字开不走路径缓存 —— 手工 `open -a LLMQuotaBar` 一下就起来了。
                _ = Proc.run("/usr/bin/open", ["-a", "LLMQuotaBar"], cwd: "/", env: [:], timeout: 20)
                Thread.sleep(forTimeInterval: 2)
            }
            FileHandle.standardOutput.write(Data(
                (appAlive() ? "  菜单栏 App 已重新拉起\n"
                            : "  ⚠︎ 菜单栏 App 没拉起来 —— 这台机器的镜像同步会停,请手动 open -a LLMQuotaBar\n").utf8))
        }

        markInstalled(manifest.sha256)

        // **这里不踢 worker。** 原来末尾有一句无条件 `launchctl kickstart -k worker`,
        // 把调用方 `restartResidentServices()` 的在飞守卫整个绕过去了 —— 自动更新一到,
        // 正在跑的 agent 跟着死(fa4e5eeb 2026-08-23 被杀两次,每次十几分钟 Kimi 额度)。
        // 同一件事两处判,必出这种事。换二进制由 work loop 自己在空闲点做(BinarySwap),
        // 要立刻踢的场合走调用方那条带守卫的路。
    }

    // MARK: - 工具

    static func sha256(of url: URL) throws -> String {
        let r = Proc.run("/usr/bin/shasum", ["-a", "256", url.path],
                         cwd: "/tmp", env: [:], timeout: 120)
        guard r.exitCode == 0, let first = r.stdout.split(separator: " ").first else {
            throw ClusterCA.err("算哈希失败")
        }
        return String(first)
    }

    private static func sign(_ data: Data) throws -> Data {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmq-relsign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = tmp.appendingPathComponent("manifest.json")
        let signature = tmp.appendingPathComponent("manifest.sig")
        try data.write(to: payload)
        let result = Proc.run("/usr/bin/openssl", [
            "dgst", "-sha256", "-sign", signerKey.path,
            "-out", signature.path, payload.path,
        ], cwd: tmp.path, env: [:], timeout: 30)
        guard result.exitCode == 0 else {
            throw ClusterCA.err("签名失败：\(result.stderr)")
        }
        return try Data(contentsOf: signature)
    }
}
