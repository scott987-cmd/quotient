import XCTest
@testable import LLMQuotaCore

/// 拆图要非常克制 —— 拆一次，失败面积就乘一次。
///
/// 2026-08-17 盘点：一次捞出 3 张搁浅的任务图，**全是拆出来的**。
/// 其中 f2872114 完成了 4 步、19 个文件的产出，第 5 步挂了就整条躺了一天。
///
/// 而拆图那条支持理由（便宜平台干机械部分）在工作区按「仓库 × 平台」
/// 复用之后已经站不住：一个 agent 带着完整会话干 5 件事，
/// 严格优于 5 个 agent 各自重新认路。
///
/// 所以判据从「复杂/高危/估时长/写了编号」收紧到只剩两种
/// **一次执行真的装不下**的情况：碰高危路径（要单独放行）、跨能力
///（生图执行器改不了代码，编码执行器画不了图）。
final class DecomposePolicyTests: XCTestCase {

    private func task(_ prompt: String, tier: TaskProfile.Tier = .complex,
                      minutes: Int = 60) -> WorkTask {
        var t = WorkTask(id: "t1", prompt: prompt, repo: "/tmp/demo")
        t.profile = TaskProfile(tier: tier, risk: .safe, estimatedMinutes: minutes,
                                isSelfContained: true, rationale: "测试")
        return t
    }

    /// 今天被误拆的那条：编号的是**完成标准**，不是步骤。
    /// 它被拆成了 7 步图。
    func testNumberedAcceptanceCriteriaDoNotTriggerSplit() {
        let p = """
        【媒体】给 Greed 生 4 张遗物图标，风格按 AGENTS.md 的美术方向。

        完成标准：
        1. 4 个 imageset 都在 Assets.xcassets 下
        2. 构建通过
        3. 各截一张图进 docs/evidence/
        """
        XCTAssertFalse(TaskDecomposer.shouldDecompose(task(p)),
                       "编号的是验收条件，不是步骤 —— 拆了等于把失败面积乘七倍")
    }

    /// 复杂 + 估时 60 分钟，但就是一件事 —— 不拆。
    /// 一个带着会话的 agent 干得完，拆开反而把上下文切碎。
    func testLongComplexButSingleThingIsNotSplit() {
        let p = "通读整个仓库，产出一份还没做的待办清单，写进 STATUS.md。"
        XCTAssertFalse(TaskDecomposer.shouldDecompose(task(p, minutes: 90)),
                       "活多 ≠ 装不下。会话能延续，一个 agent 干得完")
    }

    /// 人明写了「第一步…第二步…」—— 那是顺序依赖，照办。
    func testExplicitStepsStillSplit() {
        let p = "第一步：核查现状。第二步：改脚本。第三步：验证。"
        XCTAssertTrue(TaskDecomposer.shouldDecompose(task(p)),
                      "人明确表达了顺序依赖，不是我们猜的")
    }

    /// 跨能力：生图执行器改不了代码，编码执行器画不了图 ——
    /// 这是真的一次执行装不下。
    func testMediaPlusCodeSplits() {
        let p = "生成 4 张遗物图标，然后接进 RelicChoiceView 里。"
        XCTAssertTrue(TaskDecomposer.shouldDecompose(task(p)),
                      "一半要 mmx 一半要编码 agent，一次执行不可能都干")
    }

    /// 纯生图不拆 —— 它只用一种能力。
    func testMediaOnlyDoesNotSplit() {
        let p = "【媒体】生成 4 张遗物图标，风格按 AGENTS.md。"
        XCTAssertFalse(TaskDecomposer.shouldDecompose(task(p)))
    }

    /// 碰高危路径仍然拆：那一步要单独拿给人放行，
    /// 混在大任务里会把整包拖住等审批。
    func testRiskyPathStillSplits() {
        let p = "改 build-app.sh，让它编译前先跑一次测试。"
        XCTAssertTrue(TaskDecomposer.shouldDecompose(task(p)),
                      "高危那步要单独放行，不然整包卡在审批上")
    }
}
