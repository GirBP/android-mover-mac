import Foundation

public struct PushProgress: Sendable {
    public enum Phase: Sendable {
        case counting
        case pushing
        case verifying
        /// v0.11.0 (P2): push чи verify провалились — чекаємо пристрій перед новою спробою.
        case waitingForDevice
        /// v0.11.0 (P2): пристрій повернувся — допушуємо лише відсутні/биті файли у tmp.
        case resuming
        case finishing
    }

    public init() {}

    public var phase: Phase = .counting
    public var itemsTotal: Int = 0
    public var itemsDone: Int = 0
    public var currentName: String = ""
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    /// v0.11.0: номер спроби докачки (0 — штатна перша).
    public var attempt: Int = 0

    public var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1.0, Double(bytesDone) / Double(bytesTotal))
    }
}

public struct PushItemResult: Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case pushed
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let localURL: URL
    public let name: String
    public let status: Status
    /// Фінальний (видимий, колізієвільний) шлях на телефоні — заповнений лише при .pushed.
    public let remotePath: String?
    public let bytes: Int64
    public let warning: String?

    public var isSuccess: Bool {
        switch status {
        case .pushed: return true
        case .failed, .cancelled: return false
        }
    }
}

/// Рушій перенесення Mac → Android (B1), дзеркало TransferEngine: рахує локально → пушить у
/// тимчасову теку на телефоні → верифікує (кількість+розміри) ДО появи у видимому місці →
/// move у колізієвільне фінальне ім'я → best-effort звірка mtime → прибирає тимчасову теку.
public final class PushEngine: @unchecked Sendable {
    let client: ADBClient
    let fileManager = FileManager.default
    /// 2.2: спільний контролер скасування — раніше тут окремо жили cancelFlag/currentProcess/
    /// trackProcess, дубльовані з TransferEngine (див. CancellableADBOperation.swift).
    let cancellation = CancellationController()
    /// v0.11.0 (P2): ті самі ліміти, що в TransferEngine — транспортні обриви до maxAttempts
    /// (15 × 120 с ≈ 30 хв), верифікаційні розбіжності — до 3.
    let maxAttempts: Int
    let retryDelay: @Sendable (Int) -> TimeInterval

    public init(
        client: ADBClient,
        maxAttempts: Int = 15,
        retryDelay: @escaping @Sendable (Int) -> TimeInterval = { attempt in min(8, pow(2, Double(attempt))) }
    ) {
        self.client = client
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
    }

    func sleepCancellably(_ seconds: TimeInterval) async throws {
        var remaining = seconds
        while remaining > 0 {
            if cancellation.isCancelled { throw ADBError.cancelled }
            let step = min(0.1, remaining)
            try? await Task.sleep(nanoseconds: UInt64((step * 1_000_000_000).rounded()))
            remaining -= step
        }
        if cancellation.isCancelled { throw ADBError.cancelled }
    }

    /// Запас понад суму розмірів (метадані, FUSE-накладні): 64 МБ, як і 64 МБ на елемент у pull.
    static let pushHeadroomBytes: Int64 = 64 * 1024 * 1024

    public func cancel() {
        cancellation.cancel()
    }

