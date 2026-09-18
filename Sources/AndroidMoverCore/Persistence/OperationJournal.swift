import Foundation

/// v0.11.0 (P4): журнал НЕЗАВЕРШЕНИХ операцій — на відміну від HistoryStore (що сталось), це
/// «що мало статись»: запис створюється при постановці в чергу, стан кожного елемента
/// дописується щойно рушій його закінчив, запис закривається по завершенню. Крах/kill/вимкнення
/// живлення посеред операції лишає відкритий запис — наступний запуск пропонує продовжити
/// (перенести решту; довидалити «скопійовано, але не видалено» після повторної перевірки копії).
public struct JournalEntry: Codable, Sendable, Equatable {
    public let path: String        // pull: шлях на телефоні; push: локальний шлях на Mac
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public init(path: String, name: String, isDirectory: Bool, size: Int64) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct JournalItemState: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case done              // скопійовано/переміщено/запушено — нічого не треба
        case copiedNotDeleted  // копія верифікована на Mac, але з телефона не видалено (move)
        case failed            // чесний провал — при відновленні пропонується ще раз
    }
    public var kind: Kind
    public var localPath: String?   // pull: фінальний шлях копії на Mac (для повторної перевірки перед довидаленням)
    public init(kind: Kind, localPath: String? = nil) {
        self.kind = kind
        self.localPath = localPath
    }
}

public struct JournalRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case pull, push }
    public let id: UUID
    public let startedAt: Date
    public let kind: Kind
    public let serial: String
    public let deviceLabel: String
    public let move: Bool
    /// pull: тека призначення на Mac; push: тека призначення на телефоні.
    public let destination: String
    public let entries: [JournalEntry]
    public var itemStates: [String: JournalItemState] = [:]   // ключ — JournalEntry.path
    public var finished = false
    /// v0.14.0 (Wi-Fi): стабільна ідентичність телефона (`DeviceIdentity.stableID`) — відновлення
    /// шукає пристрій за нею, а `serial` лишається лише міткою транспорту на момент старту.
    /// Старі записи без поля декодуються з nil (резолв лише за тим самим serial).
    public var deviceStableID: String?

    public init(id: UUID = UUID(), startedAt: Date = Date(), kind: Kind, serial: String, deviceLabel: String,
                move: Bool, destination: String, entries: [JournalEntry], deviceStableID: String? = nil) {
        self.id = id
        self.deviceStableID = deviceStableID
        self.startedAt = startedAt
        self.kind = kind
        self.serial = serial
        self.deviceLabel = deviceLabel
        self.move = move
        self.destination = destination
        self.entries = entries
    }

    /// Елементи, які ще треба перенести (нема стану або провал).
    public var pendingEntries: [JournalEntry] {
        entries.filter { entry in
            guard let state = itemStates[entry.path] else { return true }
            return state.kind == .failed
        }
    }

    /// Елементи «скопійовано, але не видалено» (лише move) — довидалити після перевірки копії.
    public var copiedNotDeletedEntries: [(entry: JournalEntry, localPath: String?)] {
        entries.compactMap { entry in
            guard let state = itemStates[entry.path], state.kind == .copiedNotDeleted else { return nil }
            return (entry, state.localPath)
        }
    }

    /// Є що відновлювати?
    public var needsRecovery: Bool {
        !finished && (!pendingEntries.isEmpty || !copiedNotDeletedEntries.isEmpty)
    }
}

public final class OperationJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    /// ~/Library/Application Support/AndroidMover/operations.json
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AndroidMover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("operations.json")
    }

    public func start(_ record: JournalRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readAllUnlocked()
        all.removeAll { $0.id == record.id }
        all.append(record)
        try writeUnlocked(all)
    }

    public func markItem(recordID: UUID, path: String, state: JournalItemState) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readAllUnlocked()
        guard let index = all.firstIndex(where: { $0.id == recordID }) else { return }
        all[index].itemStates[path] = state
        try writeUnlocked(all)
    }

    /// Закриває запис. Якщо є «скопійовано, але не видалено» — запис лишається відкритим
    /// (needsRecovery), бо роботу ще треба довершити при наступному запуску/підключенні.
    public func finish(recordID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readAllUnlocked()
        guard let index = all.firstIndex(where: { $0.id == recordID }) else { return }
        if all[index].copiedNotDeletedEntries.isEmpty {
            all.remove(at: index)
        } else {
            all[index].finished = false
            // pending (провалені/нестартовані) при штатному завершенні більше не пропонуємо:
            // користувач бачив підсумок; лишаємо лише довидалення.
            for entry in all[index].pendingEntries {
                all[index].itemStates[entry.path] = JournalItemState(kind: .done)
            }
        }
        try writeUnlocked(all)
    }

    public func remove(recordID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readAllUnlocked()
        all.removeAll { $0.id == recordID }
        try writeUnlocked(all)
    }

    /// Усі відкриті записи (крах, kill, вимкнення, довидалення), новіші першими.
    public func unfinished() -> [JournalRecord] {
        lock.lock(); defer { lock.unlock() }
        return readAllUnlocked().filter(\.needsRecovery).sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Приватне (під lock)

    private func readAllUnlocked() -> [JournalRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let records = try? decoder.decode([JournalRecord].self, from: data) else { return [] }
        return records
    }

    private func writeUnlocked(_ records: [JournalRecord]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if records.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        // Атомарно: тимчасовий файл + rename — крах посеред запису не лишає битий JSON.
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
