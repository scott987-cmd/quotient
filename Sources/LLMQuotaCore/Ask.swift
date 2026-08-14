import Foundation

/// agent 干到一半发现缺信息时的提问机制。
///
/// ## 为什么不解析 stdout
///
/// 最早的方案是让 agent 打印一行 `NEED-INPUT: <问题>`，runner 匹配前缀。
/// 对抗性评审把它否掉了，四个理由，每一个都足够单独否掉它：
///
/// 1. **自指污染**。这个字面量会出现在本仓库的注入代码、文档和测试里，
///    而我们最常派活的仓库就是它自己。任何一个 grep 到它、或者要给这个协议
///    补测试的任务，都会在总结里带上这个词，于是成功的运行被判成"卡住了"。
/// 2. **格式漂移**。模型会写成 `**NEED-INPUT:**`、包进代码块、用全角冒号、
///    或者把问题写成多行。前缀匹配一个都接不住。
/// 3. **退出不干净**。Qwen 在无头模式下会反复重试同一个工具调用直到超时
///    （Work.swift 里记过这个坑）；它可能已经说了要问什么，但进程不会正常退出。
/// 4. **没法带结构**。一次只能问一个问题，多个歧义点就要多轮往返，
///    每轮都要把代码重读一遍。
///
/// ## 换成文件哨兵，而且放在**工作区外面**
///
/// runner 给 agent 一个绝对路径，让它把问题写成 JSON。这个路径在
/// `~/Library/Application Support/LLMQuotaBar/asks/` 下，**不在 git worktree 里**。
///
/// 放外面这一点是必需的：放在 worktree 里的话，`git status --porcelain`
/// 会把它算成一个改动文件，于是 changedFiles 多一个、提交里混进一个
/// 不该存在的文件、"有没有产出"的判断也跟着错。
///
/// 而且检查这个文件**不看退出码** —— 就是为了接住上面第 3 条。
public struct Ask: Codable, Sendable {

    /// 这一轮提问的唯一标识。答案必须带着它回来。
    ///
    /// 没有它的话：任务问了 Q1，你三天没回；期间任务又跑了一轮问出 Q2；
    /// 你终于回答，答的是 Q1，系统却当成 Q2 的答案并进去。
    /// 这一轮是「问问题」还是「要审批」。
    ///
    /// 两者的答复处理**完全不同**：问题答完要把任务重新排队、让 agent 带着
    /// 答案接着干；审批答完活已经干完躺在工作区里，「放行」是**提交**，
    /// 重跑反而会把已有成果铲掉重来。
    ///
    /// 老数据没这个字段，解码时默认按 question 处理 —— 那是原来唯一的形态。
    public enum Kind: String, Codable, Sendable {
        case question
        case approval
    }
    public var kind: Kind = .question

    public var id: String
    public var taskID: String
    /// 哪台机器提的问。
    ///
    /// tasks.jsonl 是**本机私有**的，而 questions/answers 在 iCloud 上共享。
    /// 不记这个的话，另一台机器会读到不属于它的答案，在自己的任务库里找不到，
    /// 然后把文件归档掉 —— 真正的主人永远收不到答案，任务永久卡死。
    public var machineID: String
    /// 第几轮提问。用来封顶，见 `Policy.maxRounds`。
    public var round: Int
    public var askedAt: Date
    public var platform: Platform?
    /// 任务原文，手机上要显示，不然光看问题不知道在问什么。
    public var taskPrompt: String
    public var repoName: String

    /// 一次可以问多个。
    ///
    /// 硬性要求一次只能问一个的话，三个歧义点就是三轮往返，
    /// 每轮 agent 都要把同样的代码重读一遍 —— 光探索就烧三份额度。
    public var questions: [Question]

    /// agent 提问前已经做到哪儿了。恢复时靠它省掉重新探索。
    public var progressNote: String?
    public var wipCommit: String?

    public struct Question: Codable, Sendable, Identifiable {
        public var id: String
        public var text: String
        /// 有选项就在手机上渲染成按钮，一下点完，不用打字。
        public var options: [String]?
        /// agent 自己倾向于哪个。用户不想细看就直接采纳。
        public var suggestion: String?

        public init(id: String = UUID().uuidString.prefix(8).lowercased(),
                    text: String, options: [String]? = nil, suggestion: String? = nil) {
            self.id = String(id)
            self.text = text
            self.options = options
            self.suggestion = suggestion
        }
    }

