import XCTest
@testable import LLMQuotaCore


// MARK: - 真需求规则

extension ReservePoolTests {
    /// TODO 只认注释里的 —— 字符串常量里的 "TODO" 是数据不是欠账。
    func testTodoOnlyCountsComments() {
        XCTAssertEqual(ReservePool.todoNote("// TODO: 把重试次数改成可配置"),
                       "把重试次数改成可配置")
        XCTAssertEqual(ReservePool.todoNote("    // FIXME 这里的时区判断在夏令时会错"),
                       "这里的时区判断在夏令时会错")
        XCTAssertNil(ReservePool.todoNote("/// TODO 是写代码的人自己留的账"),
                     "文档正文里的规则名不是待办，不应该递归生成任务")
        XCTAssertNil(ReservePool.todoNote(#"let rule = "TODO: something""#),
                     "字符串里的 TODO 不是待办，派下去只会改坏代码")
        XCTAssertNil(ReservePool.todoNote("// TODO"), "光写 TODO 没说干什么，转不成任务")
    }

    /// 审查报告的真实格式：`### 3. Foo.swift:91 — 描述（低）`。
    ///
    /// 这个测试是拿 ~/dev/Maw/reviews/REVIEW-0f5bba0.md 的真实内容钉的 ——
    /// 第一版按 `- [ ]` 复选框写解析，对着真报告一条都挖不出来。
    func testReviewFindingsParseRealReportFormat() throws {
        XCTAssertNotNil(ReservePool.findingNote(
            "### 2. Tuning.swift:90 — 注释「十来口」与实际数值不符（低）"))
        XCTAssertNotNil(ReservePool.findingNote("- [ ] 冷却台账写入没加锁"))
        XCTAssertNil(ReservePool.findingNote("## 发现"),
                     "章节标题不是发现 —— 没有文件:行就没法定位，派下去只能瞎猜")
        XCTAssertNil(ReservePool.findingNote("### 审查方法"))
    }

    func testReviewFindingsReadRecentReportsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-\(UUID().uuidString)")
        let reviews = root.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
        try """
        # 审查：合并 abc1234
        ## 发现
        ### 1. GameScene.swift:113 — 调试入口未做门控（中）
        正文正文。
        """.write(to: reviews.appendingPathComponent("REVIEW-abc1234.md"),
                  atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let facts = ReservePool.reviewFindings(root: root, limit: 10)
        XCTAssertEqual(facts.count, 1, "挖出的应该只有那条带文件:行的发现：\(facts.map(\.symbol))")
        XCTAssertTrue(facts[0].symbol.contains("GameScene.swift:113"))
        XCTAssertTrue(ReservePool.prompt(for: facts[0]).contains("GameScene.swift:113"),
                      "任务描述里必须带定位信息，否则 agent 得自己找")

        // 报告太老就不看了：问题多半早修了，派下去是白烧额度
        let old = Date().addingTimeInterval(-20 * 86400)
        XCTAssertTrue(ReservePool.reviewFindings(root: root, limit: 10,
                                                 now: Date().addingTimeInterval(20 * 86400)).isEmpty,
                      "两周前的报告不该再派")
        _ = old
    }
}

/// 冷却误判 —— 每一条误判都等于白冻一个能用的平台。
final class CooldownClassifyTests: XCTestCase {
    /// 实际烧过钱的那一次：火山方舟跑游戏任务超时，输出里有 "insufficient
    /// contrast"，整段命中 "insufficient" → 被冻 1 天 16 小时。
    func testAgentProseDoesNotFreezeAPlatform() {
        XCTAssertNil(CooldownLedger.classify(
            "checking palette: insufficient contrast between player and background"))
        XCTAssertNil(CooldownLedger.classify(
            "读 QuotaSignal.swift：这段是判断额度打满的关键词表"),
            "在这个项目里 agent 天天写「额度」，不能因此冻掉它自己的平台")
        XCTAssertNil(CooldownLedger.classify("+ let quotaWords = [\"quota\"]"))
        XCTAssertNil(CooldownLedger.classify("超时被终止"))
    }

