import Foundation

/// 按订阅页的**百分比**反推绝对上限。
///
/// ## 为什么需要这条路
///
/// 有些平台只给比例、不给数字(Kimi 全年尊享:订阅页「本周已用 X%」,
/// 老板 2026-08-21 原话「只有比例,没有绝对值」)。而作废预警、剩余量、
/// 调度余量全都要绝对上限。系统自己知道**本窗口用了多少**,
/// 人看一眼页面知道**这占了百分之几**,两者一除就是上限 ——
/// 比等 429 去学快得多,也比第三方传言可靠得多。
///
/// 误差来源要诚实:页面百分比通常是整数,±0.5 个百分点;用量小的时候
/// 相对误差大(用了 3% 时 ±17%),所以 hint 里写清楚依据,等用量大了再校一次。
public enum QuotaCalibration {
    public enum Failure: Error, Equatable {
        case percentOutOfRange   // 必须在 (0, 100]
        case noUsageYet          // 本窗口还没用过,除不出来
    }

    /// - Parameters:
    ///   - used: 本窗口到目前为止的用量(原始计量单位)
    ///   - percentUsed: 订阅页显示的已用百分比,0 < p ≤ 100
    /// - Returns: 反推的上限,按量级取整(千位以上取整到百,以下取整到十)
    public static func limit(used: Double, percentUsed: Double) throws -> Double {
        guard percentUsed > 0, percentUsed <= 100 else { throw Failure.percentOutOfRange }
        guard used > 0 else { throw Failure.noUsageYet }
        let raw = used / (percentUsed / 100)
        let unit: Double = raw >= 100_000 ? 1000 : (raw >= 1000 ? 100 : 10)
        return (raw / unit).rounded() * unit
    }

    /// 写进 hint 的依据,以后看到数字知道它怎么来的。
    public static func provenance(percentUsed: Double, used: Double,
                                  metric: QuotaMetric, on date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return "按 \(f.string(from: date)) 订阅页已用 \(Int(percentUsed.rounded()))% 反推"
            + "(当时本窗口用量 \(Format.metricValue(used, metric: metric)));"
            + "页面比例是整数,用量越大越准,可再校。"
    }
}