    /// 容错解码。
    ///
    /// **默认值救不了合成解码器** —— 实测过：给属性写了 `= .question`，
    /// 缺这个键的老 JSON 照样抛 keyNotFound，整条 Ask 解不出来，
    /// 于是手机上那个问题凭空消失、任务永远卡在 blocked。
    ///
    /// 这个坑在这个项目里踩到第五次（TaskProfile 缺 classifiedAt、
    /// OfficeEvent 缺 excluded、PlatformReport 缺 role、ClusterPresence 缺 canReach）。
    /// 凡是会跨版本读写的结构，一律手写 decodeIfPresent。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .question
        id = try c.decode(String.self, forKey: .id)
        taskID = try c.decode(String.self, forKey: .taskID)
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 1
        askedAt = try c.decodeIfPresent(Date.self, forKey: .askedAt) ?? Date()
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        taskPrompt = try c.decodeIfPresent(String.self, forKey: .taskPrompt) ?? ""
        repoName = try c.decodeIfPresent(String.self, forKey: .repoName) ?? ""
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        progressNote = try c.decodeIfPresent(String.self, forKey: .progressNote)
        wipCommit = try c.decodeIfPresent(String.self, forKey: .wipCommit)
    }

    public init(id: String = UUID().uuidString.prefix(12).lowercased(),
                taskID: String, machineID: String, round: Int, askedAt: Date = Date(),
                platform: Platform?, taskPrompt: String, repoName: String,
                questions: [Question], progressNote: String? = nil,
                wipCommit: String? = nil, kind: Kind = .question) {
        self.kind = kind
        self.id = String(id)
        self.taskID = taskID
        self.machineID = machineID
        self.round = round
        self.askedAt = askedAt
        self.platform = platform
        self.taskPrompt = taskPrompt
        self.repoName = repoName
        self.questions = questions
        self.progressNote = progressNote
        self.wipCommit = wipCommit
    }

    public enum Policy {
        /// 一个任务最多问几轮。
        ///
        /// 不封顶的话会出现这种循环：你回一句「你看着办」，agent 跑完一整轮
        /// 探索发现还是不知道，再问，再等你两天 —— 每一轮都实打实烧额度。
        public static let maxRounds = 2

        /// 简单任务不给提问的口子。
        ///
        /// trivial 是「改文档、改注释、重命名」，本来就不该需要澄清；
        /// 而且它们的超时预算只有几分钟，多一段提问契约反而挤占正事。
        public static func mayAsk(_ profile: TaskProfile?) -> Bool {
            (profile?.tier ?? .standard) != .trivial
        }
    }
}

// MARK: - 答案

public struct AskAnswer: Codable, Sendable {
    /// 必须和 Ask.id 一致才会被采纳。
    public var askID: String
    public var taskID: String
    public var machineID: String
    public var answeredAt: Date
    /// 问题 id → 回答。
    public var answers: [String: String]
    /// 用户可以直接放弃这个任务，别让它永远挂着。
    public var abandon: Bool

    public init(askID: String, taskID: String, machineID: String,
                answeredAt: Date = Date(), answers: [String: String],
                abandon: Bool = false) {
        self.askID = askID
        self.taskID = taskID
        self.machineID = machineID
        self.answeredAt = answeredAt
        self.answers = answers
        self.abandon = abandon
    }

    /// 拼给 agent 的续写说明。
    public func briefing(for ask: Ask) -> String {
        var s = """


        ---
        ## 你上一轮问的问题，已经有答复了

        这不是新任务，是接着上一轮干。上一轮你已经做过的探索不用重做。
        """
        if let n = ask.progressNote, !n.isEmpty {
            s += "\n\n你上一轮的进展：\n\(n)"
        }
        if let c = ask.wipCommit {
            s += "\n\n上一轮的改动已经提交在 \(c)，工作区里就是那个状态，直接往下接。"
        }
        s += "\n\n答复："
        for q in ask.questions {
            let a = answers[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            s += "\n\n- 问：\(q.text)\n  答：\(a?.isEmpty == false ? a! : "（没给明确答复，按你自己的判断做，别再问了）")"
        }
        s += "\n\n现在把任务做完。**这一轮不要再提问**，剩下的不确定处按你的判断决定并在提交信息里说明。"
        return s
    }
}

// MARK: - 落盘

/// 问题和答案的存放。
///
/// 目录按**机器**分，不是平铺：
///
///     questions/<machineID>/<taskID>.json
///     answers/<machineID>/<taskID>.json
///
/// 因为 tasks.jsonl 是本机私有的而 iCloud 是共享的。平铺的话，
/// 另一台机器会扫到不属于它的答案 —— 在自己的任务库里查无此人，
/// 要么把文件归档掉（真正的主人永远收不到），要么每 30 秒重读一次（永远清不掉）。
/// 按机器分目录让「谁能消费」从路径上就唯一，不需要额外判断。
public enum AskStore {

