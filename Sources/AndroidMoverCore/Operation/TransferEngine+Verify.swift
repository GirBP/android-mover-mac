import Foundation
import CryptoKit

/// Коли звіряти md5 копії з телефоном. `beforeDelete` — лише коли джерело буде видалене
/// («Перемістити»): це єдина незворотна дія, і перевірка за розміром там недостатня.
/// `always` — і для копіювання (повільніше: телефон хешує ~50–200 МБ/с).
public enum ChecksumPolicy: String, Sendable, CaseIterable {
    case never
    case beforeDelete
    case always
}

/// Доказ, що саме ці файли пройшли перевірку проти телефона (кількість і розміри, а за
/// політикою — і md5). Конструюється лише `TransferEngine.verify` (private init) — і це
/// єдиний вхід для видалення джерела після переміщення (`deleteVerifiedTree`). Список, за яким
/// видаляють, не може розійтися зі списком, який перевіряли.
public struct VerifiedManifest: Sendable {
    public let files: [RemoteFileRecord]
    public let checksumVerified: Bool
    public let verifiedAt: Date
    fileprivate init(files: [RemoteFileRecord], checksumVerified: Bool, verifiedAt: Date) {
        self.files = files
        self.checksumVerified = checksumVerified
        self.verifiedAt = verifiedAt
    }
}

/// Верифікація (кількість+розміри збігаються з телефоном), дати, розв'язання колізій імен —
/// переважно статичні допоміжні функції, використовувані і ядром (TransferEngine.swift), і
/// докачкою (TransferEngine+Resume.swift), і PushEngine (дзеркальна push-верифікація).
extension TransferEngine {
    // MARK: - Допоміжні

    /// Чи виправдовує ця помилка цикл докачки (waitForDevice → resumeMissing)? Лише
    /// ADBError — pull/verify/timeout/commandFailed/pullProducedNothing тощо — означає, що
    /// причина в зв'язку з телефоном і джерело там ціле, тож варто почекати й спробувати ще.
    /// .cancelled виключено окремо: це наш власний сигнал скасування, не привід ретраяти.
    /// Будь-яка не-ADBError помилка (напр. CocoaError від FileManager.moveItem — колізія
    /// імені, брак прав на диску Mac) — локальна і ретраєм не лікується.
    static func isResumable(_ error: Error) -> Bool {
        guard let adbError = error as? ADBError else { return false }
        switch adbError {
        case .cancelled, .remoteMissing, .unsafeDeletePath, .unsafePushTarget, .destinationNotWritable, .notEnoughDiskSpace, .notEnoughSpaceOnDevice, .wirelessFailed:
            return false
        case .commandFailed(_, _, let stderr) where isNoSpaceLeft(stderr: stderr):
            // ENOSPC на телефоні не лікується очікуванням пристрою — без цього push у повний
            // телефон крутив би 15 марних спроб.
            return false
        default:
            return true
        }
    }

    /// «No space left on device» / ENOSPC у stderr adb — невідновлювана помилка.
    public static func isNoSpaceLeft(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("no space left") || lower.contains("enospc")
    }

    /// Людське повідомлення про частковий провал виставлення дати створення — файли на
    /// місці, страждає лише мітка "дата створення" у Finder. `failures: 0` (типовий випадок) → nil.
    static func dateWarning(failures: Int) -> String? {
        guard failures > 0 else { return nil }
        return "Не вдалося виставити дату створення для \(failures) файлів — вміст скопійовано."
    }

    /// З'єднує два опціональних попередження одним рядком через пробіл — використовується,
    /// коли і дата, і видалення після move провалились одночасно; nil-частини випадають мовчки.
    static func joinWarnings(_ first: String?, _ second: String?) -> String? {
        [first, second].compactMap { $0 }.joined(separator: " ").isEmpty
            ? nil
            : [first, second].compactMap { $0 }.joined(separator: " ")
    }

