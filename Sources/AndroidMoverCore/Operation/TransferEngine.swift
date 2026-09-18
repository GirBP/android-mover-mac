import Foundation

/// Рушій перенесення: рахує → тягне (pull -a) → виставляє дати → верифікує → переміщує в
/// призначення → (для режиму «перемістити») видаляє з телефона ЛИШЕ після верифікації.
///
/// 2.8: клас розбито на 3 файли (жоден не мав перевищувати ~400 рядків), без зміни поведінки:
/// цей файл — ядро (`transfer`/`transferOne`); TransferEngine+Resume.swift — B2-докачка
/// (`pullWholeEntry`/`resumeMissing`/`finishAfterPull`/`sleepCancellably`); TransferEngine+
/// Verify.swift — верифікація/дати/колізії/статичні допоміжні (`verify`/`diff`/`localFileMap`/
/// `isResumable` тощо). `client`/`fileManager`/`cancellation` — internal (не private): Resume-
/// файл читає їх як методи-члени того самого типу з іншого файлу (Swift `private` — лише для
/// same-file extensions).
public final class TransferEngine: @unchecked Sendable {
    let client: ADBClient
    let fileManager = FileManager.default
    /// 2.2: спільний контролер скасування (SIGTERM→3с→SIGKILL, реєстрація процесу для cancel())
    /// — раніше тут окремо жили cancelFlag/currentProcess/trackProcess, дубльовані з PushEngine.
    let cancellation = CancellationController()
    /// B2: скільки разів пробувати докачати елемент після обриву pull/провалу verify,
    /// перш ніж чесно здатись (перша спроба — pull цілого елемента — у це число НЕ входить).
    let maxAttempts: Int
    /// B2: пауза між поверненням пристрою (wait-for-device) і докачкою — зростає зі спробою,
    /// щоб не бомбити щойно ожилий adb-сервер. Тести підставляють `{ _ in 0 }`.
    let retryDelay: @Sendable (Int) -> TimeInterval

    /// v0.11.0 (P1): коли звіряти md5 з телефоном. Зафіксовано в init; сам прапорець
    /// «потрібно в ЦІЙ операції» (`checksumRequired`) виставляється на старті transfer(),
    /// бо залежить від move.
    let checksumPolicy: ChecksumPolicy
    /// Виставляється РАЗ на старті transfer() до будь-якої конкурентності (engine — один на операцію).
    var checksumRequired = false

    /// v0.11.0 (P6): максимум спроб для ВЕРИФІКАЦІЙНИХ провалів (verify/md5) — 3: якщо
    /// файл тричі не збігся, справа не в кабелі. Транспортні обриви — до `maxAttempts`
    /// (за замовчуванням 15 × 120 с очікування ≈ 30 хв).
    static let verificationAttemptCap = 3

    public init(
        client: ADBClient,
        maxAttempts: Int = 15,
        retryDelay: @escaping @Sendable (Int) -> TimeInterval = { attempt in min(8, pow(2, Double(attempt))) },
        checksumPolicy: ChecksumPolicy = .beforeDelete
    ) {
        self.client = client
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
        self.checksumPolicy = checksumPolicy
    }

    /// Верифікаційна помилка (копія не збігається) на відміну від транспортної (обрив).
    static func isVerificationError(_ error: Error) -> Bool {
        guard let adbError = error as? ADBError else { return false }
        switch adbError {
        case .verificationFailed, .checksumMismatch, .pushVerificationFailed: return true
        default: return false
        }
    }

    public func cancel() {
        cancellation.cancel()
    }

