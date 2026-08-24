import Foundation
import CryptoKit

/// 推送：这台 Mac 自己当服务端，直接把通知发到手机。
///
/// ## 为什么不需要服务器
///
/// APNs 收的是一个用 ES256 签名的 JWT，签名密钥是 Apple 后台下载的 `.p8`。
/// 这个签名过程可以在任何地方做 —— 包括这台 Mac 上。手机的 device token
/// 走已有的 iCloud 共享目录传过来（App 端写 `push-tokens/*.json`）。
/// 全程零服务器、零第三方、零转发，也就没有把任务内容交给别人的问题。
///
/// ## 配置放哪
///
/// `~/.llmq/apns.json`：
///
///     { "keyID": "ABCD1234EF", "teamID": "YOURTEAMID",
///       "bundleID": "com.example.yourapp", "keyFile": "~/.llmq/AuthKey_XXX.p8" }
///
/// **`.p8` 不进仓库，配置也不进仓库** —— 这个项目要开源，任何密钥都不能打包。
/// 缺配置时推送整体静默跳过，不影响别的功能。
public enum Push {

    public struct Config: Codable, Sendable {
        public var keyID: String
        public var teamID: String
        public var bundleID: String
        public var keyFile: String

        public static func load() -> Config? {
            let p = NSString(string: "~/.llmq/apns.json").expandingTildeInPath
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
            return try? JSONDecoder().decode(Config.self, from: d)
        }
    }

    /// 手机端登记的一台设备。
    public struct Device: Codable, Sendable {
        public var token: String
        public var device: String
        public var environment: String
        public var updatedAt: String?
    }

    /// 通知的分类。**决定要不要打扰人**，所以是个显式的类型而不是随手传字符串。
    public enum Kind: String, Sendable {
        /// 有事等你拍板（方案、发布、验收）。
        case needsYou
        /// 额度快过期了还空着。
        case wasting
        /// 出事了（任务连续失败、平台被冻）。
        case trouble

        var title: String {
            switch self {
            case .needsYou: return "等你拍板"
            case .wasting: return "额度要浪费了"
            case .trouble: return "出问题了"
            }
        }
    }

    // MARK: - 设备清单

