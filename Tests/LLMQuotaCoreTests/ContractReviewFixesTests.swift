import XCTest
@testable import LLMQuotaCore

/// 契约评审(2026-08-23,Kimi 报告)核实后修掉的几条,逐条钉住。
final class ContractReviewFixesTests: XCTestCase {
    private var mainSwift: String {
        let here = URL(fileURLWithPath: #filePath)
        let src = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/llmq/main.swift")
        return (try? String(contentsOf: src, encoding: .utf8)) ?? ""
    }

    // MARK: S1 高危闸的 Ask 必须是审批,而且只推给老板该管的

    func test_高危闸Ask是approval_且只在bossCall时推手机() {
        let s = mainSwift
        guard let q = s.range(of: "这次改动碰到了高危路径，要放行吗？") else { return XCTFail("找不到高危闸 Ask") }
        // 往前 1500 字符里必须有 `if bossCall {`,往后 800 字符里必须有 `kind: .approval`
        let startIdx: String.Index = s.index(q.lowerBound, offsetBy: -1500, limitedBy: s.startIndex) ?? s.startIndex
        let endIdx: String.Index = s.index(q.upperBound, offsetBy: 800, limitedBy: s.endIndex) ?? s.endIndex
        let before = String(s[startIdx..<q.lowerBound])
        let after = String(s[q.upperBound..<endIdx])
        XCTAssertTrue(before.contains("if bossCall {"), "归 Claude 处置的技术拦截不该推手机")
        XCTAssertTrue(after.contains("kind: .approval"), "不标 approval 的话手机答「放行」会走重排重跑,再弹一张新问题")
    }

    // MARK: M5 卡片放行后要撤问题文件

    func test_卡片放行路径会撤Ask() {
        let s = mainSwift
        guard let r = s.range(of: "case (\"task\", \"approve\"), (\"task\", \"discard\"):") else { return XCTFail() }
        let endIdx: String.Index = s.index(r.upperBound, offsetBy: 2500, limitedBy: s.endIndex) ?? s.endIndex
        let tail = String(s[r.upperBound..<endIdx])
        XCTAssertTrue(tail.contains("AskStore.retract("), "两个入口(卡片/问题页)必须互相撤销,否则「确认了还弹」")
    }

    func test_人工结束或重试任务会撤下旧问题() {
        let s = mainSwift
        for marker in ["case \"retry\":", "case \"done\":", "case \"discard\":"] {
            guard let r = s.range(of: marker) else { return XCTFail("找不到 \(marker)") }
            let end = s.index(r.upperBound, offsetBy: 4200, limitedBy: s.endIndex) ?? s.endIndex
            XCTAssertTrue(String(s[r.upperBound..<end]).contains("AskStore.retract("),
                          "\(marker) 改了任务终态/轮次，却把旧问题留在手机上")
        }
    }

    func test_长任务不能堵住确认提醒() {
        let s = mainSwift
        guard let start = s.range(of: "func cmdUpdate(_ rest: [String]) throws {") else {
            return XCTFail("找不到独立于 worker 的每分钟更新入口")
        }
        let end = s.index(start.upperBound, offsetBy: 4200, limitedBy: s.endIndex) ?? s.endIndex
        XCTAssertTrue(String(s[start.upperBound..<end])
            .contains("Nudge.run(synchronizeBadge: false)"),
            "提醒只挂在同步 work loop 上时，agent 连跑几十分钟期间不会检查待确认事项")
    }

    // MARK: M6 角标和页面一个口径

    private func blocked(_ note: String, frozenBy: String? = nil) -> WorkTask {
        var t = WorkTask(id: "t-\(UUID().uuidString.prefix(6))", prompt: "x", repo: "/r")
        t.state = .blocked; t.note = note; t.frozenBy = frozenBy
        return t
    }

    func test_等你放行_角标数等于页面卡片数() {
        let tasks = [
            blocked("碰到高危路径（a.sh），等你确认"),
            blocked("碰到高危路径（b.sh），等 Claude 处置"),
            blocked("上游没完成", frozenBy: "up1"),
        ]
        let badge = Nudge.pending(tasks: tasks).first { $0.key.hasPrefix("blocked") }?.badge ?? 0
        let page = ViewFeed.blockedPage(tasks: tasks)
        let cards = page.sections.compactMap(\.cards).flatMap { $0 }.count
        XCTAssertEqual(badge, 1, "只有归老板的那条算")
        XCTAssertEqual(cards, badge, "角标说 N,页面就得有 N 张卡,否则「点进去是空的」")
    }

    func test_每条推送都携带全部待办数_不能被单条角标覆盖() {
        let items: [(key: String, kind: Push.Kind, body: String, badge: Int)] = [
            ("review-2", .needsYou, "两份成果", 2),
            ("blocked-1", .needsYou, "一项放行", 1),
        ]
        XCTAssertEqual(Nudge.notificationBadges(for: items), [3, 3],
                       "APNs 角标是覆盖语义；任一横幅带局部数都会把总数改错")
    }

    // MARK: M4 .done 两种键都认

    func test_已表态_两种键格式都认() {
        let done: Set<String> = ["/r|agent/a/1", "/r|agent/a/2|merge"]
        XCTAssertTrue(Review.isDecided(repo: "/r", branch: "agent/a/1", in: done))
        XCTAssertTrue(Review.isDecided(repo: "/r", branch: "agent/a/2", in: done), "三段键(ingest/giveUp 写的)也算已表态")
        XCTAssertFalse(Review.isDecided(repo: "/r", branch: "agent/a/3", in: done))
        XCTAssertFalse(Review.isDecided(repo: "/r", branch: "agent/a/2x", in: done), "前缀不能误伤同前缀分支")
    }

    // MARK: S2 没仓库的机器不碰结论

    func test_本机没有该仓库_不执行也不记办结() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("verd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let saved = Paths.appSupportOverride
        Paths.appSupportOverride = tmp
        defer { Paths.appSupportOverride = saved }
        let vdir = Paths.sharedRoot.appendingPathComponent("verdicts", isDirectory: true)
        try FileManager.default.createDirectory(at: vdir, withIntermediateDirectories: true)
        let v = Review.Verdict(repo: "/nonexistent/repo/\(UUID().uuidString)", branch: "agent/kimi/zz",
                               action: "merge", reason: nil, decidedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(v).write(to: vdir.appendingPathComponent("x-zz.json"))
        let applied = Review.ingestVerdicts()
        XCTAssertTrue(applied.isEmpty, "没仓库的机器应跳过,而不是按「分支不存在=办完了」记办结")
        let done = (try? String(contentsOf: vdir.appendingPathComponent(".done"), encoding: .utf8)) ?? ""
        XCTAssertFalse(done.contains("agent/kimi/zz"), "记了办结,有仓库的那台就永远跳过 —— 代码从未合入")
    }

    // MARK: M1 未知 kind 不炸整份

    func test_办公室事件_未知kind退成other_缺kind仍是finished() throws {
        let json = """
        [{"id":"a","at":"2026-08-23T01:00:00Z","kind":"dispatched","taskID":"t","machineID":"m","detail":"","taskTitle":""},
         {"id":"b","at":"2026-08-23T01:00:01Z","kind":"teleport","taskID":"t","machineID":"m","detail":"","taskTitle":""},
         {"id":"c","at":"2026-08-23T01:00:02Z","taskID":"t","machineID":"m","detail":"","taskTitle":""}]
        """
        let evs = try SnapshotCoding.decoder().decode([OfficeEvent].self, from: Data(json.utf8))
        XCTAssertEqual(evs.count, 3, "一条不认识的 kind 不能让整台机器的事件消失")
        XCTAssertEqual(evs[1].kind, .other)
        XCTAssertEqual(evs[2].kind, .finished)
    }
}
