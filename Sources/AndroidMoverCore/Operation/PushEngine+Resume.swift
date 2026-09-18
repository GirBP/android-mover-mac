import Foundation

/// v0.11.0 (P2): верифікація tmp і докачка push після обриву — винесено з PushEngine.swift (≤400).
extension PushEngine {
    /// Перша спроба: push цілого елемента в tmp + верифікація. При обриві (помилка, яку
    /// `TransferEngine.isResumable` визнає тимчасовою) — цикл докачки: чекаємо пристрій,
    /// допушуємо лише відсутні/биті файли у tmp, верифікуємо знову; до `maxAttempts` спроб
    /// (верифікаційні розбіжності — до `TransferEngine.verificationAttemptCap`). Видиме місце
    /// на телефоні не чіпається, доки tmp-копія не звірена.
    func pushItemWithRetry(
        url: URL,
        itemTmpDir: String,
        tmpItemPath: String,
        localMap: [String: Int64],
        serial: String,
        progress: inout PushProgress,
        onProgress: @escaping @Sendable (PushProgress) -> Void
    ) async throws {
        do {
            do {
                try await client.push(url, to: itemTmpDir, on: serial, onSpawn: cancellation.trackProcess)
                cancellation.clearProcess()
            } catch {
                cancellation.clearProcess()
                if cancellation.isCancelled { throw ADBError.cancelled }
                throw error
            }
            if cancellation.isCancelled { throw ADBError.cancelled }
            try await verifyTmp(tmpItemPath: tmpItemPath, localMap: localMap, serial: serial, progress: &progress, onProgress: onProgress)
        } catch {
            if cancellation.isCancelled { throw ADBError.cancelled }
            guard TransferEngine.isResumable(error) else { throw error }
            var lastError = error
            var attempt = 1
            while attempt <= (TransferEngine.isVerificationError(lastError) ? min(maxAttempts, TransferEngine.verificationAttemptCap) : maxAttempts) {
                if cancellation.isCancelled { throw ADBError.cancelled }
                progress.phase = .waitingForDevice
                progress.attempt = attempt
                onProgress(progress)
                do {
                    try await client.waitForDevice(serial, timeout: ADBClient.waitForDeviceTimeout, onSpawn: cancellation.trackProcess)
                    cancellation.clearProcess()
                } catch {
                    cancellation.clearProcess()
                    if cancellation.isCancelled { throw ADBError.cancelled }
                    lastError = error
                    attempt += 1
                    continue
                }
                try await sleepCancellably(retryDelay(attempt))
                progress.phase = .resuming
                onProgress(progress)
                do {
                    try await resumeMissingPush(localRoot: url, localMap: localMap, itemTmpDir: itemTmpDir, tmpItemPath: tmpItemPath, serial: serial)
                    if cancellation.isCancelled { throw ADBError.cancelled }
                    try await verifyTmp(tmpItemPath: tmpItemPath, localMap: localMap, serial: serial, progress: &progress, onProgress: onProgress)
                    progress.attempt = 0
                    break
                } catch {
                    if cancellation.isCancelled { throw ADBError.cancelled }
                    lastError = error
                    attempt += 1
                    if attempt > (TransferEngine.isVerificationError(lastError) ? min(maxAttempts, TransferEngine.verificationAttemptCap) : maxAttempts) {
                        throw lastError
                    }
                }
            }
            if progress.attempt != 0 { throw lastError }
        }
    }

    /// Верифікація tmp-копії на телефоні проти локальної мапи (кількість+розміри, precomposed з обох боків).
    func verifyTmp(
        tmpItemPath: String,
        localMap: [String: Int64],
        serial: String,
        progress: inout PushProgress,
        onProgress: @escaping @Sendable (PushProgress) -> Void
    ) async throws {
        progress.phase = .verifying
        onProgress(progress)
        let remoteFiles = try await client.recursiveFiles(tmpItemPath, on: serial, onSpawn: cancellation.trackProcess)
        cancellation.clearProcess()
        if cancellation.isCancelled { throw ADBError.cancelled }
        var actualMap: [String: Int64] = [:]
        for record in remoteFiles {
            let relative = TransferEngine.relativePath(of: record.path, under: tmpItemPath)
            actualMap[relative.precomposedStringWithCanonicalMapping] = record.size
        }
        if let mismatch = TransferEngine.diff(expected: localMap, actual: actualMap) {
            throw ADBError.pushVerificationFailed(Self.pushMismatchMessage(mismatch))
        }
    }

