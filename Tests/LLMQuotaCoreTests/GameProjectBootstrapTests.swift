import XCTest
@testable import LLMQuotaCore

final class GameProjectBootstrapTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("game-bootstrap-\(UUID().uuidString)")
        repo = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(Proc.run("/usr/bin/git", ["init", "-q"], cwd: repo.path,
                                env: [:], timeout: 10).exitCode, 0)
        RepoRegistry.fileOverride = root.appendingPathComponent("repos.json")
    }

    override func tearDown() {
        RepoRegistry.fileOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testCreatesReusableGameContractsAndRegistersHardGates() throws {
        let result = try GameProjectBootstrap.apply(
            alias: "next-game", path: repo.path, owner: .kimi)

        for required in ["AGENTS.md", "QUALITY.md", "BENCHMARK.md", "PLAN.md",
                         "STATUS.md", "docs/asset-log.md", "docs/evidence/README.md"] {
            XCTAssertTrue(result.created.contains(required), required)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(required).path), required)
        }
        let quality = try String(contentsOf: repo.appendingPathComponent("QUALITY.md"))
        for rule in ["垂直切片", "构建成功", "30–60 秒录屏", "变异验证"] {
            XCTAssertTrue(quality.contains(rule), "质量模板缺少防复发规则：\(rule)")
        }
        let configured = try XCTUnwrap(RepoRegistry.all().first)
        XCTAssertEqual(configured.implementationOwner, .kimi)
        XCTAssertEqual(configured.qualityContract, "QUALITY.md")
        XCTAssertTrue(configured.manualReview)
        XCTAssertFalse(configured.autoRefill, "垂直切片达标前不能自动扩内容")
    }

    func testSecondRunNeverOverwritesHumanContent() throws {
        _ = try GameProjectBootstrap.apply(alias: "next-game", path: repo.path, owner: .kimi)
        let human = "# 人工产品事实\n这款游戏的核心是潜行。\n"
        try human.write(to: repo.appendingPathComponent("AGENTS.md"),
                        atomically: true, encoding: .utf8)

        let second = try GameProjectBootstrap.apply(
            alias: "next-game", path: repo.path, owner: .claude)

        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("AGENTS.md")), human)
        XCTAssertTrue(second.created.isEmpty)
        XCTAssertEqual(second.preserved.count, 7)
        XCTAssertEqual(second.repo.implementationOwner, .claude,
                       "重复执行可以显式换负责人，但不能改人工文档")
    }
}
