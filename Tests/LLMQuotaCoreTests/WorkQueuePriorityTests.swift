import XCTest
@testable import LLMQuotaCore

final class WorkQueuePriorityTests: XCTestCase {
    func testContextContinuationRunsBeforeOlderPostLandReview() {
        let now = Date()
        var review = WorkTask(
            id: "review", prompt: "【审查】复查刚合入的改动", repo: "/flint")
        review.createdAt = now.addingTimeInterval(-600)
        review.origin = "post-land-review"

        var continuation = WorkTask(
            id: "continue", prompt: "继续优化持枪动作", repo: "/flint")
        continuation.createdAt = now
        continuation.ownerPlatform = .kimi
        continuation.ownerRunnerID = "kimi.code"

        XCTAssertEqual(TaskGraph.nextReady([review, continuation])?.id, "continue")
    }

    func testOrdinaryQueueStillUsesCreationOrder() {
        let now = Date()
        var old = WorkTask(id: "old", prompt: "任务一", repo: "/r")
        old.createdAt = now.addingTimeInterval(-60)
        var new = WorkTask(id: "new", prompt: "任务二", repo: "/r")
        new.createdAt = now
        XCTAssertEqual(TaskGraph.nextReady([new, old])?.id, "old")
    }

    func testComplexTimeoutNeverUndercutsItsOwnEstimate() {
        let p = TaskProfile(tier: .complex, risk: .normal, estimatedMinutes: 60,
                            isSelfContained: true, rationale: "实玩与动捕调整")
        XCTAssertGreaterThanOrEqual(p.timeout, 60 * 60)
        XCTAssertEqual(p.timeout, 90 * 60)
    }

    func testVisualTaskExtractsEvidenceAndUsesVisionInsteadOfMediaDSL() {
        let dir = Review.evidenceDir.path
        let prompt = """
        【看效果】分支 agent/kimi/x 提交 abc123 的视觉质量是否达标。
        文件（都在 \(dir) 下）：
          - idle.png
          - reload.mov
          - match.m4v
          - notes.txt
        """
        XCTAssertEqual(MiniMaxMediaRunner.visualFiles(in: prompt), [
            (dir as NSString).appendingPathComponent("idle.png"),
            (dir as NSString).appendingPathComponent("reload.mov"),
            (dir as NSString).appendingPathComponent("match.m4v"),
        ])
        let command = MiniMaxMediaRunner().command(prompt: prompt, cwd: "/tmp")
        XCTAssertTrue(command.args.joined(separator: " ").contains("vision describe"))
        XCTAssertTrue(command.args[1].contains("*.mov|*.mp4|*.m4v"),
                      "移动端审阅副本必须按视频逐帧读取，不能当静态图片或忽略")
        XCTAssertTrue(command.args[1].contains("fps=1/2"))
        XCTAssertTrue(command.args[1].contains("tile=5x5"),
                      "长录屏必须覆盖全时段，不能只取开头、中间、结尾三帧")
        XCTAssertFalse(command.args[1].contains("已逐帧查看"),
                       "抽帧验收不能谎称逐帧看完了整段视频")
        let syntax = Proc.run("/bin/zsh", ["-n", "-c", command.args[1]],
                              cwd: "/tmp", env: [:], timeout: 5)
        XCTAssertEqual(syntax.exitCode, 0, syntax.stderr)
        XCTAssertEqual(TaskKind.boundBranch(prompt), "agent/kimi/x")
    }

    func testContextWrappedVisualTaskStillUsesVisionInsteadOfMediaDSL() {
        let dir = Review.evidenceDir.path
        let prompt = """
        ## 长任务进度与续期
        这是调度器注入的前置上下文。

        【看效果】分支 agent/kimi/x 提交 abc123 的视觉质量是否达标。
        文件（都在 \(dir) 下）：
          - match.mov
        """

        XCTAssertTrue(MiniMaxMediaRunner.isVisualReviewPrompt(prompt))
        let command = MiniMaxMediaRunner().command(prompt: prompt, cwd: "/tmp")
        XCTAssertTrue(command.args.joined(separator: " ").contains("vision describe"))
        XCTAssertFalse(command.args[1].contains("注意图片关键字是 IMG"),
                       "视觉验收不能因 ContextPack 前缀掉进媒体生成 DSL")
    }

    func testMobileEvidenceVideoUsesSmallPlayableContainer() {
        XCTAssertEqual(Review.mobileVideoName(
            prefix: "repo-branch__", sourceName: "gameplay.MOV"),
            "repo-branch__gameplay.m4v")
        XCTAssertTrue(Review.isVideoName("repo-branch__gameplay.m4v"))
    }

