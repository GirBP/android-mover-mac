import Foundation

/// Докачка після обриву — перша спроба (pull цілого елемента) і цикл дотягування
/// відсутніх/битих файлів, коли перша спроба чи наступна verify провалились.
extension TransferEngine {
    /// Спить `seconds`, перевіряючи cancellation.isCancelled кожні ≤100 мс, замість одного суцільного
    /// Task.sleep(seconds) — інакше cancel() посеред retryDelay (що зростає зі спробою, до
    /// кількох секунд) чекав би до кінця паузи, перш ніж скасування взагалі помітили б.
    /// Кидає ADBError.cancelled щойно прапор піднявся, не чекаючи штатного кінця сну.
    func sleepCancellably(_ seconds: TimeInterval) async throws {
        let chunk: TimeInterval = 0.1
        var remaining = seconds
        while remaining > 0 {
            if cancellation.isCancelled { throw ADBError.cancelled }
            let step = min(chunk, remaining)
            try? await Task.sleep(nanoseconds: UInt64((step * 1_000_000_000).rounded()))
            remaining -= step
        }
        if cancellation.isCancelled { throw ADBError.cancelled }
    }

    /// Перша спроба: pull цілого шляху елемента в itemTmp, з фоновим пульсом прогресу
    /// (раз на секунду міряє, скільки вже лягло в itemTmp).
    func pullWholeEntry(
        entry: RemoteEntry,
        itemTmp: URL,
        serial: String,
        baseBytesDone: Int64,
        progress: TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        var snapshot = progress
        snapshot.phase = .pulling
        let poller = Task.detached { [snapshot, fileManager] in
            // Адаптивний інтервал — на великих деревах (напр. 50k файлів) сам обхід
            // itemTmp коштує помітний час; якщо один прохід зайняв > 200 мс, наступний тік
            // рідший (3 с), щоб не марнувати CPU/IO на постійний рескан того самого дерева,
            // що росте. Малі елементи лишаються на щосекундному тіку — там обхід майже
            // безкоштовний, і плавний прогрес-бар важливіший.
            var interval: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                let start = Date()
                let written = Self.directorySize(at: itemTmp, fileManager: fileManager)
                let elapsed = Date().timeIntervalSince(start)
                interval = elapsed > 0.2 ? 3_000_000_000 : 1_000_000_000
                var p = snapshot
                p.bytesDone = baseBytesDone + written
                onProgress(p)
            }
        }
        defer { poller.cancel() }

        do {
            try await client.pull(entry.path, into: itemTmp, on: serial, onSpawn: cancellation.trackProcess)
            cancellation.clearProcess()
        } catch {
            cancellation.clearProcess()
            if cancellation.isCancelled { throw ADBError.cancelled }
            throw error
        }
        poller.cancel()
        if cancellation.isCancelled { throw ADBError.cancelled }

