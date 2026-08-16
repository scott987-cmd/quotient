import Foundation

/// 撞顶观测：服务端说「你用完了」的那一刻，窗口里到底用掉了多少。
///
/// ## 为什么这是最值钱的样本
///
/// 估算上限一共只有三种依据，可信度差着数量级：
///
/// 1. **官方百分比反解** —— 最好，但只有 Codex 报，而且实测离散度 36%
///    （拟合不可信，不会自动写入）
/// 2. **历史最大用量**（现在的 `lowerBound`）—— 只能说「至少这么多」。
///    从没撞过顶的平台，这个数可能只有真实上限的一半，等于没估。
/// 3. **撞顶观测** ← 这个文件。服务端拒绝的那一刻是**唯一一个已知点**：
///    此刻窗口用量就在上限上。不需要拟合，不需要样本量。
///
/// 而在此之前，撞顶信号只被写进冷却台账用来「暂停派活」，学完就扔 ——
/// 台账还是 `[Platform: Cooldown]`，每个平台只留最新一条，撞过几次都被覆盖了。
/// 最硬的证据反而是保留时间最短的。
///
/// ## 为什么在「撞顶之后」采样，而不是撞顶的瞬间
///
/// 因为撞顶之后用量就不涨了 —— 请求全被拒。所以撞顶后的第一次采集反而是
/// 最干净的读数：不用抢在那一毫秒，也不会被后续增量污染。
public enum QuotaCeiling {

    public struct Observation: Codable, Sendable {
        public var platform: Platform
        public var at: Date
        public var windowMinutes: Int
        public var windowLabel: String
        /// 窗口起点。同一个窗口只记一条 —— 不然一次打满会被反复采样成十几条，
        /// 看着样本很多，其实全是同一个事实。
        public var windowStart: Date
        /// 撞顶时各口径的用量。哪个口径是平台真正的计费单位并不知道，
        /// 所以全都留着，交给上限学习器去比。
        public var usage: [String: Double]
        public var detail: String
    }

    static var path: URL {
        Paths.appSupport.appendingPathComponent("quota-ceilings.jsonl")
    }

