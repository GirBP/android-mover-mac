import SwiftUI
import Observation
import Foundation
import AndroidMoverCore

/// Видалити/перейменувати/нова тека на телефоні. Тримає сильні однонапрямні посилання на
/// DeviceStore/BrowserStore/TransferCoordinator (останнє — лише щоб дописувати в спільну
/// історію операцій).
@MainActor
@Observable
final class FileActions {
    let deviceStore: DeviceStore
    let browserStore: BrowserStore
    let transfers: TransferCoordinator

    var confirmingDelete = false
    var deleteTargetIDs = Set<String>()
    var renamingEntry: RemoteEntry?
    var renameText = ""
    var showingNewFolder = false
    var newFolderName = ""
    var actionError: String?

    init(deviceStore: DeviceStore, browserStore: BrowserStore, transfers: TransferCoordinator) {
        self.deviceStore = deviceStore
        self.browserStore = browserStore
        self.transfers = transfers
    }

    /// Фільтр `index.visibleEntries` (той самий патерн, що в `BrowserStore.selectedEntries`),
    /// не `deleteTargetIDs.compactMap { index.byID[$0] }` — ітерація по `Set<String>` не
    /// прив'язана до порядку в таблиці (hash-bucket, залежить від рандомізації хешу String у
    /// процесі), тож історія/помилки видалення (deleteConfirmed нижче) вийшли б у довільному
    /// порядку відносно того, що бачив і обирав користувач. O(|visibleEntries|) замість
    /// O(|deleteTargetIDs|), але видалення — не гарячий шлях (виклик на дію користувача, не на
    /// кожен ре-рендер), і на відміну від `Set.compactMap` зберігає порядок таким, яким його
    /// бачить користувач у таблиці.
    var deleteTargets: [RemoteEntry] {
        guard !deleteTargetIDs.isEmpty else { return [] }
        return browserStore.index.visibleEntries.filter { deleteTargetIDs.contains($0.id) }
    }

    /// Валідація проти видимого, не проти `entries` (усе) — єдина точка входу для видалення
    /// (контекстне меню Table і ⌘⌫ у AppCommands обидва йдуть сюди), тож досить перевірити
    /// тут, щоб жоден шлях не міг підсунути прихований тумблером/фільтром id у підтвердження
    /// видалення. `index.visibleIDs` — уже готовий Set, без перебудови на кожен виклик, навіть
    /// для видалення одного файла.
    func requestDelete(_ ids: Set<String>) {
        let valid = ids.filter { browserStore.index.visibleIDs.contains($0) }
        guard !valid.isEmpty else { return }
        deleteTargetIDs = valid
        confirmingDelete = true
    }

    func deleteConfirmed() {
        let targets = deleteTargets
        deleteTargetIDs = []
        guard !targets.isEmpty, let client = deviceStore.client, let serial = deviceStore.activeDevice?.serial
        else { return }
        Task {
            var errors: [String] = []
            var deletedMediaPaths: [String] = []
            var deletedAny = false
            var historyItems: [HistoryItem] = []
            for entry in targets {
                do {
                    try await client.delete(entry.path, on: serial)
                    deletedAny = true
                    historyItems.append(HistoryItem(
                        name: entry.name, remotePath: entry.path, bytes: entry.size,
                        status: "deleted", localPath: nil
                    ))
                    if !entry.isDirectory, MediaKind.mediaExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                        deletedMediaPaths.append(entry.path)
                    }
                } catch {
                    historyItems.append(HistoryItem(
                        name: entry.name, remotePath: entry.path, bytes: entry.size,
                        status: "failed: \(error.localizedDescription)", localPath: nil
                    ))
                    errors.append("\(entry.name): \(error.localizedDescription)")
                }
            }
            if !errors.isEmpty { actionError = errors.joined(separator: "\n") }
            transfers.appendHistory(direction: "delete", items: historyItems)
            await browserStore.refreshList()
            // Best-effort, fire-and-forget: ніколи не блокує і не провалює саме видалення.
            if deletedAny {
                Task {
                    try? await client.rescanMedia(deletedMediaPaths, on: serial)
                    try? await client.rescanVolume(on: serial)
                }
            }
        }
    }

    func beginRename(_ entry: RemoteEntry) {
        renameText = entry.name
        renamingEntry = entry
    }

    func confirmRename() {
        guard let entry = renamingEntry, let client = deviceStore.client, let serial = deviceStore.activeDevice?.serial
        else {
            renamingEntry = nil
            return
        }
        renamingEntry = nil
        let newName = renameText
        guard newName != entry.name else { return }
        Task {
            do {
                _ = try await client.rename(entry.path, to: newName, on: serial)
            } catch {
                actionError = error.localizedDescription
            }
            await browserStore.refreshList()
        }
    }

    func confirmNewFolder() {
        showingNewFolder = false
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty, !name.contains("/"), let client = deviceStore.client,
              let serial = deviceStore.activeDevice?.serial
        else {
            // Порожнє/пробільне ім'я теж пояснюється, а не мовчки відкидається.
            actionError = name.isEmpty
                ? String(localized: "Введіть ім'я теки.")
                : String(localized: "Недопустиме ім'я теки.")
            return
        }
        Task {
            do {
                try await client.makeDirectory(RemotePath.join(browserStore.currentPath, name), on: serial)
            } catch {
                actionError = error.localizedDescription
            }
            await browserStore.refreshList()
        }
    }
}
