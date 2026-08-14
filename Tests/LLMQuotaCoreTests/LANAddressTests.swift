import XCTest
@testable import LLMQuotaCore

/// 挑局域网地址。
///
/// 真实事故：这台 Mac 的网卡是
/// ```
/// en11: 169.254.46.146   ← 链路本地，没拿到 DHCP
/// en1:  192.168.31.85    ← 真地址
/// ```
/// 旧逻辑按名字三级回退（en0 → 任意 en → 第一个），没有 en0，
/// 于是选中了 `en11` 那个假地址并发布出去。对端照着连，
/// 每半分钟失败一次，日志里只有 TLS 握手错误 ——
/// **报错把人引向证书，而问题在网络层**。查了很久。
final class LANAddressTests: XCTestCase {

    func testSkipsLinkLocalEvenWhenItComesFirst() {
        let ip = ClusterNet.pickLAN([
            (name: "en11", ip: "169.254.46.146"),
            (name: "en1", ip: "192.168.31.85"),
        ])
        XCTAssertEqual(ip, "192.168.31.85",
                       "169.254 是自分配地址，对端连不上，绝不能选它")
    }

    /// `en1` 必须排在 `en11` 前面。字符串比较会给出相反的结果。
    func testNumericInterfaceOrdering() {
        let ip = ClusterNet.pickLAN([
            (name: "en11", ip: "192.168.31.200"),
            (name: "en1", ip: "192.168.31.85"),
        ])
        XCTAssertEqual(ip, "192.168.31.85")
        XCTAssertTrue(ClusterNet.ifaceRank("en1") < ClusterNet.ifaceRank("en11"))
    }

    func testPrefersPhysicalOverVirtual() {
        let ip = ClusterNet.pickLAN([
            (name: "utun7", ip: "192.168.31.9"),
            (name: "en0", ip: "192.168.31.85"),
        ])
        XCTAssertEqual(ip, "192.168.31.85", "utun 是 VPN 隧道，局域网对端到不了")
    }

    /// VPN 可能分到一个路由不到局域网的非私有段地址。
    func testPrefersPrivateRange() {
        let ip = ClusterNet.pickLAN([
            (name: "en0", ip: "100.64.3.7"),      // CGNAT，不是 RFC1918
            (name: "en1", ip: "10.0.0.5"),
        ])
        XCTAssertEqual(ip, "10.0.0.5")
    }

    func testAllLinkLocalMeansNoAddress() {
        XCTAssertNil(ClusterNet.pickLAN([
            (name: "en11", ip: "169.254.1.2"),
            (name: "en12", ip: "169.254.3.4"),
        ]), "一个可用地址都没有时要返回 nil —— 报「没有」比报一个假的强")
    }

    func testUsableAndPrivateClassification() {
        XCTAssertFalse(ClusterNet.isUsableLAN("169.254.0.1"))
        XCTAssertFalse(ClusterNet.isUsableLAN("127.0.0.1"))
        XCTAssertFalse(ClusterNet.isUsableLAN("0.0.0.0"))
        XCTAssertTrue(ClusterNet.isUsableLAN("192.168.1.1"))

        XCTAssertTrue(ClusterNet.isPrivate("10.1.2.3"))
        XCTAssertTrue(ClusterNet.isPrivate("192.168.0.1"))
        XCTAssertTrue(ClusterNet.isPrivate("172.16.0.1"))
        XCTAssertTrue(ClusterNet.isPrivate("172.31.255.255"))
        // 边界：172.15 和 172.32 都不在 RFC1918 里。
        XCTAssertFalse(ClusterNet.isPrivate("172.15.0.1"))
        XCTAssertFalse(ClusterNet.isPrivate("172.32.0.1"))
        XCTAssertFalse(ClusterNet.isPrivate("8.8.8.8"))
    }
}
