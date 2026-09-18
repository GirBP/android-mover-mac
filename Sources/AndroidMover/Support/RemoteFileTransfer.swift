import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import AndroidMoverCore

/// Перетягування рядка з таблиці у Finder. Promise-семантика Transferable: pull запускається
/// ЛИШЕ в момент фактичного дропу, не в момент початку драгу — скасований чи "промахнутий"
/// драг не займає жодного трафіку з телефона.
///
/// v0.10.2: drag стоїть на `TableRow.draggable` (BrowserView), тож у Finder тягнуться всі виділені
/// рядки разом — кожен зі своїм payload; помилка pull під час дропу показується системно (macOS),
/// не нашим UI.
struct RemoteFileTransfer: Transferable, Sendable {
    let entry: RemoteEntry
    let adbPath: String
    let serial: String

    static var transferRepresentation: some TransferRepresentation {
        // Окремі представлення для файла й теки: Finder приймає й так, і так, але
        // правильний UTType для теки (.folder) чесніший за загальний .item.
        FileRepresentation(exportedContentType: .item) { transfer in try await Self.export(transfer) }
            .exportingCondition { !$0.entry.isDirectory }
        FileRepresentation(exportedContentType: .folder) { transfer in try await Self.export(transfer) }
            .exportingCondition { $0.entry.isDirectory }
    }

    /// НЕ тягнемо клас ADBClient у struct (Transferable-значення може перетинати межі черг) —
    /// створюємо клієнт тут-таки, усередині @Sendable exporting-замикання.
    private static func export(_ transfer: RemoteFileTransfer) async throws -> SentTransferredFile {
        // v0.10.2: payload тепер на кожному рядку безумовно (TableRow.draggable) — недоступність
        // (нема adb/пристрою, symlink) перевіряється тут, у момент дропу, а не при побудові рядка.
        guard !transfer.adbPath.isEmpty, !transfer.serial.isEmpty, !transfer.entry.isSymlink else {
            throw DragUnavailableError()
        }
        // Best-effort прибирання минулих дропів: dragCacheRoot чиститься цілком лише при
        // bootstrap (наступний запуск), тож успішні дропи за сесію накопичуються. Свіжий
        // (< ~30 хв) підтек не займаємо — це може бути дроп, який ОС ще фактично копіює.
        sweepStaleCacheEntries()

        let client = ADBClient(adbPath: transfer.adbPath)
        let cacheDir = PreviewStore.dragCacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // 2.2: спільний контролер скасування (SIGTERM→3с→SIGKILL, одноразова ескалація,
        // закритий гачок гонки spawn-після-cancel) — раніше тут окремо жили processBox/
        // cancelled/killIssued/terminateAdbProcess, дубльовані з TransferEngine/PushEngine.
        let cancellation = CancellationController()

        do {
            let result = try await withTaskCancellationHandler {
                try await client.pull(
                    transfer.entry.path, into: cacheDir, on: transfer.serial,
                    onSpawn: cancellation.trackProcess
                )
                let target = cacheDir.appendingPathComponent(transfer.entry.name)
                return SentTransferredFile(target, allowAccessingOriginalFile: false)
            } onCancel: {
                cancellation.cancel()
            }
            return result
        } catch {
            // Скасований чи провалений дроп лишив би по собі порожню/часткову cacheDir —
            // прибираємо, щоб не накопичувати сироти між sweep-ами.
            try? FileManager.default.removeItem(at: cacheDir)
            throw error
        }
    }

    /// Видаляє з dragCacheRoot підтеки старші за ~30 хв. Best-effort і тихо (try?) — це
    /// гігієна кешу, а не критичний шлях перенесення.
    private static func sweepStaleCacheEntries() {
        let root = PreviewStore.dragCacheRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-30 * 60)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// Дроп неможливий: нема adb/пристрою або елемент — символічне посилання (не підтримується).
struct DragUnavailableError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Перетягування недоступне: підключіть телефон; символічні посилання не переносяться.")
    }
}
