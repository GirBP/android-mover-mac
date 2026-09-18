import SwiftUI
import Observation
import Foundation
import AndroidMoverCore

/// 2.1: швидкий перегляд (Quick Look) і кеші, з яких він і мініатюри (A3) годуються —
/// раніше жило в AppState. Тримає СИЛЬНІ (однонапрямні) посилання на DeviceStore/BrowserStore
/// для client/serial/entries/navigate.
@MainActor
@Observable
final class PreviewStore {
    let deviceStore: DeviceStore
    let browserStore: BrowserStore

    // Швидкий перегляд (Quick Look): файл стягується в кеш-теку і відкривається системно.
    var previewURL: URL?
    var previewLoadingName: String?
    var previewError: String?
    private var previewProcess: ChildProcess?
    /// v0.12.2 (M1, аудит M5): ідентичність запиту — токен, а не ім'я файла. Скасований або
    /// витіснений запит бачить чужий токен і не чіпає стан новішого.
    private var previewToken: UUID?
    private static let previewCacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AndroidMover-preview", isDirectory: true)

    // Мініатюри з preview-кешу, нуль додаткового трафіку (A3).
    let thumbnails = ThumbnailCache()

    /// Куди A4 (drag&drop у Finder) лінивo стягує файл рівно в момент дропу. Окремо від
    /// previewCacheRoot: різний час життя запису (drag — одноразовий, preview — до наступного
    /// запуску) і різна структура (тут не потрібен ключ шлях|розмір|mtime).
    /// nonisolated: RemoteFileTransfer.export (A4) виконується поза MainActor (Transferable
    /// сам обирає чергу для exporting-замикання), а тут лише детермінований шлях без стану.
    nonisolated static let dragCacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AndroidMover-drag", isDirectory: true)

    init(deviceStore: DeviceStore, browserStore: BrowserStore) {
        self.deviceStore = deviceStore
        self.browserStore = browserStore
        // 4.1: перші 64 КБ фото з телефона для вбудованої мініатюри (ThumbnailCache+Remote).
        thumbnails.remoteFetcher = { entry in
            let (client, serial) = await MainActor.run { (deviceStore.client, deviceStore.activeDevice?.serial) }
            guard let client, let serial else { throw CancellationError() }   // нема пристрою — не «нема мініатюри»
            return try await client.readHead(entry.path, bytes: EmbeddedThumbnail.headBytes, on: serial)
        }
        ThumbnailCache.pruneDiskCacheIfNeeded()
    }

    /// Кеш превʼю і кеш перетягувань (A4) живуть лише в межах одного запуску — викликається
    /// раз із AppState.bootstrap().
    static func cleanCachesAtStartup() {
        try? FileManager.default.removeItem(at: previewCacheRoot)
        try? FileManager.default.removeItem(at: dragCacheRoot)
    }

    func previewFile(_ entry: RemoteEntry) {
        guard !entry.isDirectory, !entry.isSymlink, previewLoadingName == nil else { return }
        guard let client = deviceStore.client, let serial = deviceStore.activeDevice?.serial else { return }

        // Ключ версії файла (той самий, що для мініатюр A3): шлях+розмір+mtime відкривається
        // з кешу миттєво.
        let target = Self.previewCacheURL(for: entry)
        if FileManager.default.fileExists(atPath: target.path) {
            previewURL = target
            // v0.10.1: ThumbnailCache більше не питає диск сам (перф-фікс) — тут єдине
            // джерело правди "цей ключ реально має файл на диску".
            thumbnails.markCached(Self.previewCacheKey(for: entry))
            thumbnails.requestThumbnail(for: entry)
            return
        }

        previewLoadingName = entry.name
        previewError = nil
        let token = UUID()
        previewToken = token
        Task {
            do {
                let cacheDir = target.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try await client.pull(entry.path, into: cacheDir, on: serial, onSpawn: { process in
                    Task { @MainActor [weak self] in
                        // Гонка spawn-після-cancel: запит уже не поточний — процес не лишаємо жити.
                        guard let self, self.previewToken == token else { process.terminateWithEscalation(); return }
                        self.previewProcess = process
                    }
                })
                guard previewToken == token else { return } // скасовано або витіснено новішим запитом
                previewProcess = nil
                if FileManager.default.fileExists(atPath: target.path) {
                    previewURL = target
                    // Файл щойно осів у preview-кеші — мініатюру можна згенерувати одразу,
                    // без очікування наступного .task рядка (A3).
                    thumbnails.markCached(Self.previewCacheKey(for: entry))
                    thumbnails.requestThumbnail(for: entry)
                } else {
                    previewError = String(localized: "Не вдалося отримати файл для перегляду.")
                }
            } catch {
                guard previewToken == token else { return }
                previewProcess = nil
                previewError = error.localizedDescription
            }
            previewLoadingName = nil
            previewToken = nil
        }
    }

    /// Ключ версії файла в preview-кеші: шлях+розмір+mtime. Той самий ключ використовує
    /// ThumbnailCache (A3) — щоб знати, який файл уже стягнутий і з нього можна зробити
    /// мініатюру без жодного додаткового трафіку.
    static func previewCacheKey(for entry: RemoteEntry) -> String {
        "\(entry.path)|\(entry.size)|\(Int(entry.modified.timeIntervalSince1970))"
    }

    /// Локальний шлях, куди previewFile() кладе стягнутий файл (існує лише якщо файл уже
    /// переглядався через Quick Look).
    static func previewCacheURL(for entry: RemoteEntry) -> URL {
        let key = previewCacheKey(for: entry)
        let cacheDir = previewCacheRoot
            .appendingPathComponent(String(UInt(bitPattern: key.hashValue), radix: 36), isDirectory: true)
        return cacheDir.appendingPathComponent(entry.name)
    }

    /// v0.12.2 (M1, аудит M4): та сама ескалація SIGTERM → 3 с → SIGKILL, що й усюди —
    /// голий `terminate()` лишав adb, який проігнорував SIGTERM, жити до виходу з додатка.
    func cancelPreview() {
        previewToken = nil
        previewLoadingName = nil
        previewProcess?.terminateWithEscalation()
        previewProcess = nil
    }

    /// Подвійний клік: тека — відкрити, файл — швидкий перегляд.
    /// v0.10.1: `index.byID[id]` — O(1) замість `entries.first(where:)` (O(n) на клік).
    func handleDoubleClick(_ ids: Set<String>) {
        guard ids.count == 1, let id = ids.first,
              let entry = browserStore.index.byID[id] else { return }
        if entry.isDirectory {
            Task { await browserStore.navigate(to: entry.path) }
        } else {
            previewFile(entry)
        }
    }
}
