import Foundation
import Network
import Security

/// 局域网 mTLS 传输层。
///
/// 这个文件里有四处「写错了不会报错，只会静默失去保护」的地方，
/// 每一处都在下面标了原因，也都各有一条「必须被拒」的测试：
///
/// 1. 服务端不强制客户端证书 → 任何人都能连（`peerAuthenticationRequired`）
/// 2. 验证回调无条件 `complete(true)` → 证书形同虚设
/// 3. 不限定锚点 → 系统根 CA 也算数（在 `TrustEvaluator` 里）
/// 4. 绑 0.0.0.0 而不是内网地址 → 暴露面超出预期
public enum ClusterNet {

    /// 线上协议版本。两端不一致时 ping 能一眼看出来。
    public static let protocolVersion = "1"

    // MARK: - 身份

    /// 本进程的一次性钥匙串。老系统上用，进程退出就删。
    private static var scratch: SecKeychain?
    /// 它的口令。留着是为了能**反复解锁** —— 见 ensureScratchUnlocked。
    private static var scratchPassword: String?

    /// 从 .p12 里取出本机身份。
    ///
    /// ## 新系统：只在内存里解
    ///
    /// `kSecImportToMemoryOnly` 让私钥只存在于进程内存，退出就没了，
    /// 磁盘上永远只有那个用口令加密过的 .p12。
    ///
    /// ## 老系统（macOS < 15）：给它一个一次性钥匙串
    ///
    /// 那个键 macOS 15 才有。更早的系统上 `SecPKCS12Import` 会把身份
    /// **导进登录钥匙串**，而导进去的私钥，访问控制是按**当时那个可执行
    /// 文件**建的。于是 `llmq update` 换掉二进制之后，每次用到私钥系统
    /// 都会弹窗要密码。
    ///
    /// 后果比「烦」严重得多：客户端会**卡在那个没人点的弹窗上**直到超时。
    /// 表现是握手 30 秒无响应、服务端日志一个字都没有 —— 看起来完全像
    /// 网络不通。它一路伪装成防火墙、AP 隔离、端口被拦，
    /// 最后是在那台机器上看见 SecurityAgent 进程挂着才认出来的。
    ///
    /// 所以老系统上现建一个一次性钥匙串：口令是本进程当场随机生成的，
    /// 用完即删。登录钥匙串一点不碰，也就没有 ACL、没有弹窗。
    /// 落盘的文件里私钥是用那个随机口令加密的，而口令只在内存 ——
    /// 进程一没它就是一堆无用字节，下次启动还会先清掉。
    public static func loadIdentity(node: String, password: String) throws -> SecIdentity {
        let p12 = ClusterCA.dir.appendingPathComponent("\(node).p12")
        guard let data = try? Data(contentsOf: p12) else {
            throw ClusterCA.err("找不到 \(node).p12，先跑 llmq cluster enroll \(node)")
        }
        var opts: [String: Any] = [kSecImportExportPassphrase as String: password]
        var memoryOnly = false
        if #available(macOS 15.0, *) {
            opts[kSecImportToMemoryOnly as String] = true
            memoryOnly = true
        }
        // 一次性钥匙串这条路可以关掉。
        //
        // 它解决的是「更新之后每次用私钥都弹窗」，但**导进去的私钥能不能
        // 真的用来签名**是另一回事 —— TLS 1.3 里客户端要用它签
        // CertificateVerify，签不了就等于没出证书，服务端的验证回调
        // 根本不会被调用，握手停在那儿谁也不报错。
        // 留个开关，出问题时不用重新发版就能二分。
        let noScratch = ProcessInfo.processInfo.environment["LLMQ_NO_SCRATCH_KEYCHAIN"] == "1"
        if !memoryOnly, !noScratch, let kc = scratchKeychain() {
            opts[kSecImportExportKeychain as String] = kc
        }
        var items: CFArray?
        var status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        // 一次性钥匙串这条路走不通就退回默认行为。
        //
        // 退回去会重新带来「更新之后弹窗」的老毛病，但**有服务总比没服务强**：
        // 硬失败等于这台机器彻底不参与集群，而弹窗至少还能点一下继续。
        // 新路径是优化，不该变成新的单点故障。
        if status != errSecSuccess, opts[kSecImportExportKeychain as String] != nil {
            opts.removeValue(forKey: kSecImportExportKeychain as String)
            releaseScratchKeychain()
            items = nil
            status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        }
        guard status == errSecSuccess else {
            // 这几个码值得单独翻译。裸着一个 -25264 完全看不出发生了什么，
            // 而它和"口令打错了"是两回事 —— 排查方向差得很远。
            let why: String
            switch status {
            case errSecAuthFailed:
                why = "口令不对"
            case errSecPkcs12VerifyFailure:
                why = "完整性校验没过 —— 口令不对，"
                    + "或者这台 macOS 不支持这个 p12 的 MAC 算法"
                    + "（老系统对 SHA-256 的 MAC 就会这样）"
            case errSecDecode:
                why = "这台 macOS 解不了这个 p12 的加密算法（比如 AES）"
            default:
                // 裸数字没有信息量。系统自带的描述总比「错误码 -26276」强 ——
                // 今天在这条链路上被无意义的错误信息坑了不止一次。
                let sys = SecCopyErrorMessageString(status, nil) as String?
                why = "错误码 \(status)" + (sys.map { "（\($0)）" } ?? "")
            }
            throw ClusterCA.err("导入 p12 失败：\(why)")
        }
        guard let arr = items as? [[String: Any]], let first = arr.first,
              let raw = first[kSecImportItemIdentity as String] else {
            throw ClusterCA.err("p12 里没有身份")
        }
        return raw as! SecIdentity
    }

    /// 建（或复用）本进程的一次性钥匙串。
    ///
    /// `promptUser: false` 加一个显式口令 = 全程无交互，这正是重点。
    /// 一次性钥匙串放哪。
    ///
    /// **不能放 ClusterCA.dir。** 那个目录测试会 override 到临时目录、
    /// 用完删掉，而 `scratch` 是进程级静态缓存 —— 于是第二个测试复用的是
    /// 第一个测试那个已经被删掉的钥匙串，导入直接失败。
    /// 表现是「单独跑每个测试都过，整套跑就挂三个」，
    /// 而且只在 macOS 14 发作（新系统走内存导入，压根不建这个东西）。
    static var scratchDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("llmq-scratch", isDirectory: true)
    }

    public static func scratchKeychain() -> SecKeychain? {
        // 缓存的句柄要验一下文件还在不在：文件没了（被清理、被删目录）
        // 句柄就是废的，继续用只会得到一个含糊的导入失败。
        if let kc = scratch {
            if FileManager.default.fileExists(atPath: currentScratchPath) { return kc }
            scratch = nil
            scratchPassword = nil
        }
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        sweepStaleScratchKeychains()
        let path = currentScratchPath
        let pw = randomPassword()
        var kc: SecKeychain?
        let st = pw.withCString { p in
            SecKeychainCreate(path, UInt32(strlen(p)), p, false, nil, &kc)
        }
        guard st == errSecSuccess, let kc else { return nil }
        // **必须显式解锁。**
        //
        // 新建的钥匙串不保证是解锁状态，而往锁着的钥匙串里加东西会走
        // 授权流程 —— 后台进程拿不到授权，直接 -60008
        // （Unable to obtain authorization for this operation）。
        // 这里口令是我们自己生成的，解锁不需要任何交互。
        scratchPassword = pw
        _ = pw.withCString { p in
            SecKeychainUnlock(kc, UInt32(strlen(p)), p, true)
        }
        // **到此为止，别再碰这个钥匙串的任何设置。**
        //
        // 只有 create 和 unlock 是安全的 —— 它们都吃我们自己生成的口令，
        // 不需要向系统要授权。而 `SecKeychainSetSettings`（关自动上锁）
        // 和 `SecKeychainSetSearchList`（加进搜索列表）都要走授权，
        // 后台进程要不到，于是**整个进程卡死在那一行**。
        //
        // 这是实测出来的，不是推测。进程采样的栈长这样：
        //   ClusterNet.loadIdentity
        //     → ClusterNet.scratchKeychain()
        //       → SecKeychainSetSettings          ← 停在这儿
        //         → CSSM_DL_PassThrough
        // 后果是 serve 起不来、被 launchd 拉起、再卡住，重复了 50 次，
        // 而日志里连一行「启动」都没有 —— 因为它卡在打印那行之前。
        //
        // 搜索列表是**唯一的例外**，而且它是必需的：TLS 要用证书去找配对的
        // 私钥，不在搜索列表里就找不到，握手直接 -9858 失败。
        // 实测它不像 SetSettings 那样要授权。
        // **加之前先清掉自己留下的死条目。**
        //
        // 只加不删是个隐蔽的坑：每次进程重启都会新建一个一次性钥匙串并加进
        // 搜索列表，而上一个的文件已经删了。攒到几条之后，搜索列表里指向
        // 不存在文件的条目会把整个钥匙串解析搞坏 —— 表现是 TLS 握手报
        // -9858，而且**时好时坏**：刚配好的时候是干净的，重启几次才发作。
        // 实测在对端攒到 4 条（3 条已失效）时，握手 100% 失败。
        setSearchList(adding: kc)
        scratch = kc
        return kc
    }

    /// 重设搜索列表：只剔掉**已经死掉**的一次性钥匙串，再按需加上一个。
    ///
    /// ## 为什么只能删死的
    ///
    /// 第一版写的是「删掉所有属于本工具的条目」，这在单进程下没问题，
    /// 但这台机器上同时有好几个 llmq：常驻的 `cluster serve`，
    /// 加上 launchd 每 15 分钟跑一次的 `collect`，还有人随手敲的命令。
    /// 每个进程启动都会重写一次搜索列表 —— 于是 collect 一跑，
    /// **正在服务的 serve 的条目就被它顺手踢掉了**，
    /// serve 的私钥再也解析不到，握手开始报 -9858。
    ///
    /// 现象是「serve 好好跑着，过一会儿就不通了」，而且重启 serve 又好 ——
    /// 因为重启时它把自己加回去了。周期恰好和采集间隔一致。
    ///
    /// 判断「死」的依据是文件还在不在：进程正常退出会删掉自己那个文件，
    /// 崩溃留下的文件由 `sweepStaleScratchKeychains` 按 PID 清理。
    /// 两条路都走不到的极端情况下，多留一条死条目也比踢掉活的强。
    private static func setSearchList(adding kc: SecKeychain?) {
        var list: CFArray?
        guard SecKeychainCopySearchList(&list) == errSecSuccess,
              let arr = list as? [SecKeychain] else { return }
        let mine = scratchDir.appendingPathComponent("scratch-").path
        let fm = FileManager.default
        var kept: [SecKeychain] = []
        for k in arr {
            var buf = [CChar](repeating: 0, count: 4096)
            var len = UInt32(buf.count)
            if SecKeychainGetPath(k, &len, &buf) == errSecSuccess {
                let p = String(cString: buf)
                // 本工具的、而且文件已经没了 —— 这条是死的，剔掉。
                // 别的进程还活着的那条**必须留下**。
                if p.hasPrefix(mine) && !fm.fileExists(atPath: p) { continue }
                if let kc, p == currentScratchPath { continue }  // 自己那条稍后重新插到最前
                _ = kc
            }
            kept.append(k)
        }
        if let kc { kept.insert(kc, at: 0) }
        _ = SecKeychainSetSearchList(kept as CFArray)
    }

    /// 本进程那个一次性钥匙串的路径。
    private static var currentScratchPath: String {
        scratchDir.appendingPathComponent("scratch-\(getpid()).keychain").path
    }

    /// 清掉遗留的一次性钥匙串。
    ///
    /// 正常退出会删，崩溃不会。里面的私钥是用一个已经消失的随机口令加密的，
    /// 留着也解不开，但没必要攒。活着的进程那份别动 —— 同一台机器上
    /// 可能有另一个 llmq 正在跑。
    public static func sweepStaleScratchKeychains() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: scratchDir.path) else { return }
        for f in all where f.hasPrefix("scratch-") && f.hasSuffix(".keychain") {
            let pid = Int32(f.dropFirst("scratch-".count).dropLast(".keychain".count)) ?? -1
            if pid > 0 && kill(pid, 0) == 0 { continue }
            try? fm.removeItem(atPath: scratchDir.appendingPathComponent(f).path)
        }
    }

    /// 确保一次性钥匙串是解锁的。**常驻进程必须周期性调它。**
    ///
    /// ## 为什么必须反复解锁
    ///
    /// 钥匙串会自动上锁（睡眠、闲置）。本来该用 `SecKeychainSetSettings`
    /// 关掉自动上锁，但那个调用**要授权**，后台进程拿不到，会把整个进程
    /// 卡死在那一行（实测栈停在 CSSM_DL_PassThrough，serve 因此重启了 50 次）。
    ///
    /// 所以换个方向：不去改设置，而是拿着口令反复解锁。口令是本进程自己
    /// 生成的、只在内存里，解锁全程无交互。
    ///
    /// 不做这件事的表现是：serve 重启后好一阵子，过后握手开始报 -9858，
    /// 而 lsof、防火墙、搜索列表全都正常 —— 因为私钥还在，只是签不了名。
    @discardableResult
    public static func ensureScratchUnlocked() -> Bool {
        guard let kc = scratch, let pw = scratchPassword else { return false }
        var st = SecKeychainStatus(0)
        guard SecKeychainGetStatus(kc, &st) == errSecSuccess else { return false }
        if st & SecKeychainStatus(kSecUnlockStateStatus) != 0 { return true }
        let r = pw.withCString { p in
            SecKeychainUnlock(kc, UInt32(strlen(p)), p, true)
        }
        return r == errSecSuccess
    }

    /// 删掉本进程那份，并把它从搜索列表里摘掉。
    ///
    /// 摘搜索列表这一步不能省：钥匙串文件删了但条目还在，
    /// 下一个进程就会读到一个指向不存在文件的条目。
    public static func releaseScratchKeychain() {
        guard let kc = scratch else { return }
        // 顺序要紧：**先删文件再重算列表**。
        // 反过来的话，重算时自己那个文件还在、会被当成「活的」留下，
        // 于是留下一条指向马上就要消失的文件的死条目。
        _ = SecKeychainDelete(kc)
        scratch = nil
        scratchPassword = nil
        setSearchList(adding: nil)
    }

    /// 口令存钥匙串，不存磁盘。
    ///
    /// 把口令跟它保护的文件放在同一个目录，等于没加密。放钥匙串的实际收益是：
    /// 一份不含钥匙串的 Application Support 备份泄露了，也用不出来。
    public enum Passphrase {
        static let service = "com.llmquotabar.cluster"

        /// 存口令。
        ///
        /// ## 为什么要把访问控制放宽到「本机所有程序」
        ///
        /// 钥匙串条目默认的 ACL 绑在**创建它的那个可执行文件**上。
        /// `llmq update` 换掉二进制之后签名对不上，系统就要弹窗让人确认 ——
        /// 而 `cluster serve` 是 launchd 下的后台进程，**没有界面可以弹**，
        /// 于是直接失败退出，被拉起、再失败，如此循环。
        ///
        /// 实际后果：每更新一次，跨机服务就静默死一次，而且外部表现是
        /// 「端口不通」，看起来完全像网络问题。查这个花了大半天，
        /// 而真正的线索一直躺在那个**因为块缓冲而始终是 0 字节**的日志里。
        ///
        /// 放宽之后的安全边界是「登录用户」：任何以你身份运行的程序都能读到它。
        /// 这比原来弱不了多少 —— 那些程序本来就能直接调用 llmq 本身，
        /// 拿这个口令能干的事它们本来也干得到。
        public static func save(_ password: String, node: String) throws {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: node,
            ]
            SecItemDelete(q as CFDictionary)
            var add = q
            add[kSecValueData as String] = Data(password.utf8)
            // **只在老系统上放宽 ACL。**
            //
            // 放宽解决的是 macOS 14 的问题：那里私钥要进登录钥匙串，
            // llmq update 换了二进制之后签名对不上、每次都要弹窗确认。
            //
            // 但它自己有代价：带自定义 SecAccess 的条目，读取会走一条明显更慢的
            // 路径 —— 实测 `llmq cluster ping` 从毫秒级变成 4 分 37 秒，
            // 进程采样停在 SecItemCopyMatching → SecKeychainItemCopyContent。
            // 而外面看到的是「跨机连接挂住」，服务端日志显示连接进来又被
            // 客户端关掉，所有线索都指向网络，真相却在钥匙串。
            //
            // macOS 15+ 走内存导入，压根不碰登录钥匙串里的私钥，
            // 那个弹窗问题不存在 —— 于是只剩代价。所以按系统版本分。
            if #unavailable(macOS 15.0) {
                if let access = anyAppAccess() {
                    add[kSecAttrAccess as String] = access
                }
            }
            let s = SecItemAdd(add as CFDictionary, nil)
            if s == errSecSuccess {
                try? FileManager.default.removeItem(at: fallbackFile(node: node))
                return
            }
            // **写不进钥匙串就落盘，但要大声说出来。**
            //
            // 这不是洁癖问题，是可用性问题：SSH 会话里登录钥匙串是锁着的
            // （实测 -25308），而解锁要人输密码。也就是说远程修不了 ——
            // 一台机器的跨机身份坏掉之后，只能有人**坐到那台机器前面**才能救。
            // 对一个设计成无人值守的系统，这是个比「口令落盘」严重得多的问题。
            //
            // 落盘弱在哪要说清楚：钥匙串挡的是「Application Support 被整个
            // 备份走」这一种情况。落盘之后，拿到那份备份的人就拿到了这个节点的
            // 可用身份 —— 能连进集群派任务。所以不能静默降级，
            // `llmq doctor` 会把它列出来。
            //
            // 顺带一提，主机上这层保护本来就不存在：ca.key 明文躺在同一个
            // 目录里（0600），而它比任何一张 p12 都强 —— 能给任意节点签证书。
            let f = fallbackFile(node: node)
            do {
                try Data(password.utf8).write(to: f, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: f.path)
                FileHandle.standardError.write(Data(
                    ("钥匙串写不进去（OSStatus \(s)），口令已改存 \(f.path)（0600）。"
                     + "安全性弱于钥匙串，llmq doctor 会一直提示。\n").utf8))
            } catch {
                throw ClusterCA.err("存钥匙串失败（\(s)），落盘也失败：\(error.localizedDescription)")
            }
        }

        /// 钥匙串用不了时的退路。放在 CA 目录里，跟着它的 0700 走。
        static func fallbackFile(node: String) -> URL {
            ClusterCA.dir.appendingPathComponent("\(node).pass")
        }

        /// 有哪些节点的口令在磁盘上 —— 给 `llmq doctor` 报出来用。
        public static func nodesWithPassphraseOnDisk() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: ClusterCA.dir.path)) ?? [])
                .filter { $0.hasSuffix(".pass") }
                .map { String($0.dropLast(5)) }
                .sorted()
        }

        /// 构造一个「不限程序」的 SecAccess。
        ///
        /// 注意这里有两个 nil，意思正好相反：`SecAccessCreate` 的
        /// trustedlist 传 nil 表示**只信任调用方**（正是要避开的行为），
        /// 而 `SecACLSetContents` 的应用列表传 nil 才表示**不限程序**。
        private static func anyAppAccess() -> SecAccess? {
            var access: SecAccess?
            guard SecAccessCreate("llmq 集群口令" as CFString, nil, &access) == errSecSuccess,
                  let access else { return nil }
            var list: CFArray?
            guard SecAccessCopyACLList(access, &list) == errSecSuccess,
                  let acls = list as? [SecACL] else { return access }
            for acl in acls {
                var apps: CFArray?
                var desc: CFString?
                var prompt = SecKeychainPromptSelector()
                guard SecACLCopyContents(acl, &apps, &desc, &prompt) == errSecSuccess
                else { continue }
                _ = SecACLSetContents(acl, nil, desc ?? "" as CFString, prompt)
            }
            return access
        }

        public static func load(node: String) throws -> String {
            // **必须禁止交互。**
            //
            // 不禁的话，一旦这个条目的 ACL 需要系统确认，SecItemCopyMatching
            // 会**一直等**那个确认 —— 而这个进程可能没有界面（launchd、SSH），
            // 或者弹窗根本没显示出来。表现是命令永远不返回，
            // 连它自己那个 30 秒的网络超时都走不到，因为压根没到网络那一步。
            //
            // 实测过：进程采样的栈停在
            //   Passphrase.load → SecItemCopyMatching → SecKeychainItemCopyContent
            // 而外面看到的是「llmq cluster ping 挂住十分钟」，
            // 服务端日志显示连接进来又被客户端关掉 —— 全都指向网络，
            // 而真相在钥匙串。
            //
            // 禁掉之后拿不到就立刻返回 errSecInteractionNotAllowed，
            // 下面那段会把它翻译成一句能照着做的话。
            //
            // ## 光有 kSecUseAuthenticationUI 不够
            //
            // 那个键**只在数据保护钥匙串那条路上被认**。而通用密码落在老式的
            // 文件钥匙串里，走的是 `SecItemCopyMatching_osx` →
            // `SecKeychainItemCopyContent`，它完全不看这个键 —— 于是照样挂死。
            //
            // 这个坑第二次踩：上面那段注释信誓旦旦说「禁掉之后立刻返回」，
            // 而实际采样到的栈还是停在 SecKeychainItemCopyContent，一挂五分钟。
            // 老式路径要用 `SecKeychainSetUserInteractionAllowed(false)`
            // 才关得掉，它是**进程级**开关，所以放在读之前。
            //
            // 验证过：加上之后 0.017 秒返回 errSecAuthFailed，不再挂。
            SecKeychainSetUserInteractionAllowed(false)
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: node,
                kSecReturnData as String: true,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            var out: CFTypeRef?
            let s = SecItemCopyMatching(q as CFDictionary, &out)
            if s == errSecSuccess, let d = out as? Data {
                return String(decoding: d, as: UTF8.self)
            }
            // **区分「没有」和「不让读」。**
            //
            // 原来这里把所有 OSStatus 都写成「钥匙串里没有口令」。
            // 而 launchd 下的后台进程拿到的其实是 errSecInteractionNotAllowed
            // （-25308：要弹窗，但没界面可弹）—— 条目明明就在。
            // 那条错误信息把排查引向「是不是没导入」，而真相是「没权限」。
            // 一条把 A 说成 B 的错误信息，比没有错误信息更耽误事。
            switch s {
            case errSecItemNotFound:
                throw ClusterCA.err("钥匙串里没有 \(node) 的口令，先跑 llmq cluster import")
            case errSecInteractionNotAllowed, errSecAuthFailed:
                // 顺序有讲究：先看落盘的那份，再考虑重签。
                // 重签会换掉 p12，对端不受影响（同一个 CA），
                // 但没必要为了一个还能读到的口令折腾一遍。
                if let pw = diskFallback(node: node) { return pw }
                // 换了二进制就读不到了。**这台机器要是握着 CA，就别求人。**
                if let pw = try? reissueSelf(node: node) { return pw }
                throw ClusterCA.err(
                    "钥匙串不让这个二进制读 \(node) 的口令（OSStatus \(s)）—— "
                    + "llmq 更新过，条目还绑在旧二进制上，而这台机器没有 CA 私钥、"
                    + "没法自己重签。在另一台机器上跑 llmq cluster enroll \(node)，"
                    + "把 p12 和口令分开传过来，再 llmq cluster import")
            default:
                throw ClusterCA.err("读钥匙串失败（OSStatus \(s)），节点 \(node)")
            }
        }

        /// 只读，不自愈。给「换二进制之前先把口令捞出来」用。
        ///
        /// `load` 会在读不到时重签身份，那在更新流程里正好是反效果：
        /// 我们要的是把**现有**口令原样搬过去。
        public static func rawLoad(node: String) -> String? {
            SecKeychainSetUserInteractionAllowed(false)
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: node,
                kSecReturnData as String: true,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let d = out as? Data {
                return String(decoding: d, as: UTF8.self)
            }
            return diskFallback(node: node)
        }

        /// 读落盘的那份。空文件当没有 —— 空口令解不开任何 p12，
        /// 让它一路走到「口令不对」比在这里返回 "" 更难查。
        static func diskFallback(node: String) -> String? {
            guard let d = try? Data(contentsOf: fallbackFile(node: node)),
                  !d.isEmpty else { return nil }
            return String(decoding: d, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// 拿盘上的 CA 给自己重签一张身份，配一个新口令存回钥匙串。
        ///
        /// ## 为什么要有这条路
        ///
        /// 钥匙串条目的 ACL 绑在**创建它的那个二进制**上，而这个项目是
        /// 自动更新的 —— 每发一版就换一次二进制，于是每发一版就读不到一次。
        /// 实测在 macOS 26 上无解：放宽 ACL（`SecACLSetContents` 传 nil 应用
        /// 列表）换二进制后照样 errSecAuthFailed；数据保护钥匙串写入直接
        /// -34018 缺 entitlement，未签名的 CLI 用不了。
        ///
        /// 但**口令本来就是我们自己生成的**，而 CA 私钥就在旁边的
        /// `ca.key`（0600）。读不到就重发一张，比让人去点弹窗干净得多。
        ///
        /// 顺带说明一件事：既然 `ca.key` 明文躺在 p12 旁边，
        /// 「口令进钥匙串防的是 Application Support 备份泄露」这个说法
        /// 其实已经被它自己抵消了 —— 拿到 CA 私钥的人能给任何节点签证书，
        /// 比拿到一张 p12 强得多。见 SECURITY.md。
        static func reissueSelf(node: String) throws -> String {
            guard ClusterCA.hasPrivateCA else {
                throw ClusterCA.err("没有 CA 私钥，重签不了")
            }
            let pw = ClusterNet.randomPassword()
            _ = try ClusterCA.issue(node: node, password: pw)
            try? delete(node: node)
            try save(pw, node: node)
            FileHandle.standardError.write(Data(
                "钥匙串条目绑在旧二进制上，已用本机 CA 自动重签 \(node) 的身份\n".utf8))
            return pw
        }

        /// 删掉一条。测试用来清理一次性条目。
        public static func delete(node: String) throws {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: node,
            ]
            let s = SecItemDelete(q as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else {
                throw ClusterCA.err("删钥匙串条目失败：\(s)")
            }
        }

        /// 把已有的口令按放宽后的 ACL 重存一遍。
        ///
        /// 必须在**终端里交互运行**：读那一步可能弹一次窗，点「允许」即可。
        /// 之后 launchd 下的 serve 就能直接读，以后再更新也不会断。
        public static func relax(node: String) throws {
            let pw = try load(node: node)   // 可能弹一次窗，仅此一次
            try save(pw, node: node)
        }
    }

    // MARK: - TLS 参数

    /// - Parameter allowed: 允许的对端节点名。
    ///   服务端传授权名单；客户端**只传它想连的那一个** ——
    ///   否则任何一个合法节点都能冒充另一个节点接管这条连接。
    /// - Parameter log: 握手过程的旁路日志。
    ///
    ///   排查跨机连不通时最缺的就是它：握手失败时两端都只能看到一个
    ///   「连接被对方关了」，谁都不说是为什么。而**验证回调有没有被调用**
    ///   这一个事实就能把范围劈成两半 —— 没被调用说明是 Network.framework
    ///   在更底层拒的，被调用了说明是我们自己的信任判定拒的。
    static func parameters(
        identity: SecIdentity, ca: SecCertificate, allowed: Set<String>,
        requirePeerCert: Bool, onVerified: ((String) -> Void)? = nil,
        log: ((String) -> Void)? = nil
    ) throws -> NWParameters {
        guard let secID = sec_identity_create(identity) else {
            throw ClusterCA.err("无法构造 TLS 身份")
        }
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, secID)

        // 两端都是我们自己的代码，没有兼容老客户端的包袱。
        // 直接钉死 1.3，把降级协商这一整类问题从桌面上拿掉。
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)

        // 服务端必须要求客户端出证书。默认是 false ——
        // 漏了这一行，服务端照常握手、照常收请求，只是谁都能连。
        if requirePeerCert {
            sec_protocol_options_set_peer_authentication_required(sec, true)
        }

        let queue = DispatchQueue(label: "llmq.cluster.verify")
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
                log?("验证回调：拿不到证书链，拒绝")
                complete(false); return
            }
            let verdict = TrustEvaluator.evaluate(
                peerCertificates: chain, caCertificate: ca, allowedNodes: allowed)
            switch verdict {
            case .trusted(let node):
                log?("验证回调：放行 \(node)（链 \(chain.count) 张）")
                onVerified?(node)
            case .rejected(let why):
                log?("验证回调：拒绝 —— \(why)（链 \(chain.count) 张，"
                    + "允许名单 \(allowed.sorted().joined(separator: "、"))）")
            }
            // 唯一决定放行与否的地方。这里如果写成无条件 complete(true)，
            // 上面所有东西都白搭，而且不会有任何报错。
            complete(verdict.isTrusted)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    // MARK: - 服务端

    public final class Server {
        let config: ClusterConfig
        let params: NWParameters
        let log: (String) -> Void
        var listener: NWListener?
        /// **只给监听器用。** 不能用 .main —— 调用方经常也在主线程上
        /// 阻塞等待（CLI 的 dispatchMain、测试里的同步 send），
        /// 共用主队列会直接死锁：连接建好了但没人处理。
        ///
        /// 更要紧的是：连接**不能**跟着用这条队列。它是串行的，
        /// 一个慢的处理函数会把监听器一起堵死，于是内核 accept 队列填满、
        /// 之后的 SYN 被**静默丢弃**（不回 RST）。从外面看就是
        /// 「端口明明开着，连过去却超时」，而本机 lsof 一切正常 ——
        /// 这个组合排查起来极其费劲，实际上花了大半天。
        ///
        /// 触发它的是 `.status`：它要读 iCloud 上的快照，
        /// 而读一个还没落地的占位文件会阻塞到下载完成。
        let queue = DispatchQueue(label: "llmq.cluster.server")

        /// `.waiting` 容忍多久。开机时网卡还没就绪、上一个进程还没放开端口，
        /// 都会短暂进 waiting，立刻退出会变成重启风暴。
        static let waitingGrace: TimeInterval = 30
        private var waitingTimerArmed = false

        /// 请求处理函数。做成可注入的，好写「慢处理不堵别人」的回归测试 ——
        /// 不然这个 bug 只能靠人肉复现。
        public var handler: (ClusterRequest, String) -> ClusterResponse = ClusterService.handle

        public init(config: ClusterConfig, password: String,
                    log: @escaping (String) -> Void = { print($0) }) throws {
            guard let ca = ClusterCA.loadCACertificate() else {
                throw ClusterCA.err("读不到 CA 证书，先跑 llmq cluster init")
            }
            guard !config.allowedNodes.isEmpty else {
                // 空名单意味着"谁都不许进"。与其起一个永远拒绝的服务，
                // 不如直接拦住 —— 空名单几乎总是配置忘了填，而不是本意。
                throw ClusterCA.err("允许名单是空的，先跑 llmq cluster trust <节点名>")
            }
            let id = try ClusterNet.loadIdentity(node: config.nodeName, password: password)
            self.config = config
            self.log = log
            self.params = try ClusterNet.parameters(
                identity: id, ca: ca, allowed: config.allowedSet, requirePeerCert: true,
                log: log)
        }

        /// - Parameter bindHost: 只有测试会传（127.0.0.1）。
        ///   产品里一律走下面的内网地址探测。
        public func start(bindHost: String? = nil) throws {
            // 绑到内网地址而不是 0.0.0.0。没有公网 IP 的情况下两者实际暴露面
            // 一样，但显式绑定意味着**多插一张网卡、开一次热点**都不会
            // 意外把它带到别的网段上去。
            guard let ip = bindHost ?? config.bindAddress ?? ClusterNet.lanAddress() else {
                throw ClusterCA.err("找不到局域网地址，没连 Wi-Fi 或网线？")
            }
            // 绑全部地址时**不能**设 requiredLocalEndpoint —— 那个字段要的是
            // 一个具体端点，塞 0.0.0.0 进去语义不对。不设它，NWListener
            // 本来就是所有接口都听。
            if ip != "0.0.0.0" && ip != "*" {
                params.requiredLocalEndpoint = .hostPort(
                    host: .init(ip), port: .init(rawValue: config.port)!)
            } else {
                params.requiredLocalEndpoint = nil
            }
            params.allowLocalEndpointReuse = true

            let l = (ip == "0.0.0.0" || ip == "*")
                ? try NWListener(using: params, on: .init(rawValue: config.port)!)
                : try NWListener(using: params)
            listener = l
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.waitingTimerArmed = false
                    self.log("在 \(ip):\(self.config.port) 上等活 " + "（只认 CA 签发的客户端证书）")
                    self.log("允许的节点：" + self.config.allowedNodes.joined(separator: "、"))
                case .waiting(let e):
                    // **NWListener 绑不上时进的是 .waiting，不是 .failed。**
                    // 端口被占、要求的本地地址还没就绪，都走这条路。
                    //
                    // 这里原来是 default: break，后果是进程活着、
                    // 永远不监听，而且外面完全看不出来 —— ps 里有它、
                    // launchd 觉得一切正常、lsof 却是空的。对端连过来
                    // 只有 RST，于是被当成网络问题查了大半天。
                    //
                    // 同一个坑在客户端侧已经踩过一次（握手被拒也是走 .waiting
                    // 而不是 .failed），当时只修了客户端，没推到这边。
                    self.log("暂时起不来：\(e)")
                    guard !self.waitingTimerArmed else { break }
                    self.waitingTimerArmed = true
                    self.queue.asyncAfter(deadline: .now() + Self.waitingGrace) { [weak self] in
                        guard let self, let l = self.listener else { return }
                        if case .ready = l.state { self.waitingTimerArmed = false; return }
                        self.log("等了 \(Int(Self.waitingGrace)) 秒还没起来，退出让 launchd 重来")
                        exit(1)
                    }
                case .failed(let e):
                    // 端口被占是最常见的一种，而且十有八九是自己已经起过一个 ——
                    // 裸报 POSIXErrorCode(48) 完全看不出该怎么办。
                    if case .posix(let code) = e, code == .EADDRINUSE {
                        self.log("端口 \(self.config.port) 已经被占了 —— "
                                 + "是不是已经有一个 llmq cluster serve 在跑？"
                                 + "查一下：lsof -nP -iTCP:\(self.config.port) -sTCP:LISTEN")
                    } else {
                        self.log("监听失败：\(e)")
                    }
                    exit(1)
                default: break
                }
            }
            l.start(queue: queue)
        }

        public func stop() {
            listener?.cancel()
            listener = nil
        }

        func accept(_ conn: NWConnection) {
            // 一进来就记一笔。
            //
            // 原来只在 .ready 和 .failed 记日志，于是卡在 .preparing
            // （TLS 握手没走完）的连接**什么都不留**，服务端日志一片空白 ——
            // 而这正是最需要日志的那种故障。
            self.log("← 有连接进来（还没握手）")
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let node = ClusterNet.peerNode(of: conn) ?? "?"
                    self.log("← \(node) 连上了")
                    self.readRequest(conn, from: node)
                case .failed(let e):
                    // 握手被拒也走这里。这是**正常**的拒绝路径，不是故障。
                    self.log("连接结束：\(e.debugDescription.prefix(80))")
                    conn.cancel()
                case .cancelled:
                    break
                default: break
                }
            }
            // 每个连接一条自己的队列，彼此隔离，也和监听器隔离。
            conn.start(queue: DispatchQueue(label: "llmq.cluster.conn"))
        }

        func readRequest(_ conn: NWConnection, from node: String) {
            ClusterNet.readFrame(conn) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let e):
                    self.log("读取失败：\(e.localizedDescription)")
                    conn.cancel()
                case .success(let body):
                    let req: ClusterRequest
                    do {
                        req = try Frame.decode(ClusterRequest.self, from: body)
                    } catch {
                        let r = ClusterResponse.failed(
                            reason: "请求解析失败：\(error.localizedDescription)")
                        if let out = try? Frame.encode(r) {
                            conn.send(content: out, completion: .contentProcessed { _ in
                                conn.cancel()
                            })
                        } else { conn.cancel() }
                        return
                    }
                    self.log("  \(node) → \(ClusterNet.describe(req))")
                    // 处理函数挪到全局队列：它可能很慢（.status 要读 iCloud），
                    // 而这条连接自己的队列还得负责后续的 send 回调。
                    let h = self.handler
                    DispatchQueue.global().async {
                        let resp = h(req, node)
                        guard let out = try? Frame.encode(resp) else { conn.cancel(); return }
                        conn.send(content: out, completion: .contentProcessed { _ in
                            conn.cancel()
                        })
                    }
                }
            }
        }
    }

    // MARK: - 客户端

    /// 同步发一个请求并等回应。CLI 是同步的，这里用信号量把异步 API 摊平。
    public static func send(
        _ req: ClusterRequest, to peer: String, config: ClusterConfig,
        password: String, timeout: TimeInterval = 30
    ) throws -> ClusterResponse {
        // 优先用对方**自报**的地址，手填的只当兜底。
        //
        // 手填的地址会因为 DHCP 换 IP 而失效，而失效的表现是 connect 超时 ——
        // 和「对方没起服务」长得一模一样，从这一头根本分不出来。
        // 自报地址每 5 分钟跟着采集刷新一次。
        let announced = ClusterPresenceStore.address(forNode: peer)
        guard let addr = announced ?? config.peers[peer] else {
            throw ClusterCA.err("不认识节点 \(peer)，先跑 llmq cluster peer \(peer) <host:port>")
        }
        if let announced, announced != config.peers[peer] {
            FileHandle.standardError.write(Data(
                "（用它自报的地址 \(announced)，配置里记的是 \(config.peers[peer] ?? "无")）\n".utf8))
        }
        let parts = addr.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw ClusterCA.err("对端地址要写成 host:port，现在是 \(addr)")
        }
        guard let ca = ClusterCA.loadCACertificate() else {
            throw ClusterCA.err("读不到 CA 证书")
        }
        let id = try loadIdentity(node: config.nodeName, password: password)

        // 只允许对端是我们要连的那一个节点。
        // 传整个名单的话，任何一台合法机器都能在中间冒充另一台。
        let params = try parameters(
            identity: id, ca: ca, allowed: [peer], requirePeerCert: false,
            // 客户端把握手细节打到 stderr：正常输出不受影响，
            // 而握手一旦失败，人第一眼就能看到是哪一层拒的。
            log: { FileHandle.standardError.write(Data(("  " + $0 + "\n").utf8)) })

        let conn = NWConnection(
            host: .init(String(parts[0])), port: .init(rawValue: port)!, using: params)

        var outcome: Result<ClusterResponse, Error>?
        let done = DispatchSemaphore(value: 0)
        var finished = false
        let lock = NSLock()
        func finish(_ r: Result<ClusterResponse, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            outcome = r
            done.signal()
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let payload = try? Frame.encode(req) else {
                    finish(.failure(ClusterCA.err("请求编码失败"))); return
                }
                conn.send(content: payload, completion: .contentProcessed { err in
                    if let err { finish(.failure(err)); return }
                    readFrame(conn) { r in
                        switch r {
                        case .failure(let e): finish(.failure(e))
                        case .success(let body):
                            finish(Result { try Frame.decode(ClusterResponse.self, from: body) })
                        }
                    }
                })
            case .failed(let e):
                finish(.failure(ClusterCA.err(explain(e, peer: peer))))
            case .waiting(let e):
                // 握手被拒**大多走这条路**而不是 .failed —— Network.framework
                // 把它当成"暂时连不上，等会儿重试"。对一次性的 RPC 来说
                // 没有"等会儿"：不在这里收口，调用方就会白等满整个超时，
                // 还看不到真正的原因。
                finish(.failure(ClusterCA.err(explain(e, peer: peer))))
            case .cancelled:
                finish(.failure(ClusterCA.err("连接被取消")))
            default: break
            }
        }
        conn.start(queue: .global())

        if done.wait(timeout: .now() + timeout) == .timedOut {
            conn.cancel()
            throw ClusterCA.err("\(Int(timeout)) 秒没等到 \(peer) 的回应")
        }
        conn.cancel()
        return try outcome!.get()
    }

    /// 把 Network.framework 那些没法看的错误翻成人话。
    /// 握手失败最常见的两个原因是证书不对和不在名单里，都值得直说。
    static func explain(_ e: NWError, peer: String) -> String {
        let raw = e.debugDescription
        if raw.contains("-9807") || raw.contains("badCert") || raw.contains("-9808") {
            return "\(peer) 的证书不被信任 —— 两台机器用的是同一个 CA 吗？"
        }
        if raw.contains("-9824") || raw.contains("peerCertUnknown") || raw.contains("-9825") {
            return "被 \(peer) 拒了 —— 本机可能不在它的允许名单里，"
                 + "让它跑 llmq cluster trust \(ClusterConfigStore.load()?.nodeName ?? "<本机名>")"
        }
        if raw.contains("Connection refused") || raw.contains("61") {
            return "\(peer) 没在听 —— 那台机器上跑起 llmq cluster serve 了吗？"
        }
        return "连不上 \(peer)：\(raw.prefix(120))"
    }

    // MARK: - 读一帧

    static func readFrame(_ conn: NWConnection,
                          then: @escaping (Result<Data, Error>) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, err in
            if let err { then(.failure(err)); return }
            guard let data, let n = Frame.length(of: data) else {
                then(.failure(ClusterCA.err("对端提前断开"))); return
            }
            guard n > 0, n <= Frame.maxSize else {
                // 握手过了不代表可以无条件相信对端说的长度。
                then(.failure(ClusterCA.err("消息长度不合法：\(n)"))); return
            }
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, e2 in
                if let e2 { then(.failure(e2)); return }
                guard let body, body.count == n else {
                    then(.failure(ClusterCA.err("消息不完整"))); return
                }
                then(.success(body))
            }
        }
    }

    // MARK: - 杂项

    /// 握手完成后从 TLS 元数据里读对端节点名，用来记日志。
    /// 放行与否已经在 verify block 里定了，这里只是贴个标签。
    static func peerNode(of conn: NWConnection) -> String? {
        guard let md = conn.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        var name: String?
        _ = sec_protocol_metadata_access_peer_certificate_chain(
            md.securityProtocolMetadata
        ) { cert in
            guard name == nil else { return }
            let ref = sec_certificate_copy_ref(cert).takeRetainedValue()
            name = TrustEvaluator.commonName(of: ref as! SecCertificate)
        }
        return name
    }

    /// 本机的局域网 IPv4 地址。
    public static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, ip: String)] = []
        for p in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let f = p.pointee
            guard f.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(f.ifa_flags) & IFF_LOOPBACK) == 0,
                  (Int32(f.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            candidates.append((String(cString: f.ifa_name), String(cString: host)))
        }
        // en0 优先：Mac 上那是内建网卡，比一堆虚拟接口（utun、bridge）靠谱。
        return candidates.first(where: { $0.name == "en0" })?.ip
            ?? candidates.first(where: { $0.name.hasPrefix("en") })?.ip
            ?? candidates.first?.ip
    }

    static func describe(_ r: ClusterRequest) -> String {
        switch r {
        case .ping: return "探活"
        case .status: return "拉看板"
        case .task(let id): return "查任务 \(id)"
        case .submit(let p, let repo, _):
            return "投任务（\(repo ?? "默认仓库")）：\(p.prefix(40))"
        }
    }

    /// 生成 p12 口令。
    public static func randomPassword(bytes: Int = 24) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        // 忽略返回值等于「随机数拿没拿到都当拿到了」。失败时那个数组还是全零，
        // 而全零口令不会有任何报错，只会安静地把强度归零。
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &b) != errSecSuccess {
            b = (0..<bytes).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
