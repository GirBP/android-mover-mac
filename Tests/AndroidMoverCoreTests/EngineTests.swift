import Foundation
import XCTest
@testable import AndroidMoverCore

/// Інтеграційні тести движка через scripts/mock_adb.py — той самий контракт команд, що й у реального adb.
///
/// Той самий набір тестів ганяється на двох бекендах:
///   AM_TEST_ADB=mock swift test   (default, CI) — весь "телефон" — тека на Mac.
///   AM_TEST_ADB=real swift test   (ручний прогін, потрібен ADB_PATH + AM_DEVICE_SERIAL) —
///     корінь тестових даних — /sdcard/AndroidMoverE2E/<uuid> на реальному пристрої.
/// Тести з mock-специфічними ручками (MOCK_CORRUPT_*, MOCK_FAIL_*) самі собі кажуть XCTSkip
/// у real-режимі — на реальному adb немає способу підмінити цю поведінку.

/// Детермінований генератор "ворожих" імен файлів — кирилиця, латиниця, цифри, пробіл
/// (у т.ч. на краях), лапки/апостроф/бектик, shell-метасимволи (`$()`&;|`), емодзі (у т.ч.
/// складені) і комбінуючий знак U+0306 — без "/" і "\n", ніколи "." чи "..". Власний LCG
/// (не System random) означає, що той самий seed завжди дає ту саму послідовність — тест
/// відтворюваний між прогонами й машинами. Спільний для EngineTests (round-trip через mock
/// listDirectory/rename/delete) і ParserTests (round-trip через реальний `sh`).
enum FuzzNames {
    /// Лінійний конгруентний генератор (Numerical Recipes-параметри) — детермінований,
    /// без залежності від System-генератора рандому.
    struct LCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            return state
        }
        mutating func nextInt(_ upperBound: Int) -> Int {
            Int(next() % UInt64(upperBound))
        }
    }

    static let alphabet: [String] = {
        var units: [String] = []
        // Кирилиця включно з Й/й (0x0419/0x0439): `Foundation.Process` на Darwin мовчки
        // NFD-декомпонує канонічно-композиційні символи в аргументах дочірнього процесу
        // (підтверджено ізольовано: Process(arguments: ["Й"]) дитина бачить "И"+U+0306 замість
        // "Й") — ProcessRunner натомість іде через posix_spawn з байт-у-байт C-рядками
        // (ProcessRunner.byteExactCString), без жодного fileSystemRepresentation, тож без
        // жодної декомпозиції; ProcessRunnerTests.testArgumentsArePassedByteExact/
        // testEnvironmentIsPassedByteExact перевіряють це напряму. Й/й тут — рівноправна
        // частина алфавіту, той самий фазз-тест — регресійна перевірка крізь увесь конвеєр
        // (listDirectory/rename/delete).
        for scalar in UInt32(0x0410)...UInt32(0x044F) {
            units.append(String(UnicodeScalar(scalar)!))
        }
        for scalar in UInt32(0x0041)...UInt32(0x005A) { units.append(String(UnicodeScalar(scalar)!)) } // A-Z
        for scalar in UInt32(0x0061)...UInt32(0x007A) { units.append(String(UnicodeScalar(scalar)!)) } // a-z
        for d in 0...9 { units.append(String(d)) }
        units.append(contentsOf: [" ", "|", "'", "\"", "`", "$", "(", ")", "&", ";"])
        units.append(contentsOf: ["😀", "🔥", "👍🏽", "🇺🇦"]) // прості й складені (grapheme-кластер) емодзі
        units.append("\u{0306}") // комбінуючий знак (U+0306 COMBINING BREVE)
        // Інші канонічно-композиційні символи поза основним кириличним блоком 0x0410–0x044F —
        // той самий клас ризику, що й Й/й вище: ї/Ї (українська) і é/ü (латиниця з діакритикою).
        units.append(contentsOf: ["\u{0457}", "\u{0407}", "\u{00E9}", "\u{00FC}"]) // ї Ї é ü
        return units
    }()

    /// Випадкове ім'я довжиною 1...120 елементів алфавіту, без "/", "\n", не "." чи "..".
    static func random(_ rng: inout LCG) -> String {
        while true {
            let length = 1 + rng.nextInt(120)
            var name = ""
            for _ in 0..<length { name += alphabet[rng.nextInt(alphabet.count)] }
            if name.contains("/") || name.contains("\n") { continue }
            if name == "." || name == ".." || name.isEmpty { continue }
            return name
        }
    }

    /// `count` унікальних імен: спершу гарантовані "крайні" випадки (пробіли на краях,
    /// комбінуючий знак спочатку, усі shell-метасимволи разом, емодзі), потім LCG-заповнення
    /// до потрібної кількості — детерміновано за `seed`.
    static func batch(count: Int, seed: UInt64) -> [String] {
        var rng = LCG(seed: seed)
        var names: [String] = [
            " пробіл спочатку.txt",
            "пробіл в кінці ",
            "\u{0306}комбінуюча позиція",
            "лапки'і\"апострофи`бектик",
            "$(ін'єкція); та амперсанд & pipe|",
            "емодзі🔥та🇺🇦прапор",
        ]
        var seen = Set(names)
        while names.count < count {
            let name = random(&rng)
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
        }
        return Array(names.prefix(count))
    }
}

