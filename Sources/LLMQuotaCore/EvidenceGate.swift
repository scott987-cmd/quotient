import Foundation

/// 证据闸：改了看得见的东西，就得交人能看的证据。
///
/// ## 这东西为什么存在
///
/// 老板的原话：「验收任务发给我的，怎么还有一堆合代码的，不是说过我只看
/// 人可阅读验证的成功，比如游戏截图、运行结果」。
///
/// 这句批评指向的不是措辞，是**成本装反了**。
///
/// 一份没有截图的产出，人要判断它对不对，就得自己 xcodegen、build、
/// 装模拟器、跑一局、看效果 —— 五分钟起步，而且每一份都要重来一遍。
/// 而 agent 收工前本来就在那个工作区里，跑一遍只是顺手的事。
/// 让人替 agent 补跑，是把最贵的动作推给了最贵的人。
///
/// 所以：
///
/// - **交了证据的** → 进推送，人看图判断「手感对不对」；
/// - **没交证据、又改了看得见的东西的** → 派回给原平台去跑一遍交图；
/// - **纯文档 / 报告类** → 不需要截图，也不该为此挨一次派活。
///
/// 证据闸不是合并闸。代码能不能合，由 autoland 的构建+测试说话；
/// 这里管的只是**什么东西有资格出现在人面前**。
public enum EvidenceGate {

    /// 一条该补证据的分支。
    public struct Candidate: Sendable {
        public var branch: String
        public var repo: String
        /// 当初做这条分支的平台 —— 补证据要派回给它，它有会话，也知道自己改了什么。
        public var platform: Platform?
        public var files: [String]
        public var subject: String
    }

    /// 这个文件算不算**证据**。
    ///
    /// ## 为什么有文本这一条
    ///
    /// `criteria` 白纸黑字写着「改了命令行行为 → 实跑输出，连命令一起贴」——
    /// 而这个过滤器原来只认图片/录屏。2026-08-20 当场兑现：DragonTales 的
    /// 资产完整性测试任务按条款交了 `docs/evidence/asset-integrity-tests.log`
    /// （64 行真实测试输出），落地闸却判「没有证据」，又派了一个补证据 agent
    /// 去跑截图 —— **条款按 A 标准要、闸门按 B 标准收**，正是条款注释里
    /// 声称要防的那种漂移，引入当天就被全流程验证抓个正着。
    ///
    /// 文本证据收紧到 `evidence` 目录下的 .log/.txt：报告类的 .md
    ///（reviews/EVAL-*.md）不算 —— 那是**评审的产出**，不是**改动的证据**，
    /// 混了的话每份评审报告都会给自己发证据豁免。
    public static func isEvidenceFile(_ f: String) -> Bool {
        let l = f.lowercased()
        let isVisual = [".png", ".jpg", ".jpeg", ".gif", ".mov", ".mp4"]
            .contains { l.hasSuffix($0) }
        if isVisual {
            return l.contains("evidence") || l.contains("shot")
                || l.contains("screen") || l.contains("验收")
                || l.contains("playtest") || l.contains("review")
        }
        // 实跑输出：只认 evidence 目录里的
        if l.hasSuffix(".log") || l.hasSuffix(".txt") {
            return l.contains("evidence")
        }
        return false
    }

    /// 这条分支改的东西，人看得见吗。
    ///
    /// 判据故意从宽：只要动了源码就算「看得见」。反过来（只动文档 / 报告 /
    /// 配置）才算看不见。宁可多要一次截图，也别让一个改了手感的分支
    /// 悄悄合进去 —— 手感回归是测试测不出来的那类问题。
    static func changesVisibleBehavior(_ files: [String]) -> Bool {
        files.contains { f in
            let l = f.lowercased()
            // 文档、报告、纯资源清单：看不见，不用截图
            if l.hasSuffix(".md") || l.hasSuffix(".txt") || l.hasSuffix(".json")
                || l.hasSuffix(".yml") || l.hasSuffix(".yaml")
                || l.hasSuffix(".log") { return false }
            // pbxproj 是 xcodegen 的机器产物：加个测试文件它就变。
            // 「人看得见吗」= 否。它改坏的风险另有人管 ——
            // isRiskyPath 对它要 2 票审核，那道闸不动。
            if l.hasSuffix(".pbxproj") { return false }
            // 图片/录屏/音频这类媒体产物本身就是证据，不算「被改的东西」。
            // 音频是实测补的：主题曲 + 立绘的分支被 .mp3 判成「看得见、
            // 没证据」，给一首歌派了截图任务（2026-08-20，Flint 2841e486）。
            if [".png", ".jpg", ".jpeg", ".gif", ".mov", ".mp4",
                ".mp3", ".m4a", ".wav", ".caf"]
                .contains(where: { l.hasSuffix($0) }) { return false }
            // **测试文件不算。** 测试的证据是它自己跑绿了 ——
            // `xcodebuild test` 的输出比任何截图都有说服力，
            // 而截图证明不了一个断言成不成立。
            //
            // 实测（2026-08-18）：Maw 那条「补第一批单元测试」交了 10 个测试、
            // 验证通过，却被判成「改了看得见的东西、没交证据」，
            // 差点派它回去跑一遍模拟器截图 —— 纯白烧一次额度。
            if isTestPath(l) { return false }
            return true
        }
    }

