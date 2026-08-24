import XCTest
@testable import LLMQuotaCore

/// 阶段 1 的核心不变量：没有一件真正落地、通过适用质量层的样板，
/// 同类生产就只能被看见，不能被派发。
final class GoldenSampleGateTests: XCTestCase {
    private var repo: URL!
    private var appSupport: URL!
    private var savedAppSupport: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedAppSupport = Paths.appSupportOverride
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-gate-\(UUID().uuidString)")
        repo = root.appendingPathComponent("Flint")
        appSupport = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".llmq"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport,
                                                withIntermediateDirectories: true)
        Paths.appSupportOverride = appSupport
        try JSONEncoder().encode(contract()).write(
            to: repo.appendingPathComponent(ProjectContract.relativePath), options: .atomic)
    }

    override func tearDown() {
        Paths.appSupportOverride = savedAppSupport
        if let repo {
            try? FileManager.default.removeItem(
                at: repo.deletingLastPathComponent())
        }
        super.tearDown()
    }

    func testLegacyTasksRemainReadyAndDecodeWithoutProductionMetadata() throws {
        let oldJSON = """
        {"id":"legacy","prompt":"旧项目继续跑","repo":"\(repo.path)",
         "state":"queued","createdAt":0,"dependsOn":[],"outputs":[]}
        """
        let legacy = try JSONDecoder().decode(WorkTask.self, from: Data(oldJSON.utf8))

        XCTAssertNil(legacy.production)
        XCTAssertTrue(TaskGraph.isReady(legacy, in: [legacy]),
                      "阶段 1 只能约束显式接入的生产任务，不能倒退冻结旧项目")
    }

    func testFanOutStaysBlockedUntilSampleIsDoneAndLanded() {
        var sample = sampleTask(kind: "zombie-character", sampleID: "zombie-v1")
        let fanOut = fanOutTask(source: sample)

        XCTAssertEqual(GoldenSampleGate.blockReason(for: fanOut, in: [sample, fanOut]),
                       "黄金样板还在制作或等待处理")
        XCTAssertFalse(TaskGraph.isReady(fanOut, in: [sample, fanOut]))

        sample.state = .done
        XCTAssertEqual(GoldenSampleGate.blockReason(for: fanOut, in: [sample, fanOut]),
                       "黄金样板尚未合入主线")

        sample.landedAt = Date()
        XCTAssertNil(GoldenSampleGate.blockReason(for: fanOut, in: [sample, fanOut]))
        XCTAssertTrue(TaskGraph.isReady(fanOut, in: [sample, fanOut]))
    }

    func testExperienceSampleNeedsQualityApprovalAfterLanding() {
        var sample = sampleTask(kind: "operator-character", sampleID: "operator-v1",
                                requiresExperience: true)
        sample.state = .done
        sample.landedAt = Date()
        sample.branch = "agent/kimi/operator-sample"
        let fanOut = fanOutTask(source: sample)

        XCTAssertEqual(GoldenSampleGate.blockReason(for: fanOut, in: [sample, fanOut]),
                       "黄金样板还没有通过体验质量评审")

        var review = WorkTask(id: "visual", prompt: "【看效果】分支 "
            + "agent/kimi/operator-sample 提交 abc123 的视觉质量是否达标",
                              repo: repo.path)
        review.state = .done
        review.outputs = ["**结论**：达标\n角色轮廓、材质和持枪动作均符合参考。"]
        XCTAssertNil(GoldenSampleGate.blockReason(
            for: fanOut, in: [sample, fanOut, review]))
    }

    func testRejectedExperienceReviewCannotBeMistakenForApproval() {
        var sample = sampleTask(kind: "operator-character", sampleID: "operator-v1",
                                requiresExperience: true)
        sample.state = .done
        sample.landedAt = Date()
        sample.branch = "agent/kimi/operator-rejected"
        let fanOut = fanOutTask(source: sample)
        var review = WorkTask(id: "visual", prompt: "【看效果】分支 "
            + "agent/kimi/operator-rejected 提交 abc123",
                              repo: repo.path)
        review.state = .done
        review.outputs = ["**结论**：未达标\n持枪动作与参考不一致。"]

        XCTAssertEqual(GoldenSampleGate.blockReason(
            for: fanOut, in: [sample, fanOut, review]),
            "黄金样板的体验评审未达标，必须先整改样板")
    }

    func testReconcileBlocksAndAutomaticallyRequeuesFanOut() throws {
        var sample = sampleTask(kind: "zombie-character", sampleID: "zombie-v1")
        var fanOut = fanOutTask(source: sample)

        let blocked = try XCTUnwrap(GoldenSampleGate.reconcile([sample, fanOut]).first)
        XCTAssertEqual(blocked.state, .blocked)
        XCTAssertNotNil(blocked.production?.blockedReason)

        sample.state = .done
        sample.landedAt = Date()
        fanOut = blocked
        let released = try XCTUnwrap(GoldenSampleGate.reconcile([sample, fanOut]).first)
        XCTAssertEqual(released.state, .queued)
        XCTAssertNil(released.production?.blockedReason)
        XCTAssertTrue(TaskGraph.isReady(released, in: [sample, released]))
    }

    func testUnifiedIntakeValidatesContractAndRegistersFanOutAsBlocked() throws {
        let sampleOutcome = try TaskIntake.enqueue(
            prompt: "做出第一只达到参考标准的僵尸", repo: repo.path,
            classify: false, split: true, force: true,
            production: .init(stage: .goldenSample,
                              deliverableKind: "zombie-character",
                              goldenSampleID: "zombie-v1"))
        guard case .single(let sample) = sampleOutcome else {
            return XCTFail("生产任务必须保持单会话，不应被拆成上下文断裂的任务图")
        }

        let fanOutcome = try TaskIntake.enqueue(
            prompt: "按黄金样板生产第二只僵尸", repo: repo.path,
            classify: false, split: true, force: true,
            production: .init(stage: .fanOut,
                              deliverableKind: "zombie-character",
                              goldenSampleID: "",
                              fanOutFromTaskID: sample.id))
        guard case .single(let fanOut) = fanOutcome else {
            return XCTFail("批量生产任务不应被拆图")
        }

        XCTAssertEqual(fanOut.state, .blocked)
        XCTAssertEqual(fanOut.production?.goldenSampleID, "zombie-v1")
        XCTAssertEqual(TaskStore.all().count, 2)
        XCTAssertNil(TaskStore.nextQueued()?.production?.fanOutFromTaskID,
                     "被黄金样板挡住的批量任务绝不能出现在可派发队列里")

        XCTAssertThrowsError(try GoldenSampleGate.prepare(
            .init(stage: .goldenSample, deliverableKind: "weapon",
                  goldenSampleID: "zombie-v1"),
            repo: repo.path, tasks: TaskStore.all()))

        let experienceSample = try GoldenSampleGate.prepare(
            .init(stage: .goldenSample, deliverableKind: "operator-character",
                  goldenSampleID: "operator-v1"),
            repo: repo.path, tasks: TaskStore.all())
        XCTAssertTrue(experienceSample.requiresExperienceApproval,
                      "绑定 Experience 条款的样板不能退化成只要合入就放行")
    }

    func testMobileBriefShowsProductionStageAndExactBlockReason() throws {
        let sample = sampleTask(kind: "zombie-character", sampleID: "zombie-v1")
        var fanOut = fanOutTask(source: sample)
        fanOut.state = .blocked
        fanOut.production?.blockedReason = "黄金样板尚未合入主线"
        fanOut.note = "黄金样板闸：黄金样板尚未合入主线"

        let brief = try XCTUnwrap(TaskBoard.build(
            from: [sample, fanOut], machineName: "Mac mini").tasks
            .first(where: { $0.id == fanOut.id }))

        XCTAssertEqual(brief.progressPhase, "批量扩张")
        XCTAssertEqual(brief.progressNextStep, "黄金样板尚未合入主线")
        XCTAssertEqual(brief.productionStage, "fanOut")
        XCTAssertEqual(brief.deliverableKind, "zombie-character")
        XCTAssertEqual(brief.productionBlockedReason, "黄金样板尚未合入主线")
    }

    private func sampleTask(kind: String, sampleID: String,
                            requiresExperience: Bool = false) -> WorkTask {
        var task = WorkTask(id: "sample-\(sampleID)", prompt: "制作黄金样板",
                            repo: repo.path)
        task.production = .init(stage: .goldenSample, deliverableKind: kind,
                                goldenSampleID: sampleID,
                                requiresExperienceApproval: requiresExperience)
        return task
    }

    private func fanOutTask(source: WorkTask) -> WorkTask {
        var task = WorkTask(id: "fan-\(source.id)", prompt: "批量生产", repo: repo.path)
        task.production = .init(
            stage: .fanOut,
            deliverableKind: source.production?.deliverableKind ?? "",
            goldenSampleID: source.production?.goldenSampleID ?? "",
            fanOutFromTaskID: source.id,
            requiresExperienceApproval: source.production?.requiresExperienceApproval ?? false)
        return task
    }

    private func contract() -> ProjectContract {
        ProjectContract(
            profile: "game",
            outcomeSummary: "Flint：先做出一件可验证的成熟样板，再扩张同类资产",
            criteria: [
                .init(id: "integrity", layer: "integrity",
                      evidenceTypes: ["test-log"]),
                .init(id: "experience", layer: "experience",
                      evidenceTypes: ["comparison-video"],
                      referenceFiles: ["docs/reference/csonline.png"],
                      rejectConditions: ["identity-mismatch", "wrong-weapon-pose"])
            ],
            goldenSamples: [
                .init(id: "zombie-v1", deliverableKind: "zombie-character",
                      criterionIDs: ["integrity"]),
                .init(id: "operator-v1", deliverableKind: "operator-character",
                      criterionIDs: ["integrity", "experience"])
            ])
    }
}
