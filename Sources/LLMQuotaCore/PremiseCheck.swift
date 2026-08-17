import Foundation

/// 派活前核一遍前提：任务是在**定义那一刻的世界**里写的，执行发生在很久以后。
///
/// ## 这东西对应的真实浪费
///
/// 老板手写的丢弃理由（70 个未派任务，2026-08-17）：
///
///   13 × 「基线错了：从 main 开工，而 main 上没有任何今天的游戏改动」
///    3 × 「过时：build-app.sh 已大改，这条任务的前提不在了」
///
/// 两类都是同一件事：任务描述里写着「前置事实（已完成，直接用）：
/// `Maw/Resources/Creatures/` 下有 creature-s1 …」，而真到执行的时候
/// 那些东西不在派活的基线上。agent 于是对着一个不存在的前提开工，
/// 跑完一整轮产出垃圾，最后由人一条条丢掉。
///
/// ## 两种「文件不存在」的处理必须相反
///
/// 这是这个模块存在的全部理由：
///
/// - **在 main 上没有，但在某条还没合的 agent 分支上有** → 前提**迟早成立**，
///   这个任务该**等**，等那条分支落地。这正是那 13 个「基线错了」的真相：
///   它们不是坏任务，是**派早了**。
/// - **main 和所有分支上都没有** → 前提真的不在了（比如那三个
///   「build-app.sh 已大改」），跑它必然产出垃圾，该作废。
///
/// 把第一种当成第二种，会丢掉好任务；把第二种当成第一种，会永远等一个
/// 不会到来的前提。所以必须分开判。
///
/// ## 判据只用机械手段
///
/// 不调推理平台。核前提这件事一旦要花额度，就会为了省额度而跳过 ——
/// 而它的价值恰恰在于**每次派活都做**。
public enum PremiseCheck {

    /// 核验结果。
    public enum Result: Sendable, Equatable {
        /// 前提都在，可以派。
        case ok
        /// 前提暂时不在，但在某条未合分支上 —— 等它落地。
        case notYet(missing: [String], onBranches: [String])
        /// 前提到处都找不到 —— 作废，跑它只会产出垃圾。
        case gone(missing: [String])
    }

    /// 从提示词里摘出「前置事实」段落里提到的路径。
    ///
    /// 只认**前置段落里**的路径，不认整段提示词里所有反引号。理由：
    /// 提示词经常提到「要新建 `Foo.swift`」——那个文件本来就不该存在，
    /// 拿它去核会把每个新建任务都判成前提不成立。
    ///
    /// 段落起点认这几种写法（实测都在用）：「前置事实」「前置：」「基线：」。
    /// 认不出前置段落就返回空 —— 宁可不核，也不能瞎核。
    public static func premisePaths(in prompt: String) -> [String] {
        let markers = ["前置事实", "前置：", "前置:", "基线：", "基线:"]
        guard let start = markers.compactMap({ prompt.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })?.lowerBound else { return [] }

        // 前置段落到哪儿结束：下一个空行，或者提示词结尾。
        // 不切段的话会把「要新建的文件」也算进来。
        let tail = String(prompt[start...])
        let section = tail.components(separatedBy: "\n\n").first ?? tail

        var out: [String] = []
        var rest = Substring(section)
        while let a = rest.firstIndex(of: "`") {
            let after = rest.index(after: a)
            guard after < rest.endIndex,
                  let b = rest[after...].firstIndex(of: "`") else { break }
            let token = String(rest[after..<b])
            rest = rest[rest.index(after: b)...]
            guard looksLikePath(token) else { continue }
            out.append(token)
        }
        return Array(Set(out)).sorted()
    }

    /// 这个反引号里的东西像不像一个仓库内路径。
    ///
    /// 要求带斜杠或者带已知后缀 —— 否则会把 `didMove(to:)` 这种
    /// 符号名当成文件去核，每次都判不存在。
    public static func looksLikePath(_ s: String) -> Bool {
        if s.contains(" ") || s.contains("(") { return false }
        let exts = [".swift", ".md", ".yml", ".yaml", ".sh", ".json",
                    ".py", ".png", ".jpg", ".mp3", ".plist", ".storekit"]
        if exts.contains(where: { s.hasSuffix($0) }) { return true }
        // 目录形式：`Maw/Resources/Creatures/`
        return s.contains("/") && !s.hasPrefix("http")
    }

    /// 核一个任务。
    public static func check(prompt: String, repo: String,
                             base: String = "main") -> Result {
        let paths = premisePaths(in: prompt)
        guard !paths.isEmpty else { return .ok }   // 没写前置就没什么可核的

        let root = NSString(string: repo).expandingTildeInPath
        var missing: [String] = []
        for p in paths where !exists(p, in: root, at: base) {
            missing.append(p)
        }
        guard !missing.isEmpty else { return .ok }

        // 分支上找得到吗 —— 决定「等」还是「废」
        var found: [String] = []
        for b in agentBranches(in: root) {
            if missing.contains(where: { exists($0, in: root, at: b) }) {
                found.append(b)
            }
        }
        return found.isEmpty
            ? .gone(missing: missing)
            : .notYet(missing: missing, onBranches: found.sorted())
    }

    /// 某个 ref 上有没有这个路径。目录形式（结尾带斜杠）按「下面有东西」算。
    public static func exists(_ path: String, in repo: String, at ref: String) -> Bool {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        let r = GitWorkspace.git(["cat-file", "-e", "\(ref):\(clean)"], in: repo)
        if r.exitCode == 0 { return true }
        // 目录：cat-file 对 tree 也返回 0，但保险起见再用 ls-tree 查一遍
        let ls = GitWorkspace.git(["ls-tree", "--name-only", "\(ref):\(clean)"],
                                  in: repo)
        return ls.exitCode == 0 && !ls.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
    }

    static func agentBranches(in repo: String) -> [String] {
        GitWorkspace.git(["for-each-ref", "--format=%(refname:short)",
                          "refs/heads/agent/"], in: repo)
            .stdout.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 给人 / 日志看的一句话。
    public static func describe(_ r: Result) -> String {
        switch r {
        case .ok:
            return "前提都在"
        case .notYet(let missing, let branches):
            return "前提还没落地：" + missing.prefix(3).joined(separator: "、")
                + "（在 " + branches.prefix(2).joined(separator: "、")
                + " 上，等它落地再开工 —— 现在派等于对着不存在的前提干活）"
        case .gone(let missing):
            return "前提不在了：" + missing.prefix(3).joined(separator: "、")
                + "（main 和所有 agent 分支上都找不到，跑它只会产出垃圾）"
        }
    }
}
