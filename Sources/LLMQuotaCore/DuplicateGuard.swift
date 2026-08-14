import Foundation

/// 入队时查一下：这活是不是已经有人在做、或者刚做完。
///
/// # 为什么需要它
///
/// 这个工具存在的理由是「一分不浪费」，而它自己没有查重。
/// 实测代价（同一晚）：
///
///     b6aa5e7f    为 LLMQuotaCore 里已有的 WasteMeter 增加一个命令行入口 llmq waste…
///     42266d0fs1  在 LLMQuotaCore 仓库里为已有的 WasteMeter 增加命令行入口 llmq waste…
///
/// 两条都跑到 done，改的是**同样四个文件**（README.md、WasteMeter.swift、
/// main.swift、CoreTests.swift）。两份额度、两份实现，最后还得有人挑一个丢一个。
///
/// # 怎么判
///
/// **不靠笼统的文本相似度。** 中文提示词里「增加」「命令行入口」「测试」
/// 这类词到处都是，按整段文本算相似度会把一堆不相干的活判成重复 ——
/// 而误报的代价是拦住真活，比漏报更让人烦。
///
/// 真正有区分度的是**代码标识符和文件路径**：`WasteMeter`、
/// `Sources/llmq/main.swift`、`SnapshotStore.loadAll` —— 两个任务同时提到
/// 两个以上这种词，基本就是在动同一块地方。文本相似度只作为第二判据。
public enum DuplicateGuard {

    public struct Match: Sendable {
        public var taskID: String
        public var state: WorkTask.State
        public var prompt: String
        /// 两边都提到的标识符/路径。**这是给人看的证据，不是分数。**
        public var sharedSymbols: [String]
        public var textSimilarity: Double
        public var why: String
    }

    /// 多久以内的完成任务还算「刚做过」。
    ///
    /// 太短会漏（昨天刚做的今天又提一遍），太长会误报（三个月前做过的
    /// 同名重构，现在是该做第二遍了）。一周是个能解释的折中。
    public static let recentWindow: TimeInterval = 7 * 86400

    /// 判成重复要几个共同标识符。
    ///
    /// 1 个太松：两个任务同时提到 `main.swift` 完全正常，这个仓库里
    /// 什么活都可能碰它。2 个就已经很具体了。
    public static let symbolThreshold = 2

    /// 纯文本相似度的门槛。只在标识符不够时兜底，所以定得高。
    public static let textThreshold = 0.55

    // MARK: - 查

    public static func matches(
        prompt: String, repo: String, excluding selfID: String? = nil,
        in tasks: [WorkTask], now: Date = Date()
    ) -> [Match] {
        let mySymbols = symbols(in: prompt)
        let myTokens = tokens(in: prompt)
        guard !myTokens.isEmpty else { return [] }

        var out: [Match] = []
        for t in tasks {
            guard t.id != selfID else { continue }
            guard sameRepo(t.repo, repo) else { continue }
            // 只比「还活着的」和「刚做完的」。被丢弃的不算 ——
            // 那恰恰说明这个方向需要重做一遍。
            switch t.state {
            case .queued, .running, .blocked:
                break
            case .done:
                guard t.discardedAt == nil,
                      let end = t.endedAt ?? t.startedAt,
                      now.timeIntervalSince(end) <= recentWindow else { continue }
            case .failed:
                continue
            }

            let shared = Array(mySymbols.intersection(symbols(in: t.prompt))).sorted()
            let sim = jaccard(myTokens, tokens(in: t.prompt))

            let hitBySymbols = shared.count >= symbolThreshold
            let hitByText = sim >= textThreshold
            guard hitBySymbols || hitByText else { continue }

            let why: String
            if hitBySymbols {
                // **证据要挑最具体的先说。**
                // 按字母序取前几个的话，人看到的可能是
                // 「都动 LLMQuotaCore、PlansStore」—— 前者是仓库名，
                // 几乎每条提示词都有，等于没说。文件路径最具体，排最前。
                let ranked = shared.sorted { a, b in
                    let pa = a.contains("/"), pb = b.contains("/")
                    if pa != pb { return pa }
                    return a.count > b.count
                }
                why = "都动 " + ranked.prefix(4).joined(separator: "、")
                    + (shared.count > 4 ? " 等 \(shared.count) 处" : "")
            } else {
                why = "提示词高度相似（\(Int(sim * 100))%）"
            }
            out.append(Match(taskID: t.id, state: t.state, prompt: t.prompt,
                             sharedSymbols: shared, textSimilarity: sim, why: why))
        }
        // 还在进行的排前面 —— 那是「现在就在烧额度」，比「上周做过」更急。
        return out.sorted {
            let liveA = $0.state != .done, liveB = $1.state != .done
            if liveA != liveB { return liveA }
            return $0.sharedSymbols.count > $1.sharedSymbols.count
        }
    }