    /// 测试用，产品代码里永远是 nil。
    public static var rootOverride: URL?

    static var root: URL? {
        rootOverride ?? Paths.iCloudConfigDir?.deletingLastPathComponent()
    }
    /// agent 写问题用的暂存区。**故意放在仓库外面** ——
    /// 放里面会被 git status 算成改动文件。
    public static var scratchDir: URL {
        Paths.appSupport.appendingPathComponent("asks", isDirectory: true)
    }

    public static func questionsDir(machine: String) -> URL? {
        root?.appendingPathComponent("questions/\(machine)", isDirectory: true)
    }
    public static func answersDir(machine: String) -> URL? {
        root?.appendingPathComponent("answers/\(machine)", isDirectory: true)
    }

    /// agent 该往哪个文件写问题。
    public static func scratchPath(taskID: String, round: Int) -> URL {
        try? FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)
        return scratchDir.appendingPathComponent("\(taskID)-r\(round).json")
    }

    /// 发布一个问题到 iCloud，手机能看到。
    ///
    /// **先写问题再改任务状态**。反过来的话，两步之间断电会留下一个
    /// state=blocked 但没有问题文件的任务 —— 手机上看不到要回答什么，
    /// 而任务已经出了 queued 队列，永远不会再被调度，只能人工捞。
    /// 反过来则只留下一个孤儿问题文件，无害，下轮会被覆盖。
    public static func publish(_ ask: Ask) throws {
        guard let dir = questionsDir(machine: ask.machineID) else {
            throw NSError(domain: "AskStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 iCloud 目录"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try SnapshotCoding.prettyEncoder().encode(ask)
        guard ICloudSafe.write(data, to: dir.appendingPathComponent("\(ask.taskID).json")) else {
            throw NSError(domain: "Ask", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "写 iCloud 超时 —— 提问没发出去"])
        }
    }

    /// 本机待回答的问题。
    public static func pending(machine: String) -> [Ask] {
        guard let dir = questionsDir(machine: machine) else { return [] }
        requestDownloads(in: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Ask? in
                guard let d = try? Data(contentsOf: url) else { return nil }
                return try? SnapshotCoding.decoder().decode(Ask.self, from: d)
            }
            .sorted { $0.askedAt > $1.askedAt }
    }

    /// 问题已经处理完了，撤下来。
    public static func retract(taskID: String, machine: String) {
        guard let dir = questionsDir(machine: machine) else { return }
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("\(taskID).json"))
    }

    /// 取回本机的答案。
    ///
    /// 顺带处理 iCloud 的冲突副本（`xxx 2.json`）：两台设备同时改同一个文件时
    /// iCloud 不会合并，而是留下一个带序号的副本。不认它的话答案会被漏掉。
    public static func collectAnswers(machine: String) -> [(AskAnswer, URL)] {
        guard let dir = answersDir(machine: machine) else { return [] }
        requestDownloads(in: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let d = try? Data(contentsOf: url),
                      let a = try? SnapshotCoding.decoder().decode(AskAnswer.self, from: d)
                else { return nil }
                return (a, url)
            }
            .sorted { $0.0.answeredAt < $1.0.answeredAt }
    }

