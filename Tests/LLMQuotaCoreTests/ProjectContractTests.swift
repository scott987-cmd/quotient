import XCTest
@testable import LLMQuotaCore

final class ProjectContractTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("docs/reference"),
            withIntermediateDirectories: true)
        for path in ["QUALITY.md", "BENCHMARK.md", "PRODUCTION.md"] {
            try "# \(path)\n".write(to: repo.appendingPathComponent(path),
                                    atomically: true, encoding: .utf8)
        }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(
            to: repo.appendingPathComponent("docs/reference/target.png"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: repo)
        super.tearDown()
    }

    func testCompleteContractCanStartProduction() {
        let report = ProjectDoctor.inspect(contract: validContract(), repo: repo.path)

        XCTAssertTrue(report.canStartProduction, report.issues.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testLegacyProjectDoesNotSilentlyPassWithoutManifest() throws {
        try "# 产品\n".write(to: repo.appendingPathComponent("AGENTS.md"),
                             atomically: true, encoding: .utf8)

        let report = ProjectDoctor.inspect(repo: repo.path)

        XCTAssertFalse(report.canStartProduction)
        XCTAssertTrue(report.issues.contains { $0.code == "contract.manifest.missing" })
    }

    func testGenericBootstrapCreatesOnceAndNeverOverwrites() throws {
        let first = try ProjectContractBootstrap.apply(repo: repo.path, profile: "app")
        guard case .created(let path) = first else {
            return XCTFail("首次应创建契约")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let contract = try JSONDecoder().decode(ProjectContract.self, from: data)
        XCTAssertEqual(contract.profile, "app")
        XCTAssertTrue(contract.referenceRequired)
        XCTAssertTrue(contract.goldenSampleRequired)

        try Data("human".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        let second = try ProjectContractBootstrap.apply(repo: repo.path, profile: "service")
        guard case .preserved = second else { return XCTFail("已有契约不得覆盖") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "human")
    }

    func testJSONReportIncludesProductionDecision() throws {
        let report = ProjectDoctor.inspect(contract: validContract(), repo: repo.path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(report)) as? [String: Any])

        XCTAssertEqual(object["canStartProduction"] as? Bool, true)
    }

    /// Flint 的失败形状：唯一能达到目标的三条成熟路线，分别被账号、外部服务和
    /// 付费硬约束封死；程序化人体路线只能提供 graybox。系统必须在生产八款之前
    /// 报冲突。加入一条真实可行且不触碰硬约束的路线后，同一检查必须转绿。
    func testFlintShapedRouteConflictRejectsExpansionAndAdmitsCompliantMutation() {
        let target = "commercial-realistic-character"
        var contract = validContract()
        contract.requiredOutcomes = [target]
        contract.hardConstraints = [
            "deny:paid-assets", "deny:external-api", "deny:account-required"
        ]
        contract.routes = [
            route("procedural-human", provides: ["rigged-graybox"]),
            route("image-to-3d", requires: ["external-api"], provides: [target]),
            route("mixamo", requires: ["account-required"], provides: [target]),
            route("commercial-pack", requires: ["paid-assets"], provides: [target])
        ]

        let rejected = ProjectDoctor.inspect(contract: contract, repo: repo.path)
        XCTAssertFalse(rejected.canStartProduction)
        XCTAssertTrue(rejected.issues.contains { $0.code == "route.constraint.conflict" })

        contract.routes.append(route("cc0-manual-production", provides: [target]))
        let admitted = ProjectDoctor.inspect(contract: contract, repo: repo.path)
        XCTAssertTrue(admitted.canStartProduction,
                      admitted.issues.map(\.message).joined(separator: "\n"))
        XCTAssertFalse(admitted.issues.contains { $0.code == "route.constraint.conflict" })
    }

    func testExperienceCriterionMustBindReference() {
        var contract = validContract()
        contract.criteria[1].referenceFiles = []

        let report = ProjectDoctor.inspect(contract: contract, repo: repo.path)

        XCTAssertFalse(report.canStartProduction)
        XCTAssertTrue(report.issues.contains { $0.code == "criterion.reference.missing" })
    }

    func testExperienceCriterionMustDeclareRejectConditions() {
        var contract = validContract()
        contract.criteria[1].rejectConditions = []

        let report = ProjectDoctor.inspect(contract: contract, repo: repo.path)

        XCTAssertTrue(report.issues.contains {
            $0.code == "criterion.reject-conditions.missing"
        })
    }

    func testGoldenSampleCannotReferenceUnknownCriterion() {
        var contract = validContract()
        contract.goldenSamples[0].criterionIDs.append("missing-rule")

        let report = ProjectDoctor.inspect(contract: contract, repo: repo.path)

        XCTAssertTrue(report.issues.contains { $0.code == "golden-sample.criteria.unknown" })
    }

    private func validContract() -> ProjectContract {
        ProjectContract(
            profile: "game",
            outcomeSummary: "一个可在手机上反复游玩的写实战术垂直切片",
            requiredOutcomes: ["playable-realistic-vertical-slice"],
            referenceRequired: true,
            experienceRequired: true,
            goldenSampleRequired: true,
            referenceFile: "BENCHMARK.md",
            productionFile: "PRODUCTION.md",
            referenceFiles: ["docs/reference/target.png"],
            referenceDimensions: ["silhouette", "material", "motion"],
            routes: [route("licensed-production",
                           provides: ["playable-realistic-vertical-slice"])],
            criteria: [
                .init(id: "integrity-build", layer: "integrity",
                      evidenceTypes: ["test-log"]),
                .init(id: "experience-reference", layer: "experience",
                      evidenceTypes: ["comparison-video"],
                      referenceFiles: ["docs/reference/target.png"],
                      rejectConditions: ["placeholder", "identity-mismatch"])
            ],
            goldenSamples: [
                .init(id: "first-vertical-slice", deliverableKind: "vertical-slice",
                      criterionIDs: ["integrity-build", "experience-reference"])
            ])
    }

    private func route(_ id: String, requires: [String] = [],
                       provides: [String]) -> ProjectContract.Route {
        .init(id: id, requires: requires, provides: provides,
              sourceAssets: ["licensed-or-cc0-source"],
              requiredCapabilities: ["domain-production", "device-playtest"],
              validationStages: ["golden-sample", "runtime-review"])
    }
}
