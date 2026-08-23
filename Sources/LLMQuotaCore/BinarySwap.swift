import Foundation

/// 常驻循环「等手上这件干完再换二进制」的那个机制。
///
/// 以前这句话只是一句安慰：`restart-worker` / `restartResidentServices` 看到有活在跑
/// 就不踢,打印「新二进制等它干完自然生效」—— 可 `work loop` 是 KeepAlive 常驻进程,
/// 没人踢它就永远跑旧代码。2026-08-22 晚 MacBook 停在旧版好几个钟头,老板看到的是
/// 「下午适配的 zcode 手机端看不到」;而另一条路径(`ReleaseChannel.install` 末尾的
/// 无条件 `kickstart -k`)又反过来把正在跑的 agent 一起杀掉(fa4e5eeb 2026-08-23
/// 被这样杀了两次)。两头都不对:**换二进制这件事要由循环自己在空闲点做。**
///
/// 做法:循环启动时记下自己二进制的指纹(inode+大小+修改时间);每轮末尾、确认
/// 手上没活(没有 agent 在跑、没有后台落地在跑)时,发现磁盘上的二进制换了就退出,
/// launchd KeepAlive 会用新二进制把它拉起来。退出点只在这一处,任务不会被打断。
public enum BinarySwap {
    public struct Fingerprint: Equatable, Sendable {
        public var inode: UInt64
        public var size: UInt64
        public var modified: Date
    }

    /// 当前进程的可执行文件路径。命令行工具下 `Bundle.main.executablePath` 给的是
    /// 真实路径,不是 argv[0](从 PATH 调用时 argv[0] 只是 "llmq")。
    public static var executablePath: String? {
        guard let p = Bundle.main.executablePath else { return nil }
        // 解析符号链接:~/.local/bin/llmq 有时是个 link,指纹要取真身。
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: p)).map {
            $0.hasPrefix("/") ? $0 : (p as NSString).deletingLastPathComponent + "/" + $0
        } ?? p
    }

    public static func fingerprint(of path: String) -> Fingerprint? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        let mod = (a[.modificationDate] as? Date) ?? .distantPast
        return Fingerprint(inode: inode, size: size, modified: mod)
    }

    /// 循环启动时调一次,拿到「我是哪份二进制」。
    public static func watch(path: String? = executablePath) -> Watch {
        Watch(path: path, startedWith: path.flatMap(fingerprint(of:)))
    }

    public struct Watch: Sendable {
        public let path: String?
        public let startedWith: Fingerprint?

        /// 磁盘上的二进制和启动时的不是同一份了。
        /// 取不到指纹(文件没了、正在替换中)按「没变」处理:别因为一瞬间的
        /// 中间态就退出 —— 下一轮再看。
        public func changed() -> Bool {
            guard let path, let startedWith, let now = fingerprint(of: path) else { return false }
            return now != startedWith
        }
    }

    /// 唯一的判定:换了 **且** 手上没活,才退出。
    /// `inFlight` = 有 agent 在跑 / 有后台落地在跑 —— 任何一样都再等一轮。
    public static func shouldExit(changed: Bool, inFlight: Bool) -> Bool {
        changed && !inFlight
    }
}
