import Foundation

/// 把一个任务拆成一张图。由**本机的指挥**（控制面）来做。
///
/// ## 什么时候拆
///
/// 只有一个 Agent 的执行能力确实装不下时才拆，例如同一需求同时要求生成
/// 媒体和修改代码。复杂、耗时、验收清单、先后步骤和高危路径都留在同一个
/// 主任务里；它们分别是内部里程碑、验收条件和放行门，不是新 Owner。
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
    ///
    /// **8 → 4（老板 2026-08-22：「不要拆的那么细，kimi 不比你差」）。**
    ///
    /// 上面「为什么默认不拆」那段列的三宗罪，在 8 步的图上全部兑现了：
    /// 一张人物产线的图拆成 s1…s8，任何一步挂掉下游全冻，步与步之间还要
    /// 各等一次落地闸和仓库租约 —— 老板那天问了九次「任务又停了」，
    /// 相当一部分卡顿就发生在**步与步之间**，而不是步骤内部。
    ///
    /// 干活的 agent 有能力一次吃下更大的块。即使真的跨能力，4 步也足够表达
    /// 媒体产物、代码接入和最终验证，不至于再把每条验收条件切成任务。
    public static let maxSteps = 4

    public static var timeout: TimeInterval = 180

    /// 这个任务该不该拆。
    ///
    /// 要不要拆图。**默认不拆。**
    ///
    /// ## 为什么从「默认拆」改成「默认不拆」
    ///
    /// 原来的判据是「复杂 / 高危 / 估时 ≥25 分钟 / 写了步骤」—— 几乎所有
    /// 真活都中。代价是实打实的：
    ///
    /// - **失败被乘方**。一张 7 步的图要 7 步全成；挂一步，下游全冻。
    ///   今天一次盘点捞出 3 张搁浅的图，全是拆出来的。
    /// - **上下文被切碎**。每一步换一个 agent，前一步学到的东西全丢。
    ///   老板的原话是「每次重新处理任务的上下文加载和信息丢失损耗很大」。
    /// - **假阳性**。「生 4 张遗物图标」被拆成 7 步 —— 因为提示词里的
    ///   完成标准写成了编号清单，旧步骤识别把 "1. " "2. " 当成了步骤。
    ///
    /// 而支持拆图的那条理由（便宜平台干机械部分、贵的只干难的那步）
    /// 在**工作区按仓库×平台复用**落地之后已经站不住了：一个 agent
    /// 带着完整会话干 5 件事，严格优于 5 个 agent 各自重新认路。
    ///
    /// 现在只剩一种自动拆分理由：**跨能力**。比如先生图再接线：生图执行器
    /// 改不了代码，编码执行器画不了图，一次执行里根本不可能都干。
    /// 高危路径继续走隔离分支和架构放行，但原任务、Owner、会话不变。
    public static func shouldDecompose(_ t: WorkTask) -> Bool {
        spansCapabilities(t.prompt)
    }

    /// 这个任务是不是横跨了「生成媒体」和「改代码」两种能力。
    ///
    /// 这是唯一一种**一次执行真的装不下**的活：生图执行器（mmx）
    /// 改不了文件，编码执行器画不了图。不拆的话必然有一半干不成。
    static func spansCapabilities(_ prompt: String) -> Bool {
        // 动词和名词分开匹配再取交集。连写的词表（"生成图"）匹配不到
        // 「生成 4 张遗物图标」这种中间插了数量词的写法 —— 而那恰恰是
        // 人最自然的写法。
        let makeVerb = ["生成", "生图", "出图", "画一张", "配图", "配乐", "做一张", "genart"]
        let mediaNoun = ["图", "美术", "音", "乐", "素材"]
        let codeVerb = ["接进", "接线", "改代码", "写进", "接入", "重构", "修复", "调用"]
        let makesMedia = makeVerb.contains { prompt.contains($0) }
            && mediaNoun.contains { prompt.contains($0) }
        return makesMedia && codeVerb.contains { prompt.contains($0) }
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
        // **重复的局部 id 会静默吃掉一个节点。**
        //
        // idMap 是字典，两个 s1 后写的覆盖先写的，两个节点于是拿到同一个
        // 真实 id；任务库按 id 覆盖，第二个直接把第一个改写掉。
        // 而 validate 看到的是「一个节点」，环和悬空边都查不出问题 ——
        // 整张图少了一步，没有任何地方会报错。
        guard Set(steps.map { $0.id }).count == steps.count else { return nil }

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
            // 顺序存成显式序号。**不能靠 createdAt** ——
            // 它编码成 ISO8601 之后秒以下被抹平，落盘再读回来所有节点
            // 时间戳完全相同，「第一步」就变成随机的哪一步了。
            n.stepIndex = i
            n.createdAt = now.addingTimeInterval(Double(i) * 0.001)
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
        - **最多 \(maxSteps) 步，能两步做完就别拆三步。**
          干活的 agent 有能力一次吃下一大块;拆得越细,步与步之间的等待
          (落地、审核、仓库排队)反而成了主要成本 —— 实测那部分比步骤本身还慢。
          只有真正跨执行能力、一个 Agent 无法完成整包交付时才值得分开。
          「先写测试再写实现」「先建目录再放文件」这种叙事顺序**不算**理由。
        - 碰构建脚本、CI 配置、依赖清单、权限设置时仍保留原任务和 Owner；
          在同一隔离分支上接受技术放行，不要另造一个实现任务。
        - 每一步都要能被一个不了解前情的人接手完成，所以 prompt 要自足：
          说清楚改哪里、改成什么样、怎么算完成。
        - 步骤之间用 dependsOn 表达先后。能并列的就别串成一条线。
        - **依赖照「编译需要」画，不是照「叙事顺序」画**：一步的代码引用了
          另一步才创建的类型/文件，就必须 dependsOn 那一步。反例（真实翻过车）：
          「入口文件」排在 s3、它引用的 GameScene 排在 s4，s3 先跑、编译失败。
          每一步完成后整个仓库要能独立编译通过 —— 按这个标准自查依赖有没有画反。
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
