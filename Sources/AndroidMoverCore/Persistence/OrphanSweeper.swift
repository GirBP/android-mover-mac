import Foundation

/// Прибирання «сиріт» — тимчасових тек `.androidmover-tmp-*` (TransferEngine/PushEngine),
/// які лишаються на диску Mac чи на телефоні після аварійного завершення (crash, kill -9,
/// вимкнення живлення, розрив adb посеред роботи) — звичайний `defer`/best-effort delete у самих
/// рушіях не встигає спрацювати. Викликається best-effort при підключенні пристрою/зміні
/// призначення — ніколи не блокує UI і ніколи не кидає (усі провали — тихі, `try?`).
public enum OrphanSweeper {
    public static let tmpPrefix = ".androidmover-tmp-"

    /// Видаляє елементи з префіксом `.androidmover-tmp-` у `dir`, чия дата модифікації старша
    /// за `olderThan` секунд від "зараз". Повертає кількість видалених. Best-effort: провал
    /// одного елемента (права доступу, гонка з іншим процесом) не зупиняє решту.
    @discardableResult
    public static func sweepLocal(
        in dir: URL,
        olderThan: TimeInterval,
        fileManager: FileManager = .default
    ) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return 0 }
        let cutoff = Date().addingTimeInterval(-olderThan)
        var removed = 0
        for item in items {
            guard item.lastPathComponent.hasPrefix(tmpPrefix) else { continue }
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            if (try? fileManager.removeItem(at: item)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Той самий sweep на телефоні: лістинг `dir` → елементи з тим самим префіксом і `modified`
    /// старший за поріг → `client.delete`. Best-effort на кожному кроці: провал самого лістингу
    /// (пристрій щойно відпав) тихо повертає 0, провал окремого delete не зупиняє решту.
    @discardableResult
    public static func sweepRemote(
        in dir: String,
        olderThan: TimeInterval,
        client: ADBClient,
        serial: String
    ) async -> Int {
        guard let entries = try? await client.listDirectory(dir, on: serial) else { return 0 }
        let cutoff = Date().addingTimeInterval(-olderThan)
        var removed = 0
        for entry in entries {
            guard entry.name.hasPrefix(tmpPrefix), entry.modified < cutoff else { continue }
            if (try? await client.delete(entry.path, on: serial)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
