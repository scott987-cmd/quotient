import Foundation

/// 补装展示服务不等于重装 worker：绝不触碰 Coordinator 或模型执行器。
public enum ProjectorInstallation {
    public static let label = "com.llmquotabar.projector"

    @discardableResult
    public static func ensure(
        executable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        support: URL = Paths.appSupport,
        uid: UInt32 = getuid(),
        onlyIfWorkerInstalled: Bool = true,
        run: ([String]) -> Int32 = {
            Proc.run("/bin/launchctl", $0, cwd: "/tmp", env: [:], timeout: 15).exitCode
        }
    ) throws -> Bool {
        let fm = FileManager.default
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        if onlyIfWorkerInstalled && !fm.fileExists(atPath:
            agents.appendingPathComponent("com.llmquotabar.worker.plist").path) { return false }
        guard fm.isExecutableFile(atPath: executable) else {
            throw ClusterCA.err("刷新服务程序不存在或不可执行：\(executable)")
        }
        let file = agents.appendingPathComponent(label + ".plist")
        let target = "gui/\(uid)/\(label)"
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [executable, "work", "projector"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 60,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["com.llmquotabar.menubar"],
            "StandardOutPath": support.appendingPathComponent("projector.log").path,
            "StandardErrorPath": support.appendingPathComponent("projector.err.log").path,
        ]
        let existing = (try? Data(contentsOf: file)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        let changed = existing != (plist as NSDictionary)
        let loaded = run(["print", target]) == 0
        if changed {
            try fm.createDirectory(at: agents, withIntermediateDirectories: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .xml, options: 0)
            guard ICloudSafe.write(data, to: file) else {
                throw ClusterCA.err("刷新服务配置写入失败：\(file.path)")
            }
            if loaded && run(["bootout", target]) != 0 {
                throw ClusterCA.err("旧刷新服务未能卸载；没有重启任务执行器")
            }
        }
        if !loaded || changed {
            guard run(["bootstrap", "gui/\(uid)", file.path]) == 0,
                  run(["print", target]) == 0 else {
                throw ClusterCA.err("刷新服务补装失败，请检查 \(file.path)")
            }
        }
        return true
    }
}
