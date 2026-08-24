import XCTest
@testable import LLMQuotaCore

/// **续活默认关,只对专注的项目开;而且同时只专注一个。**
///
/// 老板 2026-08-23:「现在续的活不是我需要的,不要瞎续活」「我们应该专注于
/// 项目去派活」。原来续活对所有仓库默认开,队列一空就给他不关注的仓库
/// (DragonTales/AssetPacks)乱派活。
final class AutoRefillFocusTests: XCTestCase {
    func testAutoRefillDefaultsOff() {
        let r = RepoAlias(alias: "x", path: "/x")
        XCTAssertFalse(r.autoRefill, "默认必须关 —— 空闲不是问题,乱干才是")
    }

    /// 序列化往返:开关存得住(不然重启就丢)。
    func testFlagSurvivesRoundTrip() throws {
        var r = RepoAlias(alias: "flint", path: "/flint")
        r.autoRefill = true
        let d = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RepoAlias.self, from: d)
        XCTAssertTrue(back.autoRefill)
    }

    /// 老配置没有这个字段 → 解码成 false(不会因为字段缺失崩,也不会误开)。
    func testOldConfigDecodesToOff() throws {
        let json = #"{"alias":"old","path":"/old"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(RepoAlias.self, from: json)
        XCTAssertFalse(r.autoRefill)
    }

    func testOwnerAndQualityContractSurviveRoundTrip() throws {
        var r = RepoAlias(alias: "flint", path: "/flint")
        r.implementationOwner = .kimi
        r.qualityContract = "QUALITY.md"
        let back = try JSONDecoder().decode(RepoAlias.self,
            from: JSONEncoder().encode(r))
        XCTAssertEqual(back.implementationOwner, .kimi)
        XCTAssertEqual(back.qualityContract, "QUALITY.md")
    }

    func testImplementationOwnerOnlyConstrainsCoding() {
        var r = RepoAlias(alias: "flint", path: "/flint")
        r.implementationOwner = .kimi
        XCTAssertEqual(RepoExecutionPolicy.implementationOwner(
            for: "/flint", prompt: "优化持枪动作", repos: [r]), .kimi)
        XCTAssertNil(RepoExecutionPolicy.implementationOwner(
            for: "/flint", prompt: "【审查】检查 diff", repos: [r]))
        XCTAssertNil(RepoExecutionPolicy.implementationOwner(
            for: "/flint", prompt: "【媒体】生成贴图", repos: [r]))
    }
}
