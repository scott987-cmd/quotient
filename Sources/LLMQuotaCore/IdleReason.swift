import Foundation

/// **「为什么现在没人干活」——一句话说清。**
///
/// 老板 2026-08-22 一天里问了八次「任务停了」,八次原因都不同:
/// 磁盘满、评审判不合入、每小时限流、菜单栏 App 挂了、队里的活全被
/// 依赖或落地闸挡着……每次都要我上机器查日志才能回答他。
///
/// 而这些原因**系统自己全都知道**,只是从来没说出来:
/// worker.log 里写着「但没有现成的活」,手机上却只是一片安静。
/// 看不见原因本身就是那个要修的问题。
public enum IdleReason {
    /// 静默多久之后才值得记一条 —— 太灵敏会把正常的轮次间隙也记上。
    public static let quietAfter: TimeInterval = 10 * 60

    public struct Verdict: Sendable {
        /// 手机上直接显示的一句话。
        public var line: String
        /// 是不是「正常的没活干」(队列真空) —— 这种不算故障。
        public var isNormal: Bool
    }

    /// - Parameters:
    ///   - queued: 队列里还没跑的任务
    ///   - blockedByDeps: 其中因为上游步骤没完成而不能开工的
    ///   - deferredByLease: 因为同仓库有人在改而让开的
    ///   - platformRejections: 队头任务被各平台拒绝的理由(平台名 → 原因)
    ///   - rateLimited: 是不是撞了每小时上限
    ///   - lowDisk: 是不是磁盘见底
    ///   - pendingLanding: 有多少条产出卡在落地环节(被否决/等审核)
    public static func explain(queued: Int, blockedByDeps: Int, deferredByLease: Int,
                               platformRejections: [(String, String)],
                               rateLimited: Bool, lowDisk: Bool,
                               pendingLanding: Int) -> Verdict {
        if lowDisk {
            return Verdict(line: "磁盘见底,本轮不派活 —— 派了也只会失败,先清理",
                           isNormal: false)
        }
        if rateLimited {
            return Verdict(line: "撞到每小时任务上限,等窗口滚过去就自动继续",
                           isNormal: true)
        }
        if queued == 0 {
            return pendingLanding > 0
                ? Verdict(line: "队列空了,但有 \(pendingLanding) 条产出卡在落地环节 ——"
                            + "它们合不进去,新活也就排不出来", isNormal: false)
                : Verdict(line: "队列是空的 —— 活都干完了,可以安排新的", isNormal: true)
        }
        if blockedByDeps == queued {
            return Verdict(line: "排队的 \(queued) 条全在等上一步完成"
                            + (pendingLanding > 0
                               ? "(上一步的产出卡在落地环节,\(pendingLanding) 条没合进去)"
                               : ""),
                           isNormal: pendingLanding == 0)
        }
        if deferredByLease > 0, deferredByLease == queued {
            return Verdict(line: "排队的活所在仓库都有人在改,等它们落地",
                           isNormal: true)
        }
        if !platformRejections.isEmpty {
            let why = platformRejections.prefix(3)
                .map { "\($0.0):\($0.1)" }.joined(separator: "；")
            return Verdict(line: "有活派不出去 —— \(why)", isNormal: false)
        }
        return Verdict(line: "排队 \(queued) 条,但这一轮没有能开工的", isNormal: false)
    }
}