    /// 答案消费完之后归档。
    ///
    /// **失败必须让调用方知道**。原来 Inbox.park 用 `try?` 吞掉错误，
    /// iCloud 正在同步该文件时 moveItem 会失败 —— 吞掉的话下一轮又读到同一份，
    /// 状态已经变了于是被判成"过期答案"，用户看到的是"你白答了"。
    @discardableResult
    public static func archive(_ url: URL, machine: String, suffix: String) -> Bool {
        guard let dir = answersDir(machine: machine) else { return false }
        let done = dir.appendingPathComponent("processed", isDirectory: true)
        try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let dest = done.appendingPathComponent("\(stamp)-\(suffix)-\(url.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return true
        } catch {
            // 移不动就退而求其次：删掉。留着比删掉更糟 ——
            // 留着会被反复消费，而它的内容已经并进任务了。
            return (try? FileManager.default.removeItem(at: url)) != nil
        }
    }

    static func requestDownloads(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        for url in entries where url.pathExtension == "icloud" {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }
}

// MARK: - 给 agent 的提问契约

public enum AskContract {

    /// 追加在提示词末尾，告诉 agent 卡住了怎么办。
    ///
    /// 措辞上有两处是刻意的：
    ///
    /// - **要求它先提交已有改动再提问**。不这么要求的话，最典型的形态是
    ///   agent 读了十几个文件、想清楚了大半，然后问一句就退出 ——
    ///   那几分钟的探索全部作废，回答之后还要原样重做一遍。
    /// - **要求它一次问完**。一个歧义点一轮往返的话，三个歧义点就是三轮，
    ///   每轮都要把代码重读一遍。
    public static func clause(askFile: String) -> String {
        """


        ---
        ## 如果你缺少必要信息

        只有当你**确实无法从代码和任务描述里推断**、而且猜错会导致返工时才走这条路。
        能自己决定的就自己决定，在提交信息里说明理由即可 —— 提问要等人回复，
        这期间任务是停着的。

        真的需要问的话，按顺序做三件事：

        1. 把你**已经做出的改动提交掉**（就在当前分支上，提交信息写 `wip: 等待答复`）。
           不提交的话你这一轮的工作会白费，回答之后还得重做一遍。
        2. 把问题写进这个文件（绝对路径，不在仓库里，不要动仓库里的任何其他文件）：

           \(askFile)

           格式：
           ```json
           {
             "questions": [
               {"text": "问题原文", "options": ["可选项A", "可选项B"], "suggestion": "你倾向于哪个"}
             ],
             "progressNote": "你已经查明和做完了什么，写具体些，回答之后你要靠它接着干，不用重新探索"
           }
           ```
           `options` 和 `suggestion` 可以省略，但有选项的话对方点一下就能回，比打字快得多。
           **一次把所有不确定的地方都问完**，不要问一个停一个。
        3. 然后就结束本次运行，不要继续猜着往下做。
        """
    }

