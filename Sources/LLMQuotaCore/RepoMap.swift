import Foundation

/// 仓库结构地图：一页纸讲清楚「这个仓库长什么样」。
///
/// ## 为什么要它
///
/// 每个任务都开一个全新的 worktree，所以每个 agent 都是从零开始认路。
/// 它头几步必然是 `ls`、`grep`、读几个文件 —— 每次都重来一遍，
/// 而且**每个 agent 摸出来的地图还不一样**，接力时对不上。
///
/// 更硬的一条：有些执行器**根本读不了文件**。MiniMax 走 mmx，只能文本进出，
/// 你不塞进提示词的东西它就看不见。Greed 那六份项目评审全是「材料不足 ——
/// 评审正文没给我看」，就是这么来的：它拿到了文件清单，拿不到文件内容，
/// 于是用一整轮额度产出了六份「我看不见」。
///
/// 所以地图必须由**派活方**生成并拼进提示词，不能指望 agent 自己去看。
/// 这样 Qwen / Kimi / GLM / MiniMax 一视同仁，不依赖谁认不认 CLAUDE.md。
///
/// ## 为什么不做真正的调用图
///
/// 调用图要解析类型、跟踪引用，Swift 这边意味着 SourceKit —— 一个重依赖，
/// 而且慢到不适合每次派活都跑。而实测下来 agent 卡住的地方几乎都不是
/// 「A 调了 B 吗」，是「这个仓库有哪些文件、各自管什么、我该改哪个」。
/// 一份带符号名的目录清单就能答完这些，成本是正则扫一遍。
///
/// 需要看具体实现时，能读文件的 agent 自己会去读 —— 地图给的是**去哪读**。
public enum RepoMap {

    /// 地图最多多少字符。超了截断。
    ///
    /// 3 万字符大约 1 万 token —— 对一次任务来说不算贵，
    /// 但也够装下上百个文件的骨架了。真超了说明仓库太大，
    /// 那种情况下前面的（按路径排序，源码目录在前）比后面的有用。
    public static let maxCharacters = 30_000

    // MARK: - 对外

    /// 取这个仓库的地图，能用缓存就用缓存。
    ///
    /// 缓存键是 git HEAD 的 commit hash：仓库没动过就不重扫。
    /// 拿不到 hash（不是 git 仓库、或者一个提交都没有）就每次现扫 ——
    /// 现扫也就几十毫秒，不值得为它引入别的失效机制。
    public static func text(repo: String) -> String? {
        let path = NSString(string: repo).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        if let head = headHash(repo: path), let hit = cached(repo: path, head: head) {
            return hit
        }
        let map = build(repo: path)
        if let head = headHash(repo: path) { store(repo: path, head: head, text: map) }
        return map
    }

    /// 拼进提示词的那一段。**明确告诉 agent 这是什么、别把它当任务。**
    ///
    /// 不加这个说明的话，见过 agent 把地图里列出的文件名当成「要我创建的文件」。
    public static func briefing(repo: String) -> String {
        guard let map = text(repo: repo), !map.isEmpty else { return "" }
        return """


        ---
        ## 这个仓库长什么样（自动生成，供你认路，不是任务的一部分）

        下面是文件清单和每个文件里的主要类型/函数名。它只告诉你**去哪找**，
        不是实现细节 —— 要看具体代码，自己打开对应文件。
        清单里已有的东西**不要重复创建**；要加新东西，先看看有没有该放进去的现成文件。

        \(map)
        ---

        """
    }

    // MARK: - 生成

    static func build(repo: String) -> String {
        let root = URL(fileURLWithPath: repo)
        let files = sourceFiles(under: root)
        guard !files.isEmpty else { return "" }

        var lines: [String] = []
        var lastDir = ""
        for f in files {
            let rel = f.path.replacingOccurrences(of: repo + "/", with: "")
            let dir = (rel as NSString).deletingLastPathComponent
            if dir != lastDir {
                lines.append("")
                lines.append(dir.isEmpty ? "（仓库根目录）" : dir + "/")
                lastDir = dir
            }
            let name = (rel as NSString).lastPathComponent
            let syms = symbols(in: f)
            if syms.isEmpty {
                lines.append("  " + name)
            } else {
                lines.append("  " + name + " — " + syms.joined(separator: ", "))
            }
        }

        var out = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maxCharacters {
            out = String(out.prefix(maxCharacters))
                + "\n\n（太长，后面截断了 —— 需要完整清单自己 ls）"
        }
        return out
    }

