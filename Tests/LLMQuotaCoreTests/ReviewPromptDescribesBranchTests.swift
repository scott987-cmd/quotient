import XCTest
@testable import LLMQuotaCore

/// 评审提示词要说清「这条分支是干什么的」:任务标题 + 全部提交,而不是最后一个提交的主题。
/// 实锤 2026-08-23:Flint 主线第 3 块(4 个提交,最后一个是「xcodegen 重新生成…」),
/// 评审拿最后一个提交当 PR 描述对照整条 diff,判「标题与实际改动严重不符 → 不合入」两票。
final class ReviewPromptDescribesBranchTests: XCTestCase {
    func test_多提交分支_列出任务标题和全部提交_并警告别拿末尾提交当描述() {
        var c = MergeReview.Candidate(
            branch: "agent/kimi/74f413e7", repo: "/tmp/x", files: ["Tools/gen-gear.py", "a.usdz"],
            subject: "xcodegen 重新生成：补上头发资源进工程", whyNotMechanical: "碰了构建路径", needed: 2)
        c.taskTitle = "【续活·主线 3】【人物·装备第二版】四干员穿上完整作战服"
        c.commits = ["剪影差异化：装备 dims 拉开", "出货资产剪影闸 PASS", "PLAN 标已完成", "xcodegen 重新生成：补上头发资源进工程"]
        let p = MergeReview.reviewPrompt(c)
        XCTAssertTrue(p.contains("来源任务）：【续活·主线 3】"), "任务标题要在")
        for m in c.commits { XCTAssertTrue(p.contains(m), "每个提交主题都要列出:\(m)") }
        XCTAssertTrue(p.contains("别拿最后一个提交的标题去对照整条改动"), "要明说这个坑")
        XCTAssertFalse(p.contains("这条分支：xcodegen"), "不能再把末尾提交单独当成分支描述")
    }

    func test_单提交分支_保持原样() {
        var c = MergeReview.Candidate(
            branch: "agent/a/b", repo: "/tmp/x", files: ["f.swift"],
            subject: "修一个空指针", whyNotMechanical: "高危", needed: 1)
        c.commits = ["修一个空指针"]
        let p = MergeReview.reviewPrompt(c)
        XCTAssertTrue(p.contains("这条分支：修一个空指针"))
    }
}
