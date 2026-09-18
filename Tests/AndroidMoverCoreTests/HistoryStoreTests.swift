import XCTest
@testable import AndroidMoverCore

final class HistoryStoreTests: XCTestCase {
    var fileURL: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("am-history-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
    }

    override func tearDownWithError() throws {
        if let fileURL {
            try? fm.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    private func makeItem(name: String = "IMG_0001.jpg") -> HistoryItem {
        HistoryItem(name: name, remotePath: "/sdcard/DCIM/\(name)", bytes: 1000, status: "copied", localPath: "/tmp/\(name)")
    }

    // MARK: - append + readback

    func test_appendThenRecent_readsBack() throws {
        let store = HistoryStore(fileURL: fileURL)
        let record = HistoryRecord(direction: "copy", deviceLabel: "Nothing Phone", items: [makeItem()])
        try store.append(record)

        let recent = store.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].id, record.id)
        XCTAssertEqual(recent[0].direction, "copy")
        XCTAssertEqual(recent[0].deviceLabel, "Nothing Phone")
        XCTAssertEqual(recent[0].items.count, 1)
        XCTAssertEqual(recent[0].items[0].name, "IMG_0001.jpg")
        XCTAssertEqual(recent[0].items[0].bytes, 1000)
        XCTAssertEqual(recent[0].items[0].status, "copied")
        XCTAssertEqual(recent[0].items[0].localPath, "/tmp/IMG_0001.jpg")
    }

    func test_recent_ordersNewerFirst() throws {
        let store = HistoryStore(fileURL: fileURL)
        let first = HistoryRecord(date: Date(timeIntervalSince1970: 1000), direction: "copy", deviceLabel: "A", items: [makeItem()])
        let second = HistoryRecord(date: Date(timeIntervalSince1970: 2000), direction: "move", deviceLabel: "A", items: [makeItem()])
        let third = HistoryRecord(date: Date(timeIntervalSince1970: 3000), direction: "delete", deviceLabel: "A", items: [makeItem()])
        try store.append(first)
        try store.append(second)
        try store.append(third)

        let recent = store.recent()
        XCTAssertEqual(recent.map(\.id), [third.id, second.id, first.id])
    }

    func test_recent_respectsLimit() throws {
        let store = HistoryStore(fileURL: fileURL)
        for i in 0..<10 {
            try store.append(HistoryRecord(direction: "copy", deviceLabel: "A\(i)", items: [makeItem()]))
        }
        XCTAssertEqual(store.recent(limit: 3).count, 3)
        XCTAssertEqual(store.recent().count, 10)
    }

    // MARK: - ротація

    func test_rotation_keepsOnlyLastMaxRecords() throws {
        let store = HistoryStore(fileURL: fileURL, maxRecords: 5)
        var ids: [UUID] = []
        for i in 0..<8 {
            let record = HistoryRecord(direction: "copy", deviceLabel: "A\(i)", items: [makeItem()])
            ids.append(record.id)
            try store.append(record)
        }
        let recent = store.recent(limit: 100)
        XCTAssertEqual(recent.count, 5)
        // Лишились останні 5 (найновіші), у порядку новіші-першими.
        XCTAssertEqual(recent.map(\.id), Array(ids.suffix(5).reversed()))
    }

    func test_rotation_doesNotTriggerBelowLimit() throws {
        let store = HistoryStore(fileURL: fileURL, maxRecords: 5)
        for i in 0..<5 {
            try store.append(HistoryRecord(direction: "copy", deviceLabel: "A\(i)", items: [makeItem()]))
        }
        XCTAssertEqual(store.recent(limit: 100).count, 5)
    }

    // MARK: - битий хвостовий рядок

    func test_corruptTrailingLine_isSkippedWithoutLosingRest() throws {
        let store = HistoryStore(fileURL: fileURL)
        let good1 = HistoryRecord(direction: "copy", deviceLabel: "A", items: [makeItem()])
        let good2 = HistoryRecord(direction: "move", deviceLabel: "B", items: [makeItem()])
        try store.append(good1)
        try store.append(good2)

        // Симулюємо крах посеред запису третього рядка: недописаний JSON без \n у кінці.
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("{\"id\":\"not-valid-json-tail".utf8))
        try handle.close()

        let recent = store.recent(limit: 100)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(Set(recent.map(\.id)), Set([good1.id, good2.id]))
    }

    func test_corruptMiddleLine_isSkipped() throws {
        // Пряме записування файлу вручну: другий рядок навмисно битий JSON.
        let good1 = HistoryRecord(direction: "copy", deviceLabel: "A", items: [makeItem()])
        let good2 = HistoryRecord(direction: "delete", deviceLabel: "C", items: [makeItem()])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var text = String(data: try encoder.encode(good1), encoding: .utf8)! + "\n"
        text += "{this is not json}\n"
        text += String(data: try encoder.encode(good2), encoding: .utf8)! + "\n"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(fileURL: fileURL)
        let recent = store.recent(limit: 100)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(Set(recent.map(\.id)), Set([good1.id, good2.id]))
    }

    // MARK: - clear

    func test_clear_removesAllRecords() throws {
        let store = HistoryStore(fileURL: fileURL)
        try store.append(HistoryRecord(direction: "copy", deviceLabel: "A", items: [makeItem()]))
        try store.append(HistoryRecord(direction: "move", deviceLabel: "B", items: [makeItem()]))
        XCTAssertEqual(store.recent().count, 2)

        try store.clear()
        XCTAssertEqual(store.recent().count, 0)

        // Clear на вже відсутньому файлі не кидає помилку.
        XCTAssertNoThrow(try store.clear())
    }

    // MARK: - кирилиця

    func test_cyrillicNames_roundTrip() throws {
        let store = HistoryStore(fileURL: fileURL)
        let item = HistoryItem(
            name: "Фото відпустки з бабусею.jpg",
            remotePath: "/sdcard/DCIM/Фото відпустки з бабусею.jpg",
            bytes: 12345,
            status: "перенесено",
            localPath: "/Users/тест/Загрузки/Фото відпустки з бабусею.jpg"
        )
        let record = HistoryRecord(direction: "move", deviceLabel: "Nothing Phone (2а)", items: [item])
        try store.append(record)

        let recent = store.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].deviceLabel, "Nothing Phone (2а)")
        XCTAssertEqual(recent[0].items[0].name, "Фото відпустки з бабусею.jpg")
        XCTAssertEqual(recent[0].items[0].remotePath, "/sdcard/DCIM/Фото відпустки з бабусею.jpg")
        XCTAssertEqual(recent[0].items[0].localPath, "/Users/тест/Загрузки/Фото відпустки з бабусею.jpg")
    }

    // MARK: - defaultURL

    func test_defaultURL_pointsUnderApplicationSupportAndCreatesDirectory() {
        let url = HistoryStore.defaultURL
        XCTAssertTrue(url.path.contains("AndroidMover"))
        XCTAssertEqual(url.lastPathComponent, "history.jsonl")
        var isDirectory: ObjCBool = false
        let dirExists = fm.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory)
        XCTAssertTrue(dirExists)
        XCTAssertTrue(isDirectory.boolValue)
    }
}
