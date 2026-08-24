import Foundation

/// 给新游戏仓库装上最小的“产品事实 + 质量契约 + 对标矩阵 + 证据制度”。
///
/// 模板只负责复用做游戏的过程纪律，不复制 Flint 的内容或实现。已有文件永远
/// 不覆盖：人工写下的产品判断比通用模板优先，重复执行只补后来缺失的部分。
public enum GameProjectBootstrap {
    public struct Result: Sendable {
        public var created: [String]
        public var preserved: [String]
        public var repo: RepoAlias
    }

    public static let qualityFile = "QUALITY.md"

    public static func apply(alias: String, path: String, owner: Platform,
                             makeDefault: Bool = false) throws -> Result {
        let expanded = NSString(string: path).expandingTildeInPath
        guard GitWorkspace.isRepo(expanded) else {
            throw NSError(domain: "GameProjectBootstrap", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(expanded) 不是 git 仓库"])
        }

        let root = URL(fileURLWithPath: expanded, isDirectory: true)
        var created: [String] = []
        var preserved: [String] = []
        for (relative, content) in templates.sorted(by: { $0.key < $1.key }) {
            let file = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) {
                preserved.append(relative)
                continue
            }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
            created.append(relative)
        }

        _ = try RepoRegistry.add(alias: alias, path: expanded, makeDefault: makeDefault)
        var repos = RepoRegistry.all()
        guard let i = repos.firstIndex(where: { $0.alias == alias }) else {
            throw NSError(domain: "GameProjectBootstrap", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "仓库已登记但重新读取失败"])
        }
        repos[i].implementationOwner = owner
        repos[i].qualityContract = qualityFile
        repos[i].manualReview = true
        // 新项目先做垂直切片，默认不让队列自行从 PLAN.md 扩张范围。
        repos[i].autoRefill = false
        try RepoRegistry.save(repos)

        return Result(created: created, preserved: preserved, repo: repos[i])
    }

    static let templates: [String: String] = [
        "AGENTS.md": """
        # 游戏项目事实

        > 首次派活前补全“产品身份”和验证命令。这里只放长期不变的事实；进度和待办
        > 分别写 STATUS.md 与 PLAN.md。

        ## 产品身份

        - 正式名称：待填写
        - 类型与目标平台：待填写
        - 一句话核心体验：待填写
        - 原创/IP 边界：参考对象只学习机制与体验，不复制名称、角色、地图或素材。

        ## 永久规则

        1. 不允许弄虚作假：完成、修复、验证都必须有可复现的实跑证据。
        2. 构建通过不等于体验达标；完成定义以 QUALITY.md 为准。
        3. 玩法规则、渲染表现和输入适配分层；核心规则必须可离屏测试。
        4. 数值与状态各有唯一来源，禁止界面、AI、结算各抄一份。
        5. 资产必须记录来源、授权和重新导入验证结果；占位资产不能冒充最终品质。
        6. 可见效果改动必须由实现者在同一任务内实跑、截图或录屏。

        ## 构建与测试

        - 构建命令：待填写，并同步登记到 `llmq repo verify`。
        - 测试命令：待填写。
        - 实机/模拟器目标：待填写。
        """,
        "QUALITY.md": """
        # 游戏质量契约

        这份文件是合并与“完成”判断的约束，不是愿望清单。未满足时必须明确写
        “未达标”，不能用代码存在、单测通过或构建成功代替体验验收。

        ## 1. 先过垂直切片

        扩充角色、武器、地图和模式前，先完成一个可反复游玩的最小闭环：一个角色、
        一套核心交互、一张小场景和一次完整开局—游玩—结算。闭环未达标时禁止靠
        增加内容数量制造“项目进展”。

        ## 2. 体验标准

        - 输入、动作、命中/交互、声音和画面反馈必须形成同一条因果链。
        - 人物与装备接触要检查姿势、接触距离和过渡，不只检查“不穿模”。
        - 动画不得用静态截图验收；必须录制待机、移动、核心动作和状态切换。
        - 镜头、UI、光照、材质和音频要服务核心玩法，不能停留在调试占位状态。

        ## 3. 技术底线

        - 目标设备与帧率：首次垂直切片前填写明确机型、目标值和最低值。
        - 完整游玩过程无崩溃、无卡死、无阻断闭环的错误。
        - 核心玩法可重复测试；随机性可控；同一份数值不在多层重复定义。
        - 导出资产必须重新导入最终运行时验证，生成工具里的预览不能代替成品。

        ## 4. 证据

        - 每个可见改动提交本次构建后的截图；动画、手感和流程提交 30–60 秒录屏。
        - 证据放 `docs/evidence/`，写清设备、构建、操作步骤和观察结果。
        - 终端构建日志、代码 diff、旧版本截图都不能证明最终效果。
        - 测试必须做变异验证：故意破坏关键实现，确认测试确实会失败。

        ## 5. 完成定义

        同时满足代码完成、构建与测试通过、目标设备端到端跑通、证据齐全、独立视觉/
        体验评审通过，才能标记完成或自动合并。
        """,
        "BENCHMARK.md": """
        # 参考对象拆解

        参考对象不是一句“对标某游戏”。首次垂直切片前逐行填写可测目标；只学习机制、
        节奏和反馈原则，不复制受保护的名称、角色、地图布局、音画表达或素材。

        | 维度 | 参考对象与具体片段 | 要学习的原则 | 本项目可测目标 | 验收证据 |
        |---|---|---|---|---|
        | 核心闭环 | 待填写 | 开局到结算为什么愿意再来一局 | 待填写 | 完整一局录屏 |
        | 输入与手感 | 待填写 | 输入到反馈的节奏与可预测性 | 待填写 | 慢放录屏/数值日志 |
        | 人物与动画 | 待填写 | 姿势、接触、重量与状态过渡 | 待填写 | 多视角动作录屏 |
        | 场景与引导 | 待填写 | 路线可读性、风险与选择 | 待填写 | 实玩路线录屏 |
        | 视听反馈 | 待填写 | 信息层级与命中/交互确认 | 待填写 | 有声录屏 |
        | 性能 | 待填写 | 目标设备稳定体验 | 待填写 | 帧率与卡顿记录 |
        """,
        "PLAN.md": """
        # 计划

        ## 当前唯一主线：垂直切片

        在 QUALITY.md 的最小可玩闭环达标前，不扩充批量角色、地图或玩法模式。
        把下一块工作拆成可在目标设备上直接验收的任务，并写明证据形式。
        """,
        "STATUS.md": """
        # 状态

        ## 当前结论

        垂直切片：未验收。这里记录已实跑的事实、证据路径和真实阻塞，不把计划写成完成。
        """,
        "docs/asset-log.md": """
        # 资产来源与授权

        | 资产 | 来源链接/作者 | 许可证或授权 | 修改 | 最终格式 | 重新导入验证 |
        |---|---|---|---|---|---|
        """,
        "docs/evidence/README.md": """
        # 验收证据

        每份证据写明日期、提交、设备、构建方式、复现步骤和观察结论。截图证明静态画面；
        动画、手感和流程必须录屏。构建日志只证明能编译，不能代替最终效果。
        """,
    ]
}
