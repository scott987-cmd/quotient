import XCTest
@testable import LLMQuotaCore

// MARK: - 留白比例：发给手机的那一份

/// 手机上要能看见、也能改每个平台的留白。
/// 这些测试盯的是「**看见的和实际在拦的是不是同一个数**」——
/// 不一致不会报错，只会让人以为自己设的值没生效。
final class ReservePublishingTests: XCTestCase {

    private func withRoles(_ roles: [AgentRole], _ body: () -> Void) {
        let f = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roles-\(UUID().uuidString).json")
        try? SnapshotCoding.prettyEncoder().encode(roles).write(to: f)
        AgentRoles.fileOverride = f
        defer { AgentRoles.fileOverride = nil; try? FileManager.default.removeItem(at: f) }
        body()
    }

    /// **老记录里没有 reserveIsDefault，必须照样解得出来。**
    ///
    /// 合成解码器遇到缺键抛 keyNotFound，整条角色解不出来，然后被
    /// `all()` 那个「坏的跳过」的循环静默丢掉 —— 风险闸门和留白一起失效。
    /// 给属性写默认值救不了这件事，这个坑这个项目踩过五次。
    func testOldRecordWithoutReserveIsDefaultStillDecodes() throws {
        let r = try SnapshotCoding.decoder().decode(AgentRole.self, from: Data("""
        {"platform":"minimax","title":"媒体","maxRisk":"safe","prefers":[],
         "note":"","mutedOn":[],"dispatcherOn":[]}
        """.utf8))
        XCTAssertEqual(r.platform, .minimax)
        XCTAssertNil(r.reserveFraction)
        XCTAssertTrue(r.reserveIsDefault, "没设过就是在用默认")
    }

    /// 老记录里设过留白、但没有这一位时，要推成「不是默认」。
    func testOldRecordWithReserveInfersNotDefault() throws {
        let r = try SnapshotCoding.decoder().decode(AgentRole.self, from: Data("""
        {"platform":"minimax","title":"媒体","maxRisk":"safe","reserveFraction":0.2}
        """.utf8))
        XCTAssertEqual(r.reserveFraction, 0.2)
        XCTAssertFalse(r.reserveIsDefault)
    }

    /// 越界的值当没配 —— 那么这一位也要跟着说「用的是默认」，
    /// 否则手机上会显示用户写的那个 1.5，而调度实际按 25% 在拦。
    func testOutOfRangeRecordReadsAsDefault() throws {
        let r = try SnapshotCoding.decoder().decode(AgentRole.self, from: Data("""
        {"platform":"kimi","title":"主力","maxRisk":"normal","reserveFraction":1.5}
        """.utf8))
        XCTAssertNil(r.reserveFraction)
        XCTAssertTrue(r.reserveIsDefault)
    }

    /// 发布给手机的是**生效值**，不是配置里那个 nil。
    /// 发 nil 的话手机上一片空白，用户以为一个都没设 ——
    /// 而实际每个平台都在按 25% 拦调度。
    func testPublishedRoleResolvesInheritedDefault() {
        withRoles([AgentRole(platform: .minimax, title: "媒体", maxRisk: .safe,
                             reserveFraction: 0.2)]) {
            let mm = AgentRoles.published(for: .minimax, default: 0.25)
            XCTAssertEqual(mm.reserveFraction, 0.2)
            XCTAssertFalse(mm.reserveIsDefault, "单独设过")

            let qwen = AgentRoles.published(for: .qwen, default: 0.25)
            XCTAssertEqual(qwen.reserveFraction, 0.25, "继承的也要给出数字")
            XCTAssertTrue(qwen.reserveIsDefault, "但要说明这个数是默认来的")
        }
    }

    /// 发布的生效值必须和调度**真正在拦**的那个数一致。
    /// 两条路径各算各的话，界面会显示一个不存在的规则。
    func testPublishedValueMatchesWhatSchedulerEnforces() {
        withRoles([AgentRole(platform: .minimax, title: "媒体", maxRisk: .safe,
                             reserveFraction: 0.2)]) {
            for p in [Platform.minimax, .qwen, .claude] {
                XCTAssertEqual(
                    AgentRoles.published(for: p, default: WorkScheduler.defaultHumanReserve)
                        .reserveFraction,
                    AgentRoles.reserve(for: p, default: WorkScheduler().humanReserve),
                    "\(p.rawValue)：手机看到的和调度拦的不是一个数")
            }
        }
    }

