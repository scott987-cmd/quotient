import XCTest
@testable import LLMQuotaCore

/// **图分支上已有提交时,prepare 绝不 `branch -f` 回 base。**
///
/// 实锤(2026-08-22 19:53,Flint reflog):`agent/graph/1f8de767` 被
/// `branch: Reset to main`,s1–s4 的 6 个提交 / 14 个文件从分支上消失,
/// 整张图只能人工丢弃重派。图任务共用一条分支,前面步骤的产出就在上面 ——
/// prepare 的「原地换分支」路径里那句 `branch -f branch base` 等于抹掉别人
/// 干完的活。
final class GraphBranchPreserveTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmp() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testSecondStepDoesNotResetGraphBranch() throws {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("gbr-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        func g(_ a: [String], in p: String = d) -> Proc.Result { GitWorkspace.git(a, in: p) }
        _ = g(["init", "-q", "--initial-branch=main"])
        _ = g(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"])

        // 第一步:开图工作区,在图分支上提交一个产出
        let ws1 = try GitWorkspace.prepare(repo: d, taskID: "Gs1", platform: .kimi, graphID: "G")
        try "s1 产出".write(toFile: ws1.path + "/out.txt", atomically: true, encoding: .utf8)
        _ = g(["add", "."], in: ws1.path)
        _ = g(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "s1"], in: ws1.path)
        let ahead1 = g(["rev-list", "--count", "main..\(ws1.branch)"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ahead1, "1", "第一步的提交应在图分支上")

        // 第二步:同一张图再 prepare —— 以前这里会 branch -f 回 main,抹掉 s1
        let ws2 = try GitWorkspace.prepare(repo: d, taskID: "Gs2", platform: .kimi, graphID: "G")
        XCTAssertEqual(ws2.branch, ws1.branch, "同一张图共用一条分支")
        let ahead2 = g(["rev-list", "--count", "main..\(ws2.branch)"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ahead2, "1", "第二步准备工作区后,第一步的提交必须还在 —— 不许被重置抹掉")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws2.path + "/out.txt"),
                      "第一步的产出文件要在第二步的工作区里看得见")
    }
}
