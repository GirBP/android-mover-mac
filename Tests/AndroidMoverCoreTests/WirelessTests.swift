import Foundation
import XCTest
@testable import AndroidMoverCore

/// Ідентичність окремо від адреси, толерантні парсери підкоманд adb, потоки
/// pair/connect/mdns через mock.
final class WirelessTests: XCTestCase {
    private let fm = FileManager.default

    static var mockADBPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/mock_adb.py").path
    }

    private func client(_ env: [String: String] = [:]) -> ADBClient {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.mockADBPath)
        var merged = ["MOCK_PHONE_ROOT": fm.temporaryDirectory.path]
        merged.merge(env) { _, new in new }
        return ADBClient(adbPath: Self.mockADBPath, extraEnvironment: merged)
    }

    // MARK: - Чисті парсери

    func testHostPortDetection() {
        XCTAssertEqual(ADBDevice.parseHostPort("192.168.1.23:41567")?.port, 41567)
        XCTAssertEqual(ADBDevice.parseHostPort("192.168.1.23:41567")?.host, "192.168.1.23")
        XCTAssertEqual(ADBDevice.parseHostPort("[fe80::1]:5555")?.host, "[fe80::1]")
        XCTAssertNil(ADBDevice.parseHostPort("R58M12345"))
        XCTAssertNil(ADBDevice.parseHostPort("emulator-5554"))
        XCTAssertNil(ADBDevice.parseHostPort("host:99999"))
        XCTAssertTrue(ADBDevice(serial: "10.0.0.7:5555", state: .ready, model: nil).isWireless)
        XCTAssertFalse(ADBDevice(serial: "0a388e93", state: .ready, model: nil).isWireless)
    }

    func testIdentityLadder() {
        let full = DeviceIdentity.resolve(androidID: "a1b2c3d4e5f60718", hardwareSerial: "SN123456", model: "Pixel 9", transportSerial: "1.2.3.4:5")
        XCTAssertEqual(full.stableID, "a1b2c3d4e5f60718|SN123456")
        XCTAssertEqual(full.source, .androidID)
        XCTAssertFalse(full.isWeak)
        let idOnly = DeviceIdentity.resolve(androidID: "a1b2c3d4e5f60718", hardwareSerial: "unknown", model: nil, transportSerial: "x")
        XCTAssertEqual(idOnly.stableID, "a1b2c3d4e5f60718")
        let snOnly = DeviceIdentity.resolve(androidID: "null", hardwareSerial: "SN123456", model: nil, transportSerial: "x")
        XCTAssertEqual(snOnly.stableID, "sn:SN123456")
        XCTAssertEqual(snOnly.source, .hardwareSerial)
        let weak = DeviceIdentity.resolve(androidID: "", hardwareSerial: "0000", model: nil, transportSerial: "10.0.0.7:5555")
        XCTAssertEqual(weak.stableID, "transport:10.0.0.7:5555")
        XCTAssertTrue(weak.isWeak)
        // Та сама ідентичність по USB і по Wi-Fi — різний транспорт, той самий stableID.
        let usb = DeviceIdentity.resolve(androidID: "a1b2c3d4e5f60718", hardwareSerial: "SN123456", model: nil, transportSerial: "SN123456")
        XCTAssertEqual(usb.stableID, full.stableID)
    }

    func testParseDeviceIdentityOutput() {
        let out = "__AM_ID__|a1b2c3d4e5f60718\n__AM_SN__|SN123456\n__AM_MODEL__|Nothing Phone (2a)\n"
        let identity = ADBClient.parseDeviceIdentity(out, transportSerial: "x")
        XCTAssertEqual(identity.stableID, "a1b2c3d4e5f60718|SN123456")
        XCTAssertEqual(identity.model, "Nothing Phone (2a)")
    }

    func testParseMDNSServices() {
        let out = """
        List of discovered mdns services
        adb-1A2B3C4D-XyZ123\t_adb-tls-connect._tcp\t192.168.1.5:41567
        adb-1A2B3C4D-XyZ123\t_adb-tls-pairing._tcp\t192.168.1.5:37123
        weird-line-without-address
        """
        let services = ADBClient.parseMDNSServices(out)
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].kind, .connect)
        XCTAssertEqual(services[0].hostPort, "192.168.1.5:41567")
        XCTAssertEqual(services[1].kind, .pairing)
        XCTAssertEqual(services[1].port, 37123)
    }

    // MARK: - Через mock

    func testDeviceIdentityThroughMock() async throws {
        let full = try await client().deviceIdentity(on: "MOCK001")
        XCTAssertEqual(full.stableID, "a1b2c3d4e5f60718|MOCKSN001")
        XCTAssertEqual(full.model, "Mock Phone 9")
        let weak = try await client(["MOCK_ANDROID_ID": "", "MOCK_SERIALNO": ""]).deviceIdentity(on: "10.0.0.7:5555")
        XCTAssertTrue(weak.isWeak)
        XCTAssertEqual(weak.stableID, "transport:10.0.0.7:5555")
    }

    func testMDNSThroughMock() async throws {
        let unavailable = await client().mdnsCheck()
        XCTAssertFalse(unavailable)
        let c = client(["MOCK_MDNS": "1", "MOCK_MDNS_SERVICES": "adb-1,_adb-tls-connect._tcp,10.0.0.7:41567;adb-1,_adb-tls-pairing._tcp,10.0.0.7:37123"])
        let available = await c.mdnsCheck()
        XCTAssertTrue(available)
        let services = try await c.mdnsServices()
        XCTAssertEqual(services.map(\.kind), [.connect, .pairing])
    }

    func testPairAndConnectThroughMock() async throws {
        let c = client()
        try await c.pair(host: "10.0.0.7", port: 37123, code: "123456")
        do {
            try await c.pair(host: "10.0.0.7", port: 37123, code: "000000")
            XCTFail("неправильний код мав провалити спарювання")
        } catch ADBError.wirelessFailed(let details) {
            XCTAssertTrue(details.lowercased().contains("wrong password"), details)
        }
        let serial = try await c.connect(host: "10.0.0.7", port: 41567)
        XCTAssertEqual(serial, "10.0.0.7:41567")
        try await c.disconnect(host: "10.0.0.7", port: 41567)
        do {
            _ = try await client(["MOCK_CONNECT_FAIL": "1"]).connect(host: "10.0.0.7", port: 41567)
            XCTFail("очікувався провал connect")
        } catch ADBError.wirelessFailed(let details) {
            XCTAssertTrue(details.contains("failed to connect"), details)
        }
    }
}