    /// Виконує перенесення. Глобальні передумови кидають помилку; поелементні збої — в результатах.
    public func transfer(
        entries: [RemoteEntry],
        to destination: URL,
        serial: String,
        move: Bool,
        onProgress: @escaping @Sendable (TransferProgress) -> Void,
        onItemFinished: (@Sendable (TransferItemResult) -> Void)? = nil
    ) async throws -> [TransferItemResult] {
        var progress = TransferProgress()
        progress.itemsTotal = entries.count
        onProgress(progress)
        checksumRequired = checksumPolicy == .always || (checksumPolicy == .beforeDelete && move)

        guard fileManager.isWritableFile(atPath: destination.path) else {
            throw ADBError.destinationNotWritable(destination.path)
        }

        // 1. Підрахунок: рекурсивний перелік файлів (для прогресу і верифікації) та тек
        //    з датами (для відновлення після pull). Збій одного елемента не зриває решту.
        let (remoteFileMaps, remoteDirMaps, precountFailures) = await precountEntries(
            entries: entries, serial: serial, progress: &progress, onProgress: onProgress
        )
        if cancellation.isCancelled {
            progress.phase = .finished
            onProgress(progress)
            return entries.map {
                TransferItemResult(entry: $0, status: .cancelled, finalURL: nil, bytes: 0, warning: nil)
            }
        }

        // 2. Місце на диску (з запасом 256 МБ). v0.10.3: `volumeAvailableCapacityForImportantUsage`
        //    надійний лише на APFS — на exFAT/NTFS/мережевих томах (реальний кейс власника:
        //    зовнішній exFAT-диск) він повертає 0 чи nil, і перенесення падало ще до старту з
        //    «вільно 0 B». Тепер — fallback на звичайний volumeAvailableCapacity, а якщо і
        //    його нема — перевірку пропускаємо (краще спробувати, ніж хибно відмовити).
        if let available = Self.availableCapacity(at: destination),
           progress.bytesTotal + 256 * 1024 * 1024 > available {
            throw ADBError.notEnoughDiskSpace(needed: progress.bytesTotal, available: available)
        }

        // 3. Тимчасова тека на тому ж томі (щоб фінальне перейменування було атомарним).
        let tmpRoot = destination.appendingPathComponent(".androidmover-tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tmpRoot) }

        var results: [TransferItemResult] = []

        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if cancellation.isCancelled {
                results.append(TransferItemResult(entry: entry, status: .cancelled, finalURL: nil, bytes: 0, warning: nil))
                if let last = results.last { onItemFinished?(last) }
                index += 1
                continue
            }
            // v0.11.0 (P6): диск призначення зник посеред операції (від'єднали зовнішній диск) —
            // решту елементів чесно провалюємо одразу, без 15 спроб «докачки» в нікуди.
            var destinationIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory), destinationIsDirectory.boolValue else {
                let reason = ADBError.destinationNotWritable(destination.path).localizedDescription
                results.append(TransferItemResult(entry: entry, status: .failed(reason), finalURL: nil, bytes: 0, warning: nil))
                if let last = results.last { onItemFinished?(last) }
                index += 1
                continue
            }
            // v0.11.0 (P6): місце під ЦЕЙ елемент перевіряється перед його стартом (диск міг
            // заповнитись іншими програмами після стартової перевірки) — краще чесна відмова
            // до копіювання, ніж ENOSPC посеред файла і марні спроби докачки.
            if let entryFiles = remoteFileMaps[entry.path], precountFailures[entry.path] == nil {
                let needed = entryFiles.reduce(Int64(0)) { $0 + $1.size }
                if let available = Self.availableCapacity(at: destination), needed + 64 * 1024 * 1024 > available {
                    let reason = ADBError.notEnoughDiskSpace(needed: needed, available: available).localizedDescription
                    results.append(TransferItemResult(entry: entry, status: .failed(reason), finalURL: nil, bytes: 0, warning: nil))
                    index += 1
                    continue
                }
            }
            if let failure = precountFailures[entry.path] {
                results.append(TransferItemResult(
                    entry: entry, status: .failed(failure), finalURL: nil, bytes: 0, warning: nil
                ))
                if let last = results.last { onItemFinished?(last) }
                index += 1
                continue
            }
            // v0.10.2: пробіг із ≥2 плоских файлів поспіль — батчевий шлях (TransferEngine+Batch):
            // один `adb pull -a` на ≤batchSize файлів, один `rm` на батч; дати/verify/move —
            // поштучно, як і раніше.
            if Self.isPlainFile(entry) {
                var end = index
                while end < entries.count, end - index < ADBClient.batchSize,
                      Self.isPlainFile(entries[end]), precountFailures[entries[end].path] == nil {
                    end += 1
                }
                if end - index >= 2 {
                    let batch = Array(entries[index..<end])
                    let batchResults = await transferFileBatch(
                        entries: batch, firstIndex: index, tmpRoot: tmpRoot, destination: destination,
                        serial: serial, move: move, remoteFileMaps: remoteFileMaps,
                        progress: &progress, onProgress: onProgress
                    )
                    results.append(contentsOf: batchResults)
                    batchResults.forEach { onItemFinished?($0) }
                    index = end
                    continue
                }
            }
            progress.currentName = entry.name
            progress.phase = .pulling
            onProgress(progress)

            let expected = remoteFileMaps[entry.path] ?? []
            let dirRecords = remoteDirMaps[entry.path] ?? []
            let entryBytes = expected.reduce(0) { $0 + $1.size }

            if entry.isSymlink {
                results.append(TransferItemResult(
                    entry: entry, status: .failed("Символічні посилання не підтримуються."),
                    finalURL: nil, bytes: 0, warning: nil
                ))
                if let last = results.last { onItemFinished?(last) }
                index += 1
                continue
            }

            let result = await transferAndFinishEntry(
                entry: entry, expected: expected, dirRecords: dirRecords, tmpRoot: tmpRoot, index: index,
                destination: destination, serial: serial, move: move, entryBytes: entryBytes,
                progress: &progress, onProgress: onProgress
            )
            results.append(result)
            onItemFinished?(result)
            index += 1
        }