    /// 现场复刻：Codex 的上下文里带着旧 Kimi 提交标题，标题原样引用了
    /// “quota refreshed / purchase extra usage”；本次真正的失败只是请求断流。
    /// 失败分类只能看终端失败摘要，不能让历史上下文替本次平台报额度耗尽。
    func testHistoricalQuotaTextDoesNotTurnTransportFailureIntoQuotaExhaustion() {
        let stdout = """
        历史提交：wip(kimi): Your quota will be refreshed in the next cycle.
        To continue now, purchase extra usage or upgrade your plan.
        """
        let stderr = """
        sending request for url (https://chatgpt.com/backend-api/codex/responses)
        ERROR: stream disconnected before completion: error sending request
        """

        let failure = FailureClassifier.classify(
            exitCode: 1, stdout: stdout, stderr: stderr, timedOut: false)
        guard case .platformUnavailable = failure else {
            return XCTFail("网络断流应短暂切走平台，不是额度耗尽：\(String(describing: failure))")
        }
        XCTAssertEqual(CooldownLedger.classify(failure?.describe ?? ""),
                       .environmentBroken)
    }

    /// 服务端真说打满了，还是要认出来。
    func testRealServerRejectionIsStillCaught() {
        XCTAssertEqual(CooldownLedger.classify(
            "API Error: Request rejected (429) · [已达到 5 小时的使用上限。]"),
            .quotaExhausted)
        XCTAssertEqual(CooldownLedger.classify(
            "429 token-plan 1-week quota exhausted; resets 08-17"), .quotaExhausted)
        XCTAssertEqual(CooldownLedger.classify(
            ". Your quota will be refreshed in the next cycle. To continue now, "
            + "purchase extra usage or upgrade your plan"), .quotaExhausted,
            "Kimi 的原话没有 429，但 refreshed in the next cycle 是明说打满了")
    }

    /// Claude Code 2.1.246 的会话窗口耗尽原文。2026-08-26 因未识别这句，
    /// 调度器在 11 分钟内连续派了三次必然失败的架构复核。
    func testClaudeSessionLimitIsCaught() {
        XCTAssertEqual(CooldownLedger.classify(
            "You've hit your session limit · resets 5:50pm (Asia/Shanghai)"),
            .quotaExhausted)
    }
}

extension CooldownClassifyTests {
    /// 超时不该判成额度用尽 —— 这是今天误冻两个平台的那条路径。
    ///
    /// 火山方舟 1 天 16 小时、Kimi 7 小时 45 分，两次的详情都明写着
    /// 「超时被终止」。超时被杀时输出是被掐断的半截，拿它判额度不成立。
    func testTimeoutIsNotQuotaExhaustion() {
        let f = FailureClassifier.classify(
            exitCode: -9,
            stdout: "正在调整对比度… insufficient contrast, 重新生成",
            stderr: "", timedOut: true)
        guard case .timedOut = f else {
            return XCTFail("超时应该判成 timedOut，实际是 \(String(describing: f))")
        }
    }

    /// 真额度用尽仍然要判成「平台不可用」，这样才会换平台重试。
    func testRealQuotaExhaustionStillSwitchesPlatform() {
        let f = FailureClassifier.classify(
            exitCode: 1,
            stdout: "API Error: Request rejected (429) · [已达到 5 小时的使用上限。]",
            stderr: "", timedOut: false)
        guard case .platformUnavailable = f else {
            return XCTFail("真打满要换平台，实际是 \(String(describing: f))")
        }
        XCTAssertTrue(f?.shouldTryNextPlatform == true)
    }

    /// agent 正常输出里提到额度，不该让它被判成平台不可用。
    func testAgentMentioningQuotaIsJustATaskFailure() {
        let f = FailureClassifier.classify(
            exitCode: 1,
            stdout: "读 QuotaSignal.swift，这段在判额度打满；测试没过",
            stderr: "", timedOut: false)
        guard case .agentFailed = f else {
            return XCTFail("这是任务失败不是平台问题，实际是 \(String(describing: f))")
        }
    }
}

extension CooldownClassifyTests {
    /// 额度用尽不做指数退避 —— 它有确定的恢复时刻。
    func testQuotaExhaustionDoesNotBackOffForDays() {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: sandbox)
        }

