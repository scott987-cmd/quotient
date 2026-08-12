import Foundation

/// 把一个任务拆成一张图。由**本机的指挥**（控制面）来做。
///
/// ## 什么时候拆
///
/// 只有**复杂档**或**判为高危**的任务才拆。这不是省事，是安全网：
/// 绝大多数任务仍然走今天完全一样的那条路，图那套东西一旦有 bug，
/// 爆炸半径被限制在少数任务上。
///
/// ## 拆坏了怎么办
///
/// 任何一步不顺 —— 指挥额度耗尽、输出不是 JSON、步骤超上限、依赖成环 ——
/// 一律返回 nil，调用方退回单节点，也就是今天的行为。
/// **一个新增的能力不该变成新的单点故障。**
///
/// ## 为什么在临时目录里跑
///
/// 和分诊器同一个理由：它只需要读提示词，不需要文件访问。
/// 在真实仓库里跑一个带 `--dangerously-skip-permissions` 的 agent 去"只输出
/// JSON"，是拿仓库赌它听话。仓库上下文改用摘要喂进提示词，零写入风险。
public enum TaskDecomposer {

    /// 步骤数上限。超过就判定拆解不可信，退回单节点。
    ///
    /// 不设上限的话，一次跑飞的输出能生成几十个节点，
    /// 而每个节点都要单独分诊、单独占一轮调度 —— 额度会被一次失控的拆解吃光。
    public static let maxSteps = 8

    public static var timeout: TimeInterval = 180

    /// 这个任务该不该拆。
    ///
    /// 三个触发条件，第三个是实测补上的：分诊器把
    /// 「补注释 + 在 build-app.sh 末尾加一行」判成低危（理由是不改构建行为，
    /// 本身没错），于是不拆；但落地时的高危闸看的是**实际改到的文件**，
    /// build-app.sh 照样被拦，整个任务因为一行注释全盘转人工。
    ///
    /// 提示词里已经写明了文件名 —— 那是确定性信息，
    /// 不该让它经过一次语义判断再被丢掉。
    public static func shouldDecompose(_ t: WorkTask) -> Bool {
        if GitWorkspace.mentionsRiskyPath(t.prompt) { return true }
        guard let p = t.profile else { return false }
        return p.tier == .complex || p.risk == .sensitive
    }

    // MARK: - 拆

    struct Step: Decodable {
        var id: String
        var title: String
        var prompt: String
        var dependsOn: [String]?
    }
    struct Plan: Decodable { var steps: [Step] }

    /// 拆出一组节点。返回 nil = 没拆成，调用方按单节点处理。
    public static func plan(
        _ task: WorkTask, dashboard: Dashboard,
        runners: [AgentRunner] = RunnerRegistry.reasoning,
        now: Date = Date()
    ) -> [WorkTask]? {
        guard shouldDecompose(task) else { return nil }

        // 指挥来拆。没配指挥的机器就不拆 —— 退回单节点，而不是随便找个平台顶上：
        // 拆解要读全局、要判断哪一步敏感，那正是控制面该干的事。
        guard let boss = AgentRoles.dispatcher(),
              let runner = runners.first(where: { $0.platform == boss.platform })
                  ?? RunnerRegistry.all.first(where: { $0.platform == boss.platform }),
              runner.isAvailable
        else { return nil }

        let scratch = NSTemporaryDirectory() + "llmq-plan"
        try? FileManager.default.createDirectory(
            atPath: scratch, withIntermediateDirectories: true)

        let cmd = runner.command(prompt: instruction(for: task), cwd: scratch)
        let r = Proc.run(cmd.launchPath, cmd.args, cwd: scratch,
                         env: cmd.env, timeout: timeout)
        guard r.exitCode == 0, let parsed = parse(r.stdout) else { return nil }

        return build(parsed, from: task, planner: boss.platform, now: now)
    }

