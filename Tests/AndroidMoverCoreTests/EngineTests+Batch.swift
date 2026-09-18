import Foundation
import XCTest
@testable import AndroidMoverCore

extension EngineTests {

    // MARK: - Батчі для плоских файлів

    /// Усі argv-виклики mock (JSON-рядки MOCK_LOG_FILE) — без argv[0].
    func batchMockCalls(logFile: URL) throws -> [[String]] {
        let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode([String].self, from: Data(line.utf8))
        }
    }

    func makeBatchFixture(count: Int) throws -> String {
        let dir = phoneRoot.appendingPathComponent("Batch")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            try makeFile(dir.appendingPathComponent(String(format: "IMG_%03d.jpg", i)),
                         data: Data(repeating: UInt8(i % 250), count: 10 + i), date: loneDate)
        }
        return "\(remoteRoot!)/Batch"
    }

    func testPlainFilesSkipPrecountAndPullInBatches() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: ["MOCK_LOG_FILE": logFile.path])
        let remoteDir = try makeBatchFixture(count: 70)   // 32 + 32 + 6 → 3 батчі
        let entries = try await client.listDirectory(remoteDir, on: serial)
        XCTAssertEqual(entries.count, 70)

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: entries, to: destination, serial: serial, move: true, onProgress: { _ in }
        )
        XCTAssertEqual(results.count, 70)
        XCTAssertEqual(results.map(\.entry.path), entries.map(\.path), "порядок результатів = порядок entries")
        XCTAssertTrue(results.allSatisfy { $0.status == .moved },
                      "\(results.filter { $0.status != .moved }.map { "\($0.entry.name): \($0.status)" })")
        for entry in entries {
            let copy = destination.appendingPathComponent(entry.name)
            XCTAssertEqual(try Data(contentsOf: copy).count, Int(entry.size))
            XCTAssertEqual(try mtimeEpoch(copy), Int(loneDate.timeIntervalSince1970))
            XCTAssertEqual(try creationEpoch(copy), Int(loneDate.timeIntervalSince1970))
        }
        let remaining = try await client.listDirectory(remoteDir, on: serial)
        XCTAssertEqual(remaining.count, 0, "move мусить видалити всі 70 з телефона")

        let calls = try batchMockCalls(logFile: logFile)
        XCTAssertEqual(calls.filter { $0.contains("pull") }.count, 3, "3 батчевих pull, не 70")
        XCTAssertEqual(calls.filter { $0.joined(separator: " ").contains("-type f") }.count, 0,
                       "жодного find для плоских файлів — розмір беремо з лістингу")
        // Батчеві скрипти впізнаються за опкодом, а не за текстом `for AM_P in`.
        let shells = calls.map { $0.joined(separator: " ") }
        XCTAssertEqual(shells.filter { $0.hasPrefix("-s \(serial) shell AM_OP=rmBatch;") }.count, 3, "3 батчевих rm, не 70")
        XCTAssertEqual(shells.filter { $0.hasPrefix("-s \(serial) shell AM_OP=md5Batch;") }.count, 3, "3 батчевих md5 (move → beforeDelete), не 70")
    }

    func testBatchPullFailureFallsBackPerFileWithoutLoss() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "1",      // перший pull (батч) обривається на 2-му файлі
            "MOCK_LOG_FILE": logFile.path,
        ])
        let remoteDir = try makeBatchFixture(count: 5)
        let entries = try await client.listDirectory(remoteDir, on: serial)

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.transfer(
            entries: entries, to: destination, serial: serial, move: false, onProgress: { _ in }
        )
        XCTAssertTrue(results.allSatisfy { $0.status == .copied },
                      "\(results.map { "\($0.entry.name): \($0.status)" })")
        for entry in entries {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(entry.name)).count, Int(entry.size))
        }
        // Джерело не чіпалось (copy), і батч не «здався» — файли добрані поштучно.
        let still = try await client.listDirectory(remoteDir, on: serial)
        XCTAssertEqual(still.count, 5)
        let pulls = try batchMockCalls(logFile: logFile).filter { $0.contains("pull") }
        XCTAssertGreaterThan(pulls.count, 1, "після провалу батчу мають бути поштучні pull-и")
    }

    func testBatchMoveReportsDeleteFailuresPerFile() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient(extraEnv: ["MOCK_FAIL_DELETE": "1"])
        let remoteDir = try makeBatchFixture(count: 4)
        let entries = try await client.listDirectory(remoteDir, on: serial)

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: entries, to: destination, serial: serial, move: true, onProgress: { _ in }
        )
        for result in results {
            guard case .copiedButDeleteFailed = result.status else {
                XCTFail("очікувався copiedButDeleteFailed, отримано \(result.status)")
                continue
            }
            XCTAssertNotNil(result.finalURL)
            XCTAssertTrue(fm.fileExists(atPath: result.finalURL!.path))
        }
        let still = try await client.listDirectory(remoteDir, on: serial)
        XCTAssertEqual(still.count, 4, "провал rm — джерело ціле")
    }

    func testMixedSelectionKeepsOrderAndBatchesOnlyPlainFiles() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: ["MOCK_LOG_FILE": logFile.path])
        _ = try makeBatchFixture(count: 3)
        // Вибір: [файл, файл, тека(DCIM), файл] — теки йдуть поштучно, файли — батчами.
        let batchEntries = try await client.listDirectory("\(remoteRoot!)/Batch", on: serial)
        let dcim = try await client.listDirectory("\(remoteRoot!)", on: serial).first { $0.name == "DCIM" }!
        let selection = [batchEntries[0], batchEntries[1], dcim, batchEntries[2]]

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: selection, to: destination, serial: serial, move: false, onProgress: { _ in }
        )
        XCTAssertEqual(results.map(\.entry.path), selection.map(\.path))
        XCTAssertTrue(results.allSatisfy { $0.status == .copied }, "\(results.map(\.status))")
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("DCIM/Фото відпустки/IMG_0001.jpg").path))
        let calls = try batchMockCalls(logFile: logFile)
        // find лише для теки (recursiveFiles + recursiveDirs), не для 3 файлів.
        XCTAssertEqual(calls.filter { $0.joined(separator: " ").contains("-type f") }.count, 1)
        XCTAssertEqual(calls.filter { $0.joined(separator: " ").contains("-type d") }.count, 1)
    }


}
