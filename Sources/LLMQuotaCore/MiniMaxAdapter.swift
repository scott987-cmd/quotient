import Foundation

/// MiniMax 的额度采集 —— **直接问官方，不从日志推**。
///
/// ## 为什么值得单独做
///
/// 在这之前 MiniMax 一直报「30 天 0 次用量」，报告里甚至把它列进
/// 「装了但没在用，每月 119 元在空烧」。而事实是它**一直在干活** ——
/// 每次派活的分诊都是它做的。日志推不出来是因为 `mmx` 不写
/// Claude Code 那种会话日志，原来的适配器扫 `~/.minimax` 什么也扫不到，
/// 所以那条适配器一直挂着 `verified: false`。
///
/// 「在烧额度但看不见」是这套工具最该消灭的状态：既算不出剩余，
/// 也不会进作废预警，等于这份订阅完全脱离监管。
///
/// ## 数据来自 `mmx quota show`
///
/// 它按模型给出两个窗口的剩余百分比，结构很干净：
///
///     model_name  general   区间 300 分钟 剩 99%   周 10080 分钟 剩 96%
///     model_name  video     区间 1440 分钟 剩 66%  周 10080 分钟 剩 71%
///
/// 这和 Codex 的 `used_percent` 是同一类东西：**平台自己报的数**，
/// 比本地推算可信，也不需要用户去订阅页抄上限。
///
/// 注意区间长度**按模型不同**（general 5 小时、video 24 小时），
/// 所以窗口长度从 `end_time - start_time` 现算，不写死。
public struct MiniMaxQuotaAdapter: UsageAdapter {
    public let id = "minimax-quota"
    public let displayName = "MiniMax（官方额度）"
    public let homePlatform: Platform = .minimax
    /// 配置目录用来判断「装没装」。真正的数据靠命令行拿。
    public let roots = ["~/.mmx", "~/.minimax"]
    /// 用真实账号跑通过：general/video 两条，百分比和 `mmx quota show` 一致。
    public let verified = true

    public init() {}

    /// 这个适配器不解析文件。
    ///
    /// 返回一个**固定的伪路径**，是为了白蹭采集框架那套按 (size, mtime)
    /// 的缓存 —— 但额度是随时在变的，缓存住反而会让数字发霉。
    /// 所以用配置文件当锚点：它不常变，于是每轮采集都会重新跑一次命令。
    public func discoverFiles() -> [URL] {
        guard Proc.which("mmx") != nil else { return [] }
        let cfg = URL(fileURLWithPath:
            NSString(string: "~/.mmx/config.json").expandingTildeInPath)
        return FileManager.default.fileExists(atPath: cfg.path) ? [cfg] : []
    }

    /// `data` 用不上 —— 数据来自命令行，不是这个文件。
    public func parse(file: URL, data: Data) -> ParsedFile {
        guard let bin = Proc.which("mmx") else {
            return ParsedFile(events: [], quotas: [], lastEventAt: nil)
        }
        let r = Proc.run(bin, ["quota", "show", "--output", "json"],
                         cwd: "/tmp", env: [:], timeout: 30)
        guard r.exitCode == 0,
              let d = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let models = obj["model_remains"] as? [[String: Any]]
        else { return ParsedFile(events: [], quotas: [], lastEventAt: nil) }

        let now = Date()
        var quotas: [OfficialQuota] = []
        for m in models {
            guard let name = m["model_name"] as? String else { continue }

            // 区间窗口。长度按模型算，不写死 —— general 是 5 小时、video 是 24 小时。
            if let s = JSONHelp.double(m["start_time"]),
               let e = JSONHelp.double(m["end_time"]), e > s,
               let remain = JSONHelp.double(m["current_interval_remaining_percent"]) {
                let minutes = Int((e - s) / 60000)
                quotas.append(OfficialQuota(
                    id: "mmx-\(name)-interval",
                    label: "\(name) " + Self.label(minutes: minutes),
                    // 官方给的是**剩余**百分比，我们的口径是已用。
                    // 弄反了不会报错，只会让「快满了」和「几乎没用」互换 ——
                    // 而这两者触发的是完全相反的动作。
                    usedPercent: max(0, 100 - remain),
                    windowMinutes: minutes,
                    resetsAt: Date(timeIntervalSince1970: e / 1000),
                    planType: "MiniMax",
                    observedAt: now))
            }

            if let s = JSONHelp.double(m["weekly_start_time"]),
               let e = JSONHelp.double(m["weekly_end_time"]), e > s,
               let remain = JSONHelp.double(m["current_weekly_remaining_percent"]) {
                quotas.append(OfficialQuota(
                    id: "mmx-\(name)-weekly",
                    label: "\(name) 每周",
                    usedPercent: max(0, 100 - remain),
                    windowMinutes: Int((e - s) / 60000),
                    resetsAt: Date(timeIntervalSince1970: e / 1000),
                    planType: "MiniMax",
                    observedAt: now))
            }
        }
        return ParsedFile(events: [], quotas: quotas, lastEventAt: quotas.isEmpty ? nil : now)
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时"
        case 1440: return "每日"
        case 10080: return "每周"
        default: return minutes >= 60 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
        }
    }
}