    /// 把解析出来的步骤变成真正的任务节点。
    ///
    /// 关键是**把模型给的局部 id（s1/s2）映射成真实任务 id**，
    /// 同时保住依赖边。不映射的话两次拆解会撞 id，
    /// 而任务库是按 id 覆盖的 —— 后一张图会把前一张悄悄改写掉。
    static func build(_ steps: [Step], from task: WorkTask,
                      planner: Platform, now: Date) -> [WorkTask]? {
        guard !steps.isEmpty, steps.count <= maxSteps else { return nil }

        let graphID = task.id
        var idMap: [String: String] = [:]
        for (i, s) in steps.enumerated() {
            idMap[s.id] = "\(graphID)s\(i + 1)"
        }

        var nodes: [WorkTask] = []
        for (i, s) in steps.enumerated() {
            guard let realID = idMap[s.id] else { return nil }
            var n = WorkTask(id: realID, prompt: s.prompt, repo: task.repo)
            n.graphID = graphID
            n.stepTitle = s.title
            // 模型引用了不认识的 id 就整张作废 —— 悬空边会让节点永远不就绪，
            // 而那看起来完全正常。宁可退回单节点。
            var deps: [String] = []
            for d in s.dependsOn ?? [] {
                guard let m = idMap[d] else { return nil }
                deps.append(m)
            }
            n.dependsOn = deps
            n.createdAt = now.addingTimeInterval(Double(i) * 0.001)   // 保序
            n.origin = task.origin
            n.preferredPlatform = task.preferredPlatform
            nodes.append(n)
        }

        // 环和悬空边都在这儿拦。有环不会报错，只会让整张图**静默不动**。
        if TaskGraph.validate(nodes) != nil { return nil }
        _ = planner
        return nodes
    }

    // MARK: - 提示词

    static func instruction(for task: WorkTask) -> String {
        """
        你是一个任务拆解器。把下面这个开发任务拆成有先后依赖的若干步骤。

        任务：
        \(task.prompt)

        仓库背景（可能为空）：
        \(repoContext(task.repo))

        拆解要求：
        - 最多 \(maxSteps) 步。步骤太细会让每一步的上下文成本超过它省下的东西。
        - **把碰构建脚本、CI 配置、依赖清单、权限设置的改动单独拆成一步。**
          这类改动要人工确认；混在别的步骤里会让整个任务一起卡住。
        - 每一步都要能被一个不了解前情的人接手完成，所以 prompt 要自足：
          说清楚改哪里、改成什么样、怎么算完成。
        - 步骤之间用 dependsOn 表达先后。能并列的就别串成一条线。
        - 如果这个任务本来就该一步做完，就只返回一步。

        只输出 JSON，不要任何解释文字、不要代码块围栏：
        {"steps":[{"id":"s1","title":"简短标题","prompt":"给执行者的完整指令","dependsOn":[]}]}
        """
    }

    /// 给拆解器一点仓库背景，但**不给它文件访问**。
    ///
    /// AGENTS.md 本来就是为「让人不必从零认识这个项目」写的，而且刻意写得短，
    /// 拿来当拆解上下文正合适。顶层目录清单补充结构感。
    static func repoContext(_ repo: String) -> String {
        var parts: [String] = []
        for name in ["AGENTS.md", "CLAUDE.md", "README.md"] {
            let u = URL(fileURLWithPath: repo).appendingPathComponent(name)
            if let s = try? String(contentsOf: u, encoding: .utf8), !s.isEmpty {
                parts.append("--- \(name)（前 2000 字）---\n" + String(s.prefix(2000)))
                break
            }
        }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: repo) {
            let visible = items.filter { !$0.hasPrefix(".") }.sorted().prefix(40)
            parts.append("--- 顶层条目 ---\n" + visible.joined(separator: "  "))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 解析

    /// 从模型输出里抠出 JSON。
    ///
    /// 模型经常在 JSON 前后加一句「好的，这是拆解结果：」或者套一层 ```json，
    /// 所以不能直接 JSONDecoder 一把梭 —— 那会在完全正常的输出上失败，
    /// 然后退回单节点，而没人知道为什么。
    static func parse(_ raw: String) -> [Step]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "```") {
            s = String(s[r.upperBound...])
            if s.hasPrefix("json") { s = String(s.dropFirst(4)) }
            if let e = s.range(of: "```") { s = String(s[..<e.lowerBound]) }
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"),
              start < end else { return nil }
        let body = String(s[start...end])
        guard let d = body.data(using: .utf8),
              let plan = try? JSONDecoder().decode(Plan.self, from: d),
              !plan.steps.isEmpty
        else { return nil }
        return plan.steps
    }
}
