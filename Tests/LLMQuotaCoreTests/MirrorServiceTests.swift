import XCTest
@testable import LLMQuotaCore

/// MirrorService 的规则测试。**纯本地**：两个临时目录当 local/cloud，
/// 不碰真 iCloud —— 「云端列不动」「抢占输了」用注入口模拟。
final class MirrorServiceTests: XCTestCase {

    var local: URL!
    var cloud: URL!
    let mid = "machine-A"

    override func setUp() {
        super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirror-\(UUID().uuidString)")
        local = base.appendingPathComponent("local")
        cloud = base.appendingPathComponent("cloud")
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - 工具

    @discardableResult
    func put(_ root: URL, _ rel: String, _ content: String, age: TimeInterval = 0) -> URL {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: url, atomically: false, encoding: .utf8)
        if age > 0 {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        return url
    }

    func read(_ root: URL, _ rel: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func exists(_ root: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    func sync(cloudList: ((URL) -> ICloudSafe.Probe<[URL]>)? = nil,
              cloudMove: ((URL, URL) -> Bool)? = nil) -> MirrorStats {
        MirrorService.sync(local: local, cloud: cloud, selfMachineID: mid,
                           cloudList: cloudList, cloudMove: cloudMove)
    }

    // MARK: - 按机器分文件的目录（snapshots/ taskboards/ presence/）

    func testPerMachinePushOwnPullOthers() {
        put(local, "snapshots/\(mid).json", "mine-new", age: 60)
        put(cloud, "snapshots/\(mid).json", "mine-old", age: 600)
        put(cloud, "snapshots/machine-B.json", "theirs", age: 60)

        let stats = sync()
        XCTAssertEqual(read(cloud, "snapshots/\(mid).json"), "mine-new", "本机文件要推上去")
        XCTAssertEqual(read(local, "snapshots/machine-B.json"), "theirs", "别人的文件要拉下来")
        XCTAssertGreaterThanOrEqual(stats.pushed, 1)
        XCTAssertGreaterThanOrEqual(stats.pulled, 1)
        XCTAssertTrue(stats.errors.isEmpty, "不该有错误：\(stats.errors)")
    }

    func testPerMachineNewerWinsNeverRegresses() {
        // 云端的本机文件比本地新（比如 App 上一轮刚推完、本地还没再写）——
        // 既不该推（会回退云端），也不该拉（本机文件的真相在本地）。
        put(local, "taskboards/\(mid).json", "local-old", age: 600)
        put(cloud, "taskboards/\(mid).json", "cloud-new", age: 60)

        _ = sync()
        XCTAssertEqual(read(cloud, "taskboards/\(mid).json"), "cloud-new")
        XCTAssertEqual(read(local, "taskboards/\(mid).json"), "local-old")
    }

    // MARK: - 根下单文件：只推

    func testRootFilesPushOnly() {
        put(local, "dashboard.json", "dash-new", age: 60)
        put(cloud, "dashboard.json", "dash-old", age: 600)
        // office.json 云端更新 —— 推方向的 LWW 不拉回来。
        put(local, "office.json", "office-local", age: 600)
        put(cloud, "office.json", "office-cloud", age: 60)

        _ = sync()
        XCTAssertEqual(read(cloud, "dashboard.json"), "dash-new")
        XCTAssertEqual(read(local, "office.json"), "office-local", "根文件是推方向，不拉")
        XCTAssertEqual(read(cloud, "office.json"), "office-cloud", "本地不新就不推")
    }

    // MARK: - config/ releases/：双向新者胜

    func testConfigBidirectionalNewerWins() {
        put(local, "config/plans.json", "plans-new", age: 60)
        put(cloud, "config/plans.json", "plans-old", age: 600)
        put(local, "config/roles.json", "roles-old", age: 600)
        put(cloud, "config/roles.json", "roles-new", age: 60)

        let stats = sync()
        XCTAssertEqual(read(cloud, "config/plans.json"), "plans-new")
        XCTAssertEqual(read(local, "config/roles.json"), "roles-new")
        XCTAssertTrue(stats.errors.isEmpty, "\(stats.errors)")
    }

    func testReleasesPulledForUpdate() {
        // 发布机推上去，对端拉下来给 llmq update 用。
        put(cloud, "releases/current.json", "manifest", age: 60)
        _ = sync()
        XCTAssertEqual(read(local, "releases/current.json"), "manifest")
    }

    // MARK: - questions/ outbox/：精确推（含删除）

    func testExactPushMirrorsDeletes() {
        put(local, "questions/\(mid)/q1.json", "ask", age: 60)
        put(cloud, "questions/\(mid)/retracted.json", "old-ask", age: 600)
        // 别的机器的问题目录：本机的「没有」不是它的真相，绝不能动。
        put(cloud, "questions/machine-B/their-q.json", "their-ask", age: 600)

        _ = sync()
        XCTAssertEqual(read(cloud, "questions/\(mid)/q1.json"), "ask")
        XCTAssertFalse(exists(cloud, "questions/\(mid)/retracted.json"),
                       "本机子目录里本地是唯一真相，撤回的问题云端也要消失")
        XCTAssertTrue(exists(cloud, "questions/machine-B/their-q.json"),
                      "别的机器的问题绝不能被本机的精确推删掉")
    }

    /// **outbox 只推不删 —— 双机互删是审查抓出来的真缺陷。**
    ///
    /// 云端 outbox 是两台机器共写的扁平目录。第一版契约写成「精确推含删除」，
    /// 后果：A 的「云端 := 本地」把 B 的任务结果删掉，B 下一轮推回来，A 再删……
    /// 来回拍打，手机上的任务结果时有时无。而旧架构里从来没有东西删过 outbox。
    func testOutboxNeverDeletesOtherMachinesResults() {
        put(local, "outbox/mine.json", "my-result", age: 60)
        put(cloud, "outbox/theirs.json", "peer-result", age: 600)   // B 机器的，本地没有

        _ = sync()
        XCTAssertEqual(read(cloud, "outbox/mine.json"), "my-result", "自己的照推")
        XCTAssertTrue(exists(cloud, "outbox/theirs.json"),
                      "别的机器的结果绝不能因为「本地没有」被删 —— 那是互删拍打的起点")
        XCTAssertEqual(read(cloud, "outbox/theirs.json"), "peer-result")
    }

    /// **「读不到」≠「没有」。** 云端目录列不动时，那个目录整轮跳过 ——
    /// 绝不能当成空目录去执行精确推的删除，那会把云端的问题/结果文件全删光。
    func testStalledCloudListNeverDeletes() {
        // 靶子用 questions/<本机>/ —— 它是仅剩的「精确推含删除」目录。
        // （outbox 原来也是，但审查发现那是双机互删，已改成只推不删、
        //  不再列云端 —— 所以它不能再当这条用例的靶子。）
        put(local, "questions/\(mid)/q1.json", "ask", age: 60)
        put(cloud, "questions/\(mid)/precious.json", "do-not-delete", age: 600)

        let myID = mid
        let stats = sync(cloudList: { url in
            url.lastPathComponent == myID && url.deletingLastPathComponent()
                .lastPathComponent == "questions" ? .stalled : ICloudSafe.list(url)
        })

        XCTAssertTrue(exists(cloud, "questions/\(mid)/precious.json"),
                      "列不动 ≠ 空目录 —— 删了就是把「读不到」当「没有」")
        XCTAssertFalse(exists(cloud, "questions/\(mid)/q1.json"), "整个目录该跳过，推也不推")
        XCTAssertFalse(stats.errors.isEmpty, "跳过必须记进错误，不能静默")

        // 心跳要如实说这轮没成功。
        let state = heartbeat()
        XCTAssertNotNil(state?.lastError)
        XCTAssertNil(state?.lastOKAt, "带错误的轮次不许刷新 lastOKAt")
    }

    // MARK: - 抢占拉（inbox/ config-intents/ answers/<本机ID>/）

    func testClaimPullWins() {
        put(cloud, "inbox/task.txt", "do the thing", age: 60)
        put(cloud, "config-intents/i1.json", "{\"kind\":\"reserve\"}", age: 60)
        put(cloud, "answers/\(mid)/a1.json", "{\"askID\":\"x\"}", age: 60)
        put(cloud, "answers/machine-B/their.json", "not-ours", age: 60)

        let stats = sync()

        XCTAssertEqual(read(local, "inbox/task.txt"), "do the thing")
        XCTAssertFalse(exists(cloud, "inbox/task.txt"), "抢到之后云端 inbox 里要消失")
        XCTAssertEqual(read(local, "config-intents/i1.json"), "{\"kind\":\"reserve\"}")
        XCTAssertEqual(read(local, "answers/\(mid)/a1.json"), "{\"askID\":\"x\"}")
        XCTAssertTrue(exists(cloud, "answers/machine-B/their.json"),
                      "别的机器的答案不归本机领")
        XCTAssertEqual(stats.claimed, 3)

        // processed 命名照抄 CLI 的习惯：<stamp>-<verdict>-<原名>。
        // 手机端靠「文件从 inbox 消失、在 processed 出现」判断送达。
        let parked = (try? FileManager.default.contentsOfDirectory(
            at: cloud.appendingPathComponent("inbox/processed"),
            includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(parked.count, 1)
        let name = parked.first?.lastPathComponent ?? ""
        XCTAssertTrue(name.hasSuffix("-claimed-task.txt"), "实际叫 \(name)")
        XCTAssertFalse(name.contains(":"), "时间戳里的冒号要去掉（和 CLI 一致）")
    }

    func testClaimPullLoses() {
        put(cloud, "inbox/task.txt", "contested", age: 60)

        // 模拟另一台机器先抢走了：move 时源文件已经不在了。
        let stats = sync(cloudMove: { from, _ in
            try? FileManager.default.removeItem(at: from)
            return false
        })

        XCTAssertEqual(stats.claimed, 0)
        XCTAssertFalse(exists(local, "inbox/task.txt"), "没抢到就不许落地 —— 会执行两遍")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: local.appendingPathComponent("inbox").path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasPrefix(".claim-") }.isEmpty,
                      "临时文件要清掉：\(leftovers)")
        XCTAssertTrue(stats.errors.isEmpty, "没抢到不是错误，是正常仲裁结果")
    }

    // MARK: - 永不入镜的东西

    /// 集群私钥（Application Support/LLMQuotaBar/cluster/）**不在** shared 下，
    /// 镜像的目录清单里也永远没有它 —— 私钥进 iCloud 等于全集群裸奔。
    func testClusterKeysNeverMirrored() {
        // 钉死路径关系：cluster/ 不在 sharedRoot 下面。
        let savedOverride = Paths.appSupportOverride
        defer { Paths.appSupportOverride = savedOverride }
        Paths.appSupportOverride = nil
        XCTAssertFalse(ClusterCA.dir.path.hasPrefix(Paths.sharedRoot.path + "/"),
                       "cluster/ 目录绝不能落进共享暂存")

        // 就算有人手滑把 cluster/ 放进了暂存根，镜像也只认清单里的目录。
        put(local, "cluster/ca.key", "PRIVATE KEY", age: 60)
        _ = sync()
        XCTAssertFalse(exists(cloud, "cluster/ca.key"), "私钥被推上 iCloud 了")
        XCTAssertFalse(exists(cloud, "cluster"), "cluster/ 目录根本不该出现在云端")
        XCTAssertFalse(SharedLayout.dirs.contains { $0.hasPrefix("cluster") })
    }

    func testDebrisAndDotfilesNeverMove() {
        put(local, "outbox/r.json.sb-123", "half-written", age: 60)
        put(cloud, "outbox/ghost.json.sb-9", "cloud-debris", age: 600)
        put(cloud, "inbox/x.json.sb-7", "cloud-debris", age: 60)
        put(cloud, "config/.hidden.json", "dot", age: 60)

        let stats = sync()
        XCTAssertFalse(exists(cloud, "outbox/r.json.sb-123"), ".sb- 半成品不推")
        XCTAssertTrue(exists(cloud, "outbox/ghost.json.sb-9"),
                      "云端的 .sb- 半成品不归镜像删（doctor --tidy 才管）")
        XCTAssertTrue(exists(cloud, "inbox/x.json.sb-7"), ".sb- 不抢")
        XCTAssertFalse(exists(local, "inbox/x.json.sb-7"))
        XCTAssertFalse(exists(local, "config/.hidden.json"), "点文件不拉")
        XCTAssertEqual(stats.claimed, 0)
    }

    // MARK: - 心跳

    func heartbeat() -> MirrorState? {
        guard let data = try? Data(contentsOf:
            local.appendingPathComponent(MirrorService.stateFileName)) else { return nil }
        return try? SnapshotCoding.decoder().decode(MirrorState.self, from: data)
    }

    func testHeartbeatWrittenAndNeverPushed() throws {
        put(local, "dashboard.json", "d", age: 60)
        let stats = sync()

        let state = try XCTUnwrap(heartbeat())
        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertNil(state.lastError)
        XCTAssertNotNil(state.lastOKAt)
        XCTAssertEqual(state.pushed, stats.pushed)
        XCTAssertFalse(exists(cloud, MirrorService.stateFileName), "心跳是本地的事，不上云")

        // 出错的轮次：lastError 记上，lastOKAt 保住上一轮的值。
        _ = sync(cloudList: { url in
            url.lastPathComponent == "config" ? .stalled : ICloudSafe.list(url)
        })
        let after = try XCTUnwrap(heartbeat())
        XCTAssertNotNil(after.lastError)
        XCTAssertNotNil(after.lastOKAt, "出错不能把上一次成功的记录抹掉")
    }

    /// 新增可解码字段一律手写 decodeIfPresent —— keyNotFound 翻过五次车。
    func testHeartbeatDecodesWithMissingKeys() throws {
        let state = try SnapshotCoding.decoder().decode(MirrorState.self, from: Data("{}".utf8))
        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertNil(state.lastOKAt)
        XCTAssertEqual(state.pushed, 0)
    }

    // MARK: - 心跳三态

    func writeState(_ s: MirrorState, to root: URL) {
        let data = try! SnapshotCoding.prettyEncoder().encode(s)
        try? data.write(to: root.appendingPathComponent(MirrorService.stateFileName))
    }

    func testMirrorHealthThreeStates() {
        let now = Date()

        // ① 从未授权 / App 从未跑过：没有心跳文件。
        if case .neverSynced = MirrorHealth.check(root: local, now: now) {} else {
            XCTFail("没有心跳文件必须报 neverSynced")
        }
        XCTAssertTrue(MirrorHealth.describe(.neverSynced).contains("授权"))

        // ② App 没在跑：心跳存在但 lastAttemptAt 超过 5 分钟。
        writeState(MirrorState(lastAttemptAt: now.addingTimeInterval(-600),
                               lastOKAt: now.addingTimeInterval(-600)), to: local)
        guard case .appNotRunning(let st1) = MirrorHealth.check(root: local, now: now) else {
            return XCTFail("心跳过期必须报 appNotRunning")
        }
        XCTAssertTrue(MirrorHealth.describe(.appNotRunning(st1)).contains("没在跑"))

        // ③ 镜像在报错：尝试新鲜，但上一轮有错。
        writeState(MirrorState(lastAttemptAt: now, lastOKAt: nil,
                               lastError: "inbox/：云端目录列不动"), to: local)
        guard case .failing(let st2) = MirrorHealth.check(root: local, now: now) else {
            return XCTFail("有错必须报 failing")
        }
        XCTAssertTrue(MirrorHealth.describe(.failing(st2)).contains("报错"))
        XCTAssertTrue(MirrorHealth.describe(.failing(st2)).contains("列不动"),
                      "原因要透传给人看")

        // ④ 健康。
        writeState(MirrorState(lastAttemptAt: now, lastOKAt: now, pushed: 3, pulled: 1),
                   to: local)
        guard case .ok = MirrorHealth.check(root: local, now: now) else {
            return XCTFail("新鲜且零错误必须报 ok")
        }
    }

    // MARK: - 稳定性：连跑两轮不打乒乓

    func testSecondSyncIsQuiet() {
        put(local, "snapshots/\(mid).json", "mine", age: 60)
        put(cloud, "snapshots/machine-B.json", "theirs", age: 60)
        put(local, "config/plans.json", "p", age: 60)
        put(local, "outbox/t1.json", "r", age: 60)
        _ = sync()
        let second = sync()
        XCTAssertEqual(second.pushed, 0, "第二轮不该再推 —— mtime 没对齐会永远打乒乓")
        XCTAssertEqual(second.pulled, 0)
        XCTAssertEqual(second.claimed, 0)
    }
}