    /// 这个路径是不是测试代码。
    ///
    /// 认目录名和文件名两种约定：Swift 项目惯例是 `XxxTests/` 目录
    /// 加 `XxxTests.swift` 文件名，两者都认才不会漏。
    static func isTestPath(_ lowercased: String) -> Bool {
        lowercased.contains("tests/") || lowercased.contains("test/")
            || lowercased.hasSuffix("tests.swift")
            || lowercased.hasSuffix("test.swift")
    }

    /// 挑出该补证据的分支。
    public static func candidates(repo: String, base: String = "main",
                                  tasks: [WorkTask] = TaskStore.all()) -> [Candidate] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return Review.list(repo: repo, base: base, tasks: tasks).compactMap { item in
            // 已经交了证据的不用补
            guard item.evidence.isEmpty else { return nil }
            // 跑着的不碰，失败的该人看 —— 和 StaleBranch 同一条纪律
            guard let t = byID[item.taskID], t.state == .done else { return nil }
            guard changesVisibleBehavior(item.files) else { return nil }
            return Candidate(branch: item.branch, repo: repo, platform: t.platform,
                             files: item.files, subject: item.subject)
        }
    }

    /// 「什么算证据」的唯一版本 —— 事前条款（`inlineClause`）和事后补课
    /// （`evidencePrompt`）都用它。两处各写一份的话，迟早一处改了另一处没改，
    /// agent 按 A 标准交、闸门按 B 标准收。
    static let criteria = """
        什么算证据：
        - 改了界面 / 美术 → 那个界面的截图
        - 改了动画 / 手感 → **录屏**（静态图证明不了动画）
        - 改了玩法逻辑 → 走到那个局面的截图，数字要能对上
        - 改了命令行行为 → 实跑输出，连命令一起贴

        什么**不算**证据：
        - 「构建成功」的终端截图 —— 那证明编译器高兴，不证明你改对了
        - 代码 diff 的截图 —— 人要看的是跑起来什么样，不是代码长什么样
        - 跑之前就有的旧图 —— 证据必须是这次改动之后拍的
        """

    /// 拼进**编码任务**提示词的证据条款：让干活的 agent 在**同一次执行里**
    /// 自己交证据，而不是事后另派一个 agent 重新认路、重新构建、重新截图。
    ///
    /// ## 为什么改成事前
    ///
    /// 老板（2026-08-20）：「尽量让一个任务在一个 agent 内完成工作，
    /// agent 之间尽量少的信息传递」。
    ///
    /// 原流程是事后的：干活的 agent 收工 → 落地闸发现没证据 → **另派**
    /// 一个 agent checkout 分支、装模拟器、截图 → 下一轮再判。第二个 agent
    /// 对改动一无所知，一切从零 —— 当天实测一条补证据任务跑了 11 分钟，
    /// 而干活的那个 agent 明明刚把工程跑起来过。
    ///
    /// 事后那条路（`dispatchEvidence`）保留，当漏网的兜底 —— 但正常情况
    /// 不该再走到它。
    ///
    /// 条件必须和落地闸完全一致（manualReview 仓库 + 编码任务），
    /// 否则会漂移出「条款要了、闸门不收」或反过来。
    public static func inlineClause(repoPath: String, prompt: String) -> String {
        // isCoding 的定义已经排除了媒体/评审/证据/刷新 —— 这里不再重复列举，
        // 列举第二遍就是「同一个概念两处判定」，那个形状今天已经埋过五次雷。
        guard TaskKind.isCoding(prompt) else { return "" }
        let want = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        let manual = RepoRegistry.all().contains {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == want
                && $0.manualReview
        }
        guard manual else { return "" }
        return """


        ---
        ## 交证据（这个仓库的活「看效果才合」—— 证据是任务的一部分，不是可选项）

        改完之后**你自己**把它跑起来，把效果拍下来放进 `docs/evidence/` 并提交。
        没有证据的分支不会被合入，之后还得再派一个对你的改动一无所知的 agent
        重新构建重新截图 —— 你现在工程就在手上，顺手拍掉它。

        \(criteria)

        例外：改动**只**碰了测试或文档的话不用截图（测试跑绿本身就是证据，
        落地闸也不会要）。改的是**还没接到画面上的纯数值/逻辑**（比如数值表、
        尚未渲染的系统）？那就把测试实跑输出存成 `docs/evidence/*.log` 提交 ——
        文本证据同样过闸，别硬拍一张什么都证明不了的截图。
        跑不起来就说跑不起来，说清楚卡在哪，别拿构建日志凑。
        ---

        """
    }

    /// 补证据任务的提示词。
    ///
    /// 要顶住的失败模式：agent 交一张「构建成功」的终端截图当证据。
    /// 那证明的是编译器高兴，不是这个改动做对了 —— 而人看到这种图，
    /// 得到的信息量是零，还得自己再跑一遍，等于这次派活白花。
    public static func evidencePrompt(_ c: Candidate) -> String {
        """
        【证据】把分支 \(c.branch) 的改动跑起来，留下人一眼能看出成败的证据。

        这条分支是你之前做的：\(c.subject)
        它现在没有任何可看的证据，所以没法给人验收。

        步骤：
        - `git checkout \(c.branch)`
        - 构建并**真的跑起来**（iOS 就装模拟器跑，命令行就实际执行）
        - 把改动的效果拍下来，放进 `docs/evidence/`
        - 提交这些证据

        \(criteria)

        跑不起来就说跑不起来，说清楚卡在哪，别拿构建日志凑。
        """
    }

    public struct Outcome: Sendable {
        public var branch: String
        public var enqueued: Bool
        public var note: String
    }

    /// 这条分支已经被派过几次补证据。
    ///
    /// 数的是**派出去过几次**，不管跑成没跑成 —— 判「该不该再派」要的
    /// 就是这个。
    static func evidenceAttempts(branch: String, tasks: [WorkTask]) -> Int {
        // 和 `evidencePrompt` 的模板首行是一对 —— 改模板必须同步改这里。
        // 匹配精确前缀而不是「前缀 + 任意位置含分支名」：后者会被
        // 提示词里**提到**这条分支的其他证据任务污染（同款污染在
        // 合入计票那边真实发生过，见 MergeReview.isMergeReviewPrompt）。
        // 尾部空格防前缀吞并（agent/a/x ≠ agent/a/xy）。
        tasks.filter {
            $0.prompt.hasPrefix("【证据】把分支 " + branch + " ")
        }.count
    }

    /// 给缺证据的分支派补证据任务。
    ///
    /// - Parameter maxPerCall: 一轮最多派几个。默认 1 —— 跑模拟器截图是重活。
    public static func dispatchEvidence(repo: String, base: String = "main",
                                        tasks: [WorkTask] = TaskStore.all(),
                                        maxPerCall: Int = 1) -> [Outcome] {
        var out: [Outcome] = []
        for c in candidates(repo: repo, base: base, tasks: tasks) {
            // 只数真派出去的 —— 「不重复派 / 收口」这种不动手的结果不占名额,
            // 否则排在前面的一条永久挡住后面所有(队头阻塞,2026-08-22)。
            if out.filter(\.enqueued).count >= maxPerCall { break }
            // **派够次数还交不出证据 —— 收口，别再派。**
            //
            // 去重只挡得住「已经派过、还没跑完」。任务一旦失败或超时，
            // 它就不再是重复项 —— 于是下一轮立刻重派，永远重派。
            //
            // 实测（2026-08-20）：`agent/claude/009f44f5` 改的 107 个文件
            // 全是素材图片，而 AssetPacks 根本没有能跑起来截图的 App。
            // 补证据任务每轮派一次、每次跑满 601 秒超时被杀，然后再派。
            //
            // 这个洞旁边那条路已经补过了：审核派发有 `MergeReview.exhausted`，
            // 就是为同一件事写的（同两条分支一夜被派了 16 次和 13 次审核）。
            // **当时只补了审核那一侧。** 所以这里直接复用那个判据，
            // 不再写第二份 —— 两份迟早会漂移出不一样的答案。
            let attempts = evidenceAttempts(branch: c.branch, tasks: tasks)
            if MergeReview.exhausted(attempts: attempts, needed: 1) {
                out.append(Outcome(
                    branch: c.branch, enqueued: false,
                    note: "派了 \(attempts) 次补证据都没交出来 ——"
                        + "不再重试，留给人工处置"))
                continue
            }
            do {
                // 不分诊不拆图：说死了的机械活。
                let r = try TaskIntake.enqueue(
                    prompt: evidencePrompt(c), repo: repo,
                    classify: false, split: false,
                    origin: "evidence-gate",
                    preferredPlatform: c.platform)
                switch r {
                case .duplicate:
                    continue  // 已经派过还没跑完
                default:
                    out.append(Outcome(
                        branch: c.branch, enqueued: true,
                        note: "\(c.files.count) 个文件、没有证据"
                            + "，已派给 \(c.platform?.rawValue ?? "自动挑选") 跑一遍截图"))
                }
            } catch {
                out.append(Outcome(branch: c.branch, enqueued: false,
                                   note: "派补证据失败：\(error.localizedDescription)"))
            }
        }
        return out
    }
}
