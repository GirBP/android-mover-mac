import Foundation

/// Один елемент операції (файл чи тека) у записі історії. Фіксується завжди, включно з
/// провалами й скасуваннями — чесність журналу важливіша за охайну картинку.
public struct HistoryItem: Codable, Sendable {
    public let name: String
    public let remotePath: String
    public let bytes: Int64
    public let status: String
    public let localPath: String?

    public init(name: String, remotePath: String, bytes: Int64, status: String, localPath: String?) {
        self.name = name
        self.remotePath = remotePath
        self.bytes = bytes
        self.status = status
        self.localPath = localPath
    }
}

/// Один запис журналу — одна операція (перенесення чи видалення) з одним чи кількома елементами.
public struct HistoryRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let direction: String // "copy" / "move" / "delete"
    public let deviceLabel: String
    public let items: [HistoryItem]

    public init(id: UUID = UUID(), date: Date = Date(), direction: String, deviceLabel: String, items: [HistoryItem]) {
        self.id = id
        self.date = date
        self.direction = direction
        self.deviceLabel = deviceLabel
        self.items = items
    }
}

/// Журнал операцій (A5): JSON Lines append-only у Application Support. Переживає крах
/// посеред запису — битий чи недописаний хвостовий рядок при читанні тихо пропускається,
/// решта файлу лишається читабельною. Ротація: коли записів стає більше за `maxRecords`,
/// файл переписується останніми `maxRecords` записами (перевірка при кожному append —
/// рахунок байтів `\n` без JSON-парсингу, дешево; повний перепис — лише коли ліміт
/// справді перевищено).
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let maxRecords: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, maxRecords: Int = 1000) {
        self.fileURL = fileURL
        self.maxRecords = maxRecords
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    /// ~/Library/Application Support/AndroidMover/history.jsonl — тека створюється, якщо її нема.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AndroidMover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    /// Дописує запис у кінець файлу одним JSON-рядком.
    public func append(_ record: HistoryRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(record)
        var lineData = data
        lineData.append(0x0A) // "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } else {
            try lineData.write(to: fileURL)
        }

        if lineCountUnlocked() > maxRecords {
            let records = readAllUnlocked()
            try rewriteUnlocked(records: Array(records.suffix(maxRecords)))
        }
    }

    /// Новіші першими.
    public func recent(limit: Int = 200) -> [HistoryRecord] {
        lock.lock(); defer { lock.unlock() }
        let records = readAllUnlocked()
        return Array(records.reversed().prefix(limit))
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Приватне (виклик лише під lock)

    /// Швидкий підрахунок рядків без JSON-парсингу — щоб перевіряти ліміт на кожному append дешево.
    private func lineCountUnlocked() -> Int {
        guard let data = try? Data(contentsOf: fileURL) else { return 0 }
        return data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    private func readAllUnlocked() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        var records: [HistoryRecord] = []
        for lineData in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(HistoryRecord.self, from: Data(lineData)) else {
                continue // битий/недописаний рядок — тихо пропускаємо, решта лишається читабельною
            }
            records.append(record)
        }
        return records
    }

    private func rewriteUnlocked(records: [HistoryRecord]) throws {
        var out = Data()
        for record in records {
            out.append(try encoder.encode(record))
            out.append(0x0A)
        }
        try out.write(to: fileURL)
    }
}
