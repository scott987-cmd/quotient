import XCTest
@testable import LLMQuotaCore

/// **「我没看清」不等于「我看到问题了」。**
///
/// 2026-08-22 凌晨:Flint 的 Bot AI(90 条测试全绿 + 60 秒交战录屏)和
/// 枪声混音都被判「不合入」。两份报告里「截断/看不到/看不出/如果…没有」
/// 出现 19 次和 10 次 —— 评审没自己拉 diff,靠被截断的摘要猜。
/// 而一票否决是终局,产线卡了一整夜,老板问「任务为啥又停了」才发现。
///
/// 根子是机制只给了两个格子,不确定被塞进了「不合入」。
final class VerdictQualityTests: XCTestCase {
    func testBlindRejectionIsInconclusive() {
        let report = """
        **结论**：不合入
        - Movement.swift +35 截断看不到具体内容
        - NavGraph.swift +9 改动里看不出来改了什么
        - HitResolution 截断，如果命名冲突会让打到 bot 算成没打中
        - STATUS.md 改动里看不出来具体内容
        """
        XCTAssertTrue(VerdictQuality.isInconclusive(report),
                      "通篇是「我没看到」—— 该退回去看，不该记否决")
    }

    /// 真发现问题的否决必须照旧生效 —— 把这类洗成「没看清」等于拆了审核闸。
    func testConcreteRejectionStaysRejection() {
        let report = """
        **结论**：不合入
        1. Tools/__pycache__/gen-weapon-k7.cpython-313.pyc 入库，违反基本卫生
        2. 第 212 行硬编码了 API key，泄漏风险
        3. 删除了 HitResolutionTests 里的三条断言，绕过了原本会失败的检查
        """
        XCTAssertFalse(VerdictQuality.isInconclusive(report),
                       "指名道姓的问题是真否决，不能被当成「它没看清」洗掉")
    }

    /// 一两句「看不到」不足以推翻一份有实据的报告。
    func testMostlyConcreteWithOneBlindNoteStaysRejection() {
        let report = """
        **结论**：不合入
        1. 第 88 行删除了输入校验，绕过了原本的检查
        2. project.yml 缺少登记，资产不会进包
        3. 另外 STATUS.md 那段截断看不到
        """
        XCTAssertFalse(VerdictQuality.isInconclusive(report))
    }

    func testEmptyOrApprovalIsNotInconclusive() {
        XCTAssertFalse(VerdictQuality.isInconclusive(""))
        XCTAssertFalse(VerdictQuality.isInconclusive("**结论**：合入。测试全绿，证据齐全。"))
    }
}

/// **「表过态」不等于「办成了」。**
///
/// 2026-08-22 早:老板点进推送,页面空的。Flint 的两条分支都在「已表态」
/// 名单里 —— 他点过合入,评审判不合入合不进去,于是决定记下了、活没干成、
/// 条目从他眼前永久消失。而推送还在数它们。
final class DecidedMeansExecutedTests: XCTestCase {
    override func setUp() { super.setUp(); Paths.appSupportOverride = tmp() }
    override func tearDown() { Paths.appSupportOverride = nil; super.tearDown() }
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testOnlyExecutedDecisionsHideTheItem() throws {
        let dir = Review.verdictsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 一条「点过但没办成」的结论：文件在，.done 台账里没有。
        let v = Review.Verdict(repo: "/r", branch: "agent/a/stuck",
                               action: "merge", reason: nil, decidedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(v).write(to: dir.appendingPathComponent("r-stuck.json"))
        XCTAssertFalse(Review.decidedBranches().contains("/r|agent/a/stuck"),
                       "点了但没合上的,必须留在他眼前 —— 否则就是黑洞")
        // 办成之后才隐藏。
        try "/r|agent/a/stuck".write(to: dir.appendingPathComponent(".done"),
                                    atomically: true, encoding: .utf8)
        XCTAssertTrue(Review.decidedBranches().contains("/r|agent/a/stuck"))
    }
}
