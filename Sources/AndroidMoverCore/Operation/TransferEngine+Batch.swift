import Foundation

/// v0.10.2: батчевий шлях для ПЛОСКИХ файлів (не тек, не symlink). Реальний кейс власника —
/// переміщення 1 222 .mp4: старий конвеєр робив на КОЖЕН файл окремий `find` (підрахунок),
/// окремий `adb pull` і окремий `rm` — ~3 700 спавнів adb, хвилини накладних витрат ще до
/// першого байта, і користувач скасовував на «Рахую файли…». Тепер: підрахунок для файлів —
/// з лістингу (розмір уже відомий), pull — один процес на ≤ADBClient.batchSize файлів, rm —
/// один shell на батч. Інваріанти незмінні: кожен файл окремо проходить дати → verify →
/// атомарний move; видалення з телефона — лише ПІСЛЯ verify саме цього файла; провал
/// батчевого pull, відсутній чи битий файл → поштучний transferOne (з resume після обриву).
extension TransferEngine {
    static func isPlainFile(_ entry: RemoteEntry) -> Bool {
        !entry.isDirectory && !entry.isSymlink
    }

    /// v0.11.0 (P3): видалення ВЕРИФІКОВАНОЇ теки пофайлово: батчі `rm` на файли з очікуваної
    /// мапи (усі щойно звірені з копією), потім `rmdir` лише порожніх тек знизу вгору. Чужий
    /// файл, що з'явився на телефоні під час переносу, і його тека — лишаються (повертаються).
    /// Обрив посеред: кожен файл або видалений, або цілий — жодних напіввидалених файлів.
    func deleteVerifiedTree(
        entry: RemoteEntry,
        verified: VerifiedManifest,
        dirs: [(path: String, modified: Date)],
        serial: String
    ) async throws -> Set<String> {
        let filePaths = verified.files.map(\.path)
        var index = 0
        while index < filePaths.count {
            let end = min(index + ADBClient.batchSize, filePaths.count)
            let failed = try await client.deleteMany(Array(filePaths[index..<end]), on: serial)
            if let first = failed.sorted().first {
                throw ADBError.deleteFailed(first)
            }
            index = end
        }
        var dirPaths = Set(dirs.map(\.path))
        dirPaths.insert(entry.path)
        return try await client.removeEmptyDirectories(Array(dirPaths), on: serial)
    }

