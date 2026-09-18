import Foundation
import XCTest
@testable import AndroidMoverCore

extension EngineTests {

    // MARK: - v0.11.0: протоколи надійності (P1 md5, P3 безпечне видалення тек, P7 самолікування)

    func testChecksumMismatchTriggersRepullAndMoveSucceeds() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_CORRUPT_CHECKSUM_COUNT": "1",   // перший pull: той самий розмір, інший вміст
            "MOCK_LOG_FILE": logFile.path,
        ])
        let lone = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
            .first { $0.name == "самотній.bin" }!

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })   // політика: beforeDelete
        let results = try await engine.transfer(
            entries: [lone], to: destination, serial: serial, move: true, onProgress: { _ in }
        )
        XCTAssertEqual(results[0].status, .moved, "\(results[0].status)")
        let copy = destination.appendingPathComponent("самотній.bin")
        XCTAssertEqual(try Data(contentsOf: copy), Data("12345".utf8), "після перепулу вміст справжній")
        let gone = try await remoteFileExists("Download/самотній.bin")
        XCTAssertFalse(gone, "видалено лише після md5-збігу")
        let calls = try batchMockCalls(logFile: logFile)
        XCTAssertGreaterThanOrEqual(calls.filter { $0.joined(separator: " ").contains("md5sum") }.count, 2, "md5 до і після перепулу")
        XCTAssertGreaterThanOrEqual(calls.filter { $0.contains("pull") }.count, 2, "перепул битого файла")
    }

    func testChecksumPolicyBeforeDeleteSkipsMD5ForCopy() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: ["MOCK_LOG_FILE": logFile.path])
        let lone = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
            .first { $0.name == "самотній.bin" }!
        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(entries: [lone], to: destination, serial: serial, move: false, onProgress: { _ in })
        XCTAssertEqual(results[0].status, .copied)
        let md5Calls = try batchMockCalls(logFile: logFile).filter { $0.joined(separator: " ").contains("md5sum") }
        XCTAssertEqual(md5Calls.count, 0, "копіювання без видалення — md5 не потрібен за політикою beforeDelete")
    }

    func testChecksumPolicyAlwaysVerifiesCopyToo() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: ["MOCK_LOG_FILE": logFile.path])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let engine = TransferEngine(client: client, checksumPolicy: .always)
        let results = try await engine.transfer(entries: entries, to: destination, serial: serial, move: false, onProgress: { _ in })
        XCTAssertTrue(results.allSatisfy { $0.status == .copied })
        let md5Calls = try batchMockCalls(logFile: logFile).filter { $0.joined(separator: " ").contains("md5sum") }
        XCTAssertGreaterThanOrEqual(md5Calls.count, 1)
    }

    func testMoveDirectoryDeletesVerifiedFilesAndKeepsForeignFile() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient(extraEnv: ["MOCK_ADD_FILE_ON_PULL": "нове фото.jpg"])
        let vacation = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial).first { $0.isDirectory }!

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(entries: [vacation], to: destination, serial: serial, move: true, onProgress: { _ in })
        XCTAssertEqual(results[0].status, .moved, "\(results[0].status)")
        XCTAssertNotNil(results[0].warning, "має попередити, що тека лишилась через новий файл")
        // Верифіковані файли видалені, чужий — цілий, тека лишилась.
        let stillDir = try await remoteFileExists("DCIM/Фото відпустки")
        XCTAssertTrue(stillDir)
        let foreign = try await remoteFileExists("DCIM/Фото відпустки/нове фото.jpg")
        XCTAssertTrue(foreign)
        let original = try await remoteFileExists("DCIM/Фото відпустки/IMG_0001.jpg")
        XCTAssertFalse(original)
        // Копія на Mac повна.
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("Фото відпустки/IMG_0001.jpg").path))
    }

    func testMoveDirectoryRemovesEmptiedFolderWhenClean() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient()
        let vacation = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial).first { $0.isDirectory }!
        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(entries: [vacation], to: destination, serial: serial, move: true, onProgress: { _ in })
        XCTAssertEqual(results[0].status, .moved)
        XCTAssertNil(results[0].warning)
        let stillDir = try await remoteFileExists("DCIM/Фото відпустки")
        XCTAssertFalse(stillDir, "порожня після пофайлового видалення тека прибрана")
    }

    func testStaleListingSizeSelfHealsViaRefresh() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_GROW_ON_PULL_COUNT": "1",   // джерело дописується після лістингу
        ])
        let lone = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
            .first { $0.name == "самотній.bin" }!
        XCTAssertEqual(lone.size, 5)
        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.transfer(entries: [lone], to: destination, serial: serial, move: false, onProgress: { _ in })
        XCTAssertEqual(results[0].status, .copied, "\(results[0].status)")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("самотній.bin")), Data("12345+++".utf8))
    }

    func testVerificationFailuresCapAtThreeAttempts() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: ["MOCK_CORRUPT_PULL": "1", "MOCK_LOG_FILE": logFile.path])  // безлімітно бите
        let lone = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
            .first { $0.name == "самотній.bin" }!
        let engine = TransferEngine(client: client, maxAttempts: 15, retryDelay: { _ in 0 })
        let results = try await engine.transfer(entries: [lone], to: destination, serial: serial, move: false, onProgress: { _ in })
        guard case .failed = results[0].status else { return XCTFail("очікувався провал") }
        let pulls = try batchMockCalls(logFile: logFile).filter { $0.contains("pull") }.count
        XCTAssertLessThanOrEqual(pulls, 1 + TransferEngine.verificationAttemptCap, "верифікаційні провали не крутять 15 спроб")
    }

    // MARK: - v0.12.2 (M1): маніфест, за яким видаляють, = маніфест, який верифікували (H4); повний телефон (M3)

    /// H4: після двох верифікаційних провалів список файлів перечитується (P7); файл, що з'явився
    /// у теці ПІД ЧАС переносу, потрапляє в оновлений список, докачується, верифікується — і тоді
    /// видаляється разом з рештою, бо видалення йде за `VerifiedManifest`, а не за початковим
    /// `expected`. Старий код лишав його на телефоні з попередженням (розбіжність двох списків).
    func testMoveDirectoryDeletesExactlyTheVerifiedSetAfterRefresh() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_CORRUPT_PULL_COUNT": "2",          // два верифікаційні провали → P7-оновлення
            "MOCK_ADD_FILE_ON_PULL": "нове фото.jpg", // з'являється на телефоні під час першого pull
        ])
        let vacation = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial).first { $0.isDirectory }!
        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.transfer(entries: [vacation], to: destination, serial: serial, move: true, onProgress: { _ in })
        XCTAssertEqual(results[0].status, .moved, "\(results[0].status)")
        XCTAssertNil(results[0].warning, "новий файл верифіковано й видалено разом з рештою — попередження немає")
        let copied = destination.appendingPathComponent("Фото відпустки")
        XCTAssertTrue(fm.fileExists(atPath: copied.appendingPathComponent("нове фото.jpg").path), "новий файл є в копії")
        XCTAssertTrue(fm.fileExists(atPath: copied.appendingPathComponent("IMG_0001.jpg").path))
        let stillDir = try await remoteFileExists("DCIM/Фото відпустки")
        XCTAssertFalse(stillDir, "усі файли верифіковані й видалені — тека прибрана")
    }

    func testVerifyReturnsManifestOfExpectedFiles() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("am-verify-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
        defer { try? fm.removeItem(at: root) }
        let expected = [RemoteFileRecord(path: "/sdcard/x/a.txt", size: 3), RemoteFileRecord(path: "/sdcard/x/sub/b.txt", size: 5)]
        let manifest = try TransferEngine.verify(expected: expected, remoteRoot: "/sdcard/x", localRoot: root, fileManager: fm)
        XCTAssertEqual(manifest.files, expected)
        XCTAssertFalse(manifest.checksumVerified)
        let wrong = [RemoteFileRecord(path: "/sdcard/x/a.txt", size: 4)]
        XCTAssertThrowsError(try TransferEngine.verify(expected: wrong, remoteRoot: "/sdcard/x", localRoot: root, fileManager: fm))
    }

    func testPushRefusesWhenPhoneIsFull() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient(extraEnv: ["MOCK_FREE_BYTES": "1000"])
        let file = pushSource.appendingPathComponent("великий.bin")
        try makeFile(file, data: Data(repeating: 0x55, count: 500), date: loneDate)
        let engine = PushEngine(client: client, retryDelay: { _ in 0 })
        do {
            _ = try await engine.push(urls: [file], to: "\(remoteRoot!)/DCIM", serial: serial, onProgress: { _ in })
            XCTFail("push у повний телефон мав відмовити до старту")
        } catch ADBError.notEnoughSpaceOnDevice(let needed, let available) {
            XCTAssertEqual(needed, 500)
            XCTAssertLessThan(available, needed + PushEngine.pushHeadroomBytes)
        }
        let appeared = try await remoteFileExists("DCIM/великий.bin")
        XCTAssertFalse(appeared, "жодного байта не пушилось")
        let leftovers = try await remoteTmpLeftovers("DCIM")
        XCTAssertTrue(leftovers.isEmpty, "tmp не створювалась")
    }

    func testNoSpaceLeftIsNotResumable() {
        let enospc = ADBError.commandFailed(command: "adb push", code: 1,
            stderr: "adb: error: failed to copy 'a' to 'b': remote write failed: No space left on device")
        XCTAssertFalse(TransferEngine.isResumable(enospc))
        XCTAssertFalse(TransferEngine.isResumable(ADBError.notEnoughSpaceOnDevice(needed: 1, available: 0)))
        let ordinary = ADBError.commandFailed(command: "adb push", code: 1, stderr: "error: device not found")
        XCTAssertTrue(TransferEngine.isResumable(ordinary))
    }

    // MARK: - v0.11.0 (P2): докачка push після обриву

    func testPushResumesAfterFailureWithoutLoss() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PUSH_FAIL_COUNT": "1",
            "MOCK_LOG_FILE": logFile.path,
        ])
        let localDir = pushSource.appendingPathComponent("Альбом")
        try fm.createDirectory(at: localDir.appendingPathComponent("вкладена"), withIntermediateDirectories: true)
        try makeFile(localDir.appendingPathComponent("a.jpg"), data: Data(repeating: 0x11, count: 500), date: loneDate)
        try makeFile(localDir.appendingPathComponent("b.jpg"), data: Data(repeating: 0x22, count: 700), date: loneDate)
        try makeFile(localDir.appendingPathComponent("вкладена/c.jpg"), data: Data(repeating: 0x33, count: 900), date: loneDate)

        let engine = PushEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.push(urls: [localDir], to: "\(remoteRoot!)/DCIM", serial: serial, onProgress: { _ in })
        XCTAssertEqual(results[0].status, .pushed, "\(results[0].status)")
        for rel in ["a.jpg", "b.jpg", "вкладена/c.jpg"] {
            let exists = try await remoteFileExists("DCIM/Альбом/\(rel)")
            XCTAssertTrue(exists, rel)
        }
        let data = try await remoteData("DCIM/Альбом/вкладена/c.jpg")
        XCTAssertEqual(data.count, 900)
        let leftovers = try await remoteTmpLeftovers("DCIM")
        XCTAssertEqual(leftovers, [])
        let pushes = try batchMockCalls(logFile: logFile).filter { $0.contains("push") }
        XCTAssertGreaterThan(pushes.count, 1, "після обриву — поштучні допуші")
    }

    func testPushFailsHonestlyAfterExhaustingAttemptsAndLeavesNothingVisible() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient(extraEnv: ["MOCK_FAIL_PUSH": "1"])
        let localFile = pushSource.appendingPathComponent("будь-що.bin")
        try makeFile(localFile, data: Data("x".utf8), date: loneDate)
        let engine = PushEngine(client: client, maxAttempts: 2, retryDelay: { _ in 0 })
        let results = try await engine.push(urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in })
        guard case .failed = results[0].status else { return XCTFail("очікувався провал, отримано \(results[0].status)") }
        let visible = try await remoteFileExists("Download/будь-що.bin")
        XCTAssertFalse(visible)
        let leftovers = try await remoteTmpLeftovers("Download")
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - v0.11.0 (P4): onItemFinished — по одному, в порядку entries, для всіх шляхів

    func testOnItemFinishedReportsEveryEntryInOrder() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient()
        _ = try makeBatchFixture(count: 3)
        let batchEntries = try await client.listDirectory("\(remoteRoot!)/Batch", on: serial)
        let dcim = try await client.listDirectory("\(remoteRoot!)", on: serial).first { $0.name == "DCIM" }!
        let ghost = RemoteEntry(path: "\(remoteRoot!)/немає.bin", name: "немає.bin", isDirectory: false, isSymlink: false, size: 3, modified: loneDate)
        let selection = [batchEntries[0], batchEntries[1], dcim, ghost, batchEntries[2]]

        final class Collector: @unchecked Sendable { let lock = NSLock(); var paths: [String] = [] }
        let collector = Collector()
        let engine = TransferEngine(client: client, retryDelay: { _ in 0 }, checksumPolicy: .never)
        let results = try await engine.transfer(
            entries: selection, to: destination, serial: serial, move: false,
            onProgress: { _ in },
            onItemFinished: { result in collector.lock.lock(); collector.paths.append(result.entry.path); collector.lock.unlock() }
        )
        XCTAssertEqual(results.map(\.entry.path), selection.map(\.path))
        XCTAssertEqual(collector.paths, selection.map(\.path), "кожен елемент (батч, тека, провал) звітується рівно раз і в порядку")
    }

}
