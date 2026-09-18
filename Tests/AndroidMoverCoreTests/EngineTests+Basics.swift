import Foundation
import XCTest
@testable import AndroidMoverCore

extension EngineTests {

    // MARK: - Тести

    func testDevicesRoundtrip() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") } // серійник/модель — mock-фікстура.
        let devices = try await makeClient().devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, serial)
        XCTAssertEqual(devices[0].state, .ready)
        XCTAssertEqual(devices[0].model, "Mock_Phone_9")
    }

    func testListDirectory() async throws {
        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        XCTAssertEqual(entries.count, 2)

        let dir = entries.first { $0.isDirectory }
        XCTAssertEqual(dir?.name, "Фото відпустки")
        XCTAssertEqual(dir?.path, "\(remoteRoot!)/DCIM/Фото відпустки")

        let file = entries.first { !$0.isDirectory }
        XCTAssertEqual(file?.name, "o'clock файл.txt")
        XCTAssertEqual(file?.size, 11)
        XCTAssertEqual(file.map { Int($0.modified.timeIntervalSince1970) },
                       Int(textDate.timeIntervalSince1970))
    }

    func testListMissingDirectoryThrows() async throws {
        let client = makeClient()
        do {
            _ = try await client.listDirectory("\(remoteRoot!)/такої-теки-немає", on: serial)
            XCTFail("очікувалась помилка notADirectory")
        } catch let error as ADBError {
            XCTAssertEqual(error, .notADirectory("\(remoteRoot!)/такої-теки-немає"))
        }
    }

    func testCopyDirectoryPreservesDatesAndData() async throws {
        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: [vacation], to: destination, serial: serial, move: false, onProgress: { _ in }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .copied)
        XCTAssertEqual(results[0].bytes, 3048)

        let copied = destination.appendingPathComponent("Фото відпустки")
        let img = copied.appendingPathComponent("IMG_0001.jpg")
        let video = copied.appendingPathComponent("відео кліп.mp4")

        XCTAssertTrue(fm.fileExists(atPath: img.path))
        XCTAssertEqual(try Data(contentsOf: img), Data(repeating: 0x41, count: 1000))

        // mtime секунда-в-секунду як на «телефоні».
        XCTAssertEqual(try mtimeEpoch(img), Int(photoDate.timeIntervalSince1970))
        XCTAssertEqual(try mtimeEpoch(video), Int(videoDate.timeIntervalSince1970))
        // creationDate виставлено в mtime.
        XCTAssertEqual(try creationEpoch(img), Int(photoDate.timeIntervalSince1970))
        XCTAssertEqual(try creationEpoch(video), Int(videoDate.timeIntervalSince1970))

        // Копіювання не видаляє джерело.
        let sourceStillThere = try await remoteFileExists("DCIM/Фото відпустки/IMG_0001.jpg")
        XCTAssertTrue(sourceStillThere)

        // Тимчасових тек не лишилось.
        let leftovers = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])

        // Дата САМОЇ ТЕКИ теж відновлена (adb pull -a її не зберігає — рушій робить це сам).
        XCTAssertEqual(try mtimeEpoch(copied), Int(vacationDirDate.timeIntervalSince1970))
        XCTAssertEqual(try creationEpoch(copied), Int(vacationDirDate.timeIntervalSince1970))
    }

    func testWhitespaceFilenameSurvivesListAndMove() async throws {
        // Ім'я з хвостовим пробілом — легальне на Android; трімінг шляхів ламав би його.
        let trickyName = "файл із хвостом "
        let trickyDate = Date(timeIntervalSince1970: 1_550_000_000)
        try await addRemoteFile("Download/\(trickyName)", data: Data("tricky".utf8), date: trickyDate)

        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        let tricky = entries.first { $0.name == trickyName }
        XCTAssertNotNil(tricky, "ім'я з хвостовим пробілом мусить вціліти в листингу")
        XCTAssertEqual(tricky?.path, "\(remoteRoot!)/Download/\(trickyName)")

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: [tricky!], to: destination, serial: serial, move: true, onProgress: { _ in }
        )
        XCTAssertEqual(results[0].status, .moved)
        XCTAssertEqual(results[0].finalURL?.lastPathComponent, trickyName)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(trickyName)), Data("tricky".utf8))
        // Видалено САМЕ цей файл, а сусід без пробіла (нема) не постраждав би.
        let trickyGone = try await remoteFileExists("Download/\(trickyName)")
        XCTAssertFalse(trickyGone)
        let neighborStillThere = try await remoteFileExists("Download/самотній.bin")
        XCTAssertTrue(neighborStillThere)
    }

    func testSentinelLookalikeNamesDoNotBreakListing() async throws {
        // Імена, що МІСТЯТЬ сентинел, не мають вмикати хибні помилки (перевірка першого рядка).
        try await addRemoteFile("Download/backup__AM_MISSING__old.jpg",
                                 data: Data(repeating: 0x01, count: 6), date: loneDate)
        try await addRemoteFile("Download/x__AM_NOT_A_DIR__y.txt",
                                 data: Data("ok".utf8), date: loneDate)

        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        XCTAssertTrue(entries.contains { $0.name == "backup__AM_MISSING__old.jpg" })
        XCTAssertTrue(entries.contains { $0.name == "x__AM_NOT_A_DIR__y.txt" })

        let files = try await client.recursiveFiles("\(remoteRoot!)/Download", on: serial)
        XCTAssertTrue(files.contains { $0.path.hasSuffix("backup__AM_MISSING__old.jpg") })

        // І перенесення такої теки працює.
        let downloadEntry = try await client.listDirectory("\(remoteRoot!)", on: serial)
            .first { $0.name == "Download" }!
        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: [downloadEntry], to: destination, serial: serial, move: false, onProgress: { _ in }
        )
        XCTAssertEqual(results[0].status, .copied)
    }

    func testSymlinkDirectoryIsResolvedInListing() async throws {
        // Створення symlink на телефоні не підтримано жодним методом ADBClient (це саме та
        // операція, яку тест вручну емулює прямим записом на диск mock-режиму) — mock-only.
        if Self.backend == "real" { throw XCTSkip("mock-only") }

        // /sdcard на реальних телефонах — symlink; find -P без розіменування показував би
        // «Тека порожня». Лістинг мусить розіменувати корінь і віддати КАНОНІЧНІ шляхи.
        let realDir = phoneRoot.appendingPathComponent("справжня тека")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try makeFile(realDir.appendingPathComponent("файл всередині.txt"),
                     data: Data("inside".utf8), date: loneDate)
        try fm.createSymbolicLink(
            at: phoneRoot.appendingPathComponent("посилання"),
            withDestinationURL: realDir
        )

        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/посилання", on: serial)
        XCTAssertEqual(entries.count, 1, "symlink-тека мусить показувати вміст цілі")
        XCTAssertEqual(entries[0].name, "файл всередині.txt")
        // Шлях канонічний (через ціль симлінка), тож увесь конвеєр далі консистентний.
        XCTAssertEqual(entries[0].path, "\(remoteRoot!)/справжня тека/файл всередині.txt")

        // І перенесення з такого лістингу працює end-to-end.
        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: entries, to: destination, serial: serial, move: false, onProgress: { _ in }
        )
        XCTAssertEqual(results[0].status, .copied)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("файл всередині.txt")),
                       Data("inside".utf8))
    }

    func testCountingFailureIsolatesItem() async throws {
        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        let lone = entries.first { $0.name == "самотній.bin" }!
        // Елемент, що зник між листингом і перенесенням.
        let ghost = RemoteEntry(
            path: "\(remoteRoot!)/Download/зник.bin", name: "зник.bin",
            isDirectory: false, isSymlink: false, size: 10, modified: loneDate
        )

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: [ghost, lone], to: destination, serial: serial, move: false, onProgress: { _ in }
        )
        XCTAssertEqual(results.count, 2)
        guard case .failed = results[0].status else {
            XCTFail("привид мав провалитись, отримано \(results[0].status)")
            return
        }
        // А реальний елемент — успішний, батч не зірвано.
        XCTAssertEqual(results[1].status, .copied)
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("самотній.bin").path))
    }

    func testMoveFileDeletesSourceAfterVerify() async throws {
        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        let lone = entries.first { $0.name == "самотній.bin" }!

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: [lone], to: destination, serial: serial, move: true, onProgress: { _ in }
        )

        XCTAssertEqual(results[0].status, .moved)
        let moved = destination.appendingPathComponent("самотній.bin")
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
        XCTAssertEqual(try Data(contentsOf: moved), Data("12345".utf8))
        XCTAssertEqual(try mtimeEpoch(moved), Int(loneDate.timeIntervalSince1970))
        XCTAssertEqual(try creationEpoch(moved), Int(loneDate.timeIntervalSince1970))
        // Джерело видалено.
        let sourceGone = try await remoteFileExists("Download/самотній.bin")
        XCTAssertFalse(sourceGone)
    }

    func testCorruptedPullDoesNotDeleteSource() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        // MOCK_CORRUPT_PULL=1 (безлімітний варіант, на відміну від MOCK_CORRUPT_PULL_COUNT)
        // ламає геть КОЖЕН pull, тож і докачка (B2) отримає биту копію знову — семантика
        // «джерело не видалене» мусить лишитись, попри те, що тепер є цикл спроб. maxAttempts:1
        // тримає тест швидким (без цього — дефолтні 5 спроб із зростаючою паузою).
        let client = makeClient(extraEnv: ["MOCK_CORRUPT_PULL": "1"])
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)
        let vacation = entries.first { $0.isDirectory }!

        let engine = TransferEngine(client: client, maxAttempts: 1, retryDelay: { _ in 0 })
        let results = try await engine.transfer(
            entries: [vacation], to: destination, serial: serial, move: true, onProgress: { _ in }
        )

        guard case .failed(let message) = results[0].status else {
            XCTFail("очікувався провал верифікації, отримано \(results[0].status)")
            return
        }
        XCTAssertTrue(message.contains("не збігається") || message.contains("Перевірка копії"),
                      "повідомлення: \(message)")

        // Джерело ПОВНІСТЮ на місці.
        XCTAssertTrue(fm.fileExists(atPath: phoneRoot.appendingPathComponent("DCIM/Фото відпустки/IMG_0001.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: phoneRoot.appendingPathComponent("DCIM/Фото відпустки/відео кліп.mp4").path))
        // Нічого не потрапило в призначення.
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("Фото відпустки").path))
        let leftovers = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testCollisionAutoRename() async throws {
        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        let lone = entries.first { $0.name == "самотній.bin" }!

        let engine1 = TransferEngine(client: client)
        _ = try await engine1.transfer(entries: [lone], to: destination, serial: serial, move: false, onProgress: { _ in })
        let engine2 = TransferEngine(client: client)
        let second = try await engine2.transfer(entries: [lone], to: destination, serial: serial, move: false, onProgress: { _ in })

        XCTAssertEqual(second[0].status, .copied)
        XCTAssertEqual(second[0].finalURL?.lastPathComponent, "самотній (1).bin")
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("самотній.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("самотній (1).bin").path))
    }

    func testDeleteRefusesUnsafePaths() async throws {
        let client = makeClient()
        do {
            // Літерал "/sdcard" навмисно НЕ через remoteRoot: тест перевіряє guard проти
            // видалення самого кореня тому (isUnsafeToDelete рахує компоненти шляху), а
            // "/sdcard/AndroidMoverE2E/<uuid>" сам по собі guard НЕ спрацював би — це вже
            // "усередині" тому, видаляти можна.
            try await client.delete("/sdcard", on: serial)
            XCTFail("очікувалась відмова видаляти /sdcard")
        } catch let error as ADBError {
            XCTAssertEqual(error, .unsafeDeletePath("/sdcard"))
        }
        // Guard спрацьовує до виклику adb, телефонна тека ціла.
        let dcimStillThere = try await remoteFileExists("DCIM")
        XCTAssertTrue(dcimStillThere)
    }

    func testFailedDeleteReportsButKeepsCopy() async throws {
        if Self.backend == "real" { throw XCTSkip("mock-only") }
        let client = makeClient(extraEnv: ["MOCK_FAIL_DELETE": "1"])
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        let lone = entries.first { $0.name == "самотній.bin" }!

        let engine = TransferEngine(client: client)
        let results = try await engine.transfer(
            entries: [lone], to: destination, serial: serial, move: true, onProgress: { _ in }
        )

        guard case .copiedButDeleteFailed = results[0].status else {
            XCTFail("очікувався copiedButDeleteFailed, отримано \(results[0].status)")
            return
        }
        XCTAssertTrue(results[0].isSuccess)
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("самотній.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: phoneRoot.appendingPathComponent("Download/самотній.bin").path))
    }

    func testMakeDirectoryAndListIt() async throws {
        let client = makeClient()
        try await client.makeDirectory("\(remoteRoot!)/Download/Нова тека 2026", on: serial)
        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        XCTAssertTrue(entries.contains { $0.name == "Нова тека 2026" && $0.isDirectory })

        // Створення в неіснуючому місці — чесна помилка.
        do {
            try await client.makeDirectory("\(remoteRoot!)/немає/такої", on: serial)
            XCTFail("очікувалась mkdirFailed")
        } catch let error as ADBError {
            XCTAssertEqual(error, .mkdirFailed("\(remoteRoot!)/немає/такої"))
        }
        // Поза дозволеною зоною — guard.
        do {
            try await client.makeDirectory("/data/evil", on: serial)
            XCTFail("очікувалась unsafeDeletePath")
        } catch let error as ADBError {
            XCTAssertEqual(error, .unsafeDeletePath("/data/evil"))
        }
    }

    func testRenamePreservesContentAndDates() async throws {
        let client = makeClient()
        let newPath = try await client.rename("\(remoteRoot!)/Download/самотній.bin", to: "перейменований'.bin", on: serial)
        XCTAssertEqual(newPath, "\(remoteRoot!)/Download/перейменований'.bin")

        let entries = try await client.listDirectory("\(remoteRoot!)/Download", on: serial)
        XCTAssertTrue(entries.contains { $0.name == "перейменований'.bin" })
        XCTAssertFalse(entries.contains { $0.name == "самотній.bin" })

        let renamedData = try await remoteData("Download/перейменований'.bin")
        XCTAssertEqual(renamedData, Data("12345".utf8))
        let renamedMTime = try await remoteMTimeEpoch("Download/перейменований'.bin")
        XCTAssertEqual(renamedMTime, Int(loneDate.timeIntervalSince1970))
    }

    func testRenameRejectsBadTargets() async throws {
        let client = makeClient()
        // На існуюче ім'я — відмова, обидва файли цілі.
        try await addRemoteFile("Download/зайнято.bin", data: Data("x".utf8), date: loneDate)
        do {
            _ = try await client.rename("\(remoteRoot!)/Download/самотній.bin", to: "зайнято.bin", on: serial)
            XCTFail("очікувалась alreadyExists")
        } catch let error as ADBError {
            XCTAssertEqual(error, .alreadyExists("зайнято.bin"))
        }
        let loneStillThere = try await remoteFileExists("Download/самотній.bin")
        XCTAssertTrue(loneStillThere)
        let occupiedStillThere = try await remoteFileExists("Download/зайнято.bin")
        XCTAssertTrue(occupiedStillThere)

        // Слеш в імені — відмова без виклику adb.
        do {
            _ = try await client.rename("\(remoteRoot!)/Download/самотній.bin", to: "a/b", on: serial)
            XCTFail("очікувалась invalidName")
        } catch let error as ADBError {
            XCTAssertEqual(error, .invalidName("a/b"))
        }
    }

    func testStorageInfoAgainstMock() async throws {
        let client = makeClient()
        let info = try await client.storageInfo(for: "\(remoteRoot!)", on: serial)
        XCTAssertGreaterThan(info.availableBytes, 0)
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertLessThanOrEqual(info.availableBytes, info.totalBytes)

        // Працює і з підтекою (stat -f звітує про файлову систему тому, не сам шлях).
        let sub = try await client.storageInfo(for: "\(remoteRoot!)/DCIM", on: serial)
        XCTAssertGreaterThan(sub.totalBytes, 0)
    }

    func testRescanMediaDoesNotThrow() async throws {
        let client = makeClient()
        let paths = [
            "\(remoteRoot!)/DCIM/Фото відпустки/IMG_0001.jpg",
            "\(remoteRoot!)/Download/файл із пробілом і o'clock.mp4",
        ]
        // Best-effort: жодних винятків навіть попри кирилицю/пробіли/апострофи в шляхах.
        try await client.rescanMedia(paths, on: serial)
        try await client.rescanMedia([], on: serial)
        try await client.rescanVolume(on: serial)
    }

    func testProgressReachesTotal() async throws {
        let client = makeClient()
        let entries = try await client.listDirectory("\(remoteRoot!)/DCIM", on: serial)

        let engine = TransferEngine(client: client)
        let collector = ProgressCollector()
        let results = try await engine.transfer(
            entries: entries, to: destination, serial: serial, move: false,
            onProgress: { collector.add($0) }
        )
        XCTAssertTrue(results.allSatisfy(\.isSuccess))
        let last = collector.last
        XCTAssertNotNil(last)
        XCTAssertEqual(last?.bytesTotal, 3048 + 11)
        XCTAssertEqual(last?.bytesDone, last?.bytesTotal)
        XCTAssertEqual(last?.itemsDone, 2)
    }


}