        progress.phase = .finished
        progress.currentName = ""
        onProgress(progress)
        return results
    }

    /// Крок 1: рекурсивний перелік файлів (для прогресу і верифікації) та тек з датами (для
    /// відновлення після pull) кожного елемента окремо — збій одного не зриває решту. Плоский
    /// файл (v0.10.2) бере розмір з уже наявного лістингу, без зайвого adb-виклику.
    private func precountEntries(
        entries: [RemoteEntry],
        serial: String,
        progress: inout TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async -> (
        fileMaps: [String: [RemoteFileRecord]],
        dirMaps: [String: [(path: String, modified: Date)]],
        failures: [String: String]
    ) {
        var remoteFileMaps: [String: [RemoteFileRecord]] = [:]
        var remoteDirMaps: [String: [(path: String, modified: Date)]] = [:]
        var precountFailures: [String: String] = [:]
        for entry in entries {
            if cancellation.isCancelled { break }
            if Self.isPlainFile(entry) {
                remoteFileMaps[entry.path] = [RemoteFileRecord(path: entry.path, size: entry.size)]
                remoteDirMaps[entry.path] = []
                progress.bytesTotal += entry.size
                continue
            }
            progress.currentName = entry.name
            onProgress(progress)
            do {
                let files = try await client.recursiveFiles(entry.path, on: serial, onSpawn: cancellation.trackProcess)
                let dirs = entry.isDirectory
                    ? try await client.recursiveDirs(entry.path, on: serial, onSpawn: cancellation.trackProcess)
                    : []
                cancellation.clearProcess()
                remoteFileMaps[entry.path] = files
                remoteDirMaps[entry.path] = dirs
                progress.bytesTotal += files.reduce(0) { $0 + $1.size }
                onProgress(progress)
            } catch {
                cancellation.clearProcess()
                if cancellation.isCancelled { break }
                precountFailures[entry.path] = error.localizedDescription
            }
        }
        return (remoteFileMaps, remoteDirMaps, precountFailures)
    }

    /// Тягне один елемент (`transferOne`) і, для «Перемістити», вирішує подальше видалення з
    /// телефона — лише за щойно верифікованим маніфестом (v0.12.2, H4) і лише коли copy успішна
    /// та не скасована. Повертає готовий результат елемента; сам ніколи не кидає.
    private func transferAndFinishEntry(
        entry: RemoteEntry,
        expected: [RemoteFileRecord],
        dirRecords: [(path: String, modified: Date)],
        tmpRoot: URL,
        index: Int,
        destination: URL,
        serial: String,
        move: Bool,
        entryBytes: Int64,
        progress: inout TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async -> TransferItemResult {
        do {
            let (finalURL, dateFailures, verified) = try await transferOne(
                entry: entry, expected: expected, dirRecords: dirRecords, tmpRoot: tmpRoot,
                index: index, destination: destination, serial: serial, baseBytesDone: progress.bytesDone,
                progress: &progress, onProgress: onProgress
            )
            var status: TransferItemResult.Status = .copied
            // 1.3: частковий провал виставлення дати створення — не смертельно (вміст на
            // місці), але користувач має про це знати, не лише розробник у NSLog.
            var warning: String? = Self.dateWarning(failures: dateFailures)
            if move {
                if cancellation.isCancelled {
                    // Копія вже на Mac і верифікована; видалення пропускаємо — чесніше.
                    warning = Self.joinWarnings(warning, "Скасовано до видалення з телефона — копія на Mac збережена.")
                } else {
                    progress.phase = .deleting
                    onProgress(progress)
                    do {
                        // Свідомо БЕЗ trackProcess: обрив посеред видалення не має лишити
                        // півстану. v0.11.0 (P3): теку видаляємо ПОФАЙЛОВО (лише верифіковані
                        // файли, батчами) і потім лише ПОРОЖНІ теки через rmdir — файл, що
                        // з'явився на телефоні під час переносу, лишається разом зі своєю текою.
                        if entry.isDirectory {
                            let leftover = try await deleteVerifiedTree(
                                entry: entry, verified: verified, dirs: dirRecords, serial: serial
                            )
                            status = .moved
                            if let first = leftover.sorted().first {
                                warning = Self.joinWarnings(warning, "Тека на телефоні залишена — у ній з'явились нові файли: \(RemotePath.baseName(first))")
                            }
                        } else {
                            try await client.delete(entry.path, on: serial)
                            status = .moved
                        }
                    } catch {
                        status = .copiedButDeleteFailed(error.localizedDescription)
                        warning = Self.joinWarnings(warning, "Скопійовано, але не видалено з телефона: \(error.localizedDescription)")
                    }
                }
            }
            progress.bytesDone += entryBytes
            progress.itemsDone += 1
            onProgress(progress)
            return TransferItemResult(entry: entry, status: status, finalURL: finalURL, bytes: entryBytes, warning: warning)
        } catch {
            if cancellation.isCancelled {
                return TransferItemResult(entry: entry, status: .cancelled, finalURL: nil, bytes: 0, warning: nil)
            }
            return TransferItemResult(entry: entry, status: .failed(error.localizedDescription), finalURL: nil, bytes: 0, warning: nil)
        }
    }

    // MARK: - Один елемент

    func transferOne(
        entry: RemoteEntry,
        expected: [RemoteFileRecord],
        dirRecords: [(path: String, modified: Date)],
        tmpRoot: URL,
        index: Int,
        destination: URL,
        serial: String,
        baseBytesDone: Int64,
        progress: inout TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> (url: URL, dateFailures: Int, verified: VerifiedManifest) {
        let itemTmp = tmpRoot.appendingPathComponent(String(index), isDirectory: true)
        try fileManager.createDirectory(at: itemTmp, withIntermediateDirectories: true)
        let pulled = itemTmp.appendingPathComponent(entry.name)

        // Перша спроба: pull цілого елемента, як і раніше. Якщо і сам pull, і наступні
        // дати+verify пройшли чисто — виходимо тут же, докачка (B2) нижче не чіпається.
        do {
            try await pullWholeEntry(
                entry: entry, itemTmp: itemTmp, serial: serial, baseBytesDone: baseBytesDone,
                progress: progress, onProgress: onProgress
            )
            return try await finishAfterPull(
                entry: entry, expected: expected, dirRecords: dirRecords, pulled: pulled,
                destination: destination, serial: serial, progress: &progress, onProgress: onProgress
            )
        } catch {
            if cancellation.isCancelled { throw ADBError.cancelled }
            return try await resumeAfterFailedAttempt(
                entry: entry, expected: expected, dirRecords: dirRecords, pulled: pulled,
                destination: destination, serial: serial, firstError: error,
                progress: &progress, onProgress: onProgress
            )
        }
    }
}