    /// Вільне місце на томі `url` або nil, якщо система не може сказати. Порядок:
    /// ImportantUsage (APFS, враховує purgeable) → звичайна доступна ємність (exFAT/NTFS/SMB,
    /// де ImportantUsage віддає 0/nil) → nil. Нуль трактуємо як «невідомо», не як «повний диск».
    static func availableCapacity(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let plain = values.volumeAvailableCapacity, plain > 0 { return Int64(plain) }
        return nil
    }

    /// Потоковий md5 локального файла (чанки 1 МБ — 8 ГБ відео не читається в пам'ять цілком).
    public static func md5Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Порівнює md5 кожного очікуваного файла з телефонним. Повертає сирі відносні шляхи
    /// (rawRelative) файлів, що не збіглись або для яких телефон не дав хеш (fail-closed:
    /// «не можу перевірити» = «не збігається»).
    static func checksumMismatches(
        remote: [String: String],
        expected: [RemoteFileRecord],
        remoteRoot: String,
        localRoot: URL
    ) -> [String] {
        var mismatched: [String] = []
        for record in expected {
            let rawRelative = relativePath(of: record.path, under: remoteRoot)
            let localURL = rawRelative.isEmpty ? localRoot : localRoot.appendingPathComponent(rawRelative)
            guard let remoteHash = remote[record.path],
                  let localHash = try? md5Hex(of: localURL),
                  remoteHash == localHash
            else {
                mismatched.append(rawRelative)
                continue
            }
        }
        return mismatched
    }