    public static func all() -> [Observation] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return SafeDecode.json(d, as: Observation.self,
                                   from: "quota-ceilings.jsonl", decoder: dec)
        }
    }

    /// 采集后调用：把此刻处于「额度打满」冷却中的平台，各窗口的用量记下来。
    ///
    /// - Returns: 这次新记下的观测（已存在的窗口不重复记）。
    @discardableResult
    public static func capture(dashboard: Dashboard, now: Date = Date()) -> [Observation] {
        let cooling = CooldownLedger.active(now: now)
        var existing = Set(all().map { key($0.platform, $0.windowStart, $0.windowMinutes) })
        var fresh: [Observation] = []

        for report in dashboard.reports {
            guard let cd = cooling[report.platform], cd.cause == .quotaExhausted else { continue }
            for s in report.statuses {
                // **只记真正打满的那个窗口。** 冷却是平台级的，打满的却是
                // 某一个窗口：Claude 5 小时窗打满时周窗可能才用了三成，
                // 把周窗也记成撞顶，学出来的周上限会比真值低一大截。
                //
                // 怎么知道是哪个窗口？**服务端那句话里通常直接写了** ——
                //「已达到 5 小时的使用上限」「1-week quota exhausted」。
                // 不能拿冷却的 until 去对：实测台账里的 until 大多是退避猜的
                //（服务端只说 "refreshed in the next cycle" 不给时刻），
                // 拿猜的时间去匹配窗口，等于用噪音当基准。
                guard let hinted = windowHint(cd.detail),
                      abs(hinted - minutesOf(s, now: now)) <= max(60, hinted / 10)
                else { continue }
                // 百分比是我们自己注入的状态指示器，不是用量绝对值，
                // 从 100% 反解不出「100% 是多少次」。
                guard s.metric != .percent else { continue }
                let start = s.windowStart
                let minutes = windowMinutes(s, now: now)
                guard minutes > 0 else { continue }
                let k = key(report.platform, start, minutes)
                guard !existing.contains(k) else { continue }
                // 用量为 0 说明这个窗口根本没跑过东西 —— 打满的是别的窗口，
                // 记下来只会污染样本。
                guard s.used > 0 else { continue }
                existing.insert(k)
                fresh.append(Observation(
                    platform: report.platform, at: now,
                    windowMinutes: minutes, windowLabel: s.label,
                    windowStart: start,
                    usage: [s.metric.rawValue: s.used],
                    detail: String(cd.detail.prefix(160))))
            }
        }
        guard !fresh.isEmpty else { return [] }
        append(fresh)
        return fresh
    }

    /// 从服务端的拒绝消息里认出「是哪个窗口满了」，单位分钟。
    ///
    /// 认不出就返回 nil，那一次撞顶就不采样 —— 宁可少一个样本，
    /// 也不能把 5 小时窗的用量记成周上限。
    static func windowHint(_ detail: String) -> Int? {
        let d = detail.lowercased()
        // 顺序有讲究：先认更长的窗口。"1-week" 里也含 "week"，
        // 但 "5 小时" 和 "hour" 要在 "day" 之前判，否则 "5-hour" 会被漏掉。
        if d.contains("月") || d.contains("month") { return 30 * 24 * 60 }
        if d.contains("周") || d.contains("week") { return 7 * 24 * 60 }
        for h in [5, 3, 1] {
            if d.contains("\(h) 小时") || d.contains("\(h)小时")
                || d.contains("\(h)-hour") || d.contains("\(h) hour") { return h * 60 }
        }
        if d.contains("日") || d.contains("天") || d.contains("daily")
            || d.contains("per day") || d.contains("24-hour") { return 24 * 60 }
        return nil
    }

    /// 这条状态代表多长的窗口（分钟）。
    static func minutesOf(_ s: QuotaStatus, now: Date) -> Int {
        windowMinutes(s, now: now)
    }

    static func key(_ p: Platform, _ start: Date, _ minutes: Int) -> String {
        "\(p.rawValue)|\(Int(start.timeIntervalSince1970))|\(minutes)"
    }

    /// 窗口长度。有重置时间就用「重置 − 起点」，否则退回状态自带的标签解析。
    static func windowMinutes(_ s: QuotaStatus, now: Date) -> Int {
        let start = s.windowStart
        if let resets = s.resetsAt {
            return Int(resets.timeIntervalSince(start) / 60)
        }
        return Int(now.timeIntervalSince(start) / 60)
    }

    static func append(_ items: [Observation]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var blob = ""
        for i in items {
            guard let d = try? enc.encode(i),
                  let s = String(data: d, encoding: .utf8) else { continue }
            blob += s + "\n"
        }
        guard !blob.isEmpty, let data = blob.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: path)
        }
    }

    /// 每个 (平台, 窗口长度, 口径) 的上限估计。
    ///
    /// 多次撞顶取**最大值**：每次观测都是真实上限的下界（我们可能漏采了一部分
    /// 用量），取最大的那个最接近真相。取平均反而会被漏采的那几次拉低。
    public static func estimates() -> [(platform: Platform, windowMinutes: Int,
                                        windowLabel: String, metric: String,
                                        value: Double, samples: Int)] {
        var best: [String: (Platform, Int, String, String, Double, Int)] = [:]
        for o in all() {
            for (metric, value) in o.usage {
                let k = "\(o.platform.rawValue)|\(o.windowMinutes)|\(metric)"
                if let cur = best[k] {
                    best[k] = (cur.0, cur.1, cur.2, cur.3, max(cur.4, value), cur.5 + 1)
                } else {
                    best[k] = (o.platform, o.windowMinutes, o.windowLabel, metric, value, 1)
                }
            }
        }
        return best.values
            .map { (platform: $0.0, windowMinutes: $0.1, windowLabel: $0.2,
                    metric: $0.3, value: $0.4, samples: $0.5) }
            .sorted { $0.platform.sortIndex == $1.platform.sortIndex
                ? $0.windowMinutes < $1.windowMinutes
                : $0.platform.sortIndex < $1.platform.sortIndex }
    }
}