    /// Пушить `urls` (файли й/або теки з Mac) у `destDir` на телефоні. Глобальні передумови
    /// (недозволена ціль) кидають помилку одразу; поелементні збої — у результатах.
    public func push(
        urls: [URL],
        to destDir: String,
        serial: String,
        onProgress: @escaping @Sendable (PushProgress) -> Void,
        onItemFinished: (@Sendable (PushItemResult) -> Void)? = nil
    ) async throws -> [PushItemResult] {
        var progress = PushProgress()
        progress.itemsTotal = urls.count
        onProgress(progress)

        let normalizedDest = RemotePath.normalized(destDir)
        guard RemotePath.isAllowedPushTarget(normalizedDest) else {
            throw ADBError.unsafePushTarget(normalizedDest)
        }
        guard !urls.isEmpty else {
            progress.phase = .finishing
            onProgress(progress)
            return []
        }

        // 1. Локальний підрахунок: рекурсивно файли+розміри (FileManager.enumerator).
        //    Symlink на верхньому рівні — провал ЛИШЕ цього елемента (як isSymlink-перевірка
        //    entry на pull-напрямку), решта елементів іде далі. Збій одного елемента не зриває батч.
        let (localMaps, itemBytes, precountFailures) = precountLocalItems(urls: urls, progress: &progress, onProgress: onProgress)
        if cancellation.isCancelled {
            progress.phase = .finishing
            onProgress(progress)
            return urls.map {
                PushItemResult(localURL: $0, name: $0.lastPathComponent, status: .cancelled, remotePath: nil, bytes: 0, warning: nil)
            }
        }

        // v0.12.2 (M1, аудит M3): місце на телефоні — ДО першого push і до створення tmp.
        // `storageInfo` недоступний (нема toybox) → продовжуємо; ENOSPC у stderr тоді ловить
        // класифікатор TransferEngine.isResumable (без 15 марних спроб).
        if precountFailures.count < urls.count, progress.bytesTotal > 0,
           let info = try? await client.storageInfo(for: normalizedDest, on: serial),
           info.availableBytes < progress.bytesTotal + Self.pushHeadroomBytes {
            throw ADBError.notEnoughSpaceOnDevice(needed: progress.bytesTotal, available: info.availableBytes)
        }

        // 2. Тимчасова тека на телефоні, спільна для батчу (підтека `<idx>` на елемент) —
        //    лише якщо є що пушити (не зривати мережевий виклик заради самих провалів підрахунку).
        let tmpRoot = RemotePath.join(normalizedDest, ".androidmover-tmp-\(UUID().uuidString)")
        var tmpCreated = false
        if precountFailures.count < urls.count {
            do {
                try await client.makeDirectory(tmpRoot, on: serial)
                tmpCreated = true
            } catch {
                // Не вдалось створити тимчасову теку — кожен елемент провалиться нижче з
                // чесним повідомленням (глобальний throw тут був би нечесним: підрахунок
                // уже показав користувачу обсяг роботи).
            }
        }

        let results = await pushAllItems(
            urls: urls, precountFailures: precountFailures, itemBytes: itemBytes, localMaps: localMaps,
            tmpCreated: tmpCreated, tmpRoot: tmpRoot, destDir: normalizedDest, serial: serial,
            progress: &progress, onProgress: onProgress, onItemFinished: onItemFinished
        )

        // Best-effort прибирання, попри скасування чи часткові провали — tmp усередині
        // normalizedDest, тобто під guard-ом isUnsafeToDelete гарантовано пройде.
        if tmpCreated {
            try? await client.delete(tmpRoot, on: serial)
        }

        progress.phase = .finishing
        progress.currentName = ""
        onProgress(progress)
        return results
    }

    /// Локальний підрахунок (рекурсивно файли+розміри) для кожного елемента окремо — збій
    /// одного не зриває інші; symlink на верхньому рівні провалюється одразу (не підтримується).
    private func precountLocalItems(
        urls: [URL],
        progress: inout PushProgress,
        onProgress: @escaping @Sendable (PushProgress) -> Void
    ) -> (localMaps: [Int: [String: Int64]], itemBytes: [Int: Int64], failures: [Int: String]) {
        var localMaps: [Int: [String: Int64]] = [:]
        var itemBytes: [Int: Int64] = [:]
        var precountFailures: [Int: String] = [:]
        for (index, url) in urls.enumerated() {
            if cancellation.isCancelled { break }
            progress.currentName = url.lastPathComponent
            onProgress(progress)
            if Self.isSymlink(url) {
                precountFailures[index] = "Символічні посилання не підтримуються."
                continue
            }
            do {
                let (map, bytes) = try Self.localFileMap(at: url, fileManager: fileManager)
                localMaps[index] = map
                itemBytes[index] = bytes
                progress.bytesTotal += bytes
                onProgress(progress)
            } catch {
                precountFailures[index] = error.localizedDescription
            }
        }
        return (localMaps, itemBytes, precountFailures)
    }