    /// 值得进地图的源码文件。
    ///
    /// **别只扫 .swift。** 这套东西要给游戏、资产包、工具仓库通用，
    /// 而那些仓库里管事的可能是 .md（比如 STATUS.md 写着还差什么）
    /// 或者 project.yml（工程结构）。
    static let interestingExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cpp", "py", "js", "ts", "tsx", "sh",
    ]
    /// 单独点名的文件：不看后缀，见到就收。
    /// 这些是「下一个人最该先读的」，恰恰也最容易被后缀过滤掉。
    static let alwaysInclude: Set<String> = [
        "README.md", "STATUS.md", "AGENTS.md", "CLAUDE.md",
        "Package.swift", "project.yml",
    ]

    static func sourceFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { url in
                guard !isNoise(url) else { return false }
                return alwaysInclude.contains(url.lastPathComponent)
                    || interestingExtensions.contains(url.pathExtension)
            }
            .sorted { $0.path < $1.path }
    }

    /// 构建产物、依赖、别人的代码、agent 自己的工作区 —— 全是噪音。
    ///
    /// `worktrees` 尤其重要：agent 的工作区就在仓库里，不排掉的话
    /// 地图会把同一份代码列上十几遍，还全是过期的分支。
    static func isNoise(_ url: URL) -> Bool {
        let parts = Set(url.pathComponents)
        return !parts.isDisjoint(with: [
            ".build", ".git", "DerivedData", "Pods", "Carthage",
            "worktrees", ".swiftpm", "node_modules", "vendor", "Frameworks",
        ])
    }

    // MARK: - 符号

    /// 一个文件里的顶层符号名。
    ///
    /// 正则扫，不解析 —— 要的是「这个文件里有什么」，不是精确的语法树。
    /// 漏一两个、或者把注释里的字当成声明，代价都只是地图上多一行少一行；
    /// 而上 SourceKit 的代价是一个重依赖加每次派活多花几秒。
    static func symbols(in file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        // Markdown 用标题当符号 —— STATUS.md 的小节名比「它有几个函数」有用得多。
        if file.pathExtension == "md" {
            return text.split(separator: "\n")
                .filter { $0.hasPrefix("## ") }
                .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                .prefix(8).map { $0 }
        }
        var out: [String] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 注释里的示例代码不算 —— 这个仓库注释写得多，不排会满屏噪音
            if line.hasPrefix("//") || line.hasPrefix("*") || line.hasPrefix("#") { continue }
            guard let name = declaredName(line) else { continue }
            if seen.insert(name).inserted { out.append(name) }
            if out.count >= 24 { out.append("…"); break }
        }
        return out
    }

    static let declKeywords = ["struct", "class", "enum", "protocol", "actor",
                               "extension", "func", "typealias"]

    /// 这一行声明了什么。声明不了就返回 nil。
    static func declaredName(_ line: String) -> String? {
        var words = line.split(separator: " ").map(String.init)
        // 吃掉修饰词，直到撞见声明关键字
        while let first = words.first, !declKeywords.contains(first) {
            let modifiers = ["public", "private", "internal", "fileprivate", "open",
                             "final", "static", "class", "override", "@objc",
                             "@MainActor", "nonisolated", "mutating", "convenience",
                             "required", "indirect", "package"]
            // `class` 既是修饰词（class func）又是关键字 —— 看下一个词决定
            if first == "class" {
                if words.count > 1 && ["func", "var", "let"].contains(words[1]) {
                    words.removeFirst(); continue
                }
                break
            }
            guard modifiers.contains(first) else { return nil }
            words.removeFirst()
        }
        guard words.count >= 2, declKeywords.contains(words[0]) else { return nil }
        // 名字到第一个分隔符为止：`foo(bar:)` → foo，`Baz<T>` → Baz，`A: B` → A
        let name = words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - 缓存

    static var cacheDir: URL {
        Paths.appSupport.appendingPathComponent("repomap", isDirectory: true)
    }

    /// 缓存文件名用仓库路径的哈希，不用路径本身 —— 路径里有 `/`，
    /// 而且可能很长。加上 head 就能同时当版本号。
    static func cacheFile(repo: String, head: String) -> URL {
        let key = String(abs(repo.hashValue), radix: 36) + "-" + head.prefix(12)
        return cacheDir.appendingPathComponent(key + ".txt")
    }

    static func cached(repo: String, head: String) -> String? {
        try? String(contentsOf: cacheFile(repo: repo, head: head), encoding: .utf8)
    }

    static func store(repo: String, head: String, text: String) {
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
        try? text.write(to: cacheFile(repo: repo, head: head),
                        atomically: true, encoding: .utf8)
    }

    /// 当前 HEAD 的 commit hash。**一个提交都没有时返回 nil** ——
    /// 那种仓库连 worktree 都开不了，更谈不上缓存版本。
    static func headHash(repo: String) -> String? {
        let r = Proc.run("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"],
                         cwd: repo, env: [:], timeout: 10)
        let h = r.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        // 一个提交都没有时 git 报错、stdout 是空的 —— 那种仓库连 worktree
        // 都开不了，没有版本可缓存。
        return h.isEmpty ? nil : h
    }
}
