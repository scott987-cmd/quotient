import Foundation

/// 关键成果验收:**产出录屏后主动找老板确认,不用他来问。**
///
/// ## 为什么要有这个
///
/// 老板(2026-08-22)的原话:「为啥没有录屏发给我进行评审?这个不应该你驱动,
/// 应该是我们的数字人程序在关键成果产出需要找我确认啊」。
///
/// 缺口是真的:`manualReview` 仓库的分支由**评审 agent** 判合入、自动落地,
/// 于是它从来不进「待验收」名单 —— 人被彻底跳过。老板只能靠自己发现、
/// 开口要。而他的判断恰恰最值钱:「跑的姿势不像真人」「手歪不拉几」
/// 两条都是真问题,是靠他看录屏发现的。
///
/// ## 为什么是落地后推,而不是卡住等他确认
///
/// 卡住会立刻触发另一个他更烦的毛病:基线闸看到未落地的成果就冻结整仓,
/// 「任务怎么停了」这句话他这两天问了四次。所以:**照常落地保吞吐,
/// 落地后把录屏推给他**;他点不满意 → 系统自动生成整改任务。
/// 判官还是他,只是不挡路。
///
/// ## 什么算「关键成果」
///
/// 这次落地**新增了可看的录屏/截图**——那就是一件做出来了、能看效果的东西。
/// 纯文档、评审报告、重构不打扰他(和证据闸同一套判据 `isEvidenceFile`)。
public enum Milestone {
    /// 一条已落地、带可看证据的成果。
    public struct Item: Codable, Sendable, Identifiable {
        public var id: String { repo + "|" + mergeSHA }
        public var repo: String
        public var repoName: String
        public var branch: String
        public var mergeSHA: String
        public var subject: String
        public var landedAt: Date
        /// 抽进共享目录的证据文件名(和待审那套共用 evidenceDir,手机直接播)。
        public var evidenceFiles: [String]
        /// 老板看完的结论:nil=还没看
        public var verdict: String?
    }

    static var file: URL {
        Paths.sharedRoot.appendingPathComponent("milestones.json")
    }

