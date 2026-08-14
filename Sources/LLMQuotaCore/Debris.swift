import Foundation

/// 找出我们自己留在 iCloud 上的半成品文件。
///
/// # 这些文件是怎么来的
///
/// `Data.write(to:options:.atomic)` 的实现是「先写一个临时文件、再 rename 过去」。
/// 临时文件叫 `<真名>.sb-<一串>`。正常情况下 rename 一瞬间就完成、临时文件消失。
///
/// 但 iCloud 上的 rename **可以永久阻塞**（不是慢，是不返回）——
/// 于是临时文件写成了、rename 永远不回来，半成品就留在那儿。
/// 进程被杀或重启之后，它再也没人管。
///
/// 实测代价：一天之内攒了 **166 个文件、21MB**，而且一直在往手机上同步。
/// 更糟的是它们分散在好几种名字下（快照 57、看板 50、仓库清单 45、
/// 办公室 8、任务回执 5、冷却 1）—— 我第一次统计只数了看板那一种，
/// 报出来的数字差了一个数量级。**扫就要扫全，别只数自己想得到的那一类。**
///
/// # 为什么留着这条检查
///
/// 阻塞那个根因已经用看门狗兜住了，理论上不该再产生新的半成品。
/// 但「理论上不该有」正是这一天里每一次事故的共同开场白。
/// 这条检查很便宜，而它能证伪的正是那句「理论上」。
public enum Debris {

    /// Foundation 原子写留下的临时文件的特征。
    static let marker = ".sb-"

    public struct Report: Sendable {
        public var files: [URL]
        public var totalBytes: Int
        /// 最老的那个是什么时候留下的。一直有新的说明问题还在发生。
        public var oldest: Date?
        public var newest: Date?
        /// 扫描过程中有目录读不动（iCloud 没响应），结果可能不全。
        public var incomplete: Bool

        public var isEmpty: Bool { files.isEmpty }

        /// 人看的大小。
        ///
        /// 别一律用 MB —— 1 字节印成「0.0 MB」会让人以为这条警告本身坏了，
        /// 于是真正该看的那句话被无视掉。
        public var sizeText: String {
            if totalBytes >= 1_048_576 {
                return String(format: "%.1f MB", Double(totalBytes) / 1_048_576)
            }
            if totalBytes >= 1024 {
                return String(format: "%.0f KB", Double(totalBytes) / 1024)
            }
            return "\(totalBytes) 字节"
        }
    }

    /// 扫一遍 iCloud 上的共享目录。
    ///
    /// **每一层列目录都带超时。** 这个函数本身要是能把 doctor 卡住，
    /// 那它就成了它要报告的那个问题的一部分。
    public static func scan(root: URL?, maxDepth: Int = 3) -> Report {
        guard let root else {
            return Report(files: [], totalBytes: 0, oldest: nil, newest: nil, incomplete: false)
        }
        var found: [URL] = []
        var bytes = 0
        var dates: [Date] = []
        var incomplete = false

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            let entries = Watchdog.run("debris.ls:" + dir.path, timeout: 6) {
                (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [])) ?? []
            }
            guard case .done(let list) = entries else {
                // 读不动就记一笔往下走。**别把「没读到」说成「没有」** ——
                // 这个项目在别处已经把这个错误犯过一次（空的用量桶被
                // 当成「100% 空窗」报给用户）。
                incomplete = true
                return
            }
            for url in list {
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                           .contentModificationDateKey])
                if rv?.isDirectory == true {
                    walk(url, depth: depth + 1)
                } else if url.lastPathComponent.contains(marker) {
                    found.append(url)
                    bytes += rv?.fileSize ?? 0
                    if let d = rv?.contentModificationDate { dates.append(d) }
                }
            }
        }
        walk(root, depth: 0)
        return Report(files: found.sorted { $0.path < $1.path }, totalBytes: bytes,
                      oldest: dates.min(), newest: dates.max(), incomplete: incomplete)
    }

    /// 删掉扫出来的半成品。
    ///
    /// 只删名字里带 `.sb-` 的 —— 真文件的名字里永远没有这一段
    /// （`dashboard.json` 对 `dashboard.json.sb-xxx`）。
    /// 这里再判一次而不是无条件信任传进来的清单：
    /// 删除是不可逆的，多一道判断的成本约等于零。
    @discardableResult
    public static func remove(_ files: [URL]) -> (removed: Int, failed: Int) {
        var ok = 0, bad = 0
        for url in files {
            guard url.lastPathComponent.contains(marker) else { bad += 1; continue }
            let r = Watchdog.run("debris.rm:" + url.path, timeout: 6) {
                (try? FileManager.default.removeItem(at: url)) != nil
            }
            r.valueOr(false) ? (ok += 1) : (bad += 1)
        }
        return (ok, bad)
    }
}
