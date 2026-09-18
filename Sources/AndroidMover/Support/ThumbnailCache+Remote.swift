import AppKit
import CryptoKit
import AndroidMoverCore

/// Мініатюри фото прямо з телефона — не цілий файл, а перші 64 КБ (EmbeddedThumbnail):
/// вбудований EXIF/HEIC-thumbnail. Тека DCIM на 50 ГБ показує превʼю без гігабайтів трафіку.
///
/// Правила, щоб таблиця на 50k рядків не захлинулась:
/// - лише видимі рядки (`.task(id:)` рядка; зник зі скролу — Task скасовано, черга його забуває);
/// - не більше `maxConcurrent` adb-процесів одночасно, решта чекає LIFO (щойно показані — перші);
/// - результат (і «мініатюри нема») лягає на диск у ~/Library/Caches — наступний запуск нічого
///   не перечитує з телефона; жодного синхронного FileManager на MainActor — усе в detached.
extension ThumbnailCache {
    static let remoteThumbnailsDefaultsKey = "browser.remoteThumbnails"
    nonisolated static let maxConcurrent = 3
    /// Довша сторона збереженої мініатюри в px (вбудовані EXIF — зазвичай 160×120).
    nonisolated static let storedPixelSize = 160

    nonisolated static let diskRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AndroidMover/thumbs", isDirectory: true)
    }()

    /// Тумблер у Settings; за замовчуванням увімкнено.
    static var remoteThumbnailsEnabled: Bool {
        UserDefaults.standard.object(forKey: remoteThumbnailsDefaultsKey) as? Bool ?? true
    }

    /// Ім'я файла в дисковому кеші — стабільний хеш ключа (hashValue рандомізується між
    /// запусками, тому не годиться). Порожній файл = «вбудованої мініатюри нема».
    nonisolated static func diskURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return diskRoot.appendingPathComponent(digest + ".jpg")
    }

    /// Викликається з `.task(id:)` рядка таблиці; скасування Task = рядок зник з екрана.
    func loadRemoteThumbnail(for entry: RemoteEntry) async {
        guard !entry.isDirectory, !entry.isSymlink, entry.size > 0,
              Self.remoteThumbnailsEnabled,
              EmbeddedThumbnail.supports(name: entry.name),
              let fetcher = remoteFetcher else { return }
        let key = PreviewStore.previewCacheKey(for: entry)
        guard thumbnail(for: entry) == nil, !negativeKeys.contains(key), !remotePending.contains(key) else { return }

        remotePending.insert(key)
        defer { remotePending.remove(key) }
        guard await acquireSlot() else { return }
        defer { releaseSlot() }

        let diskURL = Self.diskURL(forKey: key)
        if let cached = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: diskURL) }).value {
            if cached.isEmpty {
                negativeKeys.insert(key)
            } else if let image = NSImage(data: cached) {
                storeRemote(image, for: key)
            }
            return
        }
        if Task.isCancelled { return }

        let head: Data
        do {
            head = try await fetcher(entry)
        } catch {
            return   // обрив/таймаут — не «нема мініатюри», спробуємо наступного разу
        }
        let encoded: Data? = await Task.detached(priority: .utility) {
            guard let cg = EmbeddedThumbnail.extract(from: head, maxPixelSize: Self.storedPixelSize) else { return nil }
            return EmbeddedThumbnail.jpegData(cg)
        }.value

        let payload = encoded ?? Data()
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: Self.diskRoot, withIntermediateDirectories: true)
            try? payload.write(to: diskURL, options: .atomic)
        }
        if let encoded, let image = NSImage(data: encoded) {
            storeRemote(image, for: key)
        } else {
            negativeKeys.insert(key)
        }
    }

    // MARK: - Ліміт одночасних adb-процесів (LIFO: свіжопоказані рядки — перші)

    private func acquireSlot() async -> Bool {
        if freeSlots > 0 {
            freeSlots -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    slotWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        slotWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseSlot() {
        if let waiter = slotWaiters.popLast() {
            waiter.continuation.resume(returning: true)
        } else {
            freeSlots += 1
        }
    }

    /// Дисковий кеш — раз на запуск, у фоні: понад `pruneAbove` файлів — почати заново
    /// (простий cap, як і в пам'яті; ~5 КБ на файл → 30k файлів ≈ 150 МБ).
    static func pruneDiskCacheIfNeeded(pruneAbove: Int = 30_000) {
        Task.detached(priority: .background) {
            let root = diskRoot
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path), names.count > pruneAbove else { return }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