        var last: Cooldown?
        // 连撞四次 —— 实际发生过的情形（strikes 堆到 4）
        for _ in 0..<4 {
            last = CooldownLedger.record(platform: .claude, cause: .quotaExhausted,
                                         detail: "429 已达到 5 小时的使用上限")
        }
        let hours = (last?.remaining ?? 0) / 3600
        XCTAssertLessThanOrEqual(hours, 5.1,
            "Claude 是 5 小时窗，冻 \(Int(hours)) 小时是白冻——而它还是本机的指挥")
    }

    /// 服务端给了确切重置时间就采信，别用兜底值盖掉。
    func testKnownResetTimeWins() {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: sandbox)
        }
        let reset = Date().addingTimeInterval(7 * 86400)
        let cd = CooldownLedger.record(platform: .qwen, cause: .quotaExhausted,
                                       detail: "1-week quota exhausted",
                                       knownResetAt: reset)
        XCTAssertEqual(cd.until.timeIntervalSince1970, reset.timeIntervalSince1970,
                       accuracy: 1, "周窗真的要等一周，别用 5 小时兜底盖掉")
    }

    func testKimiSevenDayExhaustionUsesConfiguredWeeklyReset() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cd-weekly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: sandbox)
        }

        let now = Date(timeIntervalSince1970: 1_787_887_800) // 2026-08-28 03:30Z
        let reset = Date(timeIntervalSince1970: 1_787_899_620) // 2026-08-28 06:47Z
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "Kimi", limits: [QuotaLimit(
                id: "weekly", label: "每周", windowMinutes: 10_080,
                kind: .periodic, metric: .billableTokens, anchor: reset)])])
        try PlansStore.save(config, force: true)

        let cd = CooldownLedger.record(
            platform: .kimi, cause: .quotaExhausted,
            detail: "Please try again when the current 7-day window ends.", now: now)
        XCTAssertEqual(cd.until, reset,
                       "明确说 7-day window 时必须等配置中的周窗口结束，不能只冻 5 小时")
    }

    func testLegacyFiveHourCooldownStaysExhaustedUntilItsWeeklyWindowEnds() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cd-legacy-weekly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.appSupportOverride = sandbox
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: sandbox)
        }

        let now = Date(timeIntervalSince1970: 1_787_887_800)
        let reset = Date(timeIntervalSince1970: 1_787_899_620)
        let config = PlansConfig(plans: [PlatformPlan(
            platform: .kimi, planName: "Kimi", limits: [QuotaLimit(
                id: "weekly", label: "每周", windowMinutes: 10_080,
                kind: .periodic, metric: .billableTokens, anchor: reset)])])
        let legacy = Cooldown(
            platform: .kimi, cause: .quotaExhausted,
            since: now.addingTimeInterval(-6 * 3600),
            until: now.addingTimeInterval(-3600), strikes: 4,
            detail: "current 7-day window ends")
        try Paths.ensureDirectories()
        let data = try SnapshotCoding.prettyEncoder().encode([legacy])
        ICloudSafe.write(data, to: CooldownLedger.file)

        let active = CooldownLedger.active(now: now, config: config)[.kimi]
        XCTAssertEqual(active?.until, reset,
                       "旧版错误写下的 5 小时截止时间不能让周额度提前显示恢复")
        XCTAssertTrue(CooldownLedger.active(
            now: reset.addingTimeInterval(1), config: config).isEmpty,
            "跨过周窗口后必须真的解冻，不能把旧错误永久续到下一周")
    }

    /// 日志行是整个 JSON，要抠出服务端那句话，不是取头 200 字符。
    func testExcerptFindsTheActualMessage() {
        let line = #"{"parentUuid":"a0d60529-f794-4368-af2c-eeb212c4123a","sessionId":"x","type":"assistant","message":{"content":"API Error: Request rejected (429) · [1308][已达到 5 小时的使用上限。您的限额将在 2026-08-15 12:00:47 重置。]"}}"#
        let got = QuotaSignal.excerpt(line)
        XCTAssertTrue(got.contains("已达到 5 小时的使用上限"),
                      "抠出来的是：\(got)")
        XCTAssertFalse(got.hasPrefix("{\"parentUuid\""),
                       "别再把 UUID 头部当成错误消息存进台账")
    }
}

extension CooldownClassifyTests {
    /// 日志里提到额度 ≠ 撞上额度。今天连撞三次的那条路径。
    func testOnlyModelSideRejectionsCount() {
        // 1. agent 跑的命令
        XCTAssertFalse(QuotaSignal.looksExhausted(
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"API Error: Request rejected (429) 已达到使用上限"}]}}"#),
            "工具读到的文本不是我们自己撞的")
        // 2. 模型的思考内容里引用了错误消息
        XCTAssertFalse(QuotaSignal.looksExhausted(
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"API Error: Request rejected (429) 已达到 5 小时的使用上限——这就是要修的那条"}]}}"#),
            "模型在思考里引用一句错误消息，不等于真撞上了")
        // 3. 纯粹的工具调用
        XCTAssertFalse(QuotaSignal.looksExhausted(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep 429 额度 quota"}}]}}"#))
    }

    /// 服务端真的拒绝了，还是要认出来。
    func testServerRejectionIsStillASignal() {
        XCTAssertTrue(QuotaSignal.looksExhausted(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"API Error: Request rejected (429) · [1308][已达到 5 小时的使用上限。您的限额将在 2026-08-15 12:00:47 重置。]"}]}}"#))
    }
}