    /// Пушить кожен елемент окремо в `tmpRoot/<idx>` через `pushOne`, звітуючи результат
    /// (`onItemFinished`) незалежно від причини (скасовано / провал підрахунку / нема tmp /
    /// провал самого push) — один елемент ніколи не зриває решту батчу.
    private func pushAllItems(
        urls: [URL],
        precountFailures: [Int: String],
        itemBytes: [Int: Int64],
        localMaps: [Int: [String: Int64]],
        tmpCreated: Bool,
        tmpRoot: String,
        destDir: String,
        serial: String,
        progress: inout PushProgress,
        onProgress: @escaping @Sendable (PushProgress) -> Void,
        onItemFinished: (@Sendable (PushItemResult) -> Void)?
    ) async -> [PushItemResult] {
        var results: [PushItemResult] = []
        for (index, url) in urls.enumerated() {
            if cancellation.isCancelled {
                results.append(PushItemResult(localURL: url, name: url.lastPathComponent, status: .cancelled, remotePath: nil, bytes: 0, warning: nil))
                onItemFinished?(results[results.count - 1])
                continue
            }
            if let failure = precountFailures[index] {
                results.append(PushItemResult(localURL: url, name: url.lastPathComponent, status: .failed(failure), remotePath: nil, bytes: 0, warning: nil))
                onItemFinished?(results[results.count - 1])
                continue
            }
            guard tmpCreated else {
                results.append(PushItemResult(
                    localURL: url, name: url.lastPathComponent,
                    status: .failed("Не вдалося створити тимчасову теку на телефоні."),
                    remotePath: nil, bytes: 0, warning: nil
                ))
                onItemFinished?(results[results.count - 1])
                continue
            }
            progress.currentName = url.lastPathComponent
            progress.phase = .pushing
            onProgress(progress)

            let bytes = itemBytes[index] ?? 0
            let localMap = localMaps[index] ?? [:]
            do {
                let (finalPath, warning) = try await pushOne(
                    url: url, index: index, destDir: destDir, tmpRoot: tmpRoot, serial: serial,
                    localMap: localMap, progress: &progress, onProgress: onProgress
                )
                progress.bytesDone += bytes
                progress.itemsDone += 1
                onProgress(progress)
                results.append(PushItemResult(localURL: url, name: url.lastPathComponent, status: .pushed, remotePath: finalPath, bytes: bytes, warning: warning))
                onItemFinished?(results[results.count - 1])
            } catch {
                if cancellation.isCancelled {
                    results.append(PushItemResult(localURL: url, name: url.lastPathComponent, status: .cancelled, remotePath: nil, bytes: 0, warning: nil))
                    onItemFinished?(results[results.count - 1])
                } else {
                    results.append(PushItemResult(localURL: url, name: url.lastPathComponent, status: .failed(error.localizedDescription), remotePath: nil, bytes: 0, warning: nil))
                    onItemFinished?(results[results.count - 1])
                }
            }
        }
        return results
    }

    // MARK: - Один елемент

