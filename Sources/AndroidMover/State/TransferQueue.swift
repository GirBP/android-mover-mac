import Foundation
import AndroidMoverCore

/// Механіка черги операцій — `extension TransferCoordinator` (той самий тип, що в
/// TransferCoordinator.swift, розбитий по файлах). Публічний API: `enqueueTransfer`/
/// `enqueuePush` (додати в чергу), `cancel(id:)`/`remove(id:)`/`clearFinished()` (керування
/// чергою з OperationQueuePanel), `hasActiveTransfer` (гейт DeviceStore/BrowserStore,
/// AppState.init). `runNextIfNeeded()` — приватний мотор послідовного виконання: щонайбільше
/// один елемент `.active` одночасно, виклик після кожного enqueue і після завершення кожної
/// операції.
extension TransferCoordinator {
    /// «Є активний transfer у черзі» — лише transfer (copy/move), не push: push ніколи не
    /// блокував track-devices/лістинг.
    var hasActiveTransfer: Bool {
        queue.contains {
            guard case .transfer(let session) = $0 else { return false }
            return session.started && session.results == nil
        }
    }

    // MARK: - Постановка в чергу

    /// Ставить елемент у чергу й одразу пробує запустити (`runNextIfNeeded`) — якщо черга
    /// була порожня/без активного елемента, запуск відбувається негайно (1:1 зі старою
    /// поведінкою "натиснув — почалось"); якщо ні — елемент чекає своєї черги зі станом
    /// `.pending` (OperationQueuePanel показує "У черзі").
    /// Пристрій — явний параметр, а не `deviceStore.activeDevice`: відновлення після краху
    /// передає сюди serial із журналу, звичайний старт — активний.
    func enqueueTransfer(entries: [RemoteEntry], destination: URL, move: Bool, serial: String, deviceLabel: String) {
        guard let client = deviceStore.client, !entries.isEmpty else { return }
        let engine = TransferEngine(client: client, checksumPolicy: Self.checksumPolicy)
        // Запис у журнал ще до старту — крах посеред операції лишить його відкритим, і
        // наступний запуск запропонує продовжити.
        let record = JournalRecord(
            kind: .pull, serial: serial, deviceLabel: deviceLabel,
            move: move, destination: destination.path,
            entries: entries.map { JournalEntry(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, size: $0.size) },
            deviceStableID: deviceStore.stableID(for: serial)
        )
        try? journal.start(record)
        activeJournalIDs.insert(record.id)
        let journal = self.journal
        let session = TransferSession(
            engine: engine, move: move, itemCount: entries.count,
            targetSerial: serial, targetDeviceLabel: deviceLabel
        )
        session.launch = { [weak self, weak session] in
            guard let self, let session else { return }
            // Перевірка, не повторне читання «поточного активного пристрою» — serial
            // зафіксований у enqueueTransfer вище, разом з entries/destination. Якщо саме
            // цей пристрій зник чи більше не ready, елемент чесно провалюється — жодного
            // pull/delete проти якогось іншого (можливо, підключеного щойно) пристрою під
            // чужими шляхами.
            guard self.deviceStore.devices.contains(where: { $0.serial == session.targetSerial && $0.state == .ready }) else {
                session.globalError = String(localized: "Пристрій \(session.targetDeviceLabel) більше не підключений")
                session.results = []
                self.runNextIfNeeded()
                return
            }
            let serial = session.targetSerial
            Task {
                do {
                    let results = try await engine.transfer(
                        entries: entries, to: destination, serial: serial, move: move,
                        onProgress: { progress in
                            Task { @MainActor in
                                if session.isRunning { session.progress = progress }
                            }
                        },
                        onItemFinished: { result in
                            // Стан кожного елемента — у журнал одразу, не в кінці.
                            let state: JournalItemState
                            switch result.status {
                            case .copied, .moved, .cancelled: state = JournalItemState(kind: .done, localPath: result.finalURL?.path)
                            case .copiedButDeleteFailed: state = JournalItemState(kind: .copiedNotDeleted, localPath: result.finalURL?.path)
                            case .failed: state = JournalItemState(kind: .failed)
                            }
                            try? journal.markItem(recordID: record.id, path: result.entry.path, state: state)
                        }
                    )
                    session.results = results
                    if session.cancelRequested {
                        try? journal.remove(recordID: record.id)   // скасування — усвідомлене, не відновлюємо
                    } else {
                        try? journal.finish(recordID: record.id)
                    }
                    self.activeJournalIDs.remove(record.id)
                    self.loadRecoverable()
                    // Усі елементи, включно з failed/cancelled — чесність журналу.
                    self.appendHistory(
                        direction: move ? "move" : "copy",
                        items: results.map(TransferCoordinator.historyItem(for:))
                    )
                    if move {
                        // results — 1:1 з entries (той самий порядок і кількість, engine гарантує).
                        let movedMediaPaths = zip(entries, results).compactMap { entry, result -> String? in
                            guard result.status == .moved, !entry.isDirectory,
                                  MediaKind.mediaExtensions.contains((entry.name as NSString).pathExtension.lowercased())
                            else { return nil }
                            return entry.path
                        }
                        let movedAny = results.contains { $0.status == .moved }
                        // Best-effort, fire-and-forget: ніколи не блокує і не провалює перенесення.
                        if movedAny {
                            Task {
                                try? await client.rescanMedia(movedMediaPaths, on: serial)
                                try? await client.rescanVolume(on: serial)
                            }
                        }
                    }
                } catch {
                    session.globalError = error.localizedDescription
                    session.results = []
                    try? journal.remove(recordID: record.id)   // не стартувала — нема чого відновлювати
                    self.activeJournalIDs.remove(record.id)
                    self.loadRecoverable()
                }
                // Transfer щойно завершився (results виставлено обома шляхами вище) —
                // DeviceStore міг заморозити кадри track-devices, доки hasActiveTransfer був
                // true; публікуємо найсвіжіший накопичений кадр зараз.
                self.onOperationEnded?()
                self.browserStore.invalidateListingCache()
                await self.browserStore.refreshList()
                // Цей елемент завершився — звільняємо чергу для наступного `.pending`.
                self.runNextIfNeeded()
            }
        }
        queue.append(.transfer(session))
        isQueuePanelExpanded = true
        runNextIfNeeded()
    }

