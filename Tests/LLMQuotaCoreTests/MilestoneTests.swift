import XCTest
@testable import LLMQuotaCore

/// **做出来的东西要主动送到老板眼前。**
///
/// 老板(2026-08-22)的原话:「为啥没有录屏发给我进行评审?这个不应该
/// 你驱动,应该是我们的数字人程序在关键成果产出需要找我确认啊」。
///
/// 缺口是真的:manualReview 仓库由评审 agent 判合入、自动落地,分支
/// 从来不进「待验收」名单 —— 人被彻底跳过。而他看录屏发现的问题
/// (「跑的姿势不像真人」「手歪不拉几」)全是真的。
final class MilestoneTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmpDir() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRecordingWithVideoIsWorthShowing() {
        XCTAssertTrue(Milestone.isWorthShowing(files: [
            "Flint/Render/GameContainerView.swift",
            "docs/evidence/2026-08-21-bot-ai-v1-combat.mov"]),
            "带录屏 = 做出了能看效果的东西 = 该让老板看")
    }

    /// 纯文档/评审报告不打扰他 —— 天天弹的通知会被训练成背景噪音,
    /// 真成果那次也一起被划走。
    func testRoutineChangesDoNotNag() {
        XCTAssertFalse(Milestone.isWorthShowing(files: [
            "STATUS.md", "reviews/EVAL-合入-abc-def.md", "Flint/Sim/Economy.swift"]),
            "改代码但没有可看的效果 —— 不惊动他")
        XCTAssertFalse(Milestone.isWorthShowing(files: []))
    }

    /// 判据必须和证据闸同一套(isEvidenceFile),不许另写。
    /// 同一个概念多处判定,这个仓库已经踩过九次。
    func testUsesTheSameEvidenceJudgeAsTheGate() {
        XCTAssertEqual(Milestone.isWorthShowing(files: ["docs/evidence/run.log"]),
                       EvidenceGate.isEvidenceFile("docs/evidence/run.log"),
                       "文本实跑证据算不算,两边必须给同一个答案")
        XCTAssertEqual(Milestone.isWorthShowing(files: ["Assets/hero.png"]),
                       EvidenceGate.isEvidenceFile("Assets/hero.png"),
                       "随便一张美术图不因为是图片就算成果")
    }

    func testUnreviewedFiltersOutWhatBossAlreadySaw() {
        let seen = Milestone.Item(repo: "/r", repoName: "r", branch: "b1",
                                  mergeSHA: "aaa", subject: "看过的", landedAt: Date(),
                                  evidenceFiles: [], verdict: "行")
        let fresh = Milestone.Item(repo: "/r", repoName: "r", branch: "b2",
                                   mergeSHA: "bbb", subject: "没看的", landedAt: Date(),
                                   evidenceFiles: [], verdict: nil)
        Milestone.save([seen, fresh])
        XCTAssertEqual(Milestone.unreviewed().map(\.mergeSHA), ["bbb"],
                       "看过的不再打扰")
    }

    func testRejectedMilestoneQueuesSameOwnerProjectRemediationOnce() throws {
        let item = Milestone.Item(repo: "/flint", repoName: "Flint",
                                  branch: "agent/kimi/source1", mergeSHA: "abc1234",
                                  subject: "持枪姿势", landedAt: Date(),
                                  evidenceFiles: ["pose.png"], verdict: nil)
        Milestone.save([item])
        var source = WorkTask(id: "source1", prompt: "实现姿势", repo: "/flint")
        source.state = .done
        source.platform = .kimi
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"

        XCTAssertTrue(Milestone.decide(repo: "/flint", mergeSHA: "abc1234",
                                       approved: false, note: "左手没有握住前护木",
                                       tasks: [source]))
        let repair = try XCTUnwrap(TaskStore.all().last)
        XCTAssertEqual(repair.id, "mabc1234",
                       "两台机器同时收动作时要落成同一个逻辑任务 ID")
        XCTAssertEqual(repair.origin, "milestone-remediation:abc1234")
        XCTAssertEqual(repair.ownerPlatform, .kimi)
        XCTAssertEqual(repair.ownerRunnerID, "kimi.code")
        XCTAssertTrue(repair.prompt.contains("左手没有握住前护木"))
        XCTAssertEqual(Milestone.unreviewed().count, 0)

        XCTAssertTrue(Milestone.decide(repo: "/flint", mergeSHA: "abc1234",
                                       approved: false, note: "重复点击",
                                       tasks: TaskStore.all() + [source]))
        XCTAssertEqual(TaskStore.all().filter {
            $0.origin == "milestone-remediation:abc1234"
        }.count, 1, "同一成果的重复动作不能造两条整改")
    }

    func testReviewPageShowsLandedMilestoneWithExecutableDecisionActions() {
        Milestone.save([Milestone.Item(
            repo: "/flint", repoName: "Flint", branch: "agent/kimi/t1",
            mergeSHA: "abc1234", subject: "人物样板", landedAt: Date(),
            evidenceFiles: ["operator.png", "gameplay.m4v"], verdict: nil)])
        let page = ViewFeed.reviewPage()
        let cards = page.sections.flatMap { $0.cards ?? [] }
        let card = cards.first { $0.id == "/flint|abc1234" }
        XCTAssertEqual(card?.images, ["operator.png", "gameplay.m4v"])
        XCTAssertEqual(card?.actions.map(\.id), [
            "milestone:approve:/flint|abc1234",
            "milestone:reject:/flint|abc1234",
        ])
    }

    func testLegacyMilestoneDecodesAsLandedResult() throws {
        let data = Data(#"{"repo":"/flint","repoName":"Flint","branch":"b","mergeSHA":"abc","subject":"旧成果","landedAt":"2026-08-22T00:00:00Z","evidenceFiles":[],"verdict":null}"#.utf8)
        let item = try SnapshotCoding.decoder().decode(Milestone.Item.self, from: data)
        XCTAssertFalse(item.isCheckpoint)
        XCTAssertNil(item.taskID)
        XCTAssertNil(item.phase)
    }

    func testRunningCheckpointCanBeReviewedWithoutCreatingAnotherTask() throws {
        let item = Milestone.Item(
            repo: "/flint", repoName: "Flint", branch: "agent/kimi/live1",
            mergeSHA: "def5678", subject: "人物母版三机位", landedAt: Date(),
            evidenceFiles: ["front.jpg", "side.jpg"], verdict: nil,
            taskID: "live1", isCheckpoint: true)
        Milestone.save([item])
        var source = WorkTask(id: "live1", prompt: "制作人物母版", repo: "/flint")
        source.state = .running
        source.branch = item.branch
        source.platform = .kimi
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"

        XCTAssertTrue(Milestone.decide(
            repo: "/flint", mergeSHA: "def5678", approved: false,
            note: "45 度机位有白色遮挡，脸部近景拍成了胸口", tasks: [source]))

        XCTAssertTrue(TaskStore.all().isEmpty,
                      "运行中 checkpoint 被拒应反馈原会话，不能再拆整改任务")
        let feedback = try XCTUnwrap(CollaborationStore.all().last)
        XCTAssertEqual(feedback.taskID, "live1")
        XCTAssertEqual(feedback.recipientRunnerID, "kimi.code")
        XCTAssertEqual(feedback.kind, .finding)
        XCTAssertTrue(feedback.summary.contains("白色遮挡"))
    }

    func testRunningCheckpointDirectoryBecomesOneHumanReviewItem() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let evidenceDir = repo.appendingPathComponent("Production/evidence/M0")
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: evidenceDir.appendingPathComponent("front.png"))
        XCTAssertEqual(Proc.run("/usr/bin/git", ["init"], cwd: repo.path,
                                env: [:], timeout: 10).exitCode, 0)
        XCTAssertEqual(Proc.run("/usr/bin/git", ["add", "."], cwd: repo.path,
                                env: [:], timeout: 10).exitCode, 0)
        XCTAssertEqual(Proc.run("/usr/bin/git", ["-c", "user.name=Test", "-c",
            "user.email=test@example.invalid", "commit", "-m", "checkpoint"],
            cwd: repo.path, env: [:], timeout: 10).exitCode, 0)
        var task = WorkTask(id: "live1", prompt: "制作人物母版", repo: repo.path)
        task.state = .running
        task.branch = "agent/kimi/live1"
        let progress = WorkProgress(
            taskID: task.id, sequence: 1, phase: "M0", summary: "三机位渲染完成",
            evidence: ["Production/evidence/M0"], evidenceFingerprint: "fp",
            requestedMinutes: 20, updatedAt: Date())

        let item = try XCTUnwrap(Milestone.recordCheckpoint(
            task: task, progress: progress, repo: repo.path))
        XCTAssertTrue(item.isCheckpoint)
        XCTAssertEqual(item.taskID, task.id)
        XCTAssertEqual(item.evidenceFiles.count, 1)
        XCTAssertEqual(Milestone.unreviewed().count, 1,
                       "一个提交无论声明目录里有几份证据，都只能形成一张复核卡")
    }

    func testReviewPageLabelsCheckpointWithoutInventingCurrentTaskState() {
        Milestone.save([Milestone.Item(
            repo: "/flint", repoName: "Flint", branch: "agent/kimi/live1",
            mergeSHA: "def5678", subject: "人物母版三机位", landedAt: Date(),
            evidenceFiles: ["front.jpg"], verdict: nil,
            taskID: "live1", isCheckpoint: true)])
        let page = ViewFeed.reviewPage()
        let section = page.sections.first { ($0.cards ?? []).contains { $0.id == "/flint|def5678" } }
        let card = section?.cards?.first { $0.id == "/flint|def5678" }
        XCTAssertEqual(section?.title, "待你复核成果（1）")
        XCTAssertTrue(card?.body?.contains("阶段成果未合入") == true)
        XCTAssertFalse(card?.body?.contains("任务仍在运行") == true)
        XCTAssertFalse(card?.body?.contains("已合入 main") == true)
    }

    func testScreenshotOnlyCheckpointNotificationDoesNotClaimThereIsVideo() {
        Milestone.save([Milestone.Item(
            repo: "/flint", repoName: "Flint", branch: "agent/kimi/live1",
            mergeSHA: "def5678", subject: "人物母版三机位", landedAt: Date(),
            evidenceFiles: ["front.jpg", "side.jpg"], verdict: nil,
            taskID: "live1", isCheckpoint: true)])
        let notice = Nudge.pending(tasks: [], publishedAsks: []).first {
            $0.key.hasPrefix("milestone-")
        }
        XCTAssertTrue(notice?.body.contains("2 张图片") == true)
        XCTAssertFalse(notice?.body.contains("录屏") == true)
    }
}
