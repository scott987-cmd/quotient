import XCTest
@testable import LLMQuotaCore

/// **同一台机器永远是同一个身份。**
///
/// 老板 2026-08-23 早:「手机展示了好几个 mac mini」。共享目录里躺着
/// 同一台机器的 **9 个 ID**,每份快照的桶数完全相同(187)——
/// 同一份数据被反复写入,每次带一个新身份。
///
/// 根子是老实现:「读文件,没有就随机生成」—— **文件一丢就换个身份**,
/// 而快照按机器 ID 存,于是一台机器在看板上裂成好几台。
final class MachineIdentityTests: XCTestCase {
    /// 反复取要一致 —— 这是最基本的,却正是原来会漂的地方。
    func testStableAcrossCalls() {
        XCTAssertEqual(Paths.machineID(), Paths.machineID())
    }

    /// **缓存文件被删掉之后,身份不能变。** 这一条直接对应那次事故:
    /// 老实现在这里会生成一个新 UUID,于是多一台"新机器"。
    func testSurvivesCacheLoss() throws {
        let before = Paths.machineID()
        try? FileManager.default.removeItem(at: Paths.machineIDFile)
        let after = Paths.machineID()
        XCTAssertEqual(before, after, "缓存丢了也得是同一台机器")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.machineIDFile.path),
                      "顺手把缓存写回去")
    }

    /// macOS 上必须拿得到硬件 UUID —— 拿不到就会退回随机那条老路。
    func testHardwareUUIDAvailableOnMac() {
        XCTAssertNotNil(Paths.hardwareUUID(), "ioreg 取不到 IOPlatformUUID 的话,身份又要靠文件了")
    }
}
