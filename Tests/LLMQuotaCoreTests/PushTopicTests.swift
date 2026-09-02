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
}