    public static func all() -> [Item] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Item].self, from: d)) ?? []
    }

    @discardableResult
    static func save(_ items: [Item]) -> Bool {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(items) else { return false }
        try? FileManager.default.createDirectory(
            at: Paths.sharedRoot, withIntermediateDirectories: true)
        return ICloudSafe.write(d, to: file)
    }

    /// 这次落地值不值得惊动老板。
    ///
    /// 判据只有一条:**新增了可看的证据**。用 `EvidenceGate.isEvidenceFile`
    /// 而不是另写一套 —— 同一个概念多处判定这个形状,这个仓库已经踩过九次。
    public static func isWorthShowing(files: [String]) -> Bool {
        files.contains(where: EvidenceGate.isEvidenceFile)
    }

    /// 落地时记一笔。由 `Review.merge` 成功后调用。
    /// - Returns: 记下的那条(不值得展示时返回 nil)
    @discardableResult
    public static func record(repo: String, branch: String, mergeSHA: String,
                              files: [String], subject: String,
                              now: Date = Date()) -> Item? {
        guard isWorthShowing(files: files) else { return nil }
        let visual = files.filter(EvidenceGate.isEvidenceFile)
        let digestID = repo + "|" + branch
        let extracted = Review.extractEvidence(
            repo: repo, branch: branch, files: visual, digestID: digestID)
        let item = Item(
            repo: repo,
            repoName: URL(fileURLWithPath: repo).lastPathComponent,
            branch: branch, mergeSHA: mergeSHA, subject: subject,
            landedAt: now, evidenceFiles: extracted, verdict: nil)
        var items = all()
        guard !items.contains(where: { $0.id == item.id }) else { return nil }
        items.append(item)
        // 只留最近 30 条 —— 手机上翻不动更多,老的看完就没用了。
        save(items.suffix(30).map { $0 })
        return item
    }

    /// 派一份「先替老板看一眼」的任务给多模态平台。
    ///
    /// 老板 2026-08-22 指出:MiniMax 支持视频/图片输入,而审查员那条线
    /// (opencode → GLM)是纯文本。在这之前**全系统没有任何一个环节真的
    /// 看过录屏** —— 只有老板本人看,他一个人当所有验收的眼睛。
    /// 他看录屏发现的问题(「跑的姿势不像真人」「手歪不拉几」)全是真的,
    /// 但那本该在到他手上之前就被拦下一部分。
    ///
    /// 这一道不是替代他,是先过一遍明显的:人物姿势怪、UI 错位、画面全黑。
    @discardableResult
    public static func dispatchVisualCheck(_ item: Item, repoPath: String) -> String? {
        let visual = item.evidenceFiles.filter {
            let l = $0.lowercased()
            return l.hasSuffix(".mov") || l.hasSuffix(".mp4") || l.hasSuffix(".png")
                || l.hasSuffix(".jpg")
        }
        guard !visual.isEmpty else { return nil }
        let dir = Review.evidenceDir.path
        let prompt = """
        【看效果】看一遍这次产出的录屏/截图,替老板先过一道眼。

        成果：\(item.subject)
        文件（都在 \(dir) 下）：
        \(visual.map { "  - " + $0 }.joined(separator: "\n"))

        用你的图片/视频理解能力**真的看**,不要凭文件名猜。要回答的就三件事：

        1. 画面正常吗 —— 有没有全黑、纯色、卡住不动、明显穿模。
        2. 人物/动作自然吗 —— 姿势别扭、手脚朝向不对、滑步、T-pose 这类。
           （这条最要紧：老板上一轮就是靠肉眼发现「跑的姿势不像真人、
           手歪不拉几」,那两条后来都证实是真问题。）
        3. 和成果标题对得上吗 —— 说是打枪的录屏里真有开枪吗。

        输出格式（就这几行,别写长报告）：
        **看到了**：一句话描述画面里实际发生的事
        **问题**：逐条列,没有就写「没看出问题」
        **结论**：可以给老板看 / 建议先修（附一句为什么）
        """
        let r = try? TaskIntake.enqueue(
            prompt: prompt, repo: repoPath, classify: false, split: false,
            force: true, origin: "milestone-eyes",
                idempotencyKey: "milestone-eyes:" + item.mergeSHA,
            source: "milestone",
            preferredPlatform: .minimax)
        if case .single(let t)? = r { return t.id }
        return nil
    }

    /// 还没被看过的成果(推送和手机列表都用它)。
    public static func unreviewed() -> [Item] {
        all().filter { $0.verdict == nil }
    }

    /// 记录老板对已落地成果的结论；不满意时立即生成整改任务。
    ///
    /// 整改任务是新任务，但 owner 精确继承原实现者。会话本身按
    /// `稳定工作区 × runner × 能力泳道` 保存，所以新任务 ID 不会丢项目上下文；
    /// 同时避免复用已合入分支，再次撞上“旧分支已落地”的误判。
    public static func decide(repo: String, mergeSHA: String, approved: Bool,
                              note: String?, tasks: [WorkTask] = TaskStore.all()) -> Bool {
        var items = all()
        guard let index = items.firstIndex(where: {
            $0.repo == repo && $0.mergeSHA == mergeSHA
        }) else { return false }

        // 同一条手机动作可能被两台 Mac 都看见。结论已经落盘就只做幂等成功，
        // 不能再造第二条整改任务。
        if items[index].verdict != nil { return true }
        let item = items[index]

        if !approved {
            let origin = "milestone-remediation:" + mergeSHA
            if !tasks.contains(where: { $0.origin == origin }) {
                let sourceID = String(item.branch.split(separator: "/").last ?? "")
                let source = tasks.last(where: { $0.id == sourceID })
                    ?? tasks.last(where: { $0.repo == repo && $0.branch == item.branch })
                let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
                let feedback = (trimmed?.isEmpty == false ? trimmed : nil)
                    ?? "没有补充文字；请先完整查看本次证据，再对照项目质量契约定位差距。"
                var repair = WorkTask(
                    id: "m" + String(mergeSHA.prefix(7)).lowercased(),
                    prompt: """
                    【成果验收整改｜保持原 Agent 项目会话】
                    已落地成果「\(item.subject)」（提交 \(mergeSHA)，来源分支 \(item.branch)）
                    被用户判定为不满意。

                    用户反馈：\(feedback)

                    这是原成果的整改续作，不要重做项目或扩张其他内容。沿用当前项目
                    上下文，逐项修复用户从真实画面发现的问题，补回归验证，并重新提交
                    正常入口的截图或连续录屏。代码存在、单测通过不能替代实际体验达标。
                    """,
                    repo: repo)
                repair.origin = origin
                repair.ownerPlatform = source?.ownerPlatform ?? source?.platform
                repair.ownerRunnerID = source?.ownerRunnerID
                repair.ownerAssignedAt = source?.ownerAssignedAt ?? source?.startedAt
                repair.preferredPlatform = repair.ownerPlatform ?? source?.preferredPlatform
                repair.platform = repair.ownerPlatform
                repair.profile = source?.profile
                repair.production = source?.production
                repair.note = "用户不满意，已交回原 Agent 项目会话整改"
                do {
                    _ = try TaskIntake.enqueuePrepared(
                        repair, idempotencyKey: origin, source: "milestone")
                } catch {
                    return false
                }
            }
        }

        items[index].verdict = approved ? "approved" : "rejected"
        return save(items)
    }
}