final class EngineTests: XCTestCase {
    var phoneRoot: URL!        // mock-режим: Mac-тека, що вдає корінь "телефона". nil у real.
    var destination: URL!      // Mac-тека призначення — завжди реальний диск, в обох бекендах.
    var pushSource: URL!       // Mac-тека з локальними файлами-джерелами для push-тестів (B1).
    var remoteRoot: String!    // корінь фікстур на "телефоні": "/sdcard" (mock) або
                                // "/sdcard/AndroidMoverE2E/<uuid>" (real).
    var localBase: URL!        // батьківська Mac-тека для phoneRoot/destination/pushSource — прибирається в tearDown.
    var client: ADBClient!
    var serial = "MOCK001"
    let fm = FileManager.default

    // Фіксовані дати (епохи в секундах) для перевірки збереження.
    let photoDate = Date(timeIntervalSince1970: 1_579_084_245)   // 2020-01-15 10:30:45 UTC
    let videoDate = Date(timeIntervalSince1970: 1_559_390_400)   // 2019-06-01 12:00:00 UTC
    let textDate = Date(timeIntervalSince1970: 1_614_740_583)    // 2021-03-03 03:03:03 UTC
    let loneDate = Date(timeIntervalSince1970: 1_500_000_000)
    let vacationDirDate = Date(timeIntervalSince1970: 1_580_000_000) // дата самої теки

    /// mock (default) чи real — обирається через env AM_TEST_ADB (0.6).
    static var backend: String {
        ProcessInfo.processInfo.environment["AM_TEST_ADB"] ?? "mock"
    }