    func transferFileBatch(
        entries: [RemoteEntry],
        firstIndex: Int,
        tmpRoot: URL,
        destination: URL,
        serial: String,
        move: Bool,
        remoteFileMaps: [String: [RemoteFileRecord]],
        progress: inout TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async -> [TransferItemResult] {
        let batchTmp = tmpRoot.appendingPathComponent("batch-\(firstIndex)", isDirectory: true)
        try? fileManager.createDirectory(at: batchTmp, withIntermediateDirectories: true)
        let batchBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let baseBytesDone = progress.bytesDone

        progress.phase = .pulling
        progress.currentName = entries.count == 1
            ? entries[0].name
            : "\(entries[0].name) … (+\(entries.count - 1))"
        onProgress(progress)

        // Пульс прогресу — той самий адаптивний патерн, що pullWholeEntry.
        let snapshot = progress
        let poller = Task.detached { [snapshot, fileManager] in
            var interval: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                let start = Date()
                let written = Self.directorySize(at: batchTmp, fileManager: fileManager)
                interval = Date().timeIntervalSince(start) > 0.2 ? 3_000_000_000 : 1_000_000_000
                var p = snapshot
                p.bytesDone = baseBytesDone + written
                onProgress(p)
            }
        }

        var batchFailed = false
        do {
            try await client.pullMany(entries.map(\.path), into: batchTmp, on: serial, onSpawn: cancellation.trackProcess)
            cancellation.clearProcess()
        } catch {
            cancellation.clearProcess()
            // Не фатально для батчу: файли, що встигли приземлитись, ідуть далі; решта —
            // поштучно нижче (там і resume після обриву).
            batchFailed = true
        }
        poller.cancel()

        // v0.11.0 (P1): md5 усіх файлів батчу одним викликом (замість одного на файл).
        var batchSums: [String: String]? = nil
        if checksumRequired, !batchFailed, !cancellation.isCancelled {
            batchSums = try? await client.checksumsMany(entries.map(\.path), on: serial, onSpawn: cancellation.trackProcess)
            cancellation.clearProcess()
        }

        // 1. Кожен файл — окремо: дати → verify → move (finishAfterPull), або поштучний
        //    transferOne, якщо батч не доніс саме цей файл чи копія бита.
        var copied: [(entry: RemoteEntry, url: URL, dateFailures: Int)] = []
        var failures: [String: TransferItemResult.Status] = [:]
        for (offset, entry) in entries.enumerated() {
            if cancellation.isCancelled {
                failures[entry.id] = .cancelled
                continue
            }
            let expected = remoteFileMaps[entry.path] ?? [RemoteFileRecord(path: entry.path, size: entry.size)]
            let pulled = batchTmp.appendingPathComponent(entry.name)
            do {
                var outcome: (url: URL, dateFailures: Int, verified: VerifiedManifest)?
                if !batchFailed, fileManager.fileExists(atPath: pulled.path) {
                    do {
                        outcome = try await finishAfterPull(
                            entry: entry, expected: expected, dirRecords: [], pulled: pulled,
                            destination: destination, serial: serial, remoteChecksums: batchSums,
                            progress: &progress, onProgress: onProgress
                        )
                    } catch {
                        // Бита/неповна копія з батчу → прибираємо і йдемо поштучно (з resume);
                        // локальні помилки (напр. moveItem) — не лікуються повтором, кидаємо.
                        guard !cancellation.isCancelled, Self.isResumable(error) else { throw error }
                        try? fileManager.removeItem(at: pulled)
                    }
                }
                if outcome == nil {
                    outcome = try await transferOne(
                        entry: entry, expected: expected, dirRecords: [], tmpRoot: tmpRoot,
                        index: firstIndex + offset, destination: destination, serial: serial,
                        baseBytesDone: progress.bytesDone, progress: &progress, onProgress: onProgress
                    )
                }
                if let outcome {
                    copied.append((entry, outcome.url, outcome.dateFailures))
                }
            } catch {
                failures[entry.id] = cancellation.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }

        // 2. Move: один `rm`-батч на всі ВЕРИФІКОВАНІ файли цього батчу (усі копії вже на Mac).
        var deleteFailed: [String: String] = [:]   // path → причина
        var skippedDeleteAfterCancel = false
        if move, !copied.isEmpty {
            if cancellation.isCancelled {
                skippedDeleteAfterCancel = true
            } else {
                progress.phase = .deleting
                onProgress(progress)
                let paths = copied.map(\.entry.path)
                do {
                    let failed = try await client.deleteMany(paths, on: serial)
                    for path in failed { deleteFailed[path] = String(localized: "Не вдалося видалити з телефона.") }
                } catch {
                    for path in paths { deleteFailed[path] = error.localizedDescription }
                }
            }
        }

        // 3. Результати — у порядку entries.
        var results: [TransferItemResult] = []
        for entry in entries {
            if let status = failures[entry.id] {
                results.append(TransferItemResult(entry: entry, status: status, finalURL: nil, bytes: 0, warning: nil))
                continue
            }
            guard let item = copied.first(where: { $0.entry.id == entry.id }) else { continue }
            var status: TransferItemResult.Status = .copied
            var warning = Self.dateWarning(failures: item.dateFailures)
            if move {
                if skippedDeleteAfterCancel {
                    warning = Self.joinWarnings(warning, "Скасовано до видалення з телефона — копія на Mac збережена.")
                } else if let reason = deleteFailed[entry.path] {
                    status = .copiedButDeleteFailed(reason)
                    warning = Self.joinWarnings(warning, "Скопійовано, але не видалено з телефона: \(reason)")
                } else {
                    status = .moved
                }
            }
            results.append(TransferItemResult(entry: entry, status: status, finalURL: item.url, bytes: entry.size, warning: warning))
        }

        progress.bytesDone = baseBytesDone + batchBytes
        progress.itemsDone += entries.count
        progress.currentName = ""
        onProgress(progress)
        return results
    }
}