    /// Дзеркало enqueueTransfer для push — той самий deferred-launch патерн; `destDir`
    /// знімається тут (момент постановки в чергу), не в момент фактичного старту.
    func enqueuePush(urls: [URL], destDir: String, serial: String, deviceLabel: String) {
        guard let client = deviceStore.client, !urls.isEmpty else { return }
        let engine = PushEngine(client: client)
        let record = JournalRecord(
            kind: .push, serial: serial, deviceLabel: deviceLabel,
            move: false, destination: destDir,
            entries: urls.map { JournalEntry(path: $0.path, name: $0.lastPathComponent, isDirectory: $0.hasDirectoryPath, size: 0) },
            deviceStableID: deviceStore.stableID(for: serial)
        )
        try? journal.start(record)
        activeJournalIDs.insert(record.id)
        let journal = self.journal
        let session = PushSession(
            engine: engine, itemCount: urls.count,
            targetSerial: serial, targetDeviceLabel: deviceLabel
        )
        session.launch = { [weak self, weak session] in
            guard let self, let session else { return }
            // Те саме, що в enqueueTransfer вище: перевірка зафіксованого serial, не
            // повторне читання поточного активного пристрою.
            guard self.deviceStore.devices.contains(where: { $0.serial == session.targetSerial && $0.state == .ready }) else {
                session.globalError = String(localized: "Пристрій \(session.targetDeviceLabel) більше не підключений")
                session.results = []
                self.runNextIfNeeded()
                return
            }
            let serial = session.targetSerial
            Task {
                do {
                    let results = try await engine.push(
                        urls: urls, to: destDir, serial: serial,
                        onProgress: { progress in
                            Task { @MainActor in
                                if session.isRunning { session.progress = progress }
                            }
                        },
                        onItemFinished: { result in
                            let kind: JournalItemState.Kind
                            switch result.status {
                            case .pushed, .cancelled: kind = .done
                            case .failed: kind = .failed
                            }
                            try? journal.markItem(recordID: record.id, path: result.localURL.path, state: JournalItemState(kind: kind))
                        }
                    )
                    session.results = results
                    if session.cancelRequested { try? journal.remove(recordID: record.id) } else { try? journal.finish(recordID: record.id) }
                    self.activeJournalIDs.remove(record.id)
                    self.loadRecoverable()
                    self.appendHistory(direction: "push", items: results.map(TransferCoordinator.historyItem(forPush:)))

                    // Best-effort, fire-and-forget: ніколи не блокує і не провалює push.
                    let pushedMediaPaths = results.compactMap { result -> String? in
                        guard result.status == .pushed, let remotePath = result.remotePath,
                              MediaKind.mediaExtensions.contains((result.name as NSString).pathExtension.lowercased())
                        else { return nil }
                        return remotePath
                    }
                    let pushedAny = results.contains { $0.status == .pushed }
                    if pushedAny {
                        Task {
                            try? await client.rescanMedia(pushedMediaPaths, on: serial)
                            try? await client.rescanVolume(on: serial)
                        }
                    }
                } catch {
                    session.globalError = error.localizedDescription
                    session.results = []
                }
                self.browserStore.invalidateListingCache()
                await self.browserStore.refreshList()
                self.runNextIfNeeded()
            }
        }
        queue.append(.push(session))
        isQueuePanelExpanded = true
        runNextIfNeeded()
    }

