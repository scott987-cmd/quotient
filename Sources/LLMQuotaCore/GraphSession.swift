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
        if let d = try? JSONEncoder().encode(m) { ICloudSafe.write(d, to: file) }
    }

    static func key(_ graph: String, _ platform: Platform) -> String {
        graph + "|" + platform.rawValue
    }

    /// 这个（图，平台）该用哪种模式。
    ///
    /// 不是图内节点就 `.fresh` —— 用 `mode(repo:platform:graphID:)`
    /// 才拿得到普通任务的会话复用。这个重载留给只知道 graphID 的调用方。
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


public extension GraphSession {

    /// 普通任务也复用会话 —— 按「仓库 × 平台」记。
    ///
    /// ## 为什么以前不行，现在行了
    ///
    /// 以前普通任务一任务一个 worktree，跑完就删。恢复出来的会话
    /// 工作目录已经不存在，agent 会在一个空气目录里找上次的改动 ——
    /// 所以那时候只能 `.fresh`。
    ///
    /// 工作区改成按「仓库 × 平台」固定复用之后，cwd 稳定了，
    /// 这个前提就没了。于是 Claude 干这个仓库永远接同一个会话：
    /// 它记得这仓库长什么样、上次为什么那么改、哪个坑踩过。
    ///
    /// **这是省掉重读的那一半。** 另一半（仓库地图）只是让重读便宜些，
    /// 治不了重读本身。
    ///
    /// 按仓库分而不是全局一个会话：两个项目的上下文混在一起，
    /// agent 会把 A 项目的约定用到 B 项目上 —— 那比重读还糟。
    static func mode(repo: String, platform: Platform, graphID: String?) -> Mode {
        // 图内节点仍然按图记：一张图跨平台接力，靠的就是图级会话。
        if graphID != nil { return mode(graphID: graphID, platform: platform) }
        let k = "repo:" + NSString(string: repo).expandingTildeInPath
            + "|" + platform.rawValue
        var m = load()
        if let existing = m[k] { return .resume(existing) }
        let id = UUID().uuidString
        m[k] = id
        save(m)
        return .create(id)
    }

    /// 会话废掉了（上下文塞满、CLI 报会话不存在）就丢掉重开。
    ///
    /// **必须有这条路。** 会话是会过期和撑爆的，没有作废机制的话，
    /// 一个坏会话会让这个仓库这个平台**永久跑不起来** ——
    /// 而表现是每次都失败，看不出原因在会话上。
    static func forget(repo: String, platform: Platform) {
        var m = load()
        m.removeValue(forKey: "repo:" + NSString(string: repo).expandingTildeInPath
                      + "|" + platform.rawValue)
        save(m)
    }
}