    /// 契约是按 dashboard.json 的键定的 —— 直接验那份 JSON。
    func testDashboardJSONCarriesBothFields() throws {
        withRoles([AgentRole(platform: .minimax, title: "媒体", maxRisk: .safe,
                             reserveFraction: 0.2)]) {
            for (p, wantFraction, wantDefault) in [
                (Platform.minimax, 0.2, false),
                (Platform.qwen, WorkScheduler.defaultHumanReserve, true),
            ] {
                let rep = PlatformReport(
                    platform: p, planName: "x", monthlyCost: nil, currency: "CNY",
                    detected: true, machines: [], lastActivity: nil, statuses: [],
                    last30dRequests: 0, last30dBillableTokens: 0, last7dRequests: 0,
                    topModels: [])
                XCTAssertEqual(rep.role?.reserveFraction, wantFraction)
                XCTAssertEqual(rep.role?.reserveIsDefault, wantDefault)

                guard let data = try? SnapshotCoding.encoder().encode(rep),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let role = obj["role"] as? [String: Any] else {
                    return XCTFail("看板里的 role 编不出来")
                }
                XCTAssertEqual(role["reserveFraction"] as? Double, wantFraction,
                               "dashboard.json 里必须是生效值")
                XCTAssertEqual(role["reserveIsDefault"] as? Bool, wantDefault,
                               "还要说明那个数是不是默认来的")
            }
        }
    }

    /// 存回配置时这一位要跟着 reserveFraction 归一化。
    /// 不归一化的话，一份从看板回流的记录会把平台钉死在当时的默认值上，
    /// 而配置里却写着「用的是默认」。
    func testSaveNormalisesTheDerivedFlag() throws {
        withRoles([]) {
            var r = AgentRoles.role(for: .qwen)
            r.reserveFraction = 0.25
            r.reserveIsDefault = true          // 故意写成自相矛盾的
            try? AgentRoles.save([r])
            XCTAssertFalse(AgentRoles.role(for: .qwen).reserveIsDefault,
                           "设了值就不是默认了")
        }
    }
}

// MARK: - 手机递上来的配置意图

final class ConfigIntentTests: XCTestCase {

    private var root: URL!
    private var rolesFile: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("intents-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rolesFile = root.appendingPathComponent("roles.json")
        ConfigIntentIngest.rootOverride = root
        AgentRoles.fileOverride = rolesFile
    }

