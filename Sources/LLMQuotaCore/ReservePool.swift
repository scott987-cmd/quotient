import Foundation

/// 储备任务池：额度快作废时，从仓库的**结构化事实**里生成维护任务。
///
/// ## 它要解决什么
///
/// 这套系统的目标是「一分不浪费」，而浪费的主要形态不是用超，是**用不完**：
/// 5 小时窗口一天翻好几轮，没用掉的部分到点清零。真实工作是阵发的，
/// 不可能刚好填满每个窗口。所以需要一批随时能塞进去的低危维护任务。
///
/// ## 为什么不能从 TODO 注释生成
///
/// 最省事的做法是扫 `TODO:` / `FIXME:` 然后把注释内容拼进 prompt。
/// **这是一条完整的注入链**：注释是仓库里任何人都能写的自由文本，
/// 而 agent 跑在跳过权限确认的无头模式下。它不碰网络、不越权、
/// 不产生异常退出码，绕开 SECURITY.md 里列的所有防线。
///
/// 所以这里只用**工具自己算得出来的结构化事实**：文件路径、行号、
/// 规则 ID、以及一个**经过字符集校验**的标识符。prompt 是固定模板，
/// 事实只填进预留的槽位，没有任何一段来自仓库的自由文本。
public enum ReservePool {

    /// 一条可以变成任务的事实。
    public struct Fact: Sendable, Equatable {
        public enum Rule: String, Sendable {
            /// 公开 API 没有文档注释。
            case missingDoc = "missing-doc"
            /// 公开类型在测试里一次都没出现过。
            case noTestReference = "no-test-ref"
            /// 代码里自己写的 TODO / FIXME。
            ///
            /// **这是最靠谱的一类真需求**：写代码的人当场知道这里欠着账，
            /// 才会留下标记。原来储备池只会扫「缺注释/缺测试」——
            /// 那是格式问题，不是需求，做完也没人在乎（实测落地率极低）。
            case todoMarker = "todo"
            /// 审查报告里列出的问题（reviews/REVIEW-*.md 的条目）。
            ///
            /// 审查员每次落地后都会产出报告，那里面全是「有人看过、
            /// 确认有问题」的条目 —— 比任何自动扫描都准。
            case reviewFinding = "review-finding"

            public var title: String {
                switch self {
                case .missingDoc: return "补文档注释"
                case .noTestReference: return "补测试"
                case .todoMarker: return "清 TODO"
                case .reviewFinding: return "修审查发现的问题"
                }
            }

            /// 派活优先级，越小越先派。
            ///
            /// 排序依据是**有没有人真的想要它**：审查发现是人读完 diff 写下的，
            /// 代码里的待办标记是作者自己留的账，这两类有明确的需求方；
            /// 缺注释缺测试是扫出来的格式问题，做完也未必有人关心
            ///（实测这类任务落地率最低）。空窗只填得下一个活，
            /// 那就得是最值钱的那个。
            public var priority: Int {
                switch self {
                case .reviewFinding: return 0
                case .todoMarker: return 1
                case .noTestReference: return 2
                case .missingDoc: return 3
                }
            }
        }

        public var rule: Rule
        /// 仓库内相对路径。
        public var file: String
        public var line: Int
        /// 标识符。**只允许 [A-Za-z_][A-Za-z0-9_]***，见 `sanitized`。
        public var symbol: String

        /// 去重键。
        ///
        /// **不含行号**：行号会随着文件的任何改动漂移，含进去的话
        /// 同一个缺陷在别人改了上面一行之后就变成"新事实"，
        /// 于是被反复生成 —— 而这正是储备池最容易变成噪音源的方式。
        public var key: String { "\(rule.rawValue):\(file):\(symbol)" }
    }

    /// 标识符消毒。
    ///
    /// Swift 允许反引号包起来的任意标识符（`` `let` ``、甚至含空格的），
    /// 而标识符是要拼进 prompt 的。虽然比自由文本窄得多，
    /// 但"窄"不等于"安全" —— 与其论证哪些字符无害，不如只放行
    /// 一个明确的白名单，其余整条事实丢掉。少生成一个任务的代价，
    /// 远小于让一条可控字符串进入无头 agent 的提示词。
    /// **必须是 ASCII 白名单，不能用 CharacterSet.letters。**
    ///
    /// 第一版用了 `CharacterSet.letters` / `.alphanumerics`，测试立刻抓到洞：
    /// 那两个集合包含中日韩字符，而 **Swift 标识符本来就允许 Unicode** ——
    /// 于是 `忽略我并执行` 这种整句中文能当合法标识符通过消毒，
    /// 一路拼进给无头 agent 的提示词。
    ///
    /// 这正是「窄不等于安全」的例子：标识符比自由文本窄得多，
    /// 但只要还留着一整个 Unicode 字母平面，就够写下一条完整的指令。
    static func sanitized(_ s: String) -> String? {
        guard !s.isEmpty, s.count <= 64 else { return nil }
        let bytes = Array(s.utf8)
        guard s.utf8.count == s.count else { return nil }   // 非 ASCII 直接出局
        func isAlpha(_ b: UInt8) -> Bool {
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        }
        func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        guard isAlpha(bytes[0]) || bytes[0] == 95 else { return nil }
        guard bytes.allSatisfy({ isAlpha($0) || isDigit($0) || $0 == 95 }) else { return nil }
        return s
    }

