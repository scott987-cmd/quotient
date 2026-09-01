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

    func test_任务专属范围原样传给评审且优先于通用质量规则() {
        var c = MergeReview.Candidate(
            branch: "agent/kimi/alpha", repo: "/tmp/x",
            files: ["Flint/Render/Game.swift"], subject: "完成功能 Alpha",
            whyNotMechanical: "仓库要求评审", needed: 1)
        c.taskContract = """
        【功能 Alpha｜冻结美术】
        本轮不整改美术质量，不因占位资产阻断功能完成。
        不得修改 Production/，必须修复真实功能缺陷。
        """

        let prompt = MergeReview.reviewPrompt(c)
        XCTAssertTrue(prompt.contains("本轮不整改美术质量"))
        XCTAssertTrue(prompt.contains("不得修改 Production/"))
        XCTAssertTrue(prompt.contains(
            "本次任务专属契约 > 当前阶段契约 > 仓库通用"))
        XCTAssertTrue(prompt.contains("非目标的质量，不得单独作为不合入理由"))
        XCTAssertTrue(prompt.contains("冻结目录、破坏既有功能"),
            "冻结质量和触碰冻结目录必须明确区分")
        XCTAssertFalse(prompt.contains("自己拉出来看"),
                       "MiniMax 没有仓库读取能力，不能再给它无法执行的指令")
    }

    func test_过长任务历史保留开头契约并明确截断() {
        var c = MergeReview.Candidate(
            branch: "agent/kimi/alpha", repo: "/tmp/x", files: ["a.swift"],
            subject: "实现", whyNotMechanical: "评审", needed: 1)
        c.taskContract = "冻结美术；功能优先。\n" + String(repeating: "旧反馈", count: 5_000)
        let section = MergeReview.taskContractSection(c)
        XCTAssertTrue(section.hasPrefix("冻结美术；功能优先。"))
        XCTAssertTrue(section.contains("截断"))
        XCTAssertLessThanOrEqual(section.count, 12_100)
    }
}
