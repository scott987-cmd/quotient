import Foundation

/// 直接问 MiniMax 要官方额度。
///
/// 这是继 Codex 之后**第二个不用猜的额度源**，而且比 Codex 完整：
/// Codex 只在会话日志里留一个 `used_percent`，这里则同时给出
/// 5 小时窗口和每周窗口的剩余百分比、窗口起止时刻、以及次数配额的分子分母。
///
/// 有它之后，MiniMax 这条线不需要用户去填 `limit`，也不需要靠撞墙学 ——
/// 每次采集直接问一次就行。
///
/// `mmx quota show` 是只读查询，不消耗生成额度。
public enum MiniMaxProbe {

    public static var isAvailable: Bool { Proc.which("mmx") != nil }

    /// mmx 返回的一条模型配额。
    struct ModelRemain: Decodable {
        var model_name: String?
        var start_time: Double?
        var end_time: Double?
        var current_interval_remaining_percent: Double?
        var current_interval_total_count: Int?
        var current_interval_usage_count: Int?
        var weekly_start_time: Double?
        var weekly_end_time: Double?
        var current_weekly_remaining_percent: Double?
        var current_weekly_total_count: Int?
        var current_weekly_usage_count: Int?
    }

    struct Response: Decodable {
        var model_remains: [ModelRemain]?
    }

    /// 拉一次官方额度。失败返回空数组，不抛 —— 采集不该因为它挂掉。
    public static func fetch(now: Date = Date()) -> [OfficialQuota] {
        guard let mmx = Proc.which("mmx") else { return [] }
        let r = Proc.run(mmx, ["quota", "show", "--output", "json",
                               "--non-interactive", "--quiet"],
                         cwd: nil, env: [:], timeout: 45)
        guard r.exitCode == 0,
              let data = r.stdout.data(using: .utf8),
              let resp = try? JSONDecoder().decode(Response.self, from: data),
              let remains = resp.model_remains
        else { return [] }

        var out: [OfficialQuota] = []
        for m in remains {
            // 只关心文本生成那条。video/music 之类走的是另一套配额，
            // 混进来会让「MiniMax 还剩多少」这个问题没法回答 ——
            // 视频额度用光了不代表跑不了编码任务。
            let name = (m.model_name ?? "").lowercased()
            guard name.isEmpty || name == "general" || name.contains("text") else { continue }

            if let pct = m.current_interval_remaining_percent,
               let end = m.end_time, let start = m.start_time {
                let minutes = Int((end - start) / 1000 / 60)
                out.append(OfficialQuota(
                    id: "interval",
                    label: CodexAdapter.windowLabel(minutes: minutes, fallback: "当前窗口"),
                    usedPercent: max(0, min(100, 100 - pct)),
                    windowMinutes: minutes > 0 ? minutes : 300,
                    resetsAt: Date(timeIntervalSince1970: end / 1000),
                    planType: countHint(m.current_interval_usage_count,
                                        m.current_interval_total_count),
                    observedAt: now))
            }
            if let pct = m.current_weekly_remaining_percent,
               let end = m.weekly_end_time, let start = m.weekly_start_time {
                let minutes = Int((end - start) / 1000 / 60)
                out.append(OfficialQuota(
                    id: "weekly",
                    label: "每周",
                    usedPercent: max(0, min(100, 100 - pct)),
                    windowMinutes: minutes > 0 ? minutes : 10080,
                    resetsAt: Date(timeIntervalSince1970: end / 1000),
                    planType: countHint(m.current_weekly_usage_count,
                                        m.current_weekly_total_count),
                    observedAt: now))
            }
        }
        return out
    }

    /// 次数配额的分子分母，塞进 planType 里当补充说明。
    /// 文本模型的 total_count 常常是 0（按 token 计而非按次），那种情况就不显示。
    static func countHint(_ used: Int?, _ total: Int?) -> String? {
        guard let total, total > 0, let used else { return nil }
        return "\(used)/\(total) 次"
    }
}
