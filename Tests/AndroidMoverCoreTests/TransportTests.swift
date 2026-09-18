import Foundation
import XCTest
@testable import AndroidMoverCore

/// v0.13.0 (M2): транспортний шов. Заглушка доводить, що `ADBClient` розбирає вивід без жодного
/// підпроцесу; запис → відтворення доводить, що транскрипт mock-а відтворюється байт-у-байт і
/// що на незаписаний виклик відтворення кидає, а не мовчить.
final class TransportTests: XCTestCase {
    private let fm = FileManager.default

    static var mockADBPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/mock_adb.py").path
    }

    struct StubTransport: ADBTransport {
        let stdout: String
        let exitCode: Int32
        func run(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) async throws -> ProcessResult {
            ProcessResult(stdout: Data(stdout.utf8), stderr: Data(), exitCode: exitCode)
        }
        func stream(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) -> AsyncThrowingStream<Data, Error> {
            let bytes = Data(stdout.utf8)
            return AsyncThrowingStream { continuation in
                continuation.yield(bytes)
                continuation.finish()
            }
        }
    }

    func testStubTransportFeedsClientWithoutSubprocess() async throws {
        let client = ADBClient(transport: StubTransport(stdout: "List of devices attached\nSER1\tdevice usb:1 model:Pixel_9\n", exitCode: 0))
        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "SER1")
        XCTAssertEqual(devices[0].model, "Pixel_9")
        XCTAssertEqual(devices[0].state, .ready)

        let exists = ADBClient(transport: StubTransport(stdout: "__AM_EXISTS__\n", exitCode: 0))
        let yes = try await exists.remoteExists("/sdcard/Фото/й.jpg", on: "SER1")
        XCTAssertTrue(yes)
        let absent = ADBClient(transport: StubTransport(stdout: "__AM_ABSENT__\n", exitCode: 0))
        let no = try await absent.remoteExists("/sdcard/Фото/й.jpg", on: "SER1")
        XCTAssertFalse(no)
    }

    func testDefaultInitUsesSpawnTransportWithSameExecutable() {
        let client = ADBClient(adbPath: "/tmp/adb-here")
        XCTAssertEqual(client.adbPath, "/tmp/adb-here")
        XCTAssertEqual((client.transport as? SpawnTransport)?.executable, "/tmp/adb-here")
    }

    func testRecordingThenReplayRoundTrip() async throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.mockADBPath)
        let base = fm.temporaryDirectory.appendingPathComponent("am-transport-\(UUID().uuidString)")
        let phoneRoot = base.appendingPathComponent("phone")
        try fm.createDirectory(at: phoneRoot.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: phoneRoot.appendingPathComponent("DCIM/o'clock й.txt"))
        defer { try? fm.removeItem(at: base) }
        let transcript = base.appendingPathComponent("transcript.jsonl")
        let env = ["MOCK_PHONE_ROOT": phoneRoot.path]

        // 1. Запис: справжній mock через SpawnTransport, кожен виклик лягає у транскрипт.
        let recording = RecordingTransport(base: SpawnTransport(executable: Self.mockADBPath), fileURL: transcript)
        let live = ADBClient(transport: recording, adbPath: Self.mockADBPath, extraEnvironment: env)
        let liveDevices = try await live.devices()
        let liveListing = try await live.listDirectory("/sdcard/DCIM", on: "MOCK001")
        let liveExists = try await live.remoteExists("/sdcard/DCIM/o'clock й.txt", on: "MOCK001")
        XCTAssertEqual(liveListing.map(\.name), ["o'clock й.txt"])
        XCTAssertTrue(liveExists)

        // 2. Відтворення: жодного підпроцесу, ті самі argv → ті самі байти → ті самі результати.
        let replay = try TranscriptTransport(fileURL: transcript)
        XCTAssertEqual(replay.remaining.count, 3)
        let offline = ADBClient(transport: replay, extraEnvironment: env)
        let replayDevices = try await offline.devices()
        let replayListing = try await offline.listDirectory("/sdcard/DCIM", on: "MOCK001")
        let replayExists = try await offline.remoteExists("/sdcard/DCIM/o'clock й.txt", on: "MOCK001")
        XCTAssertEqual(replayDevices, liveDevices)
        XCTAssertEqual(replayListing, liveListing)
        XCTAssertEqual(replayExists, liveExists)
        XCTAssertTrue(replay.remaining.isEmpty, "усі три записи спожито по одному разу")

        // 3. Незаписаний виклик — чесний промах, не порожній вивід.
        do {
            _ = try await offline.remoteExists("/sdcard/іншого/нема", on: "MOCK001")
            XCTFail("очікувався Miss")
        } catch is TranscriptTransport.Miss {
            // ok
        }
    }

    func testRecordingCapturesStream() async throws {
        let base = fm.temporaryDirectory.appendingPathComponent("am-transport-stream-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let transcript = base.appendingPathComponent("t.jsonl")
        // Кадр track-devices: 4 hex-символи довжини + payload; "SER1\tdevice\n" = 12 байтів = 000c.
        let recording = RecordingTransport(base: StubTransport(stdout: "000cSER1\tdevice\n", exitCode: 0), fileURL: transcript)
        let client = ADBClient(transport: recording)
        var frames: [[ADBDevice]] = []
        for try await frame in client.trackDevices() { frames.append(frame) }
        guard frames.count == 1 else { return XCTFail("очікувався рівно один кадр, є \(frames.count)") }
        XCTAssertEqual(frames[0].first?.serial, "SER1")
        let replay = try TranscriptTransport(fileURL: transcript)
        XCTAssertEqual(replay.remaining.first?.kind, .stream)
        var replayed: [[ADBDevice]] = []
        for try await frame in ADBClient(transport: replay).trackDevices() { replayed.append(frame) }
        XCTAssertEqual(replayed, frames)
    }
}
