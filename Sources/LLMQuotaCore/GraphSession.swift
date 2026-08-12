import Foundation

/// 图内接力时复用同一个 agent 会话。
///
/// ## 它买到的是什么，不是什么
///
/// **买到的**：同一张图的后续步骤不用把仓库重读一遍。换人的真实成本不是
/// 切换本身，是重新认识项目 —— 那部分探索烧的额度不产生任何产出。
///
/// **没买到的**：上下文不丢。会话越长越会被压缩，而压缩是**丢信息**，
/// 不只是丢缓存 —— 常驻会话不是避免压缩，是保证它一定发生。
/// 真正保住上下文的是写进文件的那些（AGENTS.md / STATUS.md / briefing）。
/// 把「有会话」当成「不用写文档」，是这套东西最容易被误用的方式。
///
/// ## 为什么只在图内
///
/// qwen 的 `-c` 是「恢复**当前项目**的最近会话」，而每个普通任务一个独立
/// worktree、路径都不同 —— 恢复出来的会话，其工作目录已经不存在了。
/// 只有图内节点共用一个 worktree 时，接力才成立。
///
/// ## 为什么存在本机
///
/// 会话存在各 CLI 自己的本地目录里（`~/.claude` 之类）。
/// 一个在 Mac mini 上创建的会话，在 MacBook 上并不存在 ——
/// 把这份映射放进 iCloud 共享，只会让另一台去 resume 一个它没有的会话。
public enum GraphSession {

    /// 测试用。
    public static var fileOverride: URL?

    static var file: URL {
        fileOverride ?? Paths.appSupport.appendingPathComponent("graph-sessions.json")
    }

    /// 这一轮该怎么起会话。
    public enum Mode: Sendable, Equatable {
        /// 不复用，全新开始。
        case fresh
        /// 第一次：用这个 id 建一个会话。
        case create(String)
        /// 后续：恢复这个 id。
        case resume(String)
    }

    static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode([String: String].self, from: d)
        else { return [:] }
        return m
    }

    static func save(_ m: [String: String]) {
        try? Paths.ensureDirectories()
        try? JSONEncoder().encode(m).write(to: file, options: .atomic)
    }

    static func key(_ graph: String, _ platform: Platform) -> String {
        graph + "|" + platform.rawValue
    }

    /// 这个（图，平台）该用哪种模式。
    ///
    /// 不是图内节点就 `.fresh` —— 普通任务各有各的 worktree，
    /// 复用会话只会让 agent 在一个已经不存在的目录里找上一次的改动。
    public static func mode(graphID: String?, platform: Platform) -> Mode {
        guard let g = graphID else { return .fresh }
        let m = load()
        if let existing = m[key(g, platform)] { return .resume(existing) }
        // 随机 id 而不是从 graph+platform 哈希出来的。
        // 哈希要额外论证「不会撞」，而撞了的后果是两张图接到同一个会话里 ——
        // 随机 id 没有这个问题，代价只是多存一行。
        return .create(UUID().uuidString.lowercased())
    }

    /// 记下这个会话已经建过了。**必须在 create 之后调** ——
    /// 不记的话下一轮又走 create，而 CLI 会报「session id 已被占用」直接失败。
    public static func remember(graphID: String?, platform: Platform, id: String) {
        guard let g = graphID else { return }
        var m = load()
        m[key(g, platform)] = id
        save(m)
    }

    /// 忘掉这个会话。
    ///
    /// 恢复失败时要调它：会话可能被 CLI 自己清掉了、或者换过机器。
    /// 不忘的话每一轮都会拿同一个不存在的 id 去 resume，**永远失败** ——
    /// 一个为了省额度加的优化，变成了让任务再也跑不成的单点故障。
    public static func forget(graphID: String?, platform: Platform) {
        guard let g = graphID else { return }
        var m = load()
        m.removeValue(forKey: key(g, platform))
        save(m)
    }

    /// 图跑完之后清掉它名下所有会话记录，别让这个文件无限长大。
    public static func forgetGraph(_ graphID: String) {
        var m = load()
        for k in m.keys where k.hasPrefix(graphID + "|") { m.removeValue(forKey: k) }
        save(m)
    }
}