    static func directorySize(at url: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        } else if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
            total = size
        }
        return total
    }

    /// Відносний шлях запису телефона щодо кореня елемента ("" — сам корінь).
    static func relativePath(of remotePath: String, under remoteRoot: String) -> String {
        let full = RemotePath.normalized(remotePath)
        let root = RemotePath.normalized(remoteRoot)
        if full == root { return "" }
        if full.hasPrefix(root + "/") { return String(full.dropFirst(root.count + 1)) }
        return full
    }

    /// Виставляє текам mtime і creationDate з дат, знятих із телефона. Повертає кількість збоїв.
    static func restoreDirectoryDates(
        records: [(path: String, modified: Date)],
        remoteRoot: String,
        localRoot: URL,
        fileManager: FileManager
    ) -> Int {
        var failures = 0
        for record in records {
            let relative = relativePath(of: record.path, under: remoteRoot)
            let url = relative.isEmpty ? localRoot : localRoot.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            do {
                try fileManager.setAttributes(
                    [.modificationDate: record.modified, .creationDate: record.modified],
                    ofItemAtPath: url.path
                )
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// Для кожного файла і теки: creationDate = modificationDate. Повертає кількість збоїв.
    static func setCreationDatesToModificationDates(root: URL, fileManager: FileManager) -> Int {
        var failures = 0
        var urls: [URL] = [root]
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator { urls.append(url) }
        }
        for url in urls {
            do {
                let attrs = try fileManager.attributesOfItem(atPath: url.path)
                guard let modified = attrs[.modificationDate] as? Date else { continue }
                try fileManager.setAttributes([.creationDate: modified], ofItemAtPath: url.path)
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// Порівнює те, що прийшло, з тим, що було на телефоні: кількість файлів і розмір кожного.
    /// Повертає `VerifiedManifest` — єдине джерело для видалення після move.
    @discardableResult
    static func verify(expected: [RemoteFileRecord], remoteRoot: String, localRoot: URL, fileManager: FileManager) throws -> VerifiedManifest {
        var expectedMap: [String: Int64] = [:]
        for record in expected {
            let relative = relativePath(of: record.path, under: remoteRoot)
            expectedMap[relative.precomposedStringWithCanonicalMapping] = record.size
        }
        let localMap = localFileMap(root: localRoot, fileManager: fileManager)
        if let mismatch = diff(expected: expectedMap, actual: localMap) {
            throw ADBError.verificationFailed(pullMismatchMessage(mismatch))
        }
        return VerifiedManifest(files: expected, checksumVerified: false, verifiedAt: Date())
    }

    /// Той самий маніфест, але після успішної md5-звірки (лише цей файл може його «підняти»).
    static func withChecksumsVerified(_ manifest: VerifiedManifest) -> VerifiedManifest {
        VerifiedManifest(files: manifest.files, checksumVerified: true, verifiedAt: Date())
    }

    /// Локальна мапа "відносний шлях (unicode-нормалізований) → розмір" під коренем елемента —
    /// той самий обхід, що verify() використовує інлайново; resumeMissing реюзить його,
    /// щоб порахувати, чого саме бракує, без дублювання правил нормалізації.
    static func localFileMap(root: URL, fileManager: FileManager) -> [String: Int64] {
        var localMap: [String: Int64] = [:]
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            if let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            ) {
                let prefix = root.standardizedFileURL.path + "/"
                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true else { continue }
                    let path = fileURL.standardizedFileURL.path
                    let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
                    localMap[relative.precomposedStringWithCanonicalMapping] = Int64(values.fileSize ?? 0)
                }
            }
        } else {
            let size = (try? fileManager.attributesOfItem(atPath: root.path))?[.size] as? Int64 ?? -1
            localMap[""] = size
        }
        return localMap
    }

    /// Розбіжність між очікуваною мапою (відносний шлях → розмір) і фактичною —
    /// напрямково-нейтрально (жодного слова про "телефон"/"копію"/"Mac"). Використовується і
    /// pull-верифікацією (verify(), вище — джерело "очікуване" з телефона), і push-верифікацією
    /// (PushEngine — джерело "очікуване" з Mac); кожен рушій сам форматує повідомлення своїми
    /// словами (напрямок протилежний).
    enum VerifyMismatch {
        case count(expected: Int, actual: Int)
        case missing(String)
        case sizeMismatch(path: String, expected: Int64, actual: Int64)
    }

    static func diff(expected: [String: Int64], actual: [String: Int64]) -> VerifyMismatch? {
        guard expected.count == actual.count else {
            return .count(expected: expected.count, actual: actual.count)
        }
        for (relative, size) in expected {
            guard let actualSize = actual[relative] else { return .missing(relative) }
            guard actualSize == size else {
                return .sizeMismatch(path: relative, expected: size, actual: actualSize)
            }
        }
        return nil
    }

    private static func pullMismatchMessage(_ mismatch: VerifyMismatch) -> String {
        switch mismatch {
        case .count(let expected, let actual):
            return "Очікувалось файлів: \(expected), скопійовано: \(actual)."
        case .missing(let path):
            return "Файл «\(path)» не знайдено в копії."
        case .sizeMismatch(let path, let expected, let actual):
            return "Розмір «\(path)» не збігається: на телефоні \(expected) Б, у копії \(actual) Б."
        }
    }

    /// Кандидат імені при N-й спробі розв'язати колізію: 0 → саме ім'я, 1 → «name (1).ext»,
    /// 2 → «name (2).ext»… Спільний генератор для локального collisionFreeURL (pull, нижче) і
    /// remote-аналога PushEngine.remoteCollisionFreeName (push, async — існування перевіряється
    /// на телефоні, а не у FileManager).
    static func collisionCandidateName(for name: String, attempt: Int) -> String {
        guard attempt > 0 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) (\(attempt))" : "\(stem) (\(attempt)).\(ext)"
    }

    /// «name.ext» → «name (1).ext», «name (2).ext»… доки не звільниться.
    static func collisionFreeURL(for name: String, in directory: URL, fileManager: FileManager) -> URL {
        var attempt = 0
        while true {
            let candidate = directory.appendingPathComponent(collisionCandidateName(for: name, attempt: attempt))
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }
}
