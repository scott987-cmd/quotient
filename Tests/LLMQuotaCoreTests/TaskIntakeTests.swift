import XCTest
@testable import LLMQuotaCore

final class TaskIntakeTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-intake-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Paths.appSupportOverride = root
        TaskStore.resetWrittenRevForTests()
    }

    override func tearDown() {
        Paths.appSupportOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testStableRequestRetryReturnsSameTaskWithoutAnotherRow() throws {
        let first = try TaskIntake.enqueue(
            prompt: "实现登录失败后的明确提示", repo: "/tmp/demo",
            classify: false, split: false, idempotencyKey: "phone:req-42",
            source: "phone")
        let second = try TaskIntake.enqueue(
            prompt: "实现登录失败后的明确提示", repo: "/tmp/demo",
            classify: false, split: false, force: true,
            idempotencyKey: "phone:req-42", source: "phone")

        guard case .single(let a) = first, case .single(let b) = second else {
            return XCTFail("应返回单任务")
        }
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, TaskIntake.stableTaskID("phone:req-42"))
        XCTAssertEqual(TaskStore.all().count, 1)
        XCTAssertEqual(TaskStore.all().first?.intakeSource, "phone")
    }

    func testPreparedIntakePreservesPayerClassificationAndOwner() throws {
        var task = WorkTask(id: "external-request-id",
                            prompt: "集群任务描述足够长", repo: "/tmp/demo")
        task.profile = TaskProfile(
            tier: .complex, risk: .normal, estimatedMinutes: 33,
            isSelfContained: true, rationale: "由提交节点付费分诊")
        task.ownerPlatform = .kimi
        task.ownerRunnerID = "kimi.code"

        let result = try TaskIntake.enqueuePrepared(
            task, idempotencyKey: "cluster:node:req", source: "cluster-submit")
        guard case .single(let saved) = result else { return XCTFail("应返回单任务") }
        XCTAssertEqual(saved.id, "external-request-id",
                       "预构造任务的业务稳定 ID 是外部关联，不能被统一入口改名")
        XCTAssertEqual(saved.profile?.estimatedMinutes, 33)
        XCTAssertEqual(saved.ownerPlatform, .kimi)
        XCTAssertEqual(saved.ownerRunnerID, "kimi.code")
        XCTAssertEqual(saved.intakeSource, "cluster-submit")
    }

    func testConcurrentPreparedRetriesCreateOneLogicalTask() {
        let lock = NSLock()
        var ids: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            let candidate = WorkTask(
                id: "pending", prompt: "同一个远端请求", repo: "/tmp/demo")
            if case .single(let saved)? = try? TaskIntake.enqueuePrepared(
                candidate, idempotencyKey: "cluster:request-77",
                source: "cluster-submit") {
                lock.lock(); ids.append(saved.id); lock.unlock()
            }
        }

        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertEqual(ids.first, TaskIntake.stableTaskID("cluster:request-77"))
        XCTAssertEqual(TaskStore.all().count, 1)
    }
}
