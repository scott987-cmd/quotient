import XCTest
@testable import LLMQuotaCore

/// **只有风险类和验收类才惊动老板。**
///
/// 他 2026-08-22 的常设指示:「阻塞任务,你来看处理,这种问题都你来处理,
/// 给我应该就是风险类或者验收类」。
///
/// 高危路径闸的判据很粗(任何 .sh / Tools/ / .github/ / .xcodeproj 都算),
/// 拦下的绝大多数是「改了个生成脚本」这种纯技术活。全推给他的后果不是
/// 多几条通知,是**真正要他拍板的那两类被淹掉** —— 他今天已经被
/// 「推了人做不到的事」烦过两次了。
final class BossGateTests: XCTestCase {
    /// 后果是钱 / 账号 / 对外影响 → 他。这些错了不可逆。
    func testSigningAndPublishingAreHisCall() {
        XCTAssertTrue(BossGate.needsBoss(files: ["Tools/AppStoreExportOptions.plist"]))
        XCTAssertTrue(BossGate.needsBoss(files: [".github/workflows/release.yml"]))
        XCTAssertTrue(BossGate.needsBoss(files: ["fastlane/Fastfile"]))
        XCTAssertTrue(BossGate.needsBoss(files: ["Maw/Ads.swift"]) == false,
                      "文件名本身不含广告特征时不误判")
        XCTAssertTrue(BossGate.needsBoss(files: ["config/admob-units.json"]),
                      "广告位配置动的是他的收入和账号")
        XCTAssertTrue(BossGate.needsBoss(files: ["scripts/sign-and-notarize.sh"]))
    }

    /// 纯技术活 → 我。改错了大不了重跑一次。
    func testToolingIsMine() {
        XCTAssertFalse(BossGate.needsBoss(files: ["Tools/gen-skin.py"]))
        XCTAssertFalse(BossGate.needsBoss(files: ["Tools/gen-zombie.py", "build-app.sh"]))
        XCTAssertFalse(BossGate.needsBoss(files: ["Flint.xcodeproj/project.pbxproj"]),
                       "工程文件是 xcodegen 生成的，改错了重新生成即可")
    }

    /// **不能用裸的 "sign" 做判据** —— `DESIGN.md` 里就含它。
    /// 判据太宽的后果和太窄一样坏:设计文档天天惊动老板,
    /// 他很快就不看这类通知了。
    func testDesignDocIsNotMistakenForSigning() {
        XCTAssertFalse(BossGate.needsBoss(files: ["DESIGN.md"]),
                       "design 里含 sign —— 裸子串匹配会把设计文档判成签名配置")
        XCTAssertFalse(BossGate.needsBoss(files: ["Flint/Sim/AssignRoles.swift"]))
        XCTAssertTrue(BossGate.needsBoss(files: ["scripts/sign-and-notarize.sh"]),
                      "真的签名脚本还是要拦住")
    }

    /// 说明文字要讲清归谁、为什么 —— 事后回看能明白当时凭什么这么判。
    func testNoteExplainsWhichWayAndWhy() {
        XCTAssertTrue(BossGate.note(files: ["Tools/gen-skin.py"]).contains("架构师"))
        XCTAssertTrue(BossGate.note(files: ["ios/entitlements.plist"]).contains("老板"))
    }
}