    /// v0.11.0 (P2): допушує лише відсутні/биті файли у tmp на телефоні (порівняння локальної
    /// мапи з recursiveFiles(tmp)); зайві файли в tmp прибирає. Шляхи на телефон — з сирих
    /// відносних шляхів локального дерева (той самий інваріант, що resumeMissing у pull).
    func resumeMissingPush(
        localRoot: URL,
        localMap: [String: Int64],
        itemTmpDir: String,
        tmpItemPath: String,
        serial: String
    ) async throws {
        // tmp могла зникнути (перезавантаження телефона) — відтворити.
        try await client.makeDirectories(itemTmpDir, on: serial)
        var remoteMap: [String: (path: String, size: Int64)] = [:]
        if let remoteFiles = try? await client.recursiveFiles(tmpItemPath, on: serial, onSpawn: cancellation.trackProcess) {
            cancellation.clearProcess()
            for record in remoteFiles {
                let relative = TransferEngine.relativePath(of: record.path, under: tmpItemPath)
                remoteMap[relative.precomposedStringWithCanonicalMapping] = (record.path, record.size)
            }
        }
        cancellation.clearProcess()
        // Зайве в tmp — прибрати (зіб'є count у verify).
        let extra = remoteMap.filter { localMap[$0.key] == nil }.map(\.value.path)
        if !extra.isEmpty { _ = try? await client.deleteMany(extra, on: serial) }

        // Локальні відносні шляхи — СИРІ (з enumerator), ключі мапи — нормалізовані.
        let isDir = (try? localRoot.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir {
            if remoteMap[""]?.size != localMap[""] {
                if let stale = remoteMap[""]?.path { _ = try? await client.deleteMany([stale], on: serial) }
                try await pushSingle(localRoot, to: itemTmpDir, serial: serial)
            }
            return
        }
        let prefix = localRoot.standardizedFileURL.path + "/"
        guard let enumerator = fileManager.enumerator(at: localRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return }
        // DirectoryEnumerator не ітерується в async-контексті — знімаємо список синхронно.
        let localURLs = enumerator.allObjects.compactMap { $0 as? URL }
        for fileURL in localURLs {
            if cancellation.isCancelled { throw ADBError.cancelled }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = fileURL.standardizedFileURL.path
            let rawRelative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            let key = rawRelative.precomposedStringWithCanonicalMapping
            guard let expectedSize = localMap[key] else { continue }
            if remoteMap[key]?.size == expectedSize { continue }
            if let stale = remoteMap[key]?.path { _ = try? await client.deleteMany([stale], on: serial) }
            let remoteParent = RemotePath.parent(RemotePath.join(tmpItemPath, rawRelative))
            try await client.makeDirectories(remoteParent, on: serial)
            try await pushSingle(fileURL, to: remoteParent, serial: serial)
        }
    }

    func pushSingle(_ url: URL, to remoteDir: String, serial: String) async throws {
        do {
            try await client.push(url, to: remoteDir, on: serial, onSpawn: cancellation.trackProcess)
            cancellation.clearProcess()
        } catch {
            cancellation.clearProcess()
            if cancellation.isCancelled { throw ADBError.cancelled }
            throw error
        }
    }

    func mtimeWarning(localMap: [String: Int64], localRoot: URL, finalRemotePath: String, serial: String) async -> String? {
        guard let remoteMTimes = try? await client.statMTimes(finalRemotePath, on: serial) else { return nil }
        var mismatches = 0
        for relative in localMap.keys {
            let remotePath = relative.isEmpty ? finalRemotePath : RemotePath.join(finalRemotePath, relative)
            guard let remoteDate = remoteMTimes[remotePath] else { continue }
            let localURL = relative.isEmpty ? localRoot : localRoot.appendingPathComponent(relative)
            guard let attrs = try? fileManager.attributesOfItem(atPath: localURL.path),
                  let localDate = attrs[.modificationDate] as? Date else { continue }
            if abs(localDate.timeIntervalSince(remoteDate)) > 2 { mismatches += 1 }
        }
        guard mismatches > 0 else { return nil }
        return "Дати модифікації \(mismatches) файлів на телефоні відрізняються від Mac (best-effort, не провал)."
    }

}
