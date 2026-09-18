import XCTest
@testable import AndroidMoverCore

final class ParserTests: XCTestCase {

    func testParseDevices() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        R58M12345\tdevice usb:1-1 product:beyond1 model:SM_G973F device:beyond1
        emulator-5554          offline
        0A241FDD40012K         unauthorized usb:0-1

        """
        let devices = ADBClient.parseDevices(output)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].serial, "R58M12345")
        XCTAssertEqual(devices[0].state, .ready)
        XCTAssertEqual(devices[0].model, "SM_G973F")
        XCTAssertEqual(devices[0].displayName, "SM G973F")
        XCTAssertEqual(devices[1].state, .offline)
        XCTAssertEqual(devices[2].state, .unauthorized)
        XCTAssertNil(devices[2].model)
    }

    func testParseListingFiltersDotsAndKeepsPipes() {
        let output = """
        directory|4096|1600000000|/sdcard/DCIM/.
        directory|4096|1600000000|/sdcard/DCIM/..
        directory|4096|1610000000|/sdcard/DCIM/Фото відпустки
        regular file|1234|1620000000|/sdcard/DCIM/o'clock файл.txt
        regular file|10|1630000000|/sdcard/DCIM/we|ird|name.bin
        symbolic link|20|1640000000|/sdcard/DCIM/link_to_x
        мусор без роздільників
        """
        let entries = ADBClient.parseListing(output, directory: "/sdcard/DCIM")
        XCTAssertEqual(entries.count, 4)

        let dir = entries[0]
        XCTAssertTrue(dir.isDirectory)
        XCTAssertEqual(dir.name, "Фото відпустки")
        XCTAssertEqual(dir.path, "/sdcard/DCIM/Фото відпустки")
        XCTAssertEqual(Int(dir.modified.timeIntervalSince1970), 1_610_000_000)

        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("o'clock файл.txt"))
        XCTAssertTrue(names.contains("we|ird|name.bin"))
        XCTAssertFalse(names.contains("."))
        XCTAssertFalse(names.contains(".."))

        let weird = entries.first { $0.name == "we|ird|name.bin" }!
        XCTAssertEqual(weird.size, 10)

        let link = entries.first { $0.name == "link_to_x" }!
        XCTAssertTrue(link.isSymlink)
        XCTAssertFalse(link.isDirectory)
    }

    func testShellQuote() {
        XCTAssertEqual(RemotePath.shellQuote("/sdcard/DCIM"), "'/sdcard/DCIM'")
        XCTAssertEqual(RemotePath.shellQuote("/sdcard/o'clock"), "'/sdcard/o'\\''clock'")
        XCTAssertEqual(RemotePath.shellQuote("/sdcard/з пробілом і кирилицею"), "'/sdcard/з пробілом і кирилицею'")
    }

    func testRemotePathHelpers() {
        XCTAssertEqual(RemotePath.normalized("/sdcard/DCIM///"), "/sdcard/DCIM")
        // Пробіли — легальна частина імен: normalized їх НЕ чіпає…
        XCTAssertEqual(RemotePath.normalized("/sdcard/файл з хвостом "), "/sdcard/файл з хвостом ")
        // …а userInput (ручне введення шляху) — обрізає.
        XCTAssertEqual(RemotePath.userInput("  /sdcard "), "/sdcard")
        XCTAssertEqual(RemotePath.parent("/sdcard/DCIM/Camera"), "/sdcard/DCIM")
        XCTAssertEqual(RemotePath.parent("/sdcard"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
        XCTAssertEqual(RemotePath.baseName("/sdcard/DCIM/Camera"), "Camera")
        XCTAssertEqual(RemotePath.join("/sdcard", "DCIM"), "/sdcard/DCIM")
        XCTAssertEqual(RemotePath.join("/", "sdcard"), "/sdcard")
    }

    func testUnsafeDeleteGuard() {
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/sdcard"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/sdcard/"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage/emulated"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage/emulated/0"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage/self"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage/self/primary"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/data/data/app"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/mnt/sdcard/DCIM"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/sdcard/DCIM/../../system"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("sdcard/DCIM"))
        // Корінь ЗНІМНОЇ SD-картки — точка монтування тому: rm -rf стер би всю картку.
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage/AAAA-BBBB"))
        XCTAssertTrue(RemotePath.isUnsafeToDelete("/storage/1234-5678/"))

        XCTAssertFalse(RemotePath.isUnsafeToDelete("/sdcard/DCIM"))
        XCTAssertFalse(RemotePath.isUnsafeToDelete("/sdcard/DCIM/Camera/IMG.jpg"))
        XCTAssertFalse(RemotePath.isUnsafeToDelete("/storage/emulated/0/Download/файл.zip"))
        XCTAssertFalse(RemotePath.isUnsafeToDelete("/storage/self/primary/DCIM"))
        // Вміст УСЕРЕДИНІ знімної картки видаляти можна.
        XCTAssertFalse(RemotePath.isUnsafeToDelete("/storage/AAAA-BBBB/DCIM"))
        XCTAssertFalse(RemotePath.isUnsafeToDelete("/storage/1234-5678/Download/файл.zip"))
    }

    func testAllowedPushTarget() {
        // Дозволено писати В КОРІНЬ /sdcard чи /storage/... — на відміну від isUnsafeToDelete,
        // де сам корінь недоторканний.
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/sdcard"))
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/sdcard/"))
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/sdcard/Download"))
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/storage/emulated/0"))
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/storage/emulated/0/Download"))
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/storage/AAAA-BBBB"))
        XCTAssertTrue(RemotePath.isAllowedPushTarget("/storage/AAAA-BBBB/DCIM"))

        XCTAssertFalse(RemotePath.isAllowedPushTarget("/"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/storage"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/data"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/data/data/app"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/system"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/mnt/sdcard/DCIM"))
        // Текстовий збіг префікса не рятує від ".." — компоненти перевіряються окремо.
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/sdcard/../data/evil"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("/sdcard/./evil"))
        XCTAssertFalse(RemotePath.isAllowedPushTarget("sdcard/DCIM"))
    }

    func testRemoteEntryMatchesQuery() {
        let entry = RemoteEntry(
            path: "/sdcard/DCIM/Фото Відпустки.jpg", name: "Фото Відпустки.jpg",
            isDirectory: false, isSymlink: false, size: 10, modified: Date()
        )
        // Порожній запит — усе проходить.
        XCTAssertTrue(entry.matches(query: ""))
        // Регістронезалежність, у т.ч. для кирилиці.
        XCTAssertTrue(entry.matches(query: "фото"))
        XCTAssertTrue(entry.matches(query: "ВІДПУСТКИ"))
        XCTAssertTrue(entry.matches(query: ".jpg"))
        XCTAssertFalse(entry.matches(query: "відео"))
    }

    // MARK: - 2.4: adb track-devices frame parser

    private static func trackFrame(_ payload: String) -> String {
        String(format: "%04x", payload.utf8.count) + payload
    }

    func testParseTrackDevicesFrames() {
        // 2 кадри в одному чанку: перший — один пристрій, другий — порожній payload
        // (0 пристроїв, напр. відключення).
        let readyPayload = "MOCK001\tdevice\n"
        let combined = Self.trackFrame(readyPayload) + Self.trackFrame("")
        let (frames, remainder) = ADBClient.parseTrackDevicesFrames(buffer: Data(combined.utf8))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].map(\.serial), ["MOCK001"])
        XCTAssertEqual(frames[0].first?.state, .ready)
        XCTAssertEqual(frames[1], [])
        XCTAssertTrue(remainder.isEmpty)

        // Кадр розрізаний між чанками: перший чанк несе повний перший кадр + лише 2 з 4
        // hex-символів довжини другого — парсер мусить віддати рівно 1 кадр і лишити
        // непочатий хвіст (2 байти) для приліплення до наступного чанку.
        let unauthorizedPayload = "SERIAL2\tunauthorized\n"
        let full = Array((Self.trackFrame(readyPayload) + Self.trackFrame(unauthorizedPayload)).utf8)
        let splitPoint = 4 + readyPayload.utf8.count + 2
        let firstChunk = Data(full[0..<splitPoint])
        let (framesA, remainderA) = ADBClient.parseTrackDevicesFrames(buffer: firstChunk)
        XCTAssertEqual(framesA.count, 1)
        XCTAssertEqual(framesA[0].map(\.serial), ["MOCK001"])
        XCTAssertEqual(remainderA.count, 2)

        let secondChunk = remainderA + Data(full[splitPoint...])
        let (framesB, remainderB) = ADBClient.parseTrackDevicesFrames(buffer: secondChunk)
        XCTAssertEqual(framesB.count, 1)
        XCTAssertEqual(framesB[0].map(\.serial), ["SERIAL2"])
        XCTAssertEqual(framesB[0].first?.state, .unauthorized)
        XCTAssertTrue(remainderB.isEmpty)
    }

    /// 2.4-фікс: сміття (не-hex байти) перед валідним кадром більше не блокує розбір навічно —
    /// парсер відкидає його по байту і резинхронізується на початок реального кадру.
    func testParseTrackDevicesFramesResyncsPastGarbagePrefix() {
        let payload = "MOCK001\tdevice\n"
        var buffer = Data("!!!!!!!!".utf8) // 8 невалідних (не-hex) байтів перед кадром
        buffer.append(Data(Self.trackFrame(payload).utf8))
        let (frames, remainder) = ADBClient.parseTrackDevicesFrames(buffer: buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].map(\.serial), ["MOCK001"])
        XCTAssertEqual(frames[0].first?.state, .ready)
        XCTAssertTrue(remainder.isEmpty)
    }

    /// 2.4-фікс: запобіжник на >64 КБ буфера, з якого не вдалось розібрати ЖОДНОГО кадру —
    /// вигаданий, але валідний на вигляд hex-префікс ("ffff" = 65535), що заявляє кадр,
    /// більший за все, що прийшло: без запобіжника ресинхронізація не допомогла б (префікс
    /// формально валідний, кадр просто "розрізаний між чанками" — `break`, не `continue`), і
    /// буфер ріс би вічно, чекаючи payload, що ніколи повністю не прийде.
    func testParseTrackDevicesFramesClearsHugeUnresolvedBuffer() {
        var buffer = Data("ffff".utf8)
        buffer.append(Data(repeating: 0x41, count: 65_534)) // 'A' — будь-який наповнювач
        XCTAssertGreaterThan(buffer.count, 64 * 1024)
        let (frames, remainder) = ADBClient.parseTrackDevicesFrames(buffer: buffer)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(remainder.isEmpty, "буфер >64 КБ без жодного розібраного кадру мав очиститись")
    }

    func testParseStorageInfo() {
        // available_blocks|total_blocks|block_size → байти.
        let info = ADBClient.parseStorageInfo("123456|987654|4096")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.availableBytes, 123_456 * 4096)
        XCTAssertEqual(info?.totalBytes, 987_654 * 4096)
        XCTAssertTrue((info?.availableBytes ?? 0) <= (info?.totalBytes ?? 0))

        XCTAssertNil(ADBClient.parseStorageInfo("мусор без роздільників"))
        XCTAssertNil(ADBClient.parseStorageInfo(""))
        XCTAssertNil(ADBClient.parseStorageInfo("1|2"))
        XCTAssertNil(ADBClient.parseStorageInfo("1|2|0"))
        XCTAssertNil(ADBClient.parseStorageInfo("a|b|c"))
    }

    func testCollisionFreeURL() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("am-collision-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = TransferEngine.collisionFreeURL(for: "фото.jpg", in: dir, fileManager: fm)
        XCTAssertEqual(first.lastPathComponent, "фото.jpg")
        fm.createFile(atPath: first.path, contents: Data("x".utf8))

        let second = TransferEngine.collisionFreeURL(for: "фото.jpg", in: dir, fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "фото (1).jpg")
        fm.createFile(atPath: second.path, contents: Data("y".utf8))

        let third = TransferEngine.collisionFreeURL(for: "фото.jpg", in: dir, fileManager: fm)
        XCTAssertEqual(third.lastPathComponent, "фото (2).jpg")

        let noExt = TransferEngine.collisionFreeURL(for: "тека", in: dir, fileManager: fm)
        XCTAssertEqual(noExt.lastPathComponent, "тека")
        try fm.createDirectory(at: noExt, withIntermediateDirectories: true)
        let noExt2 = TransferEngine.collisionFreeURL(for: "тека", in: dir, fileManager: fm)
        XCTAssertEqual(noExt2.lastPathComponent, "тека (1)")
    }

    // MARK: - 1.3: попередження про збій виставлення дати створення

    func testDateWarningMessage() {
        XCTAssertNil(TransferEngine.dateWarning(failures: 0))
        XCTAssertEqual(
            TransferEngine.dateWarning(failures: 1),
            "Не вдалося виставити дату створення для 1 файлів — вміст скопійовано."
        )
        XCTAssertEqual(
            TransferEngine.dateWarning(failures: 5),
            "Не вдалося виставити дату створення для 5 файлів — вміст скопійовано."
        )
    }

    // MARK: - 1.7: round-trip shellQuote через реальний /bin/sh

    /// Для 30 "ворожих" імен (той самий генератор, що EngineTests.testFuzzNamesRoundTrip...)
    /// `sh -c "printf '%s' <shellQuote(name)>"` мусить надрукувати ім'я побайтово незмінним —
    /// доказ, що RemotePath.shellQuote справді безпечний для реального POSIX shell, а не лише
    /// для власного парсера mock_adb.py.
    func testShellQuoteRoundTripThroughSh() async throws {
        let names = FuzzNames.batch(count: 30, seed: 0xC0FF_EE42)
        for name in names {
            let quoted = RemotePath.shellQuote(name)
            let result = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' \(quoted)"]
            )
            XCTAssertEqual(result.exitCode, 0, "sh провалився для: \(name)")
            XCTAssertEqual(
                Array(result.out.utf8), Array(name.utf8),
                "round-trip через sh провалився для: \(name)"
            )
        }
    }

    /// v0.10.3: перевірка вільного місця не має падати на томах, де ImportantUsage = 0
    /// (exFAT/NTFS/SMB — реальний кейс власника: зовнішній exFAT з 200 ГБ вільного місця
    /// давав «вільно 0 B» і відмову ще до старту). Хелпер віддає позитивне число для будь-якого
    /// живого тому і ніколи не трактує 0 як «диск повний».
    func testAvailableCapacityIsPositiveForTemporaryDirectory() {
        let capacity = TransferEngine.availableCapacity(at: FileManager.default.temporaryDirectory)
        XCTAssertNotNil(capacity)
        XCTAssertGreaterThan(capacity ?? 0, 0)
        XCTAssertNil(TransferEngine.availableCapacity(at: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }


    func testParseMD5SumsHandlesSpacesPipesAndBinaryMarker() {
        let out = """
        d41d8cd98f00b204e9800998ecf8427e  /sdcard/DCIM/Фото відпустки/IMG 0001.jpg
        9E107D9D372BB6826BD81D3542A419D6 */sdcard/Download/x|y.bin
        сміття без хешу
        """
        let map = ADBClient.parseMD5Sums(out)
        XCTAssertEqual(map["/sdcard/DCIM/Фото відпустки/IMG 0001.jpg"], "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(map["/sdcard/Download/x|y.bin"], "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(map.count, 2)
    }

}