        let pulledURL = itemTmp.appendingPathComponent(entry.name)
        guard fileManager.fileExists(atPath: pulledURL.path) else {
            throw ADBError.pullProducedNothing(entry.path)
        }
    }

    /// Дотягує лише відсутні/биті файли елемента після провалу pull або verify — порівнює
    /// локальну мапу (той самий localFileMap(), яким користується verify) з очікуваною і для
    /// кожної розбіжності перепулює саме той файл, а не весь елемент заново. Биту/часткову
    /// локальну копію файла перед цим видаляє. Зайві локальні файли (яких нема серед
    /// очікуваних) теж прибирає — інакше вони зіб'ють count у наступній verify().
    /// Одиночний файл-елемент (relative == "") — перепул усього itemTmp.
    ///
    /// Інваріант: шляхи, якими ми звертаємось до телефона (client.pull) і якими будуємо
    /// локальний шлях файла (localRoot.appendingPathComponent) — це самі байти з телефонного
    /// лістингу (rawRelative), ніколи unicode-нормалізовані. Телефон (ext4/FUSE) шукає ім'я
    /// байт-у-байт: файл із NFD-іменем на телефоні неможливо докачати за NFC-шляхом. Ключ
    /// normalizedKey — лише індекс для звірки з localFileMap (яка сама нормалізує ключі, бо
    /// APFS нормалізаційно-нечутлива) — він ніколи не йде як шлях ні на телефон, ні у
    /// FileManager для нового/докачаного файла. Видалення "зайвих" локальних файлів — за
    /// ключами localFileMap (тобто нормалізованими) навмисно лишається як є: це вже локальний
    /// APFS-шлях, там нормалізаційна нечутливість рятує.
    func resumeMissing(
        expected: [RemoteFileRecord],
        remoteRoot: String,
        localRoot: URL,
        serial: String
    ) async throws {
        var expectedMap: [String: (rawRelative: String, size: Int64)] = [:]
        for record in expected {
            let rawRelative = Self.relativePath(of: record.path, under: remoteRoot)
            let normalizedKey = rawRelative.precomposedStringWithCanonicalMapping
            expectedMap[normalizedKey] = (rawRelative: rawRelative, size: record.size)
        }
        let localMap = Self.localFileMap(root: localRoot, fileManager: fileManager)

        for relative in localMap.keys.sorted() where expectedMap[relative] == nil {
            if cancellation.isCancelled { throw ADBError.cancelled }
            let url = relative.isEmpty ? localRoot : localRoot.appendingPathComponent(relative)
            try? fileManager.removeItem(at: url)
        }

        for (normalizedKey, entry) in expectedMap.sorted(by: { $0.key < $1.key }) {
            if localMap[normalizedKey] == entry.size { continue }
            if cancellation.isCancelled { throw ADBError.cancelled }
            let relative = entry.rawRelative

            if relative.isEmpty {
                // Одиночний файл-елемент: перепул усього itemTmp (localRoot == pulled-файл).
                if fileManager.fileExists(atPath: localRoot.path) {
                    try? fileManager.removeItem(at: localRoot)
                }
                let parent = localRoot.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                do {
                    try await client.pull(remoteRoot, into: parent, on: serial, onSpawn: cancellation.trackProcess)
                    cancellation.clearProcess()
                } catch {
                    cancellation.clearProcess()
                    if cancellation.isCancelled { throw ADBError.cancelled }
                    throw error
                }
                continue
            }

            let localURL = localRoot.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: localURL.path) {
                try? fileManager.removeItem(at: localURL)
            }
            let parentDir = localURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            do {
                try await client.pull(RemotePath.join(remoteRoot, relative), into: parentDir, on: serial, onSpawn: cancellation.trackProcess)
                cancellation.clearProcess()
            } catch {
                cancellation.clearProcess()
                if cancellation.isCancelled { throw ADBError.cancelled }
                throw error
            }
        }
    }

    /// Цикл докачки після провалу першої спроби (pull кинув помилку, не cancelled, або
    /// наступна verify не збіглась). Лише помилки зв'язку з телефоном (ADBError —
    /// pull/verify/timeout/commandFailed/pullProducedNothing тощо) виправдовують докачку:
    /// джерело на телефоні ціле, варто почекати на пристрій і спробувати ще. Будь-яка інша
    /// помилка (напр. CocoaError від moveItem у finishAfterPull — колізія імен, брак прав)
    /// кидається одразу — чекати на пристрій і докачувати тут нема сенсу. Кожна спроба чекає
    /// повернення пристрою, тоді дотягує лише відсутнє/бите (`resumeMissing`) і верифікує
    /// знову; до `maxAttempts` спроб (верифікаційні провали — до `verificationAttemptCap`).
    /// Джерело на телефоні тут ніколи не чіпається.
    func resumeAfterFailedAttempt(
        entry: RemoteEntry,
        expected: [RemoteFileRecord],
        dirRecords: [(path: String, modified: Date)],
        pulled: URL,
        destination: URL,
        serial: String,
        firstError: Error,
        progress: inout TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> (url: URL, dateFailures: Int, verified: VerifiedManifest) {
        guard Self.isResumable(firstError) else { throw firstError }
        // Якщо джерела на телефоні вже нема — чекати й докачувати нема чого; одна дешева
        // перевірка замість 15 спроб × 120 с.
        if !Self.isVerificationError(firstError), (try? await client.remoteExists(entry.path, on: serial)) == false {
            throw ADBError.remoteMissing(entry.path)
        }
        // Очікувана мапа може застаріти (файл дописується на телефоні під час переносу) —
        // після другого верифікаційного провалу перечитуємо її з телефона.
        var expected = expected
        var lastError = firstError
        var attempt = 1
        // Верифікаційні провали — до verificationAttemptCap, транспортні — до maxAttempts.
        while attempt <= (Self.isVerificationError(lastError) ? min(maxAttempts, Self.verificationAttemptCap) : maxAttempts) {
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
            if cancellation.isCancelled { throw ADBError.cancelled }

            // Пауза перед докачкою спить шматками (≤100 мс), перевіряючи cancellation.isCancelled між
            // ними — інакше довгий retryDelay (росте зі спробою) тримав би cancel() у
            // блокуванні аж до кінця всієї паузи.
            try await sleepCancellably(retryDelay(attempt))

            // Другий поспіль верифікаційний провал — перечитати розміри з телефона
            // (файл міг дописатись після лістингу); далі докачка вже проти свіжої мапи.
            if attempt >= 2, Self.isVerificationError(lastError),
               let refreshed = try? await client.recursiveFiles(entry.path, on: serial, onSpawn: cancellation.trackProcess) {
                cancellation.clearProcess()
                expected = refreshed
            }
            progress.phase = .resuming
            onProgress(progress)
            do {
                try await resumeMissing(expected: expected, remoteRoot: entry.path, localRoot: pulled, serial: serial)
                if cancellation.isCancelled { throw ADBError.cancelled }
                let outcome = try await finishAfterPull(
                    entry: entry, expected: expected, dirRecords: dirRecords, pulled: pulled,
                    destination: destination, serial: serial, progress: &progress, onProgress: onProgress
                )
                progress.attempt = 0
                return outcome
            } catch {
                if cancellation.isCancelled { throw ADBError.cancelled }
                lastError = error
                attempt += 1
            }
        }
        // Спроби вичерпано — чесний провал з останньою помилкою; джерело на телефоні ціле.
        throw lastError
    }

    /// Спільний хвіст перенесення елемента: дати → verify → атомарний move у призначення.
    /// Викликається і після першої спроби pull, і після кожного успішного resumeMissing —
    /// жодних відмінностей у поведінці між цими шляхами.
    /// Після розмірної verify — md5 (`checksumRequired`): `remoteChecksums` — заздалегідь
    /// знятий батчем словник (батчевий шлях) або nil → один виклик на елемент. Файли з
    /// розбіжністю видаляються локально і кидається checksumMismatch (resumable) — докачка
    /// перепулює лише їх.
    func finishAfterPull(
        entry: RemoteEntry,
        expected: [RemoteFileRecord],
        dirRecords: [(path: String, modified: Date)],
        pulled: URL,
        destination: URL,
        serial: String,
        remoteChecksums: [String: String]? = nil,
        progress: inout TransferProgress,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> (url: URL, dateFailures: Int, verified: VerifiedManifest) {
        // Дата створення = даті модифікації (pull -a вже виставив mtime з телефона).
        progress.phase = .settingDates
        onProgress(progress)
        var dateFailures = Self.setCreationDatesToModificationDates(root: pulled, fileManager: fileManager)

        // pull -a зберігає дати лише файлів — теки відновлюємо з переліку, знятого з телефона.
        if entry.isDirectory {
            dateFailures += Self.restoreDirectoryDates(
                records: dirRecords, remoteRoot: entry.path, localRoot: pulled, fileManager: fileManager
            )
        }

        // Верифікація: кількість і розміри файлів мають збігтися з телефоном.
        progress.phase = .verifying
        onProgress(progress)
        var verified = try Self.verify(expected: expected, remoteRoot: entry.path, localRoot: pulled, fileManager: fileManager)

        if checksumRequired {
            progress.phase = .checksumming
            onProgress(progress)
            let sums: [String: String]
            if let remoteChecksums {
                sums = remoteChecksums
            } else {
                sums = try await client.checksums(entry.path, on: serial, onSpawn: cancellation.trackProcess)
                cancellation.clearProcess()
            }
            if cancellation.isCancelled { throw ADBError.cancelled }
            let mismatched = Self.checksumMismatches(remote: sums, expected: expected, remoteRoot: entry.path, localRoot: pulled)
            if !mismatched.isEmpty {
                for relative in mismatched {
                    let url = relative.isEmpty ? pulled : pulled.appendingPathComponent(relative)
                    try? fileManager.removeItem(at: url)
                }
                throw ADBError.checksumMismatch(mismatched.first.map { $0.isEmpty ? entry.name : $0 } ?? entry.name)
            }
            verified = Self.withChecksumsVerified(verified)
        }

        // Фінальне ім'я з розв'язанням колізій, атомарне перейменування.
        let finalURL = Self.collisionFreeURL(for: entry.name, in: destination, fileManager: fileManager)
        try fileManager.moveItem(at: pulled, to: finalURL)

        if dateFailures > 0 {
            // Не фатально: файли на місці, лише частина creationDate не виставилась. Окрім
            // NSLog для розробника — число йде й нагору, у TransferItemResult.warning,
            // де його побачить користувач.
            NSLog("AndroidMover: не вдалося виставити creationDate для \(dateFailures) файлів у \(finalURL.path)")
        }
        return (finalURL, dateFailures, verified)
    }
}
