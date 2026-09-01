import XCTest
@testable import LLMQuotaCore

final class CurrentOwnerReviewTests: XCTestCase {
    private var repo: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-review-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repo = dir.path
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        write("base.txt", "base\n")
        git(["add", "-A"]); git(["commit", "-q", "-m", "init"])
    }

    override func tearDown() {
        Review.invalidateListCache()
        try? FileManager.default.removeItem(atPath: repo)
        super.tearDown()
    }

    private func git(_ args: [String]) {
        _ = GitWorkspace.git(args, in: repo)
    }

    private func write(_ path: String, _ value: String) {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(branch: String, files: [(String, String)], message: String) {
        git(["checkout", "-q", "-b", branch, "main"])
        for (path, value) in files { write(path, value) }
        git(["add", "-A"]); git(["commit", "-q", "-m", message])
        git(["checkout", "-q", "main"])
    }

    func testHandoffPublishesOnlyCurrentOwnerBranch() {
        let id = "74726e09"
        commit(branch: "agent/minimax/\(id)",
               files: [("old.png", "old")], message: "old owner")
        commit(branch: "agent/qwen/\(id)",
               files: [("current.png", "current")], message: "current owner")

        var task = WorkTask(id: id, prompt: "M0", repo: repo)
        task.state = .done
        task.branch = "agent/qwen/\(id)"
        task.ownerPlatform = .qwen
        task.ownerRunnerID = "qwen.code"

        let items = Review.list(repo: repo, tasks: [task])
        XCTAssertEqual(items.map(\.branch), ["agent/qwen/\(id)"])
    }

    func testFrozenSourceSupportingBranchIsNotPublishedForLanding() {
        let sourceID = "74726e09"
        let sourceBranch = "agent/kimi/\(sourceID)"
        commit(branch: sourceBranch,
               files: [("old-art.txt", "frozen")], message: "frozen art")
        commit(branch: "agent/minimax/review-old",
               files: [("reviews/OLD.md", "old review")], message: "old review")

        var source = WorkTask(id: sourceID, prompt: "旧美术", repo: repo)
        source.state = .failed
        source.branch = sourceBranch
        source.pausedAt = Date()
        source.note = "旧美术任务冻结并保留"
        var review = WorkTask(
            id: "review-old",
            prompt: "【审查·合入】分支 \(sourceBranch) 的改动能不能合进 main。",
            repo: repo)
        review.state = .done
        review.branch = "agent/minimax/review-old"
        review.origin = "merge-review"

        let items = Review.list(repo: repo, tasks: [source, review])
        XCTAssertFalse(items.map(\.branch).contains("agent/minimax/review-old"),
                       "冻结来源的旧评审只留审计，不得继续合入")
    }

    func testMergeReviewCandidateCarriesTheFullSourceTaskContract() throws {
        let id = "alpha"
        let branch = "agent/kimi/\(id)"
        commit(branch: branch,
               files: [("build-app.sh", "#!/bin/sh\nexit 0\n")],
               message: "功能 Alpha")

        let contract = """
        【功能 Alpha｜冻结美术】
        本轮不因美术质量阻断功能完成；不得修改 Production/。
        """
        var task = WorkTask(id: id, prompt: contract, repo: repo)
        task.state = .done
        task.branch = branch
        task.ownerPlatform = .kimi
        task.ownerRunnerID = "kimi.code"

        let candidate = try XCTUnwrap(
            MergeReview.candidates(repo: repo, tasks: [task]).first)
        XCTAssertEqual(candidate.taskContract, contract)
        XCTAssertTrue(MergeReview.reviewPrompt(candidate).contains(
            "本轮不因美术质量阻断功能完成"))
    }

    func testProductionContractSelectsExactlyCurrentMilestoneEvidence() {
        let id = "74726e09"
        let branch = "agent/qwen/\(id)"
        let contract = #"{"currentMilestone":"M0","reviewBoard":"Production/operator-yan/evidence/M0/review-board.html"}"#
        var files: [(String, String)] = [
            ("docs/evidence/v12/grip-idle-hands-closeup.png", "old"),
            ("docs/evidence/v12/match.mov", "old video"),
            ("Production/operator-yan/contract.json", contract),
        ]
        for name in ["a-front.png", "b-45.png", "c-side.png", "d-full.png", "e-face.png"] {
            files.append(("Production/operator-yan/evidence/M0/\(name)", name))
        }
        files.append(("Production/operator-yan/evidence/M0/review-board.html", "board"))
        commit(branch: branch, files: files, message: "M0 candidate")

        var task = WorkTask(id: id, prompt: "验收 M0 Blender 母版", repo: repo)
        task.state = .done
        task.branch = branch
        task.ownerPlatform = .qwen
        task.ownerRunnerID = "qwen.code"

        let item = Review.list(repo: repo, tasks: [task]).first
        XCTAssertEqual(item?.evidence, [
            "Production/operator-yan/evidence/M0/a-front.png",
            "Production/operator-yan/evidence/M0/b-45.png",
            "Production/operator-yan/evidence/M0/c-side.png",
            "Production/operator-yan/evidence/M0/d-full.png",
            "Production/operator-yan/evidence/M0/e-face.png",
        ])
        XCTAssertEqual(item?.currentRevisionEvidence, item?.evidence)
        XCTAssertEqual(item?.contractBoundEvidence, true)
    }

    func testObsoleteOwnerBranchCannotTriggerStaleRefresh() {
        let id = "74726e09"
        let old = "agent/minimax/\(id)"
        git(["checkout", "-q", "-b", old, "main"])
        for i in 0..<4 { write("shared\(i).swift", "old owner\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "old owner"])
        git(["checkout", "-q", "main"])
        for i in 0..<4 { write("shared\(i).swift", "main\n") }
        git(["add", "-A"]); git(["commit", "-q", "-m", "main moved"])

        var task = WorkTask(id: id, prompt: "M0", repo: repo)
        task.state = .done
        task.branch = "agent/qwen/\(id)"
        task.ownerPlatform = .qwen
        task.ownerRunnerID = "qwen.code"

        XCTAssertTrue(StaleBranch.candidates(repo: repo, tasks: [task]).isEmpty)
    }
}
