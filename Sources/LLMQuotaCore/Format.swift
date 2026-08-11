import Foundation

public enum Format {
    /// 大数字缩写。token 动辄上千万，完整数字在菜单栏里没法看。
    public static func compact(_ v: Double) -> String {
        let a = abs(v)
        switch a {
        case 0..<1000:
            return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        case 1000..<1_000_000:
            return String(format: "%.1fK", v / 1000)
        case 1_000_000..<1_000_000_000:
            return String(format: "%.1fM", v / 1_000_000)
        default:
            return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    public static func compact(_ v: Int) -> String { compact(Double(v)) }

    public static func bytes(_ v: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(v)
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return i == 0 ? "\(v) B" : String(format: "%.1f %@", value, units[i])
    }

    public static func percent(_ fraction: Double?, decimals: Int = 0) -> String {
        guard let f = fraction else { return "—" }
        return String(format: "%.\(decimals)f%%", f * 100)
    }

    /// 计量值按口径显示 —— 百分比口径的数字本身就是百分数，别再加单位。
    public static func metricValue(_ v: Double, metric: QuotaMetric) -> String {
        switch metric {
        case .percent: return String(format: "%.0f%%", v)
        case .cost: return String(format: "%.2f", v)
        case .requests: return compact(v) + " 次"
        default: return compact(v)
        }
    }

    /// 倒计时。菜单栏空间紧，只保留两个量级。
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "—" }
        let total = Int(s)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)天\(h)小时" : "\(d)天" }
        if h > 0 { return m > 0 ? "\(h)小时\(m)分" : "\(h)小时" }
        return "\(m)分钟"
    }

    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "从未" }
        let delta = now.timeIntervalSince(date)
        if delta < 0 { return "刚刚" }
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
        return "\(Int(delta / 86400)) 天前"
    }

    public static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 进度条。CLI 报告和菜单栏都用它，保证两边看到的是同一个视觉语言。
    public static func bar(_ fraction: Double?, width: Int = 20) -> String {
        guard let f = fraction else { return String(repeating: "·", count: width) }
        let filled = min(width, max(0, Int((f * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}
