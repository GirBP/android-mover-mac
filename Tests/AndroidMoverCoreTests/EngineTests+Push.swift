import Foundation
import XCTest
@testable import AndroidMoverCore

extension EngineTests {

    // MARK: - push Mac → Android

    func testRemoteExists() async throws {
        let client = makeClient()
        let existsFile = try await client.remoteExists("\(remoteRoot!)/Download/самотній.bin", on: serial)
        XCTAssertTrue(existsFile)
        let existsDir = try await client.remoteExists("\(remoteRoot!)/DCIM", on: serial)
        XCTAssertTrue(existsDir)
        let absent = try await client.remoteExists("\(remoteRoot!)/Download/немає-такого.bin", on: serial)
        XCTAssertFalse(absent)
    }

    func testPushFileVerifiesAndAppearsOnDevice() async throws {
        let client = makeClient()
        let pushDate = Date(timeIntervalSince1970: 1_600_000_000)
        let localFile = pushSource.appendingPathComponent("файл з пробілом.txt")
        try makeFile(localFile, data: Data("push me".utf8), date: pushDate)

        let engine = PushEngine(client: client)
        let results = try await engine.push(
            urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in }
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .pushed)
        XCTAssertEqual(results[0].remotePath, "\(remoteRoot!)/Download/файл з пробілом.txt")
        XCTAssertEqual(results[0].bytes, 7)

        let pushedExists = try await remoteFileExists("Download/файл з пробілом.txt")
        XCTAssertTrue(pushedExists)
        let pushedData = try await remoteData("Download/файл з пробілом.txt")
        XCTAssertEqual(pushedData, Data("push me".utf8))

        // Тимчасових тек не лишилось.
        let leftovers = try await remoteTmpLeftovers("Download")
        XCTAssertEqual(leftovers, [])

        // statMTimes-шлях (той самий, яким best-effort звірка користується всередині push).
        let mtimes = try await client.statMTimes("\(remoteRoot!)/Download/файл з пробілом.txt", on: serial)
        XCTAssertEqual(
            mtimes["\(remoteRoot!)/Download/файл з пробілом.txt"].map { Int($0.timeIntervalSince1970) },
            Int(pushDate.timeIntervalSince1970)
        )
    }

    func testPushDirectoryRecursive() async throws {
        let client = makeClient()
        let fileDate = Date(timeIntervalSince1970: 1_611_000_000)
        let localDir = pushSource.appendingPathComponent("Альбом")
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        try makeFile(localDir.appendingPathComponent("a.jpg"), data: Data(repeating: 0x11, count: 500), date: fileDate)
        try makeFile(localDir.appendingPathComponent("b.jpg"), data: Data(repeating: 0x22, count: 700), date: fileDate)

        let engine = PushEngine(client: client)
        let results = try await engine.push(
            urls: [localDir], to: "\(remoteRoot!)/DCIM", serial: serial, onProgress: { _ in }
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .pushed)
        XCTAssertEqual(results[0].bytes, 1200)
        XCTAssertEqual(results[0].remotePath, "\(remoteRoot!)/DCIM/Альбом")

        let pushedAExists = try await remoteFileExists("DCIM/Альбом/a.jpg")
        XCTAssertTrue(pushedAExists)
        let pushedBExists = try await remoteFileExists("DCIM/Альбом/b.jpg")
        XCTAssertTrue(pushedBExists)
        let pushedAData = try await remoteData("DCIM/Альбом/a.jpg")
        XCTAssertEqual(pushedAData, Data(repeating: 0x11, count: 500))

        let leftovers = try await remoteTmpLeftovers("DCIM")
        XCTAssertEqual(leftovers, [])
    }

    func testPushCollisionAutoRenames() async throws {
        let client = makeClient()
        let localFile = pushSource.appendingPathComponent("нова.bin")
        try makeFile(localFile, data: Data("hello".utf8), date: loneDate)

        let engine1 = PushEngine(client: client)
        let first = try await engine1.push(urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in })
        XCTAssertEqual(first[0].status, .pushed)
        XCTAssertEqual(first[0].remotePath, "\(remoteRoot!)/Download/нова.bin")

        let engine2 = PushEngine(client: client)
        let second = try await engine2.push(urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in })
        XCTAssertEqual(second[0].status, .pushed)
        XCTAssertEqual(second[0].remotePath, "\(remoteRoot!)/Download/нова (1).bin")

        let firstPushedExists = try await remoteFileExists("Download/нова.bin")
        XCTAssertTrue(firstPushedExists)
        let secondPushedExists = try await remoteFileExists("Download/нова (1).bin")
        XCTAssertTrue(secondPushedExists)
    }

    func testCorruptedPushDoesNotLeavePartialInDestination() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient(extraEnv: ["MOCK_CORRUPT_PUSH": "1"])
        let localFile = pushSource.appendingPathComponent("зіпсований.bin")
        try makeFile(localFile, data: Data(repeating: 0x55, count: 4000), date: loneDate)

        let engine = PushEngine(client: client)
        let results = try await engine.push(urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in })

        guard case .failed(let message) = results[0].status else {
            XCTFail("очікувався провал push-верифікації, отримано \(results[0].status)")
            return
        }
        XCTAssertTrue(message.contains("не збігається") || message.contains("Перевірка копії"), "повідомлення: \(message)")

        // У видимій теці елемента нема.
        XCTAssertFalse(fm.fileExists(atPath: phoneRoot.appendingPathComponent("Download/зіпсований.bin").path))
        // tmp прибраний.
        let leftovers = try fm.contentsOfDirectory(atPath: phoneRoot.appendingPathComponent("Download").path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testPushRefusesUnsafeTarget() async throws {
        let client = makeClient()
        let localFile = pushSource.appendingPathComponent("будь-що.bin")
        try makeFile(localFile, data: Data("x".utf8), date: loneDate)

        let engine = PushEngine(client: client)
        do {
            _ = try await engine.push(urls: [localFile], to: "/data/evil", serial: serial, onProgress: { _ in })
            XCTFail("очікувалась відмова писати в /data")
        } catch let error as ADBError {
            XCTAssertEqual(error, .unsafePushTarget("/data/evil"))
        }
        // Guard спрацьовує до будь-якого мережевого виклику — джерело на Mac ціле.
        XCTAssertTrue(fm.fileExists(atPath: localFile.path))
    }

    func testPushCancelledLeavesNoTmp() async throws {
        let client = makeClient()
        let localFile = pushSource.appendingPathComponent("скасовано.bin")
        try makeFile(localFile, data: Data("data".utf8), date: loneDate)

        let engine = PushEngine(client: client)
        engine.cancel() // скасування ДО старту — детерміновано ловить шлях "cancel відразу".
        let results = try await engine.push(urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .cancelled)
        let cancelledExists = try await remoteFileExists("Download/скасовано.bin")
        XCTAssertFalse(cancelledExists)
        let leftovers = try await remoteTmpLeftovers("Download")
        XCTAssertEqual(leftovers, [])
    }


}
