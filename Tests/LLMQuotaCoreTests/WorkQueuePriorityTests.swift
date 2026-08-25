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
          - notes.txt
        """
        XCTAssertEqual(MiniMaxMediaRunner.visualFiles(in: prompt), [
            (dir as NSString).appendingPathComponent("idle.png"),
            (dir as NSString).appendingPathComponent("reload.mov"),
        ])
        let command = MiniMaxMediaRunner().command(prompt: prompt, cwd: "/tmp")
        XCTAssertTrue(command.args.joined(separator: " ").contains("vision describe"))
        let syntax = Proc.run("/bin/zsh", ["-n", "-c", command.args[1]],
                              cwd: "/tmp", env: [:], timeout: 5)
        XCTAssertEqual(syntax.exitCode, 0, syntax.stderr)
        XCTAssertEqual(TaskKind.boundBranch(prompt), "agent/kimi/x")
    }

    func testMobileEvidenceVideoUsesSmallPlayableContainer() {
        XCTAssertEqual(Review.mobileVideoName(
            prefix: "repo-branch__", sourceName: "gameplay.MOV"),
            "repo-branch__gameplay.m4v")
        XCTAssertTrue(Review.isVideoName("repo-branch__gameplay.m4v"))
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