    private func pushOne(
        url: URL,
        index: Int,
        destDir: String,
        tmpRoot: String,
        serial: String,
        localMap: [String: Int64],
        progress: inout PushProgress,
        onProgress: @escaping @Sendable (PushProgress) -> Void
    ) async throws -> (remotePath: String, warning: String?) {
        let name = url.lastPathComponent
        let itemTmpDir = RemotePath.join(tmpRoot, String(index))
        try await client.makeDirectory(itemTmpDir, on: serial)
        if cancellation.isCancelled { throw ADBError.cancelled }
        let tmpItemPath = RemotePath.join(itemTmpDir, name)

        // Перша спроба: push цілого елемента + верифікація. v0.11.0 (P2): провал (обрив
        // кабеля, бита копія) → цикл докачки: чекаємо пристрій → допушуємо лише відсутні/биті
        // файли у tmp → верифікуємо знову; до maxAttempts (верифікаційні — до 3). Видиме
        // місце на телефоні не чіпається, доки tmp-копія не звірена.
        try await pushItemWithRetry(
            url: url, itemTmpDir: itemTmpDir, tmpItemPath: tmpItemPath, localMap: localMap,
            serial: serial, progress: &progress, onProgress: onProgress
        )

        // Колізієвільне ім'я і атомарний move у видиме місце; якщо конкурент устиг зайняти
        // згенероване ім'я між генерацією і move — один повтор з новим ім'ям.
        var finalName = try await Self.remoteCollisionFreeName(for: name, in: destDir, client: client, serial: serial)
        var finalPath = RemotePath.join(destDir, finalName)
        do {
            try await client.move(tmpItemPath, to: finalPath, on: serial)
        } catch ADBError.alreadyExists {
            finalName = try await Self.remoteCollisionFreeName(for: name, in: destDir, client: client, serial: serial)
            finalPath = RemotePath.join(destDir, finalName)
            try await client.move(tmpItemPath, to: finalPath, on: serial)
        }

        // Best-effort mtime-звірка (НЕ провал перенесення): sync-протокол push передає дати,
        // але FUSE-поведінка неоднорідна по OEM — розбіжність >2с у >0 файлів стає warning.
        let warning = await mtimeWarning(localMap: localMap, localRoot: url, finalRemotePath: finalPath, serial: serial)
        return (finalPath, warning)
    }

    // MARK: - Допоміжні

    /// Колізієвільне ім'я НА ТЕЛЕФОНІ: async-аналог TransferEngine.collisionFreeURL — той
    /// самий генератор кандидатів (TransferEngine.collisionCandidateName), але існування
    /// перевіряється віддалено через remoteExists замість FileManager.
    static func remoteCollisionFreeName(for name: String, in destDir: String, client: ADBClient, serial: String) async throws -> String {
        var attempt = 0
        while true {
            let candidate = TransferEngine.collisionCandidateName(for: name, attempt: attempt)
            let candidatePath = RemotePath.join(destDir, candidate)
            if try await !client.remoteExists(candidatePath, on: serial) { return candidate }
            attempt += 1
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink ?? false
    }

    /// Рекурсивний локальний підрахунок: відносний шлях (unicode-нормалізований) → розмір;
    /// "" — сам url, якщо це одиночний файл. Вкладені symlink-и тихо пропускаються (не
    /// частина даних, що переносяться) — на відміну від symlink НА ВЕРХНЬОМУ рівні, який
    /// провалює елемент цілком (перевіряється викликачем до цього виклику).
    static func localFileMap(at url: URL, fileManager: FileManager) throws -> (map: [String: Int64], bytes: Int64) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PushLocalError(message: "Файл «\(url.lastPathComponent)» не знайдено — можливо, він зник.")
        }
        var map: [String: Int64] = [:]
        var total: Int64 = 0
        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            ) else {
                throw PushLocalError(message: "Не вдалося прочитати вміст «\(url.lastPathComponent)».")
            }
            let prefix = url.standardizedFileURL.path + "/"
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                ) else { continue }
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                let path = fileURL.standardizedFileURL.path
                let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
                let size = Int64(values.fileSize ?? 0)
                map[relative.precomposedStringWithCanonicalMapping] = size
                total += size
            }
        } else {
            let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            map[""] = size
            total = size
        }
        return (map, total)
    }

    static func pushMismatchMessage(_ mismatch: TransferEngine.VerifyMismatch) -> String {
        switch mismatch {
        case .count(let expected, let actual):
            return "Очікувалось файлів: \(expected), на телефоні опинилось: \(actual)."
        case .missing(let path):
            return "Файл «\(path)» не з'явився на телефоні."
        case .sizeMismatch(let path, let expected, let actual):
            return "Розмір «\(path)» не збігається: на Mac \(expected) Б, на телефоні \(actual) Б."
        }
    }
}

private struct PushLocalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
