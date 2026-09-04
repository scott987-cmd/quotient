import XCTest
@testable import LLMQuotaCore

final class RoadmapPageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func board(_ id: String, _ tasks: [TaskBrief], age: Double = 0) -> MachineTaskBoard {
        MachineTaskBoard(machineID: id, machineName: "MacBook Pro",
                         generatedAt: now.addingTimeInterval(-age), tasks: tasks)
    }
    func task(_ id: String, state: WorkTask.State = .running) -> TaskBrief {
        TaskBrief(id: id, title: "Flint 可玩切片", state: state, platform: .kimi,
                  machineName: "Mac", elapsedSeconds: 180, repoAlias: "flint",
                  progressPhase: "验证输入", progressSummary: "触控流程已接通",
                  progressNextStep: "真机 60 秒验证", progressUpdatedAt: now,
                  progressEvidenceCount: 1, ownerRunnerID: "kimi.code",
                  branch: "agent/kimi/\(id)", progressEvidence: ["Evidence/test.log"])
    }
    func page(_ boards: [MachineTaskBoard], unreadable: [String] = []) -> ViewFeed.Page {
        RoadmapPage.page(now: now, listing: .init(boards: boards, unreadable: unreadable,
                                                directoryStalled: false, directoryMissing: false))
    }

    func testThreeMachinesAggregateWithoutLocalPlanAndKeepTaskIdentity() throws {
        let p = page([board("A", [task("same")]), board("B", [task("same", state: .queued)]),
                      board("C", [task("blocked", state: .blocked)])])
        let cards = p.sections.flatMap { $0.cards ?? [] }
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(Set(cards.map(\.id)).count, 3, "不同机器同名任务不能相互覆盖")
        let current = try XCTUnwrap(cards.first)
        XCTAssertTrue(current.title.hasPrefix("进行中"))
        XCTAssertTrue(current.body?.contains("kimi.code") == true)
        XCTAssertTrue(current.body?.contains("下一步：真机 60 秒验证") == true)
        XCTAssertTrue(current.detail?.contains("Evidence/test.log") == true)
        XCTAssertTrue(p.sections.last?.note?.contains("运行记录 1 项 · 排队/阻塞 2 项") == true)
        XCTAssertTrue(p.sections.first?.text?.contains("3 台") == true)
    }

    func testStaleOrFutureRunningIsNotLiveAndDuplicateBoardUsesLatest() throws {
        let p = page([board("A", [task("old")], age: 4000), board("A", [task("new")]),
                      board("B", [task("stale")], age: 1900),
                      board("C", [task("future")], age: -400)])
        let cards = p.sections.flatMap { $0.cards ?? [] }
        XCTAssertEqual(cards.count, 3)
        XCTAssertFalse(cards.contains { $0.taskID == "old" })
        XCTAssertEqual(cards.filter { $0.title.hasPrefix("进行中") }.count, 1)
        XCTAssertEqual(cards.filter { $0.title.hasPrefix("状态待更新") }.count, 2)
        XCTAssertTrue(p.sections.last?.note?.contains("运行记录 1 项") == true)
    }

    func testDoneAndZeroChangeNeverMasqueradeAsLanded() {
        var pending = task("pending", state: .done)
        pending.progressPhase = "等待合入"
        var zero = task("zero", state: .done)
        zero.progressPhase = "已完成 · 无新改动"
        var landed = task("landed", state: .done)
        landed.landedAt = now
        let cards = page([board("A", [pending, zero, landed])]).sections.flatMap { $0.cards ?? [] }
        XCTAssertTrue(cards.first { $0.taskID == "pending" }?.title.hasPrefix("产出待验收/合入") == true)
        XCTAssertTrue(cards.first { $0.taskID == "zero" }?.title.contains("非合入证明") == true)
        XCTAssertEqual(cards.filter { $0.title.hasPrefix("已合入 main") }.count, 1)
    }

    func testInFlightOldExecutorCannotRestoreFalseEightHourStall() throws {
        var old = task("resumed")
        old.startedAt = now.addingTimeInterval(-120)
        old.progressUpdatedAt = now.addingTimeInterval(-8 * 3600)
        old.progressPhase = "无可证明进展"
        old.progressSummary = "已 480 分钟没有结构化里程碑"
        let body = try XCTUnwrap(page([board("A", [old])]).sections.last?.cards?.first?.body)
        XCTAssertFalse(body.contains("480"))
        XCTAssertTrue(body.contains("里程碑时间待核对"))
        old.progressUpdatedAt = now // 自动 WIP 心跳不能用作 checkpoint 时间
        XCTAssertFalse(page([board("A", [old])]).sections.last?.cards?.first?.body?.contains("480") == true)
        old.progressCheckpointAt = now.addingTimeInterval(-8 * 3600)
        let verified = try XCTUnwrap(page([board("A", [old])]).sections.last?.cards?.first?.body)
        XCTAssertTrue(verified.contains("已计时 2 分钟"))
        var staleQueue = board("B", [task("queued", state: .queued)], age: 4000)
        staleQueue.nodeName = "macbook-pro-intel"
        XCTAssertTrue(page([staleQueue]).sections.last?.note?.contains("排队/阻塞 0 项") == true)
    }

    func testEmptyUnreadableAndTruncatedStatesAreExplicit() {
        let empty = page([], unreadable: ["M2.json"])
        XCTAssertTrue(empty.sections.first?.text?.contains("无法读取") == true)
        XCTAssertTrue(empty.sections.last?.text?.contains("不能据此断言项目已完成") == true)
        XCTAssertTrue(ViewFeed.worthPublishing(empty, over: empty),
                      "汇总页连续为空/读取失败时也要刷新健康提示，不能永久停在旧时间")
        var b = board("A", [task("live")])
        b.tasksTruncated = true
        XCTAssertTrue(page([b]).sections.last?.note?.contains("仅显示部分历史") == true)
    }

    func testOldTaskBriefDecodesAndNewEvidenceRoundTrips() throws {
        let old = try SnapshotCoding.decoder().decode(TaskBrief.self,
            from: Data(#"{"id":"old","state":"running"}"#.utf8))
        XCTAssertNil(old.ownerRunnerID)
        XCTAssertNil(old.landedAt)
        XCTAssertNil(old.progressEvidence)
        XCTAssertNil(old.progressCheckpointAt)
        let item = task("new")
        let decoded = try SnapshotCoding.decoder().decode(TaskBrief.self,
            from: SnapshotCoding.prettyEncoder().encode(item))
        XCTAssertEqual(decoded.ownerRunnerID, "kimi.code")
        XCTAssertEqual(decoded.progressEvidence, ["Evidence/test.log"])
        let oldBoard = try SnapshotCoding.decoder().decode(MachineTaskBoard.self,
            from: Data(#"{"machineID":"old"}"#.utf8))
        XCTAssertNil(oldBoard.nodeName)
        XCTAssertEqual(oldBoard.generatedAt, .distantPast)
        var m2 = board("B", [item])
        m2.nodeName = "macbook-pro-arm64"
        XCTAssertTrue(page([m2]).sections.last?.cards?.first?.body?.contains("macbook-pro-arm64") == true)
    }

    func testSinglePublisherStableAcrossMachinesAndRepoOrder() {
        var f = RepoAlias(alias: "flint", path: "/Flint")
        f.coordinatorMachineID = "B"
        let other = RepoAlias(alias: "maw", path: "/maw")
        for id in ["A", "B", "C"] {
            XCTAssertEqual(RoadmapPage.isPublisher(machineID: id, repos: [other, f],
                nodeName: id, peerNames: ["A", "B", "C"]), id == "B")
            XCTAssertEqual(RoadmapPage.isPublisher(machineID: id, repos: [],
                nodeName: id, peerNames: ["C", "B", "A"]), id == "A")
        }
        XCTAssertFalse(RoadmapPage.isPublisher(machineID: "A", repos: [f],
            nodeName: "A", peerNames: ["A"]), "协调机暂时离线也不允许部分页抢写")
    }

    func testDynamicMenuOnlyContainsReadOnlyExtensions() {
        XCTAssertEqual(ViewFeed.menu().entries.map(\.page), ["roadmap", "collaboration"])
    }
}