/// 跨机同步的结构体必须对「老版本写的、缺新字段」的数据免疫。
final class SnapshotCompatTests: XCTestCase {
    /// 这是真实事故的最小复现：给 OfficialQuota 加了 advisory 字段之后，
    /// 另一台机器（还没升级）写的快照解不出来，整台机器从 dashboard 消失，
    /// 调度以为它上面的平台全没在用。
    ///
    /// 根因是 Swift 合成的 Decodable **不用属性默认值** ——
    /// `var advisory = false` 不代表缺这个键时会填 false，而是直接抛错。
    func testOldQuotaWithoutNewFieldsStillDecodes() throws {
        let json = """
        {"id":"weekly","label":"每周","usedPercent":13,"windowMinutes":10080,
         "observedAt":"2026-08-16T06:33:37Z"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let q = try dec.decode(OfficialQuota.self, from: Data(json.utf8))
        XCTAssertEqual(q.id, "weekly")
        XCTAssertFalse(q.advisory, "缺 advisory 要当成 false，不是解码失败")
        XCTAssertNil(q.usedCount)
        XCTAssertNil(q.countUnit)
    }

    /// 新字段写出去也要能读回来 —— 别只顾着兼容旧的。
    func testNewFieldsRoundTrip() throws {
        let q = OfficialQuota(
            id: "weekly-video", label: "video 每周", usedPercent: 58,
            windowMinutes: 10080, observedAt: Date(),
            usedCount: 12, totalCount: 21, countUnit: "次", advisory: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(OfficialQuota.self, from: try enc.encode(q))
        XCTAssertEqual(back.usedCount, 12)
        XCTAssertEqual(back.totalCount, 21)
        XCTAssertTrue(back.advisory)
    }
}

/// 开源要能被陌生人快速试用。
final class FreshInstallTests: XCTestCase {
    /// `LLMQ_HOME` 能把整个数据目录挪走。
    ///
    /// 为什么需要：`FileManager.homeDirectoryForCurrentUser` 在 macOS 上从
    /// passwd 读，**不受 `HOME` 影响** —— 没法靠改 HOME 造干净环境。
    /// 而干净环境是三件事的前提：新用户想先试试不弄脏自己的配置、
    /// CI 跑端到端、演示可复现。
    func testDataDirectoryIsRedirectable() {
        // 进程内 override 优先级更高，免得环境变量顶掉测试沙盒
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-\(UUID().uuidString)")
        Paths.appSupportOverride = sandbox
        defer { Paths.appSupportOverride = nil }
        XCTAssertEqual(Paths.appSupport, sandbox,
                       "进程内 override 必须压过环境变量，否则测试会污染真实数据")
    }

    /// 内置清单是**模板**，不能带任何人的真实项目路径。
    ///
    /// 早先这里写死了作者自己的资产包仓库（连定价和五个主题方向都在），
    /// 别人 clone 下来第一条内置项目就是别人的私事。
    func testBuiltinPlaybookShipsNoPersonalPaths() {
        for p in Playbook.builtins() {
            XCTAssertNil(p.repo, "内置项目不该预置任何真实仓库路径")
            let blob = p.brief + p.recipes.map(\.prompt).joined()
                + p.backlog.joined() + p.shipped.joined()
            for leak in ["~/dev/", "/Users/", "itch.io", "dushibing"] {
                XCTAssertFalse(blob.contains(leak),
                               "内置模板里不该出现「\(leak)」——那是作者的私事")
            }
        }
    }
}

/// 解码失败必须留痕，而且信息要能直接指向修法。
final class SafeDecodeTests: XCTestCase {
    private struct Thing: Codable { var a: String; var b: Int }

    override func setUp() { super.setUp(); SafeDecode.reset() }

    /// 缺字段是跨版本最常见的一种：新版加了字段，老版写的文件没有它。
    /// 错误信息要直说缺哪个、在哪、怎么修 —— 今天为这个查了半小时。
    func testMissingFieldSaysWhatAndHowToFix() {
        let got: Thing? = SafeDecode.json(#"{"a":"x"}"#.data(using: .utf8)!,
                                          as: Thing.self, from: "老文件.json")
        XCTAssertNil(got)
        XCTAssertEqual(SafeDecode.failures.count, 1)
        let r = SafeDecode.failures[0].reason
        XCTAssertTrue(r.contains("缺字段「b」"), "要说清缺哪个：\(r)")
        XCTAssertTrue(r.contains("decodeIfPresent"), "要给出修法：\(r)")
    }

    /// 文件不存在不算失败 —— 「还没有这个文件」是正常状态，
    /// 记成错误会把真正的问题淹掉。
    func testMissingFileIsNotAFailure() {
        let got: Thing? = SafeDecode.json(
            at: URL(fileURLWithPath: "/tmp/不存在-\(UUID().uuidString).json"),
            as: Thing.self)
        XCTAssertNil(got)
        XCTAssertTrue(SafeDecode.failures.isEmpty)
    }

    /// 类型不对也要说清楚位置。
    func testTypeMismatchIsExplained() {
        _ = SafeDecode.json(#"{"a":"x","b":"不是数字"}"#.data(using: .utf8)!,
                            as: Thing.self, from: "坏文件.json")
        XCTAssertTrue(SafeDecode.failures.first?.reason.contains("类型不对") == true)
    }

    /// 攒太多要裁掉 —— 跑几天的 worker 不该攒出几万条。
    func testFailuresAreCapped() {
        for i in 0..<80 {
            SafeDecode.note(file: "f\(i)", type: "T", reason: "r")
        }
        XCTAssertLessThanOrEqual(SafeDecode.failures.count, 50)
        XCTAssertEqual(SafeDecode.failures.last?.file, "f79", "留的应该是最近的")
    }
}

/// 视图层的跨版本免疫。
///
/// 这三条是「服务端能不能先发新东西」的**前提条件**。任何一条不成立，
/// 服务端就被客户端的版本锁死了 —— 而客户端要走审核，一次一周。
final class ViewFeedCompatTests: XCTestCase {
    private func decode(_ json: String) -> ViewFeed.Page? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ViewFeed.Page.self, from: Data(json.utf8))
    }

    /// 1. 未知的区块类型不能让整页解码失败 —— 它必须能被读出来然后跳过。
    func testUnknownSectionKindStillDecodes() {
        let page = decode("""
        {"schema":1,"page":"now","generatedAt":"2026-08-16T14:00:00Z",
         "sections":[
           {"kind":"meters","meters":[{"label":"A","fraction":0.5,"tone":"warn"}]},
           {"kind":"未来才有的类型","someNewField":{"a":1},"title":"新东西"}
         ]}
        """)
        XCTAssertEqual(page?.sections.count, 2, "未知 kind 要读出来（客户端负责跳过），不是让整页失败")
        XCTAssertEqual(page?.sections[1].kind, "未来才有的类型")
    }

    /// 2. 多出来的字段要被忽略 —— 新服务端写的东西，老客户端也要能读。
    func testExtraFieldsAreIgnored() {
        let page = decode("""
        {"schema":1,"page":"now","generatedAt":"2026-08-16T14:00:00Z",
         "brandNewTopLevelKey":42,
         "sections":[{"kind":"text","text":"x","futureField":"y"}]}
        """)
        XCTAssertEqual(page?.sections.first?.text, "x")
    }

    /// 3. 缺字段要有默认值 —— 老服务端写的东西，新客户端也要能读。
    func testMissingFieldsGetDefaults() {
        let page = decode("""
        {"schema":1,"page":"now","generatedAt":"2026-08-16T14:00:00Z",
         "sections":[{"kind":"text"}]}
        """)
        let s = page?.sections.first
        XCTAssertEqual(s?.tone, .neutral, "缺 tone 要默认 neutral，不是解码失败")
        XCTAssertNil(s?.meters)
    }

    /// 未知的 tone 也不能炸 —— 服务端哪天加个 "critical"，老客户端得活着。
    func testUnknownToneFallsBack() {
        let page = decode("""
        {"schema":1,"page":"now","generatedAt":"2026-08-16T14:00:00Z",
         "sections":[{"kind":"text","tone":"某种新语气"}]}
        """)
        XCTAssertEqual(page?.sections.first?.tone, .neutral)
    }

    /// 动作 id 对服务端有意义，对客户端只是个字符串 ——
    /// 加一种新动作不该需要客户端认识它。
    func testActionIsOpaqueToClient() {
        let page = decode("""
        {"schema":1,"page":"now","generatedAt":"2026-08-16T14:00:00Z",
         "sections":[{"kind":"cards","cards":[
           {"id":"c1","title":"t","tone":"warn","images":[],
            "actions":[{"id":"future:verb:arg","label":"做点新事",
                        "style":"primary","needsNote":false}]}]}]}
        """)
        XCTAssertEqual(page?.sections.first?.cards?.first?.actions.first?.id,
                       "future:verb:arg")
    }
}