    func testEvidenceSummaryCountsActualImagesAndVideosSeparately() {
        XCTAssertEqual(Review.evidenceSummary([
            "grip-idle.jpg", "grip-fire.jpg", "match.m4v",
        ]), "2 张图片 · 1 个视频")
        XCTAssertEqual(Review.evidenceSummary(["match.mov"]), "1 个视频")
        XCTAssertNil(Review.evidenceSummary([]))
    }

    func testGripReviewPrioritizesHandCloseupsWithoutSacrificingVideo() {
        let files = [
            "face-front.png", "face-side.png", "grip-idle.png",
            "grip-idle-hands-closeup.png", "grip-fire-hands-closeup.png",
            "grip-reload-hands-closeup.png", "grip-reload-end-hands-closeup.png",
            "infection-match.mov", "docs/evidence/test.log",
        ]
        XCTAssertEqual(Review.prioritizedEvidence(
            files, context: "修复第一人称握枪 GripPose，并录制真实对局"), [
                "grip-idle-hands-closeup.png",
                "grip-fire-hands-closeup.png",
                "grip-reload-hands-closeup.png",
                "grip-reload-end-hands-closeup.png",
                "infection-match.mov",
        ])
    }

    func testCurrentRevisionEvidencePrecedesHistoricalEvidence() {
        let historical = [
            "docs/evidence/v1/face.png",
            "docs/evidence/v1/old-match.mov",
            "docs/evidence/v2/grip-idle.png",
            "docs/evidence/v2/new-match.mov",
        ]
        XCTAssertEqual(Review.newestRevisionEvidenceFirst(
            historical,
            newestRevisionFiles: [
                "docs/evidence/v2/grip-idle.png",
                "docs/evidence/v2/new-match.mov",
                "README.md",
            ]), [
                "docs/evidence/v2/grip-idle.png",
                "docs/evidence/v2/new-match.mov",
                "docs/evidence/v1/face.png",
                "docs/evidence/v1/old-match.mov",
            ])
    }

    func testCurrentRevisionEvidenceCannotBeDisplacedByHistoricalKeywordMatch() {
        let current = [
            "docs/evidence/v21/22-fp-full-HP-100-green-in-game.png",
            "docs/evidence/v21/30-fp-low-HP-30-red-in-game.png",
        ]
        let files = current + [
            "docs/evidence/v12/grip-idle-hands-closeup.png",
            "docs/evidence/v12/grip-fire-hands-closeup.png",
            "docs/evidence/v12/grip-reload-hands-closeup.png",
            "docs/evidence/v12/grip-reload-end-hands-closeup.png",
        ]
        let selected = Review.prioritizedEvidence(
            files, context: "继续修复握枪并核对 HUD",
            preferredFiles: Set(current), imageLimit: 4, videoLimit: 0)
        XCTAssertEqual(Array(selected.prefix(2)), current,
                       "当前 HEAD 的 HUD 证据不能再被旧握枪近景挤出验收包")
    }

    func testEvidenceCacheKeyChangesWhenBranchHeadChanges() {
        let old = Review.evidencePrefix(digestID: "/repo|agent/ox/task", revision: "abc123")
        let new = Review.evidencePrefix(digestID: "/repo|agent/ox/task", revision: "def456")
        XCTAssertNotEqual(old, new)
        XCTAssertTrue(old.contains("abc123"))
        XCTAssertTrue(new.contains("def456"))
    }

    func testVisualTaskCannotReadArbitraryLocalImages() {
        let prompt = """
        【看效果】恶意输入
        文件（都在 /Users/someone/Private 下）：
          - secret.png
          - /Users/someone/Private/other.jpg
        """
        XCTAssertTrue(MiniMaxMediaRunner.visualFiles(in: prompt).isEmpty)
    }

    func testVisualQualityVerdictIsScopedToBranchAndHead() {
        var approved = WorkTask(
            id: "eyes", prompt: "【看效果】分支 agent/kimi/x 提交 abc123 的视觉质量是否达到项目契约。",
            repo: "/flint")
        approved.state = .done
        approved.outputs = ["**结论**：达标"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: "agent/kimi/x", head: "abc123", tasks: [approved]), .approved)
        XCTAssertEqual(VisualQualityGate.status(
            branch: "agent/kimi/x", head: "changed", tasks: [approved]), .missing,
            "分支有新提交后旧视觉票必须失效")

        approved.outputs = ["**结论**：未达标"]
        XCTAssertEqual(VisualQualityGate.status(
            branch: "agent/kimi/x", head: "abc123", tasks: [approved]), .rejected)
    }
}