    static var mockADBPath: String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDir
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("scripts/mock_adb.py").path
    }

    // MARK: - Налаштування (mock/real)

    override func setUp() async throws {
        try await super.setUp()
        if Self.backend == "real" {
            try await setUpReal()
        } else {
            try setUpMock()
        }
    }

    override func tearDown() async throws {
        if Self.backend == "real", let client, let remoteRoot {
            try? await client.delete(remoteRoot, on: serial)
        }
        if let localBase {
            try? fm.removeItem(at: localBase)
        }
        try await super.tearDown()
    }

    func setUpMock() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.mockADBPath)
        let base = fm.temporaryDirectory.appendingPathComponent("am-engine-\(UUID().uuidString)")
        localBase = base
        phoneRoot = base.appendingPathComponent("phone")
        destination = base.appendingPathComponent("dest")
        pushSource = base.appendingPathComponent("push-source")
        remoteRoot = "/sdcard"
        serial = "MOCK001"
        try fm.createDirectory(at: phoneRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: pushSource, withIntermediateDirectories: true)
        client = ADBClient(adbPath: Self.mockADBPath, extraEnvironment: ["MOCK_PHONE_ROOT": phoneRoot.path])

        // /sdcard/DCIM/Фото відпустки/{IMG_0001.jpg, відео кліп.mp4}
        // /sdcard/DCIM/o'clock файл.txt
        // /sdcard/Download/самотній.bin
        let vacation = phoneRoot.appendingPathComponent("DCIM/Фото відпустки")
        try fm.createDirectory(at: vacation, withIntermediateDirectories: true)
        try makeFile(vacation.appendingPathComponent("IMG_0001.jpg"),
                     data: Data(repeating: 0x41, count: 1000), date: photoDate)
        try makeFile(vacation.appendingPathComponent("відео кліп.mp4"),
                     data: Data(repeating: 0x42, count: 2048), date: videoDate)
        try makeFile(phoneRoot.appendingPathComponent("DCIM/o'clock файл.txt"),
                     data: Data("hello there".utf8), date: textDate)
        let download = phoneRoot.appendingPathComponent("Download")
        try fm.createDirectory(at: download, withIntermediateDirectories: true)
        try makeFile(download.appendingPathComponent("самотній.bin"),
                     data: Data("12345".utf8), date: loneDate)
        // Дату теки виставляємо після створення файлів у ній (запис оновлює mtime теки).
        try fm.setAttributes([.modificationDate: vacationDirDate], ofItemAtPath: vacation.path)
    }

    /// Той самий набір фікстур, що й mock, але заливається через client.push із локальної
    /// тимчасової теки (0.6) — а не прямим записом на MOCK_PHONE_ROOT, якого в real-режимі нема.
    func setUpReal() async throws {
        guard let adbPath = ProcessInfo.processInfo.environment["ADB_PATH"], !adbPath.isEmpty else {
            throw XCTSkip("AM_TEST_ADB=real потребує ADB_PATH")
        }
        guard let realSerial = ProcessInfo.processInfo.environment["AM_DEVICE_SERIAL"], !realSerial.isEmpty else {
            throw XCTSkip("AM_TEST_ADB=real потребує AM_DEVICE_SERIAL")
        }
        serial = realSerial
        client = ADBClient(adbPath: adbPath)
        remoteRoot = "/sdcard/AndroidMoverE2E/\(UUID().uuidString)"
        try await client.makeDirectory(remoteRoot, on: serial)

        let base = fm.temporaryDirectory.appendingPathComponent("am-engine-\(UUID().uuidString)")
        localBase = base
        destination = base.appendingPathComponent("dest")
        pushSource = base.appendingPathComponent("push-source")
        let fixtureSource = base.appendingPathComponent("fixture-source")
        phoneRoot = nil // немає локального диска "телефона" у real-режимі.
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: pushSource, withIntermediateDirectories: true)
        try fm.createDirectory(at: fixtureSource, withIntermediateDirectories: true)

        try await client.makeDirectory(RemotePath.join(remoteRoot, "DCIM"), on: serial)
        let vacationLocal = fixtureSource.appendingPathComponent("Фото відпустки")
        try fm.createDirectory(at: vacationLocal, withIntermediateDirectories: true)
        try makeFile(vacationLocal.appendingPathComponent("IMG_0001.jpg"),
                     data: Data(repeating: 0x41, count: 1000), date: photoDate)
        try makeFile(vacationLocal.appendingPathComponent("відео кліп.mp4"),
                     data: Data(repeating: 0x42, count: 2048), date: videoDate)
        try fm.setAttributes([.modificationDate: vacationDirDate], ofItemAtPath: vacationLocal.path)
        try await client.push(vacationLocal, to: RemotePath.join(remoteRoot, "DCIM"), on: serial)

        let textLocal = fixtureSource.appendingPathComponent("o'clock файл.txt")
        try makeFile(textLocal, data: Data("hello there".utf8), date: textDate)
        try await client.push(textLocal, to: RemotePath.join(remoteRoot, "DCIM"), on: serial)

        try await client.makeDirectory(RemotePath.join(remoteRoot, "Download"), on: serial)
        let loneLocal = fixtureSource.appendingPathComponent("самотній.bin")
        try makeFile(loneLocal, data: Data("12345".utf8), date: loneDate)
        try await client.push(loneLocal, to: RemotePath.join(remoteRoot, "Download"), on: serial)
    }

    func makeFile(_ url: URL, data: Data, date: Date) throws {
        try data.write(to: url)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Створює файл із рівно такими байтами імені, як передано в `name` — на відміну від
    /// `Data.write(to: URL)` (і будь-якого шляху через `URL`/`FileManager`), який на Darwin
    /// іде через `CFStringGetFileSystemRepresentation` і мовчки NFD-декомпонує деякі символи
    /// (напр. "й" → "и" + U+0306) — артефакт сумісності з HFS+, якого нема на реальному ext4
    /// телефона. Пряме POSIX open/write/close обходить цей шар — так само поводиться і
    /// mock_adb.py (Python os.listdir), і реальний Android: фікстура і те, що дійсно "лежить
    /// на диску", — побайтово те саме.
    func writeRawFixture(in directory: URL, name: String, data: Data) throws {
        let path = directory.path + "/" + name
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open failed for \(name): \(String(cString: strerror(errno)))"])
        }
        defer { close(fd) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                  userInfo: [NSLocalizedDescriptionKey: "write failed for \(name)"])
                }
                offset += n
            }
        }
    }

    func makeClient(extraEnv: [String: String] = [:]) -> ADBClient {
        if Self.backend == "real" {
            // real: extraEnv — це виключно mock-ручки (MOCK_CORRUPT_*, MOCK_FAIL_*), яких на
            // реальному adb не існує; тести, що їх просять, самі роблять XCTSkip до цього виклику.
            return client
        }
        var env = ["MOCK_PHONE_ROOT": phoneRoot.path]
        env.merge(extraEnv) { _, new in new }
        return ADBClient(adbPath: Self.mockADBPath, extraEnvironment: env)
    }

    func mtimeEpoch(_ url: URL) throws -> Int {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return Int((attrs[.modificationDate] as! Date).timeIntervalSince1970)
    }

    func creationEpoch(_ url: URL) throws -> Int {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return Int((attrs[.creationDate] as! Date).timeIntervalSince1970)
    }

    // MARK: - Хелпери "прочитати з телефона" (0.6): та сама перевірка на обох бекендах —
    // mock читає MOCK_PHONE_ROOT напряму з диска (як і раніше), real іде через
    // client.remoteExists/pull/listDirectory/statMTimes. Жодного `if backend == real` у тілі тесту.

    /// Існування файлу/теки на "телефоні" за шляхом відносно remoteRoot.
    func remoteFileExists(_ relativePath: String) async throws -> Bool {
        if Self.backend == "real" {
            return try await client.remoteExists(RemotePath.join(remoteRoot, relativePath), on: serial)
        }
        return fm.fileExists(atPath: phoneRoot.appendingPathComponent(relativePath).path)
    }

    /// Вміст файлу на "телефоні" (real: pull у tmp і прочитати звідти).
    func remoteData(_ relativePath: String) async throws -> Data {
        if Self.backend == "real" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("am-pull-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let full = RemotePath.join(remoteRoot, relativePath)
            try await client.pull(full, into: tmp, on: serial)
            let pulled = tmp.appendingPathComponent(RemotePath.baseName(full))
            return try Data(contentsOf: pulled)
        }
        return try Data(contentsOf: phoneRoot.appendingPathComponent(relativePath))
    }

    /// mtime файлу/теки на "телефоні" (real: через statMTimes, той самий шлях, яким best-effort
    /// звірка дат push користується всередині рушія).
    func remoteMTimeEpoch(_ relativePath: String) async throws -> Int {
        if Self.backend == "real" {
            let full = RemotePath.join(remoteRoot, relativePath)
            let mtimes = try await client.statMTimes(full, on: serial)
            guard let date = mtimes[full] else { throw ADBError.notADirectory(full) }
            return Int(date.timeIntervalSince1970)
        }
        return try mtimeEpoch(phoneRoot.appendingPathComponent(relativePath))
    }

    /// Імена тимчасових `.androidmover-tmp-*`, що лишились у теці на "телефоні" (мають бути
    /// прибрані рушієм після успіху чи провалу — перевіряється в кінці майже кожного B0/B1 тесту).
    func remoteTmpLeftovers(_ relativeDir: String) async throws -> [String] {
        if Self.backend == "real" {
            let entries = try await client.listDirectory(RemotePath.join(remoteRoot, relativeDir), on: serial)
            return entries.map(\.name).filter { $0.hasPrefix(".androidmover-tmp") }
        }
        return try fm.contentsOfDirectory(atPath: phoneRoot.appendingPathComponent(relativeDir).path)
            .filter { $0.hasPrefix(".androidmover-tmp") }
    }

    /// Додає файл-фікстуру на "телефон" посеред тесту (після setUp): mock — прямий запис на
    /// диск, real — push через тимчасову локальну теку (client.push, не прямий запис у
    /// MOCK_PHONE_ROOT).
    func addRemoteFile(_ relativePath: String, data: Data, date: Date) async throws {
        if Self.backend == "real" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("am-fixture-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let name = RemotePath.baseName(relativePath)
            let localFile = tmp.appendingPathComponent(name)
            try makeFile(localFile, data: data, date: date)
            let remoteDir = RemotePath.parent(RemotePath.join(remoteRoot, relativePath))
            try await client.push(localFile, to: remoteDir, on: serial)
        } else {
            try makeFile(phoneRoot.appendingPathComponent(relativePath), data: data, date: date)
        }
    }

    // MARK: - B2-хелпери: файл стану mock-лічильників, файл-лог викликів (mock-only)

    /// Унікальний файл стану для MOCK_PULL_FAIL_COUNT/MOCK_CORRUPT_PULL_COUNT — кожен тест
    /// свій, інакше паралельні тести намотали б лічильники один одному.
    func makeMockStateFile() -> URL {
        localBase.appendingPathComponent("mock-state-\(UUID().uuidString).txt")
    }

    func makeMockLogFile() -> URL {
        localBase.appendingPathComponent("mock-log-\(UUID().uuidString).txt")
    }

    /// Розбирає MOCK_LOG_FILE (по рядку — JSON-масив argv одного виклику mock) і повертає
    /// REMOTE-шлях кожного pull-виклику (`adb -s SERIAL pull -a REMOTE LOCALDIR`), у порядку.
    func pullCallRemotePaths(logFile: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: logFile) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var paths: [String] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: lineData) as? [String],
                  array.count >= 5, array[0] == "-s", array[2] == "pull", array[3] == "-a"
            else { continue }
            paths.append(array[4])
        }
        return paths
    }
}

/// Локальний потокобезпечний колектор кадрів `ADBClient.trackDevices` — той самий патерн, що
/// ProgressCollector нижче, для тестів track-devices (2.4).
final class DeviceFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[ADBDevice]] = []
    private var capturedError: Error?

    func add(_ frame: [ADBDevice]) {
        lock.lock(); defer { lock.unlock() }
        frames.append(frame)
    }

    func recordError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        capturedError = error
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    var all: [[ADBDevice]] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return capturedError
    }
}

final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [TransferProgress] = []

    func add(_ p: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        all.append(p)
    }

    var last: TransferProgress? {
        lock.lock(); defer { lock.unlock() }
        return all.last
    }

    /// Усі фази, у порядку появи — перевіряє, що цикл докачки справді проходить через
    /// waitingForDevice/resuming, а не просто мовчки повторює pull.
    var phases: [TransferProgress.Phase] {
        lock.lock(); defer { lock.unlock() }
        return all.map(\.phase)
    }

}
