import XCTest
@testable import LLMQuotaCore

/// **isRiskyPath 必须是 BossGate.needsBoss 的超集。**
///
/// 2026-08-23 复审逮到:钱/账号/签名类文件(admob 配置、entitlements、
/// .p8 密钥、release.yml)BossGate 认定归老板,但 isRiskyPath 一律 false ——
/// 于是它们根本不进拦截闸,agent 改了直接提交,老板永远看不到。
/// 保护看着做了、BossGate 单测还全绿,实际到不了生产。
///
/// 要老板拍板的,必须先被高危闸拦住。这条测试守住这个包含关系。
final class RiskyPathSupersetTests: XCTestCase {
    func testEveryBossPathIsRisky() {
        for f in ["config/admob-units.json", "ios/entitlements.plist",
                  "keys/AuthKey.p8", "certs/dist.p12", "profile.mobileprovision",
                  "release.yml", "app/billing.swift", "iap-products.json"] {
            XCTAssertTrue(GitWorkspace.isRiskyPath(f),
                          "\(f) 要老板拍板,却没被高危闸拦住 —— agent 会直接提交")
        }
    }

    /// 反向:普通代码文件不能因为这条变化被误拦。
    func testOrdinaryFilesStayUnblocked() {
        for f in ["Flint/Sim/Economy.swift", "docs/PLAN.md", "README.md"] {
            XCTAssertFalse(GitWorkspace.isRiskyPath(f), "\(f) 不该被拦")
        }
    }
}