    /// iCloud 那份（手机直接写在这里）。
    public static var mirrorDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/LLMQuotaBar",
                isDirectory: true)
    }

    /// 手机登记的设备。
    ///
    /// **两个地方都读**：镜像同步下来的本地副本（`sharedRoot/push-tokens`）
    /// 和 iCloud 原件。只读一个都会漏 —— 镜像还没跑到时只有 iCloud 有，
    /// 而 iCloud 文件可能是没下载的占位符、本地副本反而是全的。
    /// 同一台设备两边都有时按 token 去重。
    public static func devices(sharedRoot: URL? = nil) -> [Device] {
        var seen = Set<String>()
        var out: [Device] = []
        for root in [sharedRoot ?? Paths.sharedRoot, mirrorDir] {
            let dir = root.appendingPathComponent("push-tokens")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            for n in names where n.hasSuffix(".json") {
                guard let dev = SafeDecode.json(
                        at: dir.appendingPathComponent(n), as: Device.self,
                        decoder: JSONDecoder()),
                      !seen.contains(dev.token) else { continue }
                seen.insert(dev.token)
                out.append(dev)
            }
        }
        return out
    }

    // MARK: - 发送

    /// 推一条通知给所有登记过的设备。
    ///
    /// - Returns: 成功推送的设备数。0 表示没配置、没设备，或者全失败 ——
    ///   调用方**不要**因此中断自己的流程，推送是锦上添花不是前置条件。
    @discardableResult
    public static func send(_ kind: Kind, body: String,
                            subtitle: String? = nil,
                            badge: Int? = nil) -> Int {
        guard let cfg = Config.load() else { return 0 }
        let list = devices()
        guard !list.isEmpty else { return 0 }
        guard let jwt = signedJWT(cfg: cfg) else { return 0 }

        var ok = 0
        for d in list {
            var aps: [String: Any] = [
                "alert": [
                    "title": kind.title,
                    "subtitle": subtitle as Any,
                    "body": body,
                ].compactMapValues { $0 is NSNull ? nil : $0 },
                "sound": "default",
            ]
            if let badge { aps["badge"] = badge }
            let payload: [String: Any] = ["aps": aps, "kind": kind.rawValue]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            if post(token: d.token, environment: d.environment,
                    payload: data, jwt: jwt, cfg: cfg) { ok += 1 }
        }
        return ok
    }

    /// 只改角标，不弹横幅。
    ///
    /// **角标是持久的。** 推送把它设成 94 之后，它就一直挂在图标上 ——
    /// 除非 App 主动清除，或者被新推送覆盖。而新推送又被两小时限流挡着，
    /// 于是人盯着一个 94 找不到对应的东西（实测就是这样：判据修好之后
    /// 真实数是 10，图标上还是 94）。
    ///
    /// 所以角标要能**单独同步**，而且这个动作不该打扰人 ——
    /// 没有 alert 就不会响、不会弹。
    @discardableResult
    public static func syncBadge(_ n: Int) -> Int {
        guard let cfg = Config.load() else { return 0 }
        let list = devices()
        guard !list.isEmpty, let jwt = signedJWT(cfg: cfg) else { return 0 }
        // badge 本身就是用户可见交互，APNs 要求它走 alert 类型。
        // 以前把它伪装成 background；Apple 明确说 background 不会改角标，
        // 而且这类低优先级通知允许被延迟/丢弃，于是清零最容易永远不到。
        let payload: [String: Any] = ["aps": ["badge": n]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return 0 }
        var ok = 0
        for d in list {
            if post(token: d.token, environment: d.environment,
                    payload: data, jwt: jwt, cfg: cfg, pushType: "alert") { ok += 1 }
        }
        return ok
    }

    /// 一次 APNs 投递。用 curl 而不是 URLSession ——
    /// APNs 要求 HTTP/2，而 URLSession 在命令行工具里对 HTTP/2 的支持
    /// 取决于系统版本，curl 是确定的。
    static func post(token: String, environment: String,
                     payload: Data, jwt: String, cfg: Config,
                     pushType: String = "alert") -> Bool {
        let host = environment == "sandbox"
            ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("apns-\(UUID().uuidString).json")
        try? payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = Proc.run("/usr/bin/curl", [
            "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--http2", "-X", "POST",
            "-H", "authorization: bearer " + jwt,
            "-H", "apns-topic: " + cfg.bundleID,
            "-H", "apns-push-type: " + pushType,
            // 静默推送必须用低优先级，用 10 会被 APNs 直接拒（BadPriority）。
            "-H", "apns-priority: " + (pushType == "background" ? "5" : "10"),
            "--data-binary", "@" + tmp.path,
            "https://\(host)/3/device/\(token)",
        ], cwd: nil, env: [:], timeout: 20)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "200"
    }

    // MARK: - JWT

    /// APNs 的 provider token：ES256 签名的 JWT，有效期最长 1 小时。
    ///
    /// 缓存到 `~/.llmq/apns-token.cache` 并且**每 40 分钟才重签一次** ——
    /// Apple 对同一个 key 的签发频率有限制（每 20 分钟一次以上会被拒），
    /// 每条通知都重签会把整个推送通道弄挂。
    static func signedJWT(cfg: Config, now: Date = Date()) -> String? {
        let cache = URL(fileURLWithPath:
            NSString(string: "~/.llmq/apns-token.cache").expandingTildeInPath)
        if let d = try? Data(contentsOf: cache),
           let s = String(data: d, encoding: .utf8),
           let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?
               .contentModificationDate,
           now.timeIntervalSince(age) < 40 * 60 {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let key = loadPrivateKey(cfg.keyFile) else { return nil }
        let header = ["alg": "ES256", "kid": cfg.keyID]
        let claims: [String: Any] = ["iss": cfg.teamID, "iat": Int(now.timeIntervalSince1970)]
        guard let h = try? JSONSerialization.data(withJSONObject: header),
              let c = try? JSONSerialization.data(withJSONObject: claims) else { return nil }
        let signingInput = base64url(h) + "." + base64url(c)
        guard let sig = try? key.signature(for: Data(signingInput.utf8)) else { return nil }
        let jwt = signingInput + "." + base64url(sig.rawRepresentation)
        try? jwt.data(using: .utf8)?.write(to: cache)
        return jwt
    }

    /// 读 `.p8`。里面是 PKCS#8 包着的 P-256 私钥。
    static func loadPrivateKey(_ path: String) -> P256.Signing.PrivateKey? {
        let p = NSString(string: path).expandingTildeInPath
        guard let pem = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8)
        else { return nil }
        return try? P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 自检

    /// 不用真设备也能验证签名通不通。
    ///
    /// 拿一个全 0 的假 token 发一次，看 APNs 回什么：
    /// - `BadDeviceToken` → **签名是对的**，Apple 收下并验过了 JWT，
    ///   只是这个设备不存在。整条链路除了真 token 以外全通。
    /// - `InvalidProviderToken` → 签名/keyID/teamID 有问题
    /// - `TopicDisallowed` → bundleID 不对，或者 App ID 没开推送能力
    ///
    /// 这个区分很值钱：没它的话，推不出去只能干瞪眼猜是哪一环。
    public static func probeSignature() -> (ok: Bool, reason: String) {
        guard let cfg = Config.load() else { return (false, "没有配置") }
        guard let jwt = signedJWT(cfg: cfg) else { return (false, "签不出 JWT，检查 .p8") }
        let fake = String(repeating: "0", count: 64)
        let r = Proc.run("/usr/bin/curl", [
            "-s", "--http2", "-X", "POST",
            "-H", "authorization: bearer " + jwt,
            "-H", "apns-topic: " + cfg.bundleID,
            "-H", "apns-push-type: alert",
            "-d", #"{"aps":{"alert":"probe"}}"#,
            "https://api.push.apple.com/3/device/" + fake,
        ], cwd: nil, env: [:], timeout: 20)
        let body = r.stdout
        if body.contains("BadDeviceToken") {
            return (true, "签名通过（Apple 验过 JWT 了，只是探测用的假 token 不存在）")
        }
        if body.contains("InvalidProviderToken") {
            return (false, "JWT 被拒：keyID / teamID / .p8 对不上")
        }
        if body.contains("TopicDisallowed") {
            return (false, "bundleID 不对，或者 App ID 没开推送能力")
        }
        return (false, body.isEmpty ? "没有响应" : String(body.prefix(120)))
    }

    /// 推送这条路通不通，卡在哪一步。
    public static func diagnose() -> [(step: String, ok: Bool, detail: String)] {
        var out: [(String, Bool, String)] = []
        let cfg = Config.load()
        out.append(("配置 ~/.llmq/apns.json", cfg != nil,
                    cfg.map { "team \($0.teamID) · key \($0.keyID)" }
                        ?? "缺文件。需要 keyID / teamID / bundleID / keyFile 四项"))
        if let cfg {
            let key = loadPrivateKey(cfg.keyFile)
            out.append((".p8 私钥", key != nil,
                        key != nil ? cfg.keyFile : "读不出或格式不对：" + cfg.keyFile))
            if key != nil {
                out.append(("JWT 签名", signedJWT(cfg: cfg) != nil, "ES256"))
            }
        }
        if cfg != nil {
            let probe = probeSignature()
            out.append(("APNs 握手", probe.ok, probe.reason))
        }
        let devs = devices()
        out.append(("手机登记的设备", !devs.isEmpty,
                    devs.isEmpty
                        ? "还没有。手机上打开 App 并允许通知，token 会自动写进共享目录"
                        : devs.map { "\($0.device)(\($0.environment))" }.joined(separator: "、")))
        return out
    }
}
