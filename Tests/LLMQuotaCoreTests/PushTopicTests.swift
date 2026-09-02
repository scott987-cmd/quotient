import XCTest
@testable import LLMQuotaCore

final class PushTopicTests: XCTestCase {
    private let config = Push.Config(
        keyID: "key", teamID: "team",
        bundleID: "com.example.legacy", keyFile: "/tmp/key.p8")

    func testRegisteredDeviceUsesItsOwnBundleID() {
        let device = Push.Device(
            token: "token", device: "iPhone", environment: "production",
            updatedAt: nil, bundleID: "com.example.current")

        XCTAssertEqual(Push.topic(for: device, config: config),
                       "com.example.current")
    }

    func testLegacyDeviceFallsBackToConfiguredBundleID() throws {
        let data = Data(#"{"token":"token","device":"iPad","environment":"production"}"#.utf8)
        let device = try JSONDecoder().decode(Push.Device.self, from: data)

        XCTAssertNil(device.bundleID)
        XCTAssertEqual(Push.topic(for: device, config: config),
                       "com.example.legacy")
    }

    func testNotificationPayloadCarriesDestinationPage() throws {
        let data = try XCTUnwrap(Push.notificationPayload(
            .needsYou, body: "阶段成果等你确认", badge: 1, page: "review"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["page"] as? String, "review")
        XCTAssertEqual(json["kind"] as? String, Push.Kind.needsYou.rawValue)
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(aps["badge"] as? Int, 1)
    }
}
