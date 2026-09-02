import XCTest
@testable import LLMQuotaCore

final class ClusterDispatchPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func presence(_ id: String, node: String,
                          repos: [String] = ["flint"],
                          automatic: [String] = ["flint"],
                          running: [String] = [], slots: Int = 1,
                          used: Int = 0, canReach: [String: Bool] = [:],
                          capabilities: [String] = [],
                          claims: [String] = []) -> ClusterPresence {
        ClusterPresence(
            machineID: id, machineName: id, nodeName: node,
            lanIP: "192.168.1.2", port: 8443, serving: true,
            boundAddress: "192.168.1.2:8443", lanRouteInterface: "en0",
            firewallOn: false, canReach: canReach, updatedAt: now, version: "1",
            repoAliases: repos, automaticRepoAliases: automatic,
            maxConcurrentTasks: slots, runningTaskCount: used,
            runningRepoAliases: running, capabilities: capabilities,
            runningResourceClaims: claims)
    }

    private func agent(_ machine: String, runner: String = "kimi.code",
                       platform: Platform = .kimi,
                       risk: TaskProfile.Risk = .normal,
                       tier: TaskProfile.Tier = .standard,
                       quota: Double? = nil,
                       blockedReason: String? = nil) -> AgentRegistration {
        AgentRegistration(
            machineID: machine, machineName: machine, runnerID: runner,
            platform: platform, canConsult: false, canEdit: true,
            canReadFiles: true, maxRisk: risk, maxTier: tier,
            quotaAvailableFraction: quota, quotaBlockedReason: blockedReason,
            updatedAt: now)
    }

    func testSelectsReadyMachineByStableIdentityAndRepoAlias() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            currentMachineID: "mini", coordinatorMachineID: "mini",
            presences: [
                presence("mini", node: "mac-mini", canReach: ["m2": true]),
                presence("m2-id", node: "m2", slots: 2),
            ], registrations: [agent("m2-id")], now: now)

        XCTAssertEqual(plan.selected?.machineID, "m2-id")
        XCTAssertEqual(plan.selected?.nodeName, "m2")
        XCTAssertEqual(plan.selected?.runnerID, "kimi.code")
        XCTAssertEqual(plan.selected?.freeSlots, 2)
    }

    func testPrefersUsableQuotaAndRejectsBlockedAgent() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            currentMachineID: "mini", coordinatorMachineID: "mini",
            presences: [
                presence("mini", node: "mac-mini",
                         canReach: ["m2": true, "intel": true, "blocked": true]),
                presence("m2-id", node: "m2", slots: 1),
                presence("intel-id", node: "intel", slots: 3),
                presence("blocked-id", node: "blocked", slots: 8),
            ], registrations: [
                agent("m2-id", quota: 0.7),
                agent("intel-id", quota: 0.1),
                agent("blocked-id", quota: 0,
                      blockedReason: "额度已用尽"),
            ], now: now)

        XCTAssertEqual(plan.selected?.machineID, "m2-id")
        XCTAssertEqual(plan.selected?.quotaAvailableFraction, 0.7)
        XCTAssertFalse(plan.options.contains { $0.machineID == "blocked-id" })
        XCTAssertTrue(plan.rejected.contains { $0.machineID == "blocked-id"
            && $0.reason.contains("额度已用尽") })
    }

    func testCoordinatorCanChooseItselfWhenExecutionScopeAllows() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            currentMachineID: "m2-id", coordinatorMachineID: "m2-id",
            presences: [
                presence("m2-id", node: "m2", slots: 2),
                presence("intel-id", node: "intel", slots: 3),
            ], registrations: [
                agent("m2-id", quota: 0.8),
                agent("intel-id", quota: 0.2),
            ], now: now)

        XCTAssertEqual(plan.selected?.machineID, "m2-id")
        XCTAssertEqual(plan.selected?.nodeName, "m2")
        XCTAssertEqual(plan.selected?.runnerID, "kimi.code")
    }

    func testRequiresMachineCapabilityAndRejectsConflictingResourceClaim() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            requiredCapabilities: ["tool:unreal"],
            resourceClaims: ["tool:unreal-editor"],
            currentMachineID: "mini", coordinatorMachineID: "mini",
            presences: [
                presence("mini", node: "mac-mini",
                         canReach: ["m2": true, "intel": true]),
                presence("m2-id", node: "m2", capabilities: ["tool:unreal"],
                         claims: ["tool:unreal-editor"]),
                presence("intel-id", node: "intel", capabilities: []),
            ], registrations: [agent("m2-id"), agent("intel-id")], now: now)

        XCTAssertNil(plan.selected)
        XCTAssertTrue(plan.rejected.contains { $0.machineID == "m2-id"
            && $0.reason.contains("资源") })
        XCTAssertTrue(plan.rejected.contains { $0.machineID == "intel-id"
            && $0.reason.contains("能力") })
    }

    func testProjectImplementationOwnerIsAHardCrossMachineBoundary() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            preferredPlatform: .kimi,
            currentMachineID: "m2-id", coordinatorMachineID: "m2-id",
            presences: [presence("m2-id", node: "m2", slots: 2)],
            registrations: [
                agent("m2-id", runner: "codex.code", platform: .codex, quota: 0.95),
                agent("m2-id", quota: 0.20),
            ], now: now)

        XCTAssertEqual(plan.selected?.runnerID, "kimi.code")
        XCTAssertEqual(plan.selected?.platform, .kimi)
    }

    func testDoesNotRouteIntoBusySameProjectOrWrongFocus() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            currentMachineID: "mini", coordinatorMachineID: "mini",
            presences: [
                presence("mini", node: "mac-mini", canReach: ["busy": true, "maw": true]),
                presence("busy-id", node: "busy", running: ["flint"]),
                presence("maw-id", node: "maw", automatic: ["maw"]),
            ], registrations: [agent("busy-id"), agent("maw-id")], now: now)

        XCTAssertNil(plan.selected)
        XCTAssertTrue(plan.rejected.contains { $0.machineID == "busy-id"
            && $0.reason.contains("同一项目") })
        XCTAssertTrue(plan.rejected.contains { $0.machineID == "maw-id"
            && $0.reason.contains("作用域") })
    }

    func testExactOwnerAndCapabilityLimitsAreHardGates() {
        let complex = TaskProfile(
            tier: .complex, risk: .sensitive, estimatedMinutes: 30,
            isSelfContained: true, rationale: "test")
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: complex,
            preferredRunnerID: "kimi.code", currentMachineID: "mini",
            coordinatorMachineID: "mini",
            presences: [
                presence("mini", node: "mac-mini", canReach: ["m2": true]),
                presence("m2-id", node: "m2"),
            ], registrations: [agent("m2-id", runner: "qwen.code",
                                    risk: .sensitive, tier: .complex),
                               agent("m2-id", risk: .normal, tier: .standard)], now: now)

        XCTAssertNil(plan.selected)
        XCTAssertTrue(plan.rejected.first?.reason.contains("Owner kimi.code") == true)
    }

    func testLegacyPresenceWithoutCapabilityFailsClosed() throws {
        let legacyJSON = """
        {"machineID":"m2-id","machineName":"M2","nodeName":"m2",
         "lanIP":"192.168.1.2","port":8443,"serving":true,
         "firewallOn":false,"canReach":{},"updatedAt":"2033-05-18T03:33:20Z","version":"1"}
        """
        let old = try SnapshotCoding.decoder().decode(
            ClusterPresence.self, from: Data(legacyJSON.utf8))
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            currentMachineID: "mini", coordinatorMachineID: "mini",
            presences: [presence("mini", node: "mac-mini", canReach: ["m2": true]), old],
            registrations: [agent("m2-id")], now: now)

        XCTAssertNil(plan.selected)
        XCTAssertEqual(old.maxConcurrentTasks, 0)
        XCTAssertEqual(old.repoAliases, [])
        XCTAssertNil(old.coordinatorState)
        XCTAssertNil(old.coordinatorSummary)
    }

    func testOnlyProjectCoordinatorMayAutoRoute() {
        let plan = ClusterDispatchPlanner.plan(
            repoAlias: "flint", lane: .coding, profile: nil,
            currentMachineID: "laptop", coordinatorMachineID: "mini",
            presences: [
                presence("laptop", node: "laptop", canReach: ["m2": true]),
                presence("m2-id", node: "m2"),
            ], registrations: [agent("m2-id")], now: now)

        XCTAssertNil(plan.selected)
        XCTAssertTrue(plan.rejected.allSatisfy { $0.reason.contains("唯一协调机") })
    }
}