    // MARK: - Керування чергою (OperationQueuePanel)

    /// `.pending` — прибирає елемент із черги без запуску (ніколи не викликав engine).
    /// `.active` — скасовує роботу, що виконується (SIGTERM→3с→SIGKILL); рядок лишається в
    /// черзі до фактичного завершення Task (результат "cancelled" по елементах).
    /// `.finished` — no-op, для прибирання завершених є `remove(id:)`/`clearFinished()`.
    func cancel(id: UUID) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        switch item.rowState {
        case .pending: queue.removeAll { $0.id == id }
        case .active: item.requestCancel()
        case .finished: break
        }
    }

    /// Лише завершені елементи — «×» на рядку.
    func remove(id: UUID) {
        queue.removeAll { $0.id == id && $0.rowState == .finished }
    }

    /// «Очистити завершені» в шапці панелі.
    func clearFinished() {
        queue.removeAll { $0.rowState == .finished }
    }

    // MARK: - Підтвердження закриття вікна/виходу з додатка

    /// Чи є в черзі щось незавершене (active чи pending) — і AppDelegate
    /// (applicationShouldTerminate), і WindowAccessor (windowShouldClose одного вікна)
    /// перевіряють це, перш ніж показати alert підтвердження.
    var hasQueueWork: Bool {
        queue.contains { $0.rowState != .finished }
    }

    /// Викликається з обох alert-ів підтвердження (весь додаток чи одне вікно), лише коли
    /// користувач підтвердив закриття попри активну роботу. pending — прибрати з черги
    /// (ніколи не стартував, нічого скасовувати); active — cancel() (та сама SIGTERM-
    /// ескалація, що й звичайна кнопка «Скасувати» в панелі) — синхронно шле сигнал
    /// дочірньому adb-процесу негайно, а не покладається лише на бекстоп процес-рівня
    /// (ChildProcessRegistry — той спрацює однаково, але пізніше й лише при фактичному виході).
    func cancelAll() {
        for item in queue where item.rowState == .active {
            item.requestCancel()
        }
        queue.removeAll { $0.rowState == .pending }
    }

    // MARK: - Послідовний запуск

    /// Щонайбільше один елемент `.active` одночасно — якщо такий уже є, нічого не робимо
    /// (наступний `.pending` дочекається завершення поточного, яке саме й покличе цей метод
    /// знову). Викликається після кожного enqueue і в кінці кожного launch-Task.
    private func runNextIfNeeded() {
        defer { updateSleepAssertion() }
        guard !queue.contains(where: { $0.rowState == .active }) else { return }
        queue.first(where: { $0.rowState == .pending })?.start()
    }

    // MARK: - Відновлення після краху

    /// Політика контрольних сум із Settings («Звіряти md5»: перед видаленням / завжди / ніколи).
    static var checksumPolicy: ChecksumPolicy {
        ChecksumPolicy(rawValue: UserDefaults.standard.string(forKey: "transfer.checksumPolicy") ?? "") ?? .beforeDelete
    }

    func loadRecoverable() {
        // Записи операцій, що виконуються зараз у цій сесії, теж «відкриті» — але це не
        // «незавершене з минулого», банер їх не показує.
        recoverable = journal.unfinished().filter { !activeJournalIDs.contains($0.id) }
        recoveryMessage = nil
    }

    func dismissRecovery(_ record: JournalRecord) {
        try? journal.remove(recordID: record.id)
        loadRecoverable()
    }

    /// «Продовжити»: решта елементів → нова операція в чергу; «скопійовано, але не видалено»
    /// → довидалення після повторної перевірки (копія на Mac існує і розмір збігається з
    /// файлом на телефоні прямо зараз). Потребує того самого пристрою в стані ready.
    func resumeRecovery(_ record: JournalRecord) {
        // Телефон шукаємо за стабільною ідентичністю з журналу — після перезавантаження
        // Wi-Fi-адреса інша, а телефон той самий; старий запис без ідентичності — лише той самий serial.
        let serial = record.deviceStableID.flatMap { deviceStore.connectedSerial(forStableID: $0) } ?? record.serial
        guard deviceStore.devices.contains(where: { $0.serial == serial && $0.state == .ready }),
              let client = deviceStore.client else {
            recoveryMessage = String(localized: "Підключіть телефон \(record.deviceLabel), щоб продовжити")
            return
        }
        switch record.kind {
        case .pull:
            let pending = record.pendingEntries.map {
                RemoteEntry(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, isSymlink: false, size: $0.size, modified: Date())
            }
            let destination = URL(fileURLWithPath: record.destination, isDirectory: true)
            if !pending.isEmpty {
                if self.destination?.path != destination.path { addDestination(destination) }
                enqueueTransfer(entries: pending, destination: destination, move: record.move,
                                serial: serial, deviceLabel: record.deviceLabel)
            }
            let cleanup = record.copiedNotDeletedEntries
            try? journal.remove(recordID: record.id)
            loadRecoverable()
            if !cleanup.isEmpty {
                Task { await self.finishPendingDeletes(cleanup, client: client, serial: serial, deviceLabel: record.deviceLabel) }
            }
        case .push:
            let pending = record.pendingEntries.map { URL(fileURLWithPath: $0.path, isDirectory: $0.isDirectory) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            try? journal.remove(recordID: record.id)
            loadRecoverable()
            if !pending.isEmpty {
                enqueuePush(urls: pending, destDir: record.destination, serial: serial, deviceLabel: record.deviceLabel)
            }
        }
    }

    /// Довидалення з телефона лише тих файлів, чия копія на Mac існує і чий розмір на телефоні
    /// зараз збігається з копією (файл не змінився з моменту переносу). Теки — пропускаються з
    /// поясненням (їх безпечно видалити лише пофайлово, що робить сам рушій під час move).
    private func finishPendingDeletes(_ items: [(entry: JournalEntry, localPath: String?)], client: ADBClient, serial: String, deviceLabel: String) async {
        var safeToDelete: [String] = []
        var historyItems: [HistoryItem] = []
        for item in items where !item.entry.isDirectory {
            guard let localPath = item.localPath,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                  let localSize = attrs[.size] as? Int64,
                  let remote = try? await client.recursiveFiles(item.entry.path, on: serial),
                  remote.count == 1, remote[0].size == localSize
            else {
                historyItems.append(HistoryItem(name: item.entry.name, remotePath: item.entry.path, bytes: 0,
                                                status: "failed: копію не підтверджено — на телефоні не видалено", localPath: item.localPath))
                continue
            }
            // Та сама md5-політика, що й у штатному move — розмір сам по собі не доводить,
            // що копія на Mac побайтово та сама.
            if Self.checksumPolicy != .never {
                let remoteSums = try? await client.checksumsMany([item.entry.path], on: serial)
                let localHash = try? TransferEngine.md5Hex(of: URL(fileURLWithPath: localPath))
                guard let remoteHash = remoteSums?[item.entry.path], let localHash, remoteHash == localHash else {
                    historyItems.append(HistoryItem(name: item.entry.name, remotePath: item.entry.path, bytes: 0,
                                                    status: "failed: md5 копії не збігається з телефоном — не видалено", localPath: item.localPath))
                    continue
                }
            }
            safeToDelete.append(item.entry.path)
        }
        if !safeToDelete.isEmpty {
            let failed = (try? await client.deleteMany(safeToDelete, on: serial)) ?? Set(safeToDelete)
            for path in safeToDelete {
                let entry = items.first { $0.entry.path == path }!
                historyItems.append(HistoryItem(name: entry.entry.name, remotePath: path, bytes: entry.entry.size,
                                                status: failed.contains(path) ? "failed: не вдалося видалити" : "deleted", localPath: entry.localPath))
            }
        }
        for item in items where item.entry.isDirectory {
            historyItems.append(HistoryItem(name: item.entry.name, remotePath: item.entry.path, bytes: 0,
                                            status: "failed: теку довидаліть вручну після перевірки", localPath: item.localPath))
        }
        appendHistory(direction: "delete", items: historyItems)
        browserStore.invalidateListingCache()
        await browserStore.refreshList()
    }

    /// Доки в черзі є активна операція — Mac не засинає сам (idle sleep): сон посеред
    /// pull/push розриває USB-сесію adb. Кришку/⌘-Sleep це не блокує — лише автоматичне
    /// засинання від бездіяльності.
    func updateSleepAssertion() {
        let busy = queue.contains { $0.rowState == .active }
        if busy, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Android Mover: перенесення файлів"
            )
        } else if !busy, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}
