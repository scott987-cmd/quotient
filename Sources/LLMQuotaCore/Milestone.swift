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
public enum Milestone: Codable, Sendable {
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

    static func save(_ items: [Item]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: Paths.sharedRoot, withIntermediateDirectories: true)
        try? d.write(to: file)
    }

    /// 这次落地值不值得惊动老板。
    ///
    /// 判据只有一条:**新增了可看的证据**。用 `EvidenceGate.isEvidenceFile`
    /// 而不是另写一套 —— 同一个概念多处判定这个形状,这个仓库已经踩过九次。
    public static func isWorthShowing(files: [String]) -> Bool {
        files.contains(EvidenceGate.isEvidenceFile)
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

    /// 还没被看过的成果(推送和手机列表都用它)。
    public static func unreviewed() -> [Item] {
        all().filter { $0.verdict == nil }
    }
}
