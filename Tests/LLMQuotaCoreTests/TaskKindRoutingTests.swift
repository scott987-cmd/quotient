import XCTest
@testable import LLMQuotaCore

/// 任务类型判定**只准有一处实现**，而且编码任务绝不能落到评审执行器手里。
///
/// ## 这条对应的真实事故
///
/// 2026-08-18，派下去的第一批上架任务里，「把 Maw 里的临时调试入口清干净」
/// 被派给了 MiniMax 的**评审**执行器。那个执行器把**任何**提示词都当评审
/// 处理，于是它 20 秒写了一份 `reviews/EVAL-项目-*.md` 就报「完成」——
/// **一行调试代码都没删**。
///
/// 而且是静默的：任务状态 done、有提交、有分支，外面看一切正常。
/// 盘点发现**12 个非评审任务**被这样处理过 —— 那批一直合不进去的
/// `EVAL-*.md` 分支，大半就是这么来的。
///
/// 根因：同一个概念四种写法。调度那道闸判的是 `hasPrefix("【评审")`，
/// 而当天新加的合入审核用的是 `【审查·合入】`，两边对不上。
/// 「同一个概念多处判定」这个形状当天已经害了五次。
final class TaskKindRoutingTests: XCTestCase {

    func testReviewIntakePrefersMiniMaxByDefault() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-intake-\(UUID().uuidString)")
        Paths.appSupportOverride = scratch
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        let outcome = try TaskIntake.enqueue(
            prompt: "【审查】复查合并 abc", repo: "/tmp/project",
            classify: false, split: false, force: true)
        guard case .single(let task) = outcome else {
            return XCTFail("评审任务应作为单任务入队")
        }
        XCTAssertEqual(task.preferredPlatform, .minimax)
        XCTAssertEqual(task.profile?.tier, .standard)
        XCTAssertTrue(task.prompt.contains(ArchitectReview.contractMarker),
                      "新主观评审必须带复核契约，历史任务才不会被回灌")
    }

    func testTestingIntakePrefersMiniMaxAndStaysOneTask() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-intake-\(UUID().uuidString)")
        Paths.appSupportOverride = scratch
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        let outcome = try TaskIntake.enqueue(
            prompt: "【测试】运行全量回归并分析覆盖缺口", repo: "/tmp/project",
            classify: false, split: true, force: true)
        guard case .single(let task) = outcome else {
            return XCTFail("测试任务应整体交给 MiniMax，不应拆成开发图")
        }
        XCTAssertTrue(TaskKind.isTesting(task.prompt))
        XCTAssertTrue(TaskKind.isReview(task.prompt))
        XCTAssertEqual(task.preferredPlatform, .minimax)
        XCTAssertEqual(task.profile?.tier, .standard)
        XCTAssertFalse(task.prompt.contains(ArchitectReview.contractMarker),
                       "真实测试退出码不能交给架构师二次猜测")
    }

    func testMiniMaxTestingFindsVerifyCommandFromWorktree() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-test-runner-\(UUID().uuidString)")
        Paths.appSupportOverride = scratch.appendingPathComponent("support")
        defer {
            Paths.appSupportOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        let repo = scratch.appendingPathComponent("repo").path
        let worktree = scratch.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: repo,
                                                withIntermediateDirectories: true)
        func git(_ args: [String], in path: String = repo) {
            _ = GitWorkspace.git(args, in: path)
        }
        git(["init", "-q", "--initial-branch=main"])
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q",
             "--allow-empty", "-m", "base"])
        git(["branch", "test-worktree"])
        git(["worktree", "add", "-q", worktree, "test-worktree"])
        var entry = RepoAlias(alias: "runner", path: repo)
        entry.verifyCommand = "swift test"
        try RepoRegistry.save([entry])

        let command = MiniMaxReviewRunner().command(
            prompt: "【测试】运行全量回归", cwd: worktree)
        XCTAssertEqual(command.env["LLMQ_VERIFY_COMMAND"], "swift test",
                       "worktree 必须继承主仓登记的验证命令")
        XCTAssertTrue(command.args.joined().contains("真实退出码"))
        XCTAssertTrue(command.args.joined().contains("git diff \"$stamp^1\" \"$stamp\""),
                       "事后审查必须从 merge commit 读取完整改动")
    }

    /// **两种写法都得认。** 这套系统里人写「评审」、机器写「审查」，
    /// 只认一种就等于闸没关。
    func testBothReviewSpellingsAreRecognised() {
        let reviewPrompts = [
            "【评审·项目】Greed 卡牌游戏",
            "【评审·方案】给 Maw 加深度机制",
            "【审查·合入】分支 agent/kimi/x 的改动能不能合进 main",
            "【审查】复查刚合入 main 的合并 7f79ac8",
            "【测试】运行全量回归并分析失败日志",
        ]
        for p in reviewPrompts {
            XCTAssertTrue(TaskKind.isReview(p), "没认出是评审：\(p)")
            XCTAssertFalse(TaskKind.isCoding(p), "评审任务不该被当成编码活：\(p)")
        }
    }

    /// **没写前缀的就是编码活，任何专用执行器都不该接。**
    ///
    /// 这是事故的正面：那条「把调试入口清干净」没有前缀，
    /// 它必须被判成编码任务。
    func testUnprefixedPromptIsCoding() {
        let coding = [
            "把 Maw 里的临时调试入口清干净，让它能作为正式版发布。",
            "给 Greed 补上苹果强制要求的隐私清单",
            "修一下翻牌手感",
        ]
        for p in coding {
            XCTAssertTrue(TaskKind.isCoding(p), "该判成编码活：\(p)")
            XCTAssertFalse(TaskKind.isReview(p),
                           "编码活被判成评审 = 它会被写成一份报告，"
                           + "而真正的活一行都没干：\(p)")
            XCTAssertFalse(TaskKind.isMedia(p))
        }
    }

    /// 媒体任务判前缀，不判「含有」。
    ///
    /// 判「含有」的话，一句「这一步不做媒体资源」也会中 ——
    /// 然后这个编码任务被派给生图执行器，必然产出垃圾。
    func testMediaIsPrefixOnly() {
        XCTAssertTrue(TaskKind.isMedia("【媒体】生成 4 张遗物图标"))
        XCTAssertFalse(TaskKind.isMedia("本步不做媒体资源，只改代码"),
                       "正文提到「媒体」不代表它是媒体任务")
    }

    /// 今天新加的两类前缀也要认，别让它们掉进「编码活」里
    /// 被普通执行器抢走。
    func testTodaysNewPrefixesAreClassified() {
        XCTAssertTrue(TaskKind.isEvidence("【证据】把分支跑起来截图"))
        XCTAssertTrue(TaskKind.isRefresh("【刷新】把 main 合进分支 agent/a/x"))
        XCTAssertFalse(TaskKind.isCoding("【证据】把分支跑起来截图"))
        XCTAssertFalse(TaskKind.isCoding("【刷新】把 main 合进分支 agent/a/x"))
    }

    /// **调度闸：评审执行器只接评审任务。**
    ///
    /// 这条直接复刻事故现场 —— 一个没前缀的编码任务，
    /// 评审执行器必须被拒。
    func testReviewOnlyRunnerRejectsCodingTask() {
        var t = WorkTask(id: "t1",
                         prompt: "把 Maw 里的临时调试入口清干净",
                         repo: "/tmp/x")
        t.state = .queued
        let d = WorkScheduler().decide(
            dashboard: LLMQuota.dashboard(),
            runners: RunnerRegistry.all, task: t, history: [])
        let reviewRejected = d.rejected.contains {
            $0.reason.contains("评审")
        }
        XCTAssertTrue(reviewRejected || d.candidates.allSatisfy { $0.platform != .minimax },
                      "编码任务要么明确拒掉评审执行器，要么根本不该把它列成候选 —— "
                      + "否则它会把这活写成一份报告：\(d.rejected)")
    }

    func testReviewAndTestingRejectDevelopmentRunners() {
        for prompt in ["【审查】复查合并 abc", "【测试】运行全量回归"] {
            var task = WorkTask(id: UUID().uuidString, prompt: prompt, repo: "/tmp/x")
            task.state = .queued
            task.profile = TaskProfile(
                tier: .standard, risk: .safe, estimatedMinutes: 8,
                isSelfContained: true, rationale: "测试")
            task.preferredPlatform = .minimax
            let decision = WorkScheduler().decide(
                dashboard: LLMQuota.dashboard(), runners: RunnerRegistry.all,
                task: task, history: [])
            XCTAssertTrue(decision.candidates.allSatisfy {
                $0.runner.runnerID == "minimax.review"
            },
                          "评审和测试不得回退消耗开发 Agent：\(decision.candidates)")
        }
    }
    // MARK: 基线闸：解锁的钥匙不能被锁在外面

    /// **审查 / 证据 / 刷新 / 媒体不该等基线。**
    ///
    /// 实测（2026-08-19）：基线闸原先对所有任务一视同仁，于是
    ///
    ///   基线旧（有分支没合）→ 挡住所有任务 → 审查任务跑不了
    ///     → 分支等不到 agent 审核 → 永远合不进去 → 基线永远旧
    ///
    /// **解开基线的钥匙被基线锁在外面。** 整套系统停摆两天，
    /// 老板在手机上看到的是「正在进行」永远空着。
    func testUnblockingKindsDoNotWaitForBaseline() {
        let exempt = [
            "【审查】复查刚合入 main 的合并 fc6c225（来源分支 agent/graph/f2872114）",
            "【审查·合入】分支 agent/kimi/x 的改动能不能合进 main",
            "【评审·项目】Greed 卡牌游戏",
            "【证据】把分支 agent/qwen/abc21d46 的改动跑起来",
            "【刷新】把 main 合进分支 agent/a/x",
            "【媒体】生成 4 张遗物图标",
        ]
        for p in exempt {
            XCTAssertFalse(TaskKind.needsFreshBaseline(p),
                           "这类活拿旧基线也不会重造任何东西，"
                           + "挡住它就是把解锁的钥匙锁在外面：\(p)")
        }
    }

    /// **但编码活必须等。** 别把「解死结」做成「闸全拆了」——
    /// 基线闸挡住的是最贵的一种浪费：agent 拿落后几十个提交的 main
    /// 当「现状」，把已经做好的东西重造一遍。
    func testCodingWorkStillWaitsForBaseline() {
        let coding = [
            "把 Maw 里的临时调试入口清干净，让它能作为正式版发布。",
            "给 Greed 补上苹果强制要求的隐私清单",
            "修一下翻牌手感",
        ]
        for p in coding {
            XCTAssertTrue(TaskKind.needsFreshBaseline(p),
                          "编码活拿旧基线会重造已有的东西：\(p)")
        }
    }

}
