import Foundation

/// 发布是否真的到达了每一台在线机器。
///
/// “包已上传”和“本机已安装”都不是集群发布完成；只有每台近期仍上报状态的
/// 对端亲自报告相同 release 哈希才算完成。离线机器不阻塞，回来后由 updater
/// 自行追上。
public enum ReleaseFanout {
    public static let identityLength = 12

    public static func matches(target: String, installed: String?) -> Bool {
        guard let installed, installed.count >= identityLength,
              target.count >= identityLength else { return false }
        return installed.prefix(identityLength) == target.prefix(identityLength)
    }

    public static func pending(target: String, localMachineID: String,
                               presences: [ClusterPresence], now: Date = Date())
        -> [ClusterPresence] {
        presences.filter {
            $0.machineID != localMachineID
                && !$0.isStale(now: now)
                && !matches(target: target, installed: $0.installedRelease)
        }.sorted { $0.machineName < $1.machineName }
    }
}
