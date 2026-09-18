import Foundation
import XCTest
@testable import AndroidMoverCore

extension EngineTests {

    // MARK: - B2: resume/делта-докачка після обриву

    func testResumeRefetchesOnlyMissingFilesAfterMidTransferFailure() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "1",
            "MOCK_LOG_FILE": logFile.path,
        ])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let collector = ProgressCollector()
        let results = try await engine.transfer(
            entries: [vacation], to: destination, serial: serial, move: false,
            onProgress: { collector.add($0) }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .copied)

        // Дані й дати — так само правильні, як у щасливому шляху без обриву.
        let copied = destination.appendingPathComponent("Фото відпустки")
        let img = copied.appendingPathComponent("IMG_0001.jpg")
        let video = copied.appendingPathComponent("відео кліп.mp4")
        XCTAssertEqual(try Data(contentsOf: img), Data(repeating: 0x41, count: 1000))
        XCTAssertEqual(try Data(contentsOf: video), Data(repeating: 0x42, count: 2048))
        XCTAssertEqual(try mtimeEpoch(img), Int(photoDate.timeIntervalSince1970))
        XCTAssertEqual(try mtimeEpoch(video), Int(videoDate.timeIntervalSince1970))
        XCTAssertEqual(try creationEpoch(img), Int(photoDate.timeIntervalSince1970))
        XCTAssertEqual(try creationEpoch(video), Int(videoDate.timeIntervalSince1970))
        XCTAssertEqual(try mtimeEpoch(copied), Int(vacationDirDate.timeIntervalSince1970))
        XCTAssertEqual(try creationEpoch(copied), Int(vacationDirDate.timeIntervalSince1970))

        // tmp прибраний.
        let leftovers = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])

        // Прогрес пройшов через waitingForDevice і resuming (B2) — не просто мовчки повторив pull.
        XCTAssertTrue(collector.phases.contains(.waitingForDevice))
        XCTAssertTrue(collector.phases.contains(.resuming))

        // Рівно 2 pull-виклики; другий — лише за відсутнім/битим файлом, не всією текою.
        let pullPaths = try pullCallRemotePaths(logFile: logFile)
        XCTAssertEqual(pullPaths.count, 2, "очікувались 2 pull-виклики (перший провал + докачка), отримано \(pullPaths)")
        XCTAssertEqual(pullPaths.first, "\(remoteRoot!)/DCIM/Фото відпустки")
        XCTAssertEqual(pullPaths.last, "\(remoteRoot!)/DCIM/Фото відпустки/відео кліп.mp4")
    }

    func testVerificationCorruptionSelfHealsViaResume() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_CORRUPT_PULL_COUNT": "1",
        ])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.transfer(
            entries: [vacation], to: destination, serial: serial, move: false, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .copied)
        let copied = destination.appendingPathComponent("Фото відпустки")
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("IMG_0001.jpg")),
                       Data(repeating: 0x41, count: 1000))
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("відео кліп.mp4")),
                       Data(repeating: 0x42, count: 2048))
    }

    func testResumeExhaustsRetriesAndFailsHonestly() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        // Бюджет обривів (10) свідомо перевищує кількість pull-викликів, які взагалі
        // встигнуть статись (1 початковий + 3 спроби докачки) — усі мають провалитись.
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "10",
        ])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client, maxAttempts: 3, retryDelay: { _ in 0 })
        let results = try await engine.transfer(
            entries: [vacation], to: destination, serial: serial, move: true, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        guard case .failed = results[0].status else {
            XCTFail("очікувався чесний провал після вичерпання спроб, отримано \(results[0].status)")
            return
        }

        // У призначенні НІЧОГО — ні готового елемента, ні tmp.
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("Фото відпустки").path))
        let leftovers = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])

        // Джерело на "телефоні" ціле — режим move нічого не видалив попри провал.
        XCTAssertTrue(fm.fileExists(atPath: phoneRoot.appendingPathComponent("DCIM/Фото відпустки/IMG_0001.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: phoneRoot.appendingPathComponent("DCIM/Фото відпустки/відео кліп.mp4").path))
    }

    func testMoveAfterResumeDeletesSourceOnlyAfterFinalVerify() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "1",
        ])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.transfer(
            entries: [vacation], to: destination, serial: serial, move: true, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .moved)
        let copied = destination.appendingPathComponent("Фото відпустки")
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("IMG_0001.jpg")),
                       Data(repeating: 0x41, count: 1000))
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("відео кліп.mp4")),
                       Data(repeating: 0x42, count: 2048))

        // Джерело видалене ЛИШЕ після того, як фінальна verify (по докачці) пройшла.
        let sourceGone = try await remoteFileExists("DCIM/Фото відпустки")
        XCTAssertFalse(sourceGone)
    }

    func testCancelDuringWaitForDeviceDoesNotHang() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        // MOCK_WAIT_HANG змушує wait-for-device спати 30 с — тест доводить, що cancel()
        // перериває ЦЕ очікування напряму (через trackProcess), а не чекає весь таймаут.
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "5",
            "MOCK_WAIT_HANG": "1",
        ])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let finished = expectation(description: "transfer finishes after cancel")
        // Swift 6: локальні копії властивостей XCTestCase — Task{}-замикання нижче не мусить
        // неявно захоплювати `self` (XCTestCase не Sendable), лише Sendable-значення (URL/String).
        let destination = self.destination!
        let serial = self.serial

        let task = Task {
            defer { finished.fulfill() }
            return try await engine.transfer(
                entries: [vacation], to: destination, serial: serial, move: false, onProgress: { _ in }
            )
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        engine.cancel()

        await fulfillment(of: [finished], timeout: 5)
        let results = try await task.value

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .cancelled)

        let leftovers = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])
    }

    /// Регресія: докачка (resumeMissing) МУСИТЬ звертатись до телефона за СИРИМИ байтами
    /// імені з лістингу, не unicode-нормалізованим ключем. "й" на телефоні лежить як NFD
    /// (U+0438 CYRILLIC SMALL LETTER I + U+0306 COMBINING BREVE) — телефон (ext4/FUSE) шукає
    /// ім'я байт-у-байт, тож pull за NFC-варіантом отримав би "не існує". "b.txt" навмисно
    /// сортується ПЕРЕД NFD-файлом (код-пойнт 'b' 0x62 < код-пойнт 'и' 0x438), тож
    /// MOCK_PULL_FAIL_COUNT=1 (частковий pull) лишає "b.txt" цілим, а NFD-файл — обрізаним
    /// навпіл: саме його resumeMissing і мусить докачати.
    func testResumePullsMissingFileByRawDeviceBytesNotNormalized() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let logFile = makeMockLogFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "1",
            "MOCK_LOG_FILE": logFile.path,
        ])

        let nfdName = "и\u{0306}.txt"
        let folder = phoneRoot.appendingPathComponent("NFDTest")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeFile(folder.appendingPathComponent("b.txt"), data: Data("перший файл".utf8), date: loneDate)
        try makeFile(folder.appendingPathComponent(nfdName), data: Data(repeating: 0x39, count: 4000), date: loneDate)

        let entries = try await client.listDirectory("\(remoteRoot!)", on: serial)
        let nfdFolder = entries.first { $0.name == "NFDTest" }!

        let engine = TransferEngine(client: client, retryDelay: { _ in 0 })
        let results = try await engine.transfer(
            entries: [nfdFolder], to: destination, serial: serial, move: false, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .copied)

        let copied = destination.appendingPathComponent("NFDTest")
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("b.txt")), Data("перший файл".utf8))
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent(nfdName)), Data(repeating: 0x39, count: 4000))

        let pullPaths = try pullCallRemotePaths(logFile: logFile)
        XCTAssertEqual(pullPaths.count, 2,
                       "очікувались 2 pull-виклики (перший провал + докачка NFD-файла), отримано \(pullPaths)")

        // Головний асерт: докачувальний pull мусить нести САМЕ NFD-байти, не NFC-нормалізовану
        // версію. Swift String `==` порівнює канонічно-еквівалентно (NFC і NFD того самого
        // імені виглядають "рівними"!), тому звірка йде побайтово через utf8, а не через `==`.
        let expectedRemotePath = "\(remoteRoot!)/NFDTest/\(nfdName)"
        let actualRemotePath = pullPaths.last!
        XCTAssertEqual(Array(actualRemotePath.utf8), Array(expectedRemotePath.utf8),
                       "докачувальний pull використав нормалізований шлях замість сирих байтів телефона")
    }

    /// #2: цикл спроб докачки має стартувати ЛИШЕ для ADBError — будь-яка локальна помилка
    /// (напр. CocoaError від FileManager.moveItem у finishAfterPull) кидається одразу.
    func testIsResumableDistinguishesADBErrorsFromLocalErrors() {
        XCTAssertTrue(TransferEngine.isResumable(ADBError.verificationFailed("mismatch")))
        XCTAssertFalse(TransferEngine.isResumable(CocoaError(.fileWriteFileExists)))
    }

    /// #3: cancel() посеред retryDelay (не лише посеред waitForDevice) мусить спрацювати
    /// негайно — retryDelay спить чанками ≤100 мс, а не одним суцільним Task.sleep.
    func testCancelDuringRetryDelayIsPrompt() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let stateFile = makeMockStateFile()
        let client = makeClient(extraEnv: [
            "MOCK_STATE_FILE": stateFile.path,
            "MOCK_PULL_FAIL_COUNT": "5",
        ])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        // Довгий retryDelay (5 с): без фіксу #3 cancel() посеред нього чекав би до штатного
        // кінця паузи; з фіксом мусить спрацювати за частки секунди.
        let engine = TransferEngine(client: client, retryDelay: { _ in 5 })
        let finished = expectation(description: "transfer finishes after cancel during retryDelay")
        let start = Date()
        // Swift 6: локальні копії властивостей XCTestCase — Task{}-замикання нижче не мусить
        // неявно захоплювати `self` (XCTestCase не Sendable), лише Sendable-значення (URL/String).
        let destination = self.destination!
        let serial = self.serial

        let task = Task {
            defer { finished.fulfill() }
            return try await engine.transfer(
                entries: [vacation], to: destination, serial: serial, move: false, onProgress: { _ in }
            )
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        engine.cancel()

        await fulfillment(of: [finished], timeout: 5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(
            elapsed, 2.0,
            "cancel посеред retryDelay мав спрацювати швидко, а не чекати штатну паузу (\(elapsed) с)"
        )

        let results = try await task.value
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .cancelled)

        let leftovers = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])
    }


}
