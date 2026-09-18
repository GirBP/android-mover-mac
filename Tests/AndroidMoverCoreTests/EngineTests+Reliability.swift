import Foundation
import XCTest
@testable import AndroidMoverCore

extension EngineTests {

    // MARK: - Ідле-таймаут ProcessRunner

    func testIdleTimeoutResetsWhileOutputFlows() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: MOCK_SLOW_STREAM") }
        let folder = phoneRoot.appendingPathComponent("Idle/Слайдшоу")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<6 {
            try makeFile(folder.appendingPathComponent("f\(i).bin"), data: Data([0x1]), date: loneDate)
        }
        // 6 рядків по 0.4 с паузи = 2.4 с загалом (> 1 с ідле-таймауту), але кожна окрема
        // пауза між рядками (0.4 с) коротша за таймаут — потік не мусить перерватись.
        let client = ADBClient(
            adbPath: Self.mockADBPath,
            extraEnvironment: ["MOCK_PHONE_ROOT": phoneRoot.path, "MOCK_SLOW_STREAM": "400"],
            findTimeoutOverride: 1.0
        )
        let records = try await client.recursiveFiles("\(remoteRoot!)/Idle/Слайдшоу", on: serial)
        XCTAssertEqual(records.count, 6)
    }

    func testIdleTimeoutKillsSilentProcess() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: MOCK_SILENT_BEFORE") }
        let folder = phoneRoot.appendingPathComponent("Idle/Тиша")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeFile(folder.appendingPathComponent("f.bin"), data: Data([0x1]), date: loneDate)
        // Процес мовчить 3 с — ідле-таймаут 1 с мусить убити його задовго до того, як він
        // сам би щось надрукував.
        let client = ADBClient(
            adbPath: Self.mockADBPath,
            extraEnvironment: ["MOCK_PHONE_ROOT": phoneRoot.path, "MOCK_SILENT_BEFORE": "3000"],
            findTimeoutOverride: 1.0
        )
        let start = Date()
        do {
            _ = try await client.recursiveFiles("\(remoteRoot!)/Idle/Тиша", on: serial)
            XCTFail("очікувався ADBError.timeout")
        } catch let error as ADBError {
            guard case .timeout = error else {
                XCTFail("очікувався .timeout, отримано \(error)")
                return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(elapsed, 2.5, "ідле-таймаут мав спрацювати швидко (\(elapsed) с)")
    }

    // MARK: - Sweep сиріт (.androidmover-tmp-*)

    func testSweepLocalRemovesOldOrphansOnly() throws {
        let dir = localBase.appendingPathComponent("sweep-local-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let oldTmp = dir.appendingPathComponent(".androidmover-tmp-old")
        try fm.createDirectory(at: oldTmp, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: oldTmp.path)

        let freshTmp = dir.appendingPathComponent(".androidmover-tmp-fresh")
        try fm.createDirectory(at: freshTmp, withIntermediateDirectories: true)

        let unrelated = dir.appendingPathComponent("не-tmp-тека")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: unrelated.path)

        let removed = OrphanSweeper.sweepLocal(in: dir, olderThan: 3600, fileManager: fm)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: oldTmp.path))
        XCTAssertTrue(fm.fileExists(atPath: freshTmp.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    func testSweepRemoteRemovesOldOrphansOnly() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: пряма маніпуляція mtime на диску") }
        let client = makeClient()
        let oldTmp = phoneRoot.appendingPathComponent("DCIM/.androidmover-tmp-old")
        try fm.createDirectory(at: oldTmp, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: oldTmp.path)

        let freshTmp = phoneRoot.appendingPathComponent("DCIM/.androidmover-tmp-new")
        try fm.createDirectory(at: freshTmp, withIntermediateDirectories: true)

        let removed = await OrphanSweeper.sweepRemote(
            in: "\(remoteRoot!)/DCIM", olderThan: 3600, client: client, serial: serial
        )
        XCTAssertEqual(removed, 1)
        let oldGone = try await remoteFileExists("DCIM/.androidmover-tmp-old")
        XCTAssertFalse(oldGone)
        let freshStillThere = try await remoteFileExists("DCIM/.androidmover-tmp-new")
        XCTAssertTrue(freshStillThere)
    }

    // MARK: - Chaos-mock (обрив з'єднання на конкретному виклику)

    /// Виклики transfer(move:false) для [перший, другий] файли-елементи: #1 recursiveFiles
    /// (підрахунок) першого елемента, #2 recursiveFiles другого. Окремий "чистий" client
    /// (без MOCK_STATE_FILE) готує `entries` — жоден з цих підготовчих викликів НЕ потрапляє
    /// в лічильник chaos-client'а, тож #1 гарантовано саме recursiveFiles(перший).
    func testDisconnectDuringCountingIsolatesItem() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: MOCK_DISCONNECT_ON_CALL") }
        let setupClient = makeClient()
        // Підрахунок (find) робиться лише для тек — плоскі файли беруть розмір з лістингу без
        // adb-виклику; тому перший елемент — тека (виклик #1 = її recursiveFiles).
        let first = try await setupClient.listDirectory("\(remoteRoot!)/DCIM", on: serial)
            .first { $0.isDirectory }!
        let second = try await setupClient.listDirectory("\(remoteRoot!)/Download", on: serial)
            .first { $0.name == "самотній.bin" }!

        let stateFile = makeMockStateFile()
        let chaosClient = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_DISCONNECT_ON_CALL": "1",
        ])

        let engine = TransferEngine(client: chaosClient)
        let results = try await engine.transfer(
            entries: [first, second], to: destination, serial: serial, move: false, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 2)
        guard case .failed = results[0].status else {
            XCTFail("перший елемент мав провалитись на обриві, отримано \(results[0].status)")
            return
        }
        XCTAssertEqual(results[1].status, .copied)
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("самотній.bin").path))
    }

    /// Для move md5 йде перед видаленням: виклики transfer(move:true) для одного
    /// файла-елемента дають #1 pull, #2 md5sum, #3 rm (обрив на #3, delete джерела після
    /// verify — саме на ньому й імітується обрив зв'язку).
    func testDisconnectDuringDeleteReportsCopiedButNotDeleted() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: MOCK_DISCONNECT_ON_CALL") }
        let setupClient = makeClient()
        let lone = try await setupClient.listDirectory("\(remoteRoot!)/Download", on: serial)
            .first { $0.name == "самотній.bin" }!

        let stateFile = makeMockStateFile()
        let chaosClient = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_DISCONNECT_ON_CALL": "3",
        ])

        let engine = TransferEngine(client: chaosClient)
        let results = try await engine.transfer(
            entries: [lone], to: destination, serial: serial, move: true, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        guard case .copiedButDeleteFailed = results[0].status else {
            XCTFail("очікувався copiedButDeleteFailed, отримано \(results[0].status)")
            return
        }
        let copied = destination.appendingPathComponent("самотній.bin")
        XCTAssertTrue(fm.fileExists(atPath: copied.path))
        XCTAssertEqual(try Data(contentsOf: copied), Data("12345".utf8))
        // Джерело на "телефоні" лишилось (rm провалився через обрив) — дані не загубились.
        let sourceStillThere = try await remoteFileExists("Download/самотній.bin")
        XCTAssertTrue(sourceStillThere)
    }

    /// Виклики push() для одного локального файла: #1 mkdir(tmpRoot), #2 mkdir(itemTmpDir),
    /// #3 push, #4 recursiveFiles-верифікація після push (обрив саме тут), #5 delete tmpRoot
    /// (best-effort прибирання — mock знову живий після одного обриву, тож проходить). Обрив
    /// на verify не є провалом — докачка йде після повернення пристрою.
    func testDisconnectDuringPushVerifyResumesAndCleansTmp() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: MOCK_DISCONNECT_ON_CALL") }
        let localFile = pushSource.appendingPathComponent("обрив-push.bin")
        try makeFile(localFile, data: Data(repeating: 0x77, count: 800), date: loneDate)

        let stateFile = makeMockStateFile()
        let chaosClient = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_DISCONNECT_ON_CALL": "4",
        ])

        let engine = PushEngine(client: chaosClient, retryDelay: { _ in 0 })
        let results = try await engine.push(
            urls: [localFile], to: "\(remoteRoot!)/Download", serial: serial, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .pushed, "після обриву на verify — докачка й успіх: \(results[0].status)")
        XCTAssertEqual(try Data(contentsOf: phoneRoot.appendingPathComponent("Download/обрив-push.bin")), Data(repeating: 0x77, count: 800))
        // Тимчасова тека прибрана.
        let leftovers = try fm.contentsOfDirectory(atPath: phoneRoot.appendingPathComponent("Download").path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Fuzz/property-тест парсерів

    func testFuzzNamesRoundTripThroughListingRenameDelete() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only: пряме створення файлів на диску") }
        let client = makeClient()
        let fuzzDir = phoneRoot.appendingPathComponent("fuzz")
        try fm.createDirectory(at: fuzzDir, withIntermediateDirectories: true)

        var names = FuzzNames.batch(count: 60, seed: 0xA5F0_0D15)
        for (index, name) in names.enumerated() {
            let data = Data(repeating: UInt8(index % 251), count: index + 1)
            try writeRawFixture(in: fuzzDir, name: name, data: data)
        }

        let entries = try await client.listDirectory("\(remoteRoot!)/fuzz", on: serial)
        XCTAssertEqual(entries.count, names.count)
        for (index, name) in names.enumerated() {
            guard let entry = entries.first(where: { Array($0.name.utf8) == Array(name.utf8) }) else {
                XCTFail("ім'я #\(index) не знайдено побайтово в лістингу: \(Array(name.unicodeScalars))")
                continue
            }
            XCTAssertEqual(entry.size, Int64(index + 1), "розмір не збігається для імені #\(index)")
        }

        // Перейменовуємо перші 10 на нові випадкові (унікальні) імена. ADBClient.rename сам
        // обрізає пробіли з країв нового імені (як і слід — це введення користувача) — тест
        // звіряє з тою ж обрізаною версією, інакше ім'я з випадковим пробілом на краю
        // (алфавіт fuzz-генератора його свідомо включає) хибно "зникло" б у порівнянні.
        var rng = FuzzNames.LCG(seed: 0xDEAD_BEEF)
        var seen = Set(names)
        for index in 0..<10 {
            var candidate = FuzzNames.random(&rng)
            var trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.isEmpty || seen.contains(trimmed) {
                candidate = FuzzNames.random(&rng)
                trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            seen.insert(trimmed)
            let renamed = try await client.rename("\(remoteRoot!)/fuzz/\(names[index])", to: candidate, on: serial)
            // Побайтово, не String.hasSuffix: коли `trimmed` починається з комбінуючого знака,
            // Character-based hasSuffix хибно негативить через ту саму grapheme-fusion межу
            // "/" + знак, що й баг у RemotePath, який ми вже полагодили нижче по стеку.
            let renamedTail = Array(renamed.utf8).suffix(Array(trimmed.utf8).count)
            XCTAssertEqual(Array(renamedTail), Array(trimmed.utf8))
            names[index] = trimmed
        }
        // Видаляємо наступні 10 (окремі від щойно перейменованих).
        for index in 10..<20 {
            try await client.delete("\(remoteRoot!)/fuzz/\(names[index])", on: serial)
        }
        let deletedNames = Set(names[10..<20])
        names.removeAll { deletedNames.contains($0) }

        let finalEntries = try await client.listDirectory("\(remoteRoot!)/fuzz", on: serial)
        XCTAssertEqual(finalEntries.count, names.count)
        let finalNameBytes = Set(finalEntries.map { Array($0.name.utf8) })
        for name in names {
            XCTAssertTrue(finalNameBytes.contains(Array(name.utf8)), "ім'я зникло після rename/delete: \(name)")
        }
    }

    // MARK: - adb track-devices (ProcessRunner.stream())

    /// Крутиться, доки `condition()` не стане true чи не спливе `timeout` — без жодного throw
    /// на таймаут (нехай подальші XCTAssert самі чесно провалять тест зі зрозумілим числом,
    /// а не замаскують провал під помилку самого хелпера).
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// MOCK_TRACK_FILE: device → none → device (той самий трюк, що і B2-стан-файли —
    /// mock перечитує файл кожні 200 мс і друкує новий кадр при зміні вмісту). Стрім
    /// `client.trackDevices` мусить віддати рівно 3 знімки в тому самому порядку; скасування
    /// Task, що ітерує стрім, мусить убити mock-процес (SIGTERM→3с→SIGKILL у ProcessRunner.stream)
    /// не довше ніж за ≤3 с попри те, що mock без MOCK_TRACK_FILE-змін живе нескінченно довго.
    func testTrackDevicesStreamEmitsOnChange() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let trackFile = localBase.appendingPathComponent("mock-track-\(UUID().uuidString).txt")
        try Data("device".utf8).write(to: trackFile)
        let client = makeClient(extraEnv: ["MOCK_TRACK_FILE": trackFile.path])

        let capturedChild = LockedBox<ChildProcess>()
        let collector = DeviceFrameCollector()

        let consumerTask = Task {
            do {
                for try await frame in client.trackDevices(onSpawn: { capturedChild.value = $0 }) {
                    collector.add(frame)
                }
            } catch {
                collector.recordError(error)
            }
        }

        try await waitUntil(timeout: 3) { collector.count >= 1 }
        try Data("none".utf8).write(to: trackFile)
        try await waitUntil(timeout: 3) { collector.count >= 2 }
        try Data("device".utf8).write(to: trackFile)
        try await waitUntil(timeout: 3) { collector.count >= 3 }

        let frames = collector.all
        XCTAssertEqual(frames.count, 3, "очікувались рівно 3 кадри (device → none → device), отримано \(frames.count)")
        XCTAssertNil(collector.error)
        if frames.count == 3 {
            XCTAssertEqual(frames[0].map(\.serial), ["MOCK001"])
            XCTAssertEqual(frames[0].first?.state, .ready)
            XCTAssertEqual(frames[1], [])
            XCTAssertEqual(frames[2].map(\.serial), ["MOCK001"])
        }

        guard let child = capturedChild.value else {
            XCTFail("onSpawn не викликався")
            consumerTask.cancel()
            return
        }

        // Скасування Task, що ітерує стрім, мусить убити mock-процес ≤3 с (SIGTERM→3с→SIGKILL
        // у ProcessRunner.stream, той самий патерн, що idle-таймаут/cancel() рушіїв).
        let cancelStart = Date()
        consumerTask.cancel()
        await consumerTask.value // не throwing: Task сам ловить помилку в collector.recordError

        let deadline = Date().addingTimeInterval(3.5)
        while child.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let elapsed = Date().timeIntervalSince(cancelStart)
        XCTAssertFalse(child.isRunning, "adb track-devices мав завершитись після cancel Task (\(elapsed) с)")
        XCTAssertLessThanOrEqual(elapsed, 3.5)

        try? fm.removeItem(at: trackFile)
    }


}
