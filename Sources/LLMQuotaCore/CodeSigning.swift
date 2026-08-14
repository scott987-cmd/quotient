import Foundation

/// 给发布出去的二进制签一个**跨重建稳定**的身份。
///
/// # 为什么非签不可
///
/// macOS 的访问授权（TCC）要靠代码签名来认「这个程序是谁」。
/// SwiftPM 默认产出的是 **adhoc 签名**：`TeamIdentifier=not set`，
/// 系统只能拿 cdhash 当身份 —— 而 cdhash **每次重建都不一样**。
/// 实测同一份源码构建两次：
/// ```
/// d6fc4a0d6dc0778364805b5a6d1f089a5646d05a
/// ed2063c405602a6b7c8ebc81b2929734d849a7c3
/// ```
///
/// 后果是一条谁都想不到的因果链：用户在系统设置里给 `llmq` 开了完全磁盘访问，
/// worker 立刻能干活了；然后**下一次 `llmq release publish` 就把这个授权作废了**，
/// 因为装上去的是一个 cdhash 不同的新二进制。一次排查里发布了六次，
/// 于是「能跑 / 不能跑」反复横跳，而每一次看起来都像是别的原因。
///
/// 签上一张有 Team ID 的证书之后，身份变成 `identifier + team`，
/// 跟具体哪一次构建无关，授权就能一直有效。
///
/// # 身份从哪来（**不写进仓库**）
///
/// 证书名里带着开发者的邮箱和 Team ID，属于个人信息 ——
/// 这个项目要开源，不能硬编码。所以：
///
/// - 存在本机的 `signing.json`（Application Support 下，不进 iCloud、不进 git）
/// - 或者环境变量 `LLMQ_CODESIGN_IDENTITY`
/// - 都没有就**不签**，行为和现在完全一致
///
/// 别人拿这个项目去用，什么都不用配；想要授权不失效，就配上自己的证书。
public enum CodeSigning {

    public static var configFile: URL {
        Paths.appSupport.appendingPathComponent("signing.json")
    }

    private struct Config: Codable { var identity: String }

    /// 当前配置的签名身份。没配就是 nil（= 不签）。
    public static func identity() -> String? {
        if let env = ProcessInfo.processInfo.environment["LLMQ_CODESIGN_IDENTITY"],
           !env.isEmpty { return env }
        guard let d = try? Data(contentsOf: configFile),
              let c = try? JSONDecoder().decode(Config.self, from: d),
              !c.identity.isEmpty
        else { return nil }
        return c.identity
    }

    public static func setIdentity(_ id: String) throws {
        try Paths.ensureDirectories()
        let d = try JSONEncoder().encode(Config(identity: id))
        // 本机文件，走本地路径 —— 签名身份不该跟着 iCloud 到处跑。
        guard ICloudSafe.write(d, to: configFile) else {
            throw NSError(domain: "CodeSigning", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "写签名配置失败"])
        }
    }

    public static func clearIdentity() {
        try? FileManager.default.removeItem(at: configFile)
    }

    /// 机器上可用的签名身份。
    public static func available() -> [String] {
        let r = Proc.run("/usr/bin/security",
                         ["find-identity", "-v", "-p", "codesigning"],
                         cwd: NSTemporaryDirectory(), env: [:], timeout: 20)
        return r.stdout.split(separator: "\n").compactMap { line in
            guard let a = line.firstIndex(of: "\""),
                  let b = line.lastIndex(of: "\""), a < b else { return nil }
            return String(line[line.index(after: a)..<b])
        }
    }

    public struct Result: Sendable {
        public var signed: Bool
        public var detail: String
    }

    /// 签一个可执行文件。没配身份就原样返回，不算失败。
    ///
    /// - Parameter identifier: 显式钉死签名标识。
    ///   **不能省** —— codesign 默认拿文件名当 identifier，实测签
    ///   `/tmp/sigtest1` 得到的是 `Identifier=sigtest1`。
    ///   而系统授权认的正是 `identifier + team` 这一对，
    ///   靠文件名去凑等于把身份交给调用现场，换个路径就又是一个新程序。
    @discardableResult
    public static func sign(_ path: String, identifier: String = "llmq") -> Result {
        guard let id = identity() else {
            return Result(signed: false, detail:
                "没配签名身份，保持 adhoc —— "
                + "系统授权（完全磁盘访问等）会在下次发布后失效。"
                + "配一次：llmq release sign-with \"<证书名>\"")
        }
        let r = Proc.run("/usr/bin/codesign",
                         ["--force", "--sign", id, "--identifier", identifier,
                          "--timestamp=none", path],
                         cwd: NSTemporaryDirectory(), env: [:], timeout: 120)
        guard r.exitCode == 0 else {
            return Result(signed: false, detail:
                "签名失败（退出码 \(r.exitCode)）："
                + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        }
        return Result(signed: true, detail: "已签名：" + id)
    }

    /// 读一个二进制的签名身份，用来验证「稳不稳定」。
    public static func describe(_ path: String) -> (team: String?, identifier: String?) {
        let r = Proc.run("/usr/bin/codesign", ["-dv", "--verbose=2", path],
                         cwd: NSTemporaryDirectory(), env: [:], timeout: 20)
        // codesign 把这些信息打到 stderr。
        let text = r.stderr + r.stdout
        func field(_ k: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix(k + "=") {
                return String(line.dropFirst(k.count + 1))
            }
            return nil
        }
        let team = field("TeamIdentifier")
        return (team == "not set" ? nil : team, field("Identifier"))
    }
}
