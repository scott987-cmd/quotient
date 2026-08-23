import XCTest
@testable import LLMQuotaCore

/// 「装了」不等于「调得起来」。
/// 实锤 2026-08-23(老板的 MacBook):ZCode 装着,但 `/usr/bin/env node` 在 launchd 环境里
/// 报 `env: node: No such file or directory`,CLI 配置也缺 —— 每条派给 GLM 的活都在这里
/// 无声死掉,而调度还以为它可用。老板:「不是说改个名就可以了,要确保真实可调度」。
final class ZcodeRunnableTests: XCTestCase {
    func test_起进程用绝对路径的node_不靠env找() {
        let c = ZcodeRunner().command(prompt: "p", cwd: "/tmp")
        XCTAssertFalse(c.launchPath.hasSuffix("/env"),
                       "不能靠 /usr/bin/env 找 node:launchd 环境里 PATH 没有它")
        XCTAssertTrue(c.launchPath.hasPrefix("/"), "要绝对路径:\(c.launchPath)")
        XCTAssertFalse(c.args.first == "node", "node 不该再作为参数传给 env")
        XCTAssertEqual(c.args.first, ZcodeRunner.scriptPath, "第一个参数应是 CLI 脚本")
    }

    func test_凭据走环境变量_而且不出现在参数里() {
        let c = ZcodeRunner().command(prompt: "p", cwd: "/tmp")
        // 有凭据的机器上才会带;没有的机器上 binaryPath 也会是 nil(下一条测)。
        if let key = c.env["ZCODE_API_KEY"] {
            XCTAssertFalse(key.isEmpty)
            XCTAssertNotNil(c.env["ZCODE_BASE_URL"])
            XCTAssertFalse(c.args.contains(key), "密钥绝不能出现在命令行参数里(ps 能看到)")
        }
    }

    /// 四样缺一就不可用 —— 这条是「不许假装可用」的机制。
    func test_四样齐了才算可用() {
        let r = ZcodeRunner()
        let fm = FileManager.default
        let hasScript = fm.isReadableFile(atPath: ZcodeRunner.scriptPath)
        let hasNode = ZcodeRunner.nodePath != nil
        let hasCLIConfig = fm.isReadableFile(atPath: ZcodeRunner.cliConfigPath)
        let hasCreds = ZcodeRunner.credentials() != nil
        let allFour = hasScript && hasNode && hasCLIConfig && hasCreds
        XCTAssertEqual(r.binaryPath != nil, allFour,
                       "可用性必须等于「四样齐」;缺的是:\(ZcodeRunner.missingPieces())")
        if !allFour {
            XCTAssertFalse(ZcodeRunner.missingPieces().isEmpty, "不可用就要说清缺什么")
        }
    }

    /// 名字跟着**集群里真正能跑的那个**走(下面「本机没装但对端有」那条测的就是这个)。
    /// 老板的 MacBook 上 Claude Code+GLM 和官方 ZCode 并存,写死任何一个都会撒谎。
    func test_本机可用时叫ZCode() {
        _ = fake(script: true, node: true, cliConfig: true, creds: true)
        XCTAssertEqual(AgentIdentity.name(for: .glm), "ZCode · GLM")
        XCTAssertEqual(AgentIdentity.binaryName(for: .glm), "zcode")
    }

    // MARK: 四样齐 —— 用注入的假路径测,两台机器上结果一样

    private func fake(script: Bool, node: Bool, cliConfig: Bool, creds: Bool) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("zc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let sc = d.appendingPathComponent("zcode.cjs")
        let cli = d.appendingPathComponent("cli.json")
        let gui = d.appendingPathComponent("gui.json")
        if script { try? "x".write(to: sc, atomically: true, encoding: .utf8) }
        if cliConfig { try? "{}".write(to: cli, atomically: true, encoding: .utf8) }
        let key = creds ? "sk-fake" : ""
        let g = #"{"provider":{"builtin:bigmodel-coding-plan":{"options":{"baseURL":"https://x","apiKey":"\#(key)"}}}}"#
        try? g.write(to: gui, atomically: true, encoding: .utf8)
        ZcodeRunner.pathsOverride = (sc.path, cli.path, gui.path, node ? "/bin/echo" : nil)
        return d
    }

    override func tearDown() { ZcodeRunner.pathsOverride = nil }

    func test_缺任何一样都不可用() {
        _ = fake(script: true, node: true, cliConfig: true, creds: true)
        XCTAssertNotNil(ZcodeRunner().binaryPath, "四样齐了应该可用")
        XCTAssertTrue(ZcodeRunner.missingPieces().isEmpty)

        for (name, f) in [("没装脚本", (false, true, true, true)),
                          ("没有 node", (true, false, true, true)),
                          ("缺 CLI 配置", (true, true, false, true)),
                          ("没有凭据", (true, true, true, false))] {
            _ = fake(script: f.0, node: f.1, cliConfig: f.2, creds: f.3)
            XCTAssertNil(ZcodeRunner().binaryPath, "\(name) 时不该报可用")
            XCTAssertFalse(ZcodeRunner.missingPieces().isEmpty, "\(name) 时要说清缺什么")
        }
    }

    func test_可用时凭据进环境变量() {
        _ = fake(script: true, node: true, cliConfig: true, creds: true)
        let c = ZcodeRunner().command(prompt: "p", cwd: "/tmp")
        XCTAssertEqual(c.env["ZCODE_API_KEY"], "sk-fake")
        XCTAssertEqual(c.env["ZCODE_BASE_URL"], "https://x")
        XCTAssertEqual(c.launchPath, "/bin/echo")
    }

    // MARK: 名字要按「集群里谁能跑」判,不是按本机

    func test_本机没装但对端快照里有zcode_也叫ZCode() throws {
        ZcodeRunner.pathsOverride = ("/nope/zcode.cjs", "/nope/cli.json", "/nope/gui.json", nil)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        let saved = Paths.appSupportOverride
        Paths.appSupportOverride = tmp
        defer { Paths.appSupportOverride = saved }
        let dir = Paths.sharedRoot.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 只有「本机没有 GLM」的那份 → 还是老名字
        let mini = #"{"platforms":[{"platform":"glm","detected":false,"sources":[]}]}"#
        try mini.write(to: dir.appendingPathComponent("MINI.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIdentity.name(for: .glm), "Claude Code · GLM")

        // 对端快照里 GLM 来源含 .zcode → 整个集群按 ZCode 算
        let mac = #"{"platforms":[{"platform":"glm","detected":true,"sources":["~/.claude","~/.zcode"]}]}"#
        try mac.write(to: dir.appendingPathComponent("MAC.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIdentity.name(for: .glm), "ZCode · GLM",
                       "dashboard.json 是单文件后写覆盖:只看本机的话 mini 每写一次就把 ZCode 盖掉,老板又看不见了")
        XCTAssertEqual(AgentIdentity.binaryName(for: .glm), "zcode")
    }
}