    static func sameRepo(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path
            == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    // MARK: - 抽标识符

    /// 从提示词里抽出有区分度的东西：文件路径、驼峰标识符、`llmq xxx` 子命令。
    ///
    /// 刻意**不抽**普通英文单词和中文词 —— 那些在这个仓库的任务描述里
    /// 满天飞，抽了只会制造误报。
    static func symbols(in text: String) -> Set<String> {
        var out: Set<String> = []
        let seps = CharacterSet(charactersIn: " \t\n\r，。、；：（）()「」【】\"'`*#>-—…!?！？")
        let parts = text.components(separatedBy: seps).filter { !$0.isEmpty }

        for raw in parts {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            guard w.count >= 3 else { continue }

            // 文件路径：带 / 且有扩展名，或以已知源码目录开头。
            if w.contains("/"), w.contains(".") || w.hasPrefix("Sources") || w.hasPrefix("Tests") {
                out.insert(normalizePath(w))
                continue
            }
            // 驼峰标识符：至少两个大写字母开头的段，比如 WasteMeter、SnapshotStore。
            if isCamelIdentifier(w) {
                // `SnapshotStore.loadAll()` → 也收 `SnapshotStore`，
                // 这样「提到同一个类型但方法不同」也能对上。
                out.insert(w.replacingOccurrences(of: "()", with: ""))
                if let head = w.split(separator: ".").first, isCamelIdentifier(String(head)) {
                    out.insert(String(head))
                }
                continue
            }
        }

        // `llmq waste` 这种子命令：两个词才有意义，单独一个 llmq 没区分度。
        let lower = text.lowercased()
        var idx = lower.startIndex
        while let r = lower.range(of: "llmq ", range: idx..<lower.endIndex) {
            let rest = lower[r.upperBound...]
            let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            if word.count >= 3 { out.insert("llmq " + word) }
            idx = r.upperBound
            if idx >= lower.endIndex { break }
        }
        return out
    }

    static func isCamelIdentifier(_ w: String) -> Bool {
        guard let first = w.first, first.isUppercase else { return false }
        guard w.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "(" || $0 == ")" })
        else { return false }
        // 至少要有第二个大写字母，否则 "Sources" 这种普通词也会中。
        guard w.dropFirst().contains(where: { $0.isUppercase }) else { return false }
        // **全大写的排除**：README / TODO / API / JSON 这类缩写词到处都是，
        // 收进来只会让「共同标识符」这个判据失去区分度 ——
        // 而它是整个查重唯一靠得住的信号。
        return w.contains { $0.isLowercase }
    }

    /// 路径统一成相对形式再比 —— 一个写绝对路径、一个写相对路径是常事。
    static func normalizePath(_ p: String) -> String {
        for marker in ["Sources/", "Tests/", "Scripts/", "Tools/"] {
            if let r = p.range(of: marker) { return String(p[r.lowerBound...]) }
        }
        return (p as NSString).lastPathComponent
    }

    // MARK: - 文本相似度

    /// 分词。中文没有空格，所以按**字符二元组**切；英文按词切。
    ///
    /// 不这么做的话，两段中文提示词的「词」几乎不会重合，
    /// 相似度永远接近 0，这条兜底判据等于不存在。
    static func tokens(in text: String) -> Set<String> {
        var out: Set<String> = []
        var cjkRun: [Character] = []

        func flushCJK() {
            if cjkRun.count >= 2 {
                for i in 0..<(cjkRun.count - 1) {
                    out.insert(String(cjkRun[i...(i + 1)]))
                }
            } else if let c = cjkRun.first {
                out.insert(String(c))
            }
            cjkRun.removeAll()
        }

        var word = ""
        for ch in text.lowercased() {
            if isCJK(ch) {
                if !word.isEmpty { out.insert(word); word = "" }
                cjkRun.append(ch)
            } else if ch.isLetter || ch.isNumber || ch == "." || ch == "/" || ch == "_" {
                flushCJK()
                word.append(ch)
            } else {
                flushCJK()
                if word.count >= 2 { out.insert(word) }
                word = ""
            }
        }
        flushCJK()
        if word.count >= 2 { out.insert(word) }
        return out
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
