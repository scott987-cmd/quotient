import Foundation

/// 用 LLM 给任务画像。
///
/// 三条设计约束：
///
/// 1. **只在入队时跑一次**，结果存进任务记录。派发每 30 秒一轮，
///    如果每轮都调 LLM，等于为「决定怎么花一次调用」再花一次调用。
/// 2. **用最闲的平台去分类**。分类本身也消耗额度，它没有理由豁免于
///    「把活派给最闲的那个」这条原则。
/// 3. **失败不阻塞**。分类挂了任务照样入队，只是退化成纯额度排序 ——
///    也就是加这个功能之前的行为。一个可选的优化层不该成为单点故障。
public enum TaskClassifier {

    /// 分类用的调用要短平快，别让它占着一个执行槽。
    static let timeout: TimeInterval = 90

    public static func classify(
        prompt: String, repo: String, history: [WorkTask],
        dashboard: Dashboard, runners: [AgentRunner] = RunnerRegistry.reasoning
    ) -> TaskProfile? {
        // requiresEditing: false —— 分类只需要文本进出，不改文件。
        // 不传这个的话 MiniMax 会被「能不能改文件」那道闸排除掉，
        // 而它正是额度最富余、最该干这活的。
        let decision = WorkScheduler().decide(
            dashboard: dashboard, runners: runners, requiresEditing: false)
        guard let pick = decision.pick else { return nil }

        let instruction = buildPrompt(prompt: prompt, repo: repo, history: history)
        // 分类在临时目录里跑，不碰任何仓库 —— 它只需要读提示词，不需要文件访问。
        let scratch = NSTemporaryDirectory() + "llmq-classify"
        try? FileManager.default.createDirectory(
            atPath: scratch, withIntermediateDirectories: true)

        let cmd = pick.runner.command(prompt: instruction, cwd: scratch)
        let r = Proc.run(cmd.launchPath, cmd.args, cwd: scratch,
                         env: cmd.env, timeout: timeout)
        guard r.exitCode == 0 else { return nil }

        guard var profile = parse(r.stdout) else { return nil }
        profile.classifiedBy = pick.platform
        return profile
    }

    static func buildPrompt(prompt: String, repo: String, history: [WorkTask]) -> String {
        """
        你是一个任务分诊器。判断下面这个编码任务的难度、风险和自洽性，只输出 JSON。

        ## 待分诊的任务
        仓库：\(URL(fileURLWithPath: repo).lastPathComponent)
        任务：
        \(prompt)

        ## 最近的历史任务（供参考各档次实际耗时）
        \(TaskHistory.summary(from: history))

        ## 输出格式
        只输出一个 JSON 对象，不要 markdown 代码块，不要任何解释文字：

        {
          "tier": "trivial | standard | complex",
          "risk": "safe | normal | sensitive",
          "estimatedMinutes": <整数>,
          "isSelfContained": true | false,
          "missingContext": "<不自洽时说明缺什么，自洽则为 null>",
          "rationale": "<一句话依据，不超过 60 字>"
        }

        ## 判定标准

        tier：
        - trivial：改文档/注释/重命名/格式化，不需要理解业务逻辑
        - standard：加函数、补测试、修一个描述明确的 bug
        - complex：跨模块重构、要先读懂现有架构才能动手、涉及并发或数据一致性

        risk：
        - safe：只动文档和测试
        - normal：动源码
        - sensitive：动构建配置、脚本、CI、依赖清单、权限位

        isSelfContained：任务描述是否足以独立执行。
        出现「上次那个」「继续之前的」这类无指代对象的说法，
        或者缺少判断"做完了没有"的标准，就是 false。
        这一项要严格——描述不清导致跑偏，整轮额度就白烧了。
        """
    }

    /// 宽松解析：模型经常会裹一层 markdown 代码块，或在 JSON 前后加客套话。
    static func parse(_ raw: String) -> TaskProfile? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let tier = TaskProfile.Tier(rawValue: (obj["tier"] as? String) ?? "") ?? .standard
        let risk = TaskProfile.Risk(rawValue: (obj["risk"] as? String) ?? "") ?? .normal
        let minutes = JSONHelp.int(obj["estimatedMinutes"])
        // 自洽性缺省取 true：分类器没给出明确的 false 时不该拦住任务。
        let selfContained = (obj["isSelfContained"] as? Bool) ?? true
        var missing = obj["missingContext"] as? String
        if missing?.isEmpty == true || missing == "null" { missing = nil }

        return TaskProfile(
            tier: tier, risk: risk,
            estimatedMinutes: minutes > 0 ? minutes : 5,
            isSelfContained: selfContained,
            missingContext: selfContained ? nil : missing,
            rationale: (obj["rationale"] as? String) ?? "")
    }
}