    override func tearDown() {
        ConfigIntentIngest.rootOverride = nil
        AgentRoles.fileOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func drop(_ json: String, name: String = UUID().uuidString) -> URL {
        ConfigIntentIngest.ensureDirectories()
        let url = ConfigIntentIngest.dir!.appendingPathComponent("\(name).json")
        try? Data(json.utf8).write(to: url)
        return url
    }

    private var pending: [URL] {
        ICloudSafe.contentsOfDirectory(ConfigIntentIngest.dir!)
            .filter { $0.pathExtension == "json" }
    }
    private var processed: [URL] {
        ICloudSafe.contentsOfDirectory(ConfigIntentIngest.doneDir!)
    }

    /// **同一轮里，最晚写的那条说了算 —— 而不是文件名排在最后的那条。**
    ///
    /// 这条是审查时实测复现出来的缺陷：原来按文件名排序应用，而文件名是
    /// UUID，也就是随机顺序。11:00 设 0.6、10:00 设 0.2，生效的是 **0.2**，
    /// 两份回执还都写着「已应用」。
    ///
    /// 而手机每次滑动提交写一个 UUID 文件，一轮攒到多条是常态
    /// （Mac 睡着时手机写的意图会在恢复后一次性到齐 —— 这个功能的
    /// 场景恰恰就是「人在外面、Mac 在忙」）。所以这是必然会触发的路径。
    func testLatestIntentWinsRegardlessOfFilename() {
        // 故意让「早的那条」文件名排在后面。
        drop("""
        {"id":"old","createdAt":"2026-08-13T10:00:00Z","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.2}
        """, name: "zzz")
        drop("""
        {"id":"new","createdAt":"2026-08-13T11:00:00Z","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.6}
        """, name: "aaa")

        ConfigIntentIngest.run()
        XCTAssertEqual(AgentRoles.all()[.minimax]?.reserveFraction, 0.6,
                       "生效的必须是 11:00 那条（0.6），不是文件名排最后的那条")
    }

    /// 被取代的那条**不能也写「已应用」**。
    ///
    /// 事后查「这个值怎么变成现在这样的」，两条互相矛盾的回执比没有回执更糟。
    func testSupersededIntentIsNotReportedAsApplied() {
        drop("""
        {"id":"old","createdAt":"2026-08-13T10:00:00Z","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.2}
        """, name: "zzz")
        drop("""
        {"id":"new","createdAt":"2026-08-13T11:00:00Z","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.6}
        """, name: "aaa")

        let out = ConfigIntentIngest.run()
        let applied = out.filter(\.accepted)
        XCTAssertEqual(applied.count, 1, "只能有一条算数，实际 \(out.map { ($0.id, $0.accepted) })")
        XCTAssertEqual(applied.first?.id, "new")
        XCTAssertTrue(pending.isEmpty, "两条都该被移走")
    }

    /// 不同平台互不影响 —— 去重的键不能只是 platform 之外的东西。
    func testDifferentPlatformsBothApply() {
        drop("""
        {"id":"a","createdAt":"2026-08-13T10:00:00Z","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.2}
        """)
        drop("""
        {"id":"b","createdAt":"2026-08-13T10:00:01Z","source":"phone",
         "kind":"reserve","platform":"qwen","fraction":0.0}
        """)
        ConfigIntentIngest.run()
        XCTAssertEqual(AgentRoles.all()[.minimax]?.reserveFraction, 0.2)
        XCTAssertEqual(AgentRoles.all()[.qwen]?.reserveFraction, 0.0)
    }

    /// 日期格式不认识时，**意图不能被当成坏 JSON 丢掉**。
    ///
    /// 原来 `decodeIfPresent(Date.self)` 遇到格式不符会抛 typeMismatch，
    /// 而调用方是 `try?` —— 一条完全合法的意图会被归档成「不是 JSON」，
    /// 用户那边只看到设置没生效、文件不见了。
    func testWeirdDateStillApplies() {
        drop("""
        {"id":"x","createdAt":"昨天下午","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.3}
        """)
        let out = ConfigIntentIngest.run()
        XCTAssertTrue(out.first?.accepted ?? false,
                      "日期解不出来只该影响排序，不该丢掉意图：\(out.first?.note ?? "")")
        XCTAssertEqual(AgentRoles.all()[.minimax]?.reserveFraction, 0.3)
    }

    /// 合法意图要真的改到配置上 —— 不是「收到了」，是**调度下一次判定会用它**。
    func testValidIntentActuallyChangesRoles() {
        drop("""
        {"id":"3F2504E0","createdAt":"2026-08-13T13:30:00Z","source":"phone",
         "kind":"reserve","platform":"minimax","fraction":0.2}
        """)
        let out = ConfigIntentIngest.run()
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].accepted, out[0].note)
        XCTAssertEqual(AgentRoles.reserve(for: .minimax, default: 0.25), 0.2,
                       "调度取的就是这个数")
        XCTAssertEqual(AgentRoles.role(for: .minimax).reserveFraction, 0.2)
        XCTAssertFalse(AgentRoles.role(for: .minimax).reserveIsDefault)
    }

    /// 落地必须走 AgentRoles.save —— 它是 diff-based 的，别的字段要保住。
    /// 手机端的模型认不全这些字段，这正是它不能自己写配置的原因。
    func testOtherFieldsSurviveTheWrite() throws {
        var claude = AgentRoles.role(for: .claude)
        claude.dispatcherOn = ["某台Mac"]
        claude.maxTier = .complex
        claude.mutedOn = ["某台Mac"]
        try AgentRoles.save([claude])

        drop("""
        {"id":"a","kind":"reserve","platform":"claude","fraction":0.5}
        """)
        XCTAssertTrue(ConfigIntentIngest.run().first?.accepted == true)

        let back = AgentRoles.role(for: .claude)
        XCTAssertEqual(back.reserveFraction, 0.5)
        XCTAssertEqual(back.dispatcherOn, ["某台Mac"], "指挥身份被洗掉了")
        XCTAssertEqual(back.maxTier, .complex, "难度上限被洗掉了")
        XCTAssertEqual(back.mutedOn, ["某台Mac"], "静音被洗掉了")
        XCTAssertEqual(back.maxRisk, .sensitive, "风险上限被洗掉了")
    }

    /// **超范围要拒，不能静默钳制。**
    ///
    /// 钳到 0.95 的话，用户记得自己设的是 99%，界面回读也说 95%，
    /// 于是「为什么它还在被调度」这个问题会带着错误的前提去查。
    func testOutOfRangeIsRejectedNotClamped() {
        for bad in ["0.99", "1", "1.5", "-0.1"] {
            drop("""
            {"id":"bad-\(bad)","kind":"reserve","platform":"qwen","fraction":\(bad)}
            """)
            let out = ConfigIntentIngest.run()
            XCTAssertEqual(out.count, 1)
            XCTAssertFalse(out[0].accepted, "\(bad) 该被拒")
            XCTAssertTrue(out[0].note.contains("超出允许范围"), out[0].note)
            XCTAssertNil(AgentRoles.role(for: .qwen).reserveFraction,
                         "\(bad) 被拒之后不许留下任何改动（尤其不许是钳过的值）")
        }
    }

    /// 边界值本身是合法的 —— 0 = 随便用光，0.95 = 只留一线。
    func testBoundaryValuesAreAccepted() {
        for (p, f) in [(Platform.qwen, "0"), (.kimi, "0.95")] {
            drop("""
            {"id":"ok","kind":"reserve","platform":"\(p.rawValue)","fraction":\(f)}
            """)
            XCTAssertTrue(ConfigIntentIngest.run().first?.accepted == true,
                          "\(f) 是合法边界")
            XCTAssertEqual(AgentRoles.role(for: p).reserveFraction, Double(f))
        }
    }

    /// 不认识的平台/类型/缺字段/坏 JSON：一律拒，但都要说清是哪一种。
    /// 合并成一句「参数不对」的话，用户不知道该补字段还是该改数。
    func testMalformedIntentsAreRejectedWithDistinctReasons() {
        let cases: [(String, String)] = [
            ("""
             {"id":"1","kind":"reserve","platform":"没这个平台","fraction":0.2}
             """, "不认识的平台"),
            ("""
             {"id":"2","kind":"未来的类型","platform":"qwen","fraction":0.2}
             """, "不认识的意图类型"),
            ("""
             {"id":"3","kind":"reserve","platform":"qwen"}
             """, "没带 fraction"),
            ("这不是 json", "不是能解的 JSON"),
        ]
        for (body, want) in cases {
            drop(body)
            let out = ConfigIntentIngest.run()
            XCTAssertEqual(out.count, 1)
            XCTAssertFalse(out[0].accepted)
            XCTAssertTrue(out[0].note.contains(want), "说的是「\(out[0].note)」")
        }
    }

    /// **处理过的文件要被移走** —— 不移的话每轮重试同一个坏文件，
    /// 日志里每 30 秒一条同样的红字，真正的新意图淹在里面。
    /// 移走而不是删掉：删了手机上会看到文件凭空消失，让人怀疑没送达。
    func testProcessedFilesAreMovedNotDeleted() {
        let good = drop("""
        {"id":"good","kind":"reserve","platform":"qwen","fraction":0.1}
        """, name: "good")
        let bad = drop("""
        {"id":"bad","kind":"reserve","platform":"没这个平台","fraction":0.1}
        """, name: "bad")

        _ = ConfigIntentIngest.run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertTrue(pending.isEmpty, "待处理目录该空了")

        let names = processed.map(\.lastPathComponent)
        XCTAssertTrue(names.contains { $0.hasSuffix("-applied-good.json") },
                      "原文件要留在 processed 里：\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("-rejected-bad.json") }, "\(names)")
        // 判定理由也要留下，不然只有一个文件名能看。
        XCTAssertTrue(names.contains { $0.hasSuffix("-rejected-bad.result.json") }, "\(names)")

        // 移走之后不许再被消费一次。
        XCTAssertTrue(ConfigIntentIngest.run().isEmpty)
    }

    /// 回执里要能看出到底改成了什么。
    func testReceiptSaysWhatChanged() throws {
        drop("""
        {"id":"r1","kind":"reserve","platform":"minimax","fraction":0.4}
        """, name: "r1")
        _ = ConfigIntentIngest.run()
        guard let url = processed.first(where: { $0.lastPathComponent.hasSuffix(".result.json") }),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return XCTFail("没写回执：\(processed.map(\.lastPathComponent))") }
        XCTAssertEqual(obj["id"] as? String, "r1")
        XCTAssertEqual(obj["accepted"] as? Bool, true)
        XCTAssertTrue((obj["note"] as? String ?? "").contains("40%"), "\(obj)")
    }

    /// **写不进去时意图要留在原地。**
    ///
    /// 这是「这次没写成」，不是「这条不合法」—— 移走等于把一条合法意图
    /// 永久吞掉，而用户那边只看到文件不见了、配置没变，无从判断发生了什么。
    func testWriteFailureKeepsTheIntentForNextRound() {
        AgentRoles.fileOverride = URL(fileURLWithPath: "/dev/null/没有这个目录/roles.json")
        defer { AgentRoles.fileOverride = rolesFile }
        drop("""
        {"id":"keep","kind":"reserve","platform":"qwen","fraction":0.3}
        """, name: "keep")

        let out = ConfigIntentIngest.run()
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].accepted)
        XCTAssertTrue(out[0].note.contains("下一轮再试"), out[0].note)
        XCTAssertEqual(pending.count, 1, "意图不该被移走")
    }

    /// 目录里的 processed 子目录不能被当成一条意图扫进来。
    func testProcessedSubdirectoryIsNotIngested() {
        ConfigIntentIngest.ensureDirectories()
        XCTAssertTrue(ConfigIntentIngest.run().isEmpty)
    }
}
