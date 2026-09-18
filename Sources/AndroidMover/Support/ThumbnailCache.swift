import AppKit
import Observation
import QuickLookThumbnailing
import AndroidMoverCore

/// Мініатюри з двох джерел: (A3) файли, що вже осіли в preview-кеші після Quick Look —
/// повноцінна QL-мініатюра без трафіку; (4.1, +Remote.swift) фото JPEG/HEIC на телефоні —
/// вбудований EXIF-thumbnail з перших 64 КБ файла. Масового pull цілих файлів заради іконок
/// як не було, так і нема. Ключ той самий, що в PreviewStore.previewCacheURL
/// (шлях|розмір|mtime): нова версія файла на телефоні — нова мініатюра, стара не плутається.
@MainActor
@Observable
final class ThumbnailCache {
    private var cache: [String: NSImage] = [:]
    private var pending: Set<String> = []
    // v0.10.1 (перф-фікс): ключі, для яких ВЖЕ відомо (PreviewStore.markCached, викликається
    // одразу після позитивного fileExists у PreviewStore.previewFile), що файл лежить у
    // preview-кеші на диску. requestThumbnail нижче читає ЛИШЕ це — жодного синхронного
    // FileManager.fileExists (дисковий stat на MainActor) на кожну появу рядка Table під час
    // скролу віртуалізованого списку з 50k елементів.
    private var knownCachedKeys: Set<String> = []

    // 4.1 (ThumbnailCache+Remote.swift): мініатюри з перших 64 КБ файла на телефоні.
    /// Постачальник перших байтів файла — PreviewStore підключає ADBClient.readHead.
    var remoteFetcher: (@Sendable (RemoteEntry) async throws -> Data)?
    var remotePending: Set<String> = []
    /// Ключі, для яких вбудованої мініатюри в файлі нема — щоб не читати той самий head знову.
    var negativeKeys: Set<String> = []
    var freeSlots = maxConcurrent
    var slotWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Сторона мініатюри в points — рядок таблиці невисокий, більше не потрібно.
    private static let sizePoints: CGFloat = 32
    /// Простий cap без переускладнення: досягли ліміту — почали кеш заново.
    private static let cacheLimit = 3000

    /// Миттєво, без побічних ефектів — те, що вже згенеровано.
    func thumbnail(for entry: RemoteEntry) -> NSImage? {
        cache[PreviewStore.previewCacheKey(for: entry)]
    }

    /// PreviewStore викликає одразу після того, як САМ підтвердив (fileExists), що ключ ліг у
    /// previewCacheRoot — єдине джерело правди про те, які ключі реально мають файл на диску.
    func markCached(_ key: String) {
        knownCachedKeys.insert(key)
    }

    /// Якщо файл уже лежить у preview-кеші і мініатюри для нього ще нема — згенерувати
    /// асинхронно через QLThumbnailGenerator. Якщо файла в кеші нема (Quick Look ще не
    /// робили) — тихо виходить, НІЧОГО не тягнучи з телефона.
    func requestThumbnail(for entry: RemoteEntry) {
        let key = PreviewStore.previewCacheKey(for: entry)
        guard cache[key] == nil, !pending.contains(key), knownCachedKeys.contains(key) else { return }
        let url = PreviewStore.previewCacheURL(for: entry)

        pending.insert(key)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let side = Self.sizePoints * scale
        Task {
            defer { pending.remove(key) }
            guard let png = await Self.generateThumbnailPNG(url: url, side: side, scale: scale),
                  let image = NSImage(data: png)
            else { return }
            // Файл (і сам ключ) міг застаріти, поки генерація йшла в фоні — заново
            // перевіряти нема сенсу: ключ уже враховує шлях+розмір+mtime, тож старе
            // зображення під новим ключем просто нікому не заважає.
            store(image, for: key)
        }
    }

    /// v0.12.1 (CI, Swift 6.1): `QLThumbnailRepresentation` і `QLThumbnailGenerator.Request` —
    /// не-Sendable класи, тому async-API генератора не можна «привезти» на MainActor. Запит
    /// будується тут, поза MainActor, із Sendable-аргументів, а назад повертаються лише PNG-байти
    /// (Data — Sendable на будь-якому компіляторі). Мініатюра 32 pt — конвертація дешева.
    nonisolated private static func generateThumbnailPNG(url: URL, side: CGFloat, scale: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let cgImage = representation?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                continuation.resume(returning: rep.representation(using: .png, properties: [:]))
            }
        }
    }

    func storeRemote(_ image: NSImage, for key: String) { store(image, for: key) }

    private func store(_ image: NSImage, for key: String) {
        if cache.count >= Self.cacheLimit {
            cache.removeAll()
        }
        cache[key] = image
    }
}