    /// 解析 agent 写出来的文件。
    ///
    /// 宽松处理：模型可能裹一层 markdown 代码块，也可能直接给一个数组而不是对象。
    public static func parse(_ url: URL, taskID: String, machineID: String,
                             round: Int, platform: Platform?,
                             taskPrompt: String, repoName: String) -> Ask? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let tail = String(raw[start...])
        guard let end = tail.lastIndex(where: { $0 == "}" || $0 == "]" }) else { return nil }
        let json = String(tail[...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var rawQuestions: [[String: Any]] = []
        var progress: String?
        var wip: String?
        if let arr = obj as? [[String: Any]] {
            rawQuestions = arr
        } else if let dict = obj as? [String: Any] {
            rawQuestions = (dict["questions"] as? [[String: Any]]) ?? []
            // 模型有时会退化成一个字符串数组
            if rawQuestions.isEmpty, let strs = dict["questions"] as? [String] {
                rawQuestions = strs.map { ["text": $0] }
            }
            progress = dict["progressNote"] as? String
            wip = dict["wipCommit"] as? String
        }

        let questions = rawQuestions.compactMap { q -> Ask.Question? in
            guard let text = (q["text"] as? String ?? q["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            let opts = (q["options"] as? [String])?.filter { !$0.isEmpty }
            return Ask.Question(text: text,
                                options: (opts?.isEmpty ?? true) ? nil : opts,
                                suggestion: q["suggestion"] as? String)
        }
        guard !questions.isEmpty else { return nil }

        return Ask(taskID: taskID, machineID: machineID, round: round,
                   platform: platform, taskPrompt: taskPrompt, repoName: repoName,
                   questions: questions, progressNote: progress, wipCommit: wip)
    }
}

// MARK: - 摄入答案

public enum AskIngest {

    public struct Result: Sendable {
        public var taskID: String
        public var accepted: Bool
        public var note: String
    }

    /// 把手机上回来的答案并进任务。
    ///
    /// **这不是无条件赋值，是带前置条件的状态转换。** 这一点是整个机制里
    /// 最容易写错、后果最贵的地方：
    ///
    /// 设计前提就是「消息会积压」—— 你可能三天后才回答。这三天里任务
    /// 完全可能已经被人工跑掉、已经 done 并提交到分支了。如果 ingest
    /// 无条件把状态推回 queued，那么：它的 createdAt 最老，`nextQueued`
    /// 下一轮就把它排到队头，在 auto 模式下**重跑一遍已经完成的任务** ——
    /// 再烧一次额度、在已有产出的分支上二次改写。failed 的任务同理会被无限复活。
    ///
    /// 所以只有 `state == .blocked` **且** 答案里的 askID 和任务当前
    /// 挂着的那个问题对得上，才接受。对不上的一律归档，并往 outbox 写一条
    /// 反馈，让手机上能看见「这个问题已经过期了」，而不是石沉大海。
    public static func run(machineID: String,
                           load: () -> [WorkTask],
                           save: (WorkTask) throws -> Void) -> [Result] {
        var out: [Result] = []
        let answers = AskStore.collectAnswers(machine: machineID)
        guard !answers.isEmpty else { return out }
        var tasks = Dictionary(uniqueKeysWithValues: load().map { ($0.id, $0) })

        for (answer, url) in answers {
            guard let task = tasks[answer.taskID] else {
                // 本机没有这个任务。按机器分目录之后这不该发生，
                // 但真发生了也别删 —— 留着，人能看见有个孤儿答案。
                out.append(Result(taskID: answer.taskID, accepted: false,
                                  note: "本机没有这个任务"))
                continue
            }
            guard task.state == .blocked else {
                AskStore.archive(url, machine: machineID, suffix: "stale-state")
                AskStore.retract(taskID: task.id, machine: machineID)
                out.append(Result(taskID: task.id, accepted: false,
                                  note: "任务已经是「\(task.state.rawValue)」，这份答复用不上了"))
                continue
            }
            guard let pending = task.pendingAsk, pending.id == answer.askID else {
                AskStore.archive(url, machine: machineID, suffix: "stale-ask")
                out.append(Result(taskID: task.id, accepted: false,
                                  note: "答的是上一轮的问题，现在问的已经不是它了"))
                continue
            }

            var t = task
            // 审批和提问的答复处理完全不同。
            //
            // 提问：答完重新排队，agent 带着答案接着干。
            // 审批：活已经干完躺在工作区里，「放行」是**提交**——
            // 走重新排队那条路会把已有成果铲掉重来，白烧一份额度，
            // 而且第二次跑出来的东西未必和你看过的那份一样。
            if pending.kind == .approval {
                let picked = answer.answers.first?.value ?? ""
                let approve = !answer.abandon && picked.contains("放行")
                let r = Approval.settle(task: t, approve: approve)
                t = r.task
                t.pendingAsk = nil
                AskStore.retract(taskID: t.id, machine: machineID)
                AskStore.archive(url, machine: machineID,
                                 suffix: approve ? "approved" : "rejected")
                try? save(t)
                tasks[t.id] = t
                out.append(Result(taskID: t.id, accepted: true, note: r.note))
                continue
            }
            if answer.abandon {
                t.state = .failed
                t.endedAt = Date()
                t.note = "你选择了放弃这个任务"
                t.pendingAsk = nil
                AskStore.retract(taskID: t.id, machine: machineID)
                AskStore.archive(url, machine: machineID, suffix: "abandoned")
                try? save(t)
                tasks[t.id] = t
                out.append(Result(taskID: t.id, accepted: true, note: "已放弃"))
                continue
            }

            t.answeredAsk = answer
            t.state = .queued
            t.startedAt = nil
            t.endedAt = nil
            t.note = "答复已收到，排队继续"
            AskStore.retract(taskID: t.id, machine: machineID)
            AskStore.archive(url, machine: machineID, suffix: t.id)
            try? save(t)
            tasks[t.id] = t
            out.append(Result(taskID: t.id, accepted: true, note: "已恢复排队"))
        }
        return out
    }
}