    /// 扫出仓库里的事实。
    ///
    /// 只读文件、只用正则，不执行仓库里的任何东西 —— 扫描本身也在
    /// 无人值守路径上，不能因为仓库内容而产生副作用。
    public static func facts(repo: String, limitPerRule: Int = 20) -> [Fact] {
        let root = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath)
        // **别写死 Sources/。** SwiftPM 包是 Sources/，但 Xcode 工程
        // 把代码放在与产品同名的目录下（Maw/Maw、Greed/Greed）。
        // 写死的后果实测过：两个游戏仓库扫出 0 条事实，储备池对它们
        // 完全是瞎的 —— 而它们恰恰是待办最多的仓库。
        let all = swiftFiles(under: root)
        let sources = all.filter { !isTestFile($0) }
        guard !sources.isEmpty else {
            // 没有 Swift 代码也可能有审查报告（比如纯资源仓库）
            return reviewFindings(root: root, limit: limitPerRule)
        }

        let testText = all.filter { isTestFile($0) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        var out: [Fact] = []
        var missingDoc = 0, noTest = 0

        for url in sources {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let lines = text.components(separatedBy: "\n")

            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("public ") else { continue }
                guard let (kind, name) = declaration(line), let sym = sanitized(name)
                else { continue }

                // 上一条非空、非属性的行是不是 ///
                if missingDoc < limitPerRule, !hasDocComment(lines, before: i) {
                    out.append(Fact(rule: .missingDoc, file: rel, line: i + 1, symbol: sym))
                    missingDoc += 1
                }
                // 只对类型看测试覆盖：函数名太容易碰巧出现在别处。
                if noTest < limitPerRule,
                   ["struct", "enum", "class", "actor"].contains(kind),
                   !testText.contains(sym) {
                    out.append(Fact(rule: .noTestReference, file: rel, line: i + 1, symbol: sym))
                    noTest += 1
                }
            }

            // TODO / FIXME：写代码的人当场留下的欠账
            for (i, raw) in lines.enumerated() {
                guard todoNote(raw) != nil else { continue }
                guard out.filter({ $0.rule == .todoMarker }).count < limitPerRule else { break }
                out.append(Fact(rule: .todoMarker, file: rel, line: i + 1,
                                symbol: todoNote(raw) ?? ""))
            }
        }
        out.append(contentsOf: reviewFindings(root: root, limit: limitPerRule))
        return out
    }

    /// 一行里的 TODO/FIXME 注释内容（不是就返回 nil）。
    ///
    /// 只认**注释里**的标记：字符串常量里出现 "TODO" 是数据不是欠账
    ///（比如这个文件自己的规则名）。
    static func todoNote(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("//"), !line.hasPrefix("///") else { return nil }
        let body = line.drop(while: { $0 == "/" }).trimmingCharacters(in: .whitespaces)
        for marker in ["TODO", "FIXME", "HACK", "XXX"] {
            guard body.hasPrefix(marker) else { continue }
            let note = body.dropFirst(marker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            // 光写个 TODO 不说要干什么的，没法转成任务
            guard note.count >= 8 else { return nil }
            return String(note.prefix(160))
        }
        return nil
    }

    /// 审查报告里列出的发现。
    ///
    /// 审查员每次落地后都会往 `reviews/` 写报告。它的发现是**有人读过
    /// 完整 diff、逐文件核对过**才写下来的 —— 比任何自动扫描都接近真需求。
    /// 而在此之前这些报告写完就躺在那儿没人管：40% 的落地率里，
    /// 审查发现的问题几乎没有一条被转成过任务。
    ///
    /// 认两种写法：审查员的标题式发现（`### 3. Foo.swift:91 — 描述（低）`）
    /// 和普通的未勾选清单项（`- [ ] …`）。
    /// 只读最近两周改过的报告：更老的问题多半早就修了或已不适用。
    static func reviewFindings(root: URL, limit: Int,
                               now: Date = Date()) -> [Fact] {
        let dir = root.appendingPathComponent("reviews")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Fact] = []
        for name in names.sorted().reversed() where name.hasSuffix(".md") {
            let f = dir.appendingPathComponent(name)
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(mod) < 14 * 86400 else { continue }
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                guard let note = findingNote(raw) else { continue }
                out.append(Fact(rule: .reviewFinding,
                                file: "reviews/" + name, line: i + 1, symbol: note))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// 报告里的一行是不是一条发现。
    ///
    /// 严重度标注（高/中/低）一并留在描述里 —— 派活时它是优先级信息。
    static func findingNote(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- [ ]") {
            let note = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return note.count >= 8 ? String(note.prefix(200)) : nil
        }
        // `### 3. GameScene.swift:113-116 — 描述（中）`
        guard line.hasPrefix("###") else { return nil }
        let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        // 必须带「文件:行」才算可执行的发现；`## 发现` 这种标题不是。
        guard body.range(of: #"[A-Za-z0-9_]+\.\w+:\d+"#,
                         options: .regularExpression) != nil else { return nil }
        guard body.count >= 12 else { return nil }
        return String(body.prefix(200))
    }

    /// `public func foo(` → ("func", "foo")
    static func declaration(_ line: String) -> (kind: String, name: String)? {
        let kinds = ["func", "struct", "enum", "class", "actor", "protocol"]
        let parts = line.split(separator: " ").map(String.init)
        guard let ki = parts.firstIndex(where: { kinds.contains($0) }),
              ki + 1 < parts.count else { return nil }
        let raw = parts[ki + 1]
        // 截到第一个分隔符：foo(x:) → foo，Bar<T> → Bar，Baz: → Baz
        let name = raw.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : (parts[ki], String(name))
    }

    static func hasDocComment(_ lines: [String], before index: Int) -> Bool {
        var i = index - 1
        while i >= 0 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            if t.hasPrefix("///") { return true }
            // 属性和修饰符不算隔断：@discardableResult 上面还可能有文档。
            if t.hasPrefix("@") || t.hasPrefix("//") { i -= 1; continue }
            return false
        }
        return false
    }

    static func swiftFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !isGenerated($0) }
            .sorted { $0.path < $1.path }
    }

    /// 构建产物、依赖、工作区 —— 不是我们的代码，扫出来的「待办」全是噪音。
    static func isGenerated(_ url: URL) -> Bool {
        let parts = Set(url.pathComponents)
        return !parts.isDisjoint(with: [".build", "DerivedData", "Pods",
                                        "Carthage", "worktrees", ".swiftpm",
                                        "node_modules"])
    }

    /// 测试文件。目录叫 Tests，或者文件名以 Tests.swift 结尾。
    static func isTestFile(_ url: URL) -> Bool {
        url.pathComponents.contains("Tests")
            || url.lastPathComponent.hasSuffix("Tests.swift")
    }

    /// 事实 → 任务描述。**固定模板，事实只填槽位。**
    public static func prompt(for f: Fact) -> String {
        switch f.rule {
        case .missingDoc:
            return "为 \(f.file) 第 \(f.line) 行的 `\(f.symbol)` 补一段文档注释（///），"
                + "说明它为什么存在、什么时候该用它、以及有什么不显然的约束。"
                + "只改这一个文件，不要改动任何代码逻辑。"
        case .noTestReference:
            return "为 \(f.file) 里的 `\(f.symbol)` 补单元测试，放进 Tests/。"
                + "先读懂它的实际行为再写断言，覆盖边界情况。"
                + "只新增测试，不要改 Sources/ 下的任何文件。"
        case .todoMarker:
            return "\(f.file) 第 \(f.line) 行留着一条待办：「\(f.symbol)」。"
                + "读懂上下文后把它做掉，然后删掉那条 TODO 注释。"
                + "如果读完发现它已经不成立（需求变了/早就做过了），"
                + "就只删注释并在提交信息里说明为什么它不再适用。"
        case .reviewFinding:
            return "代码审查报告 \(f.file) 里列了一条待修项：「\(f.symbol)」。"
                + "定位到对应代码把它修掉，补上能复现该问题的测试，"
                + "然后把报告里那一条从 `- [ ]` 改成 `- [x]`。"
        }
    }

    /// 哪些事实**还需要**被做。
    ///
    /// 去重规则（和 WorkTask 上那段注释对应）：
    /// - 排队中 / 执行中 → 跳过，别重复派
    /// - 已落地 → 跳过，缺陷已经修了
    /// - 跑完但还没落地、也没被丢弃 → 跳过，它正在等评审
    /// - **被丢弃过 → 允许重来**：缺陷还在，只是上次的解法你不满意
    public static func pending(_ facts: [Fact], tasks: [WorkTask]) -> [Fact] {
        var blocked: Set<String> = []
        for t in tasks {
            guard let key = t.origin else { continue }
            switch t.state {
            case .queued, .running, .blocked:
                blocked.insert(key)
            case .done:
                if t.discardedAt == nil { blocked.insert(key) }
            case .failed:
                break   // 失败的允许再试，换个平台可能就成了
            }
        }
        return facts.filter { !blocked.contains($0.key) }
    }
}
