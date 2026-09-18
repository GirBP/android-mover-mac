import XCTest
@testable import AndroidMoverCore

final class OperationJournalTests: XCTestCase {
    private func makeJournal() -> (OperationJournal, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-journal-\(UUID().uuidString)/operations.json")
        return (OperationJournal(fileURL: url), url)
    }

    private func record(entries: Int = 3, move: Bool = true) -> JournalRecord {
        JournalRecord(
            kind: .pull, serial: "S1", deviceLabel: "Телефон", move: move, destination: "/tmp/dest",
            entries: (0..<entries).map { JournalEntry(path: "/sdcard/f\($0).jpg", name: "f\($0).jpg", isDirectory: false, size: Int64(10 + $0)) }
        )
    }

    func testStartMarkFinishLifecycle() throws {
        let (journal, _) = makeJournal()
        let rec = record()
        try journal.start(rec)
        XCTAssertEqual(journal.unfinished().map(\.id), [rec.id], "щойно стартована операція — відкрита")
        try journal.markItem(recordID: rec.id, path: "/sdcard/f0.jpg", state: .init(kind: .done))
        XCTAssertEqual(journal.unfinished().first?.pendingEntries.count, 2)
        try journal.markItem(recordID: rec.id, path: "/sdcard/f1.jpg", state: .init(kind: .done))
        try journal.markItem(recordID: rec.id, path: "/sdcard/f2.jpg", state: .init(kind: .done))
        try journal.finish(recordID: rec.id)
        XCTAssertTrue(journal.unfinished().isEmpty, "усе done — запис прибрано")
    }

    func testCrashMidwayLeavesPendingEntries() throws {
        let (journal, url) = makeJournal()
        let rec = record()
        try journal.start(rec)
        try journal.markItem(recordID: rec.id, path: "/sdcard/f0.jpg", state: .init(kind: .done))
        // «Крах»: новий інстанс над тим самим файлом.
        let reopened = OperationJournal(fileURL: url)
        let open = try XCTUnwrap(reopened.unfinished().first)
        XCTAssertEqual(open.pendingEntries.map(\.path), ["/sdcard/f1.jpg", "/sdcard/f2.jpg"])
        XCTAssertTrue(open.needsRecovery)
    }

    func testFinishKeepsCopiedNotDeletedForCleanup() throws {
        let (journal, _) = makeJournal()
        let rec = record()
        try journal.start(rec)
        try journal.markItem(recordID: rec.id, path: "/sdcard/f0.jpg", state: .init(kind: .done))
        try journal.markItem(recordID: rec.id, path: "/sdcard/f1.jpg", state: .init(kind: .copiedNotDeleted, localPath: "/tmp/dest/f1.jpg"))
        try journal.markItem(recordID: rec.id, path: "/sdcard/f2.jpg", state: .init(kind: .failed))
        try journal.finish(recordID: rec.id)
        let open = try XCTUnwrap(journal.unfinished().first)
        XCTAssertEqual(open.copiedNotDeletedEntries.map(\.entry.path), ["/sdcard/f1.jpg"])
        XCTAssertEqual(open.copiedNotDeletedEntries.first?.localPath, "/tmp/dest/f1.jpg")
        XCTAssertTrue(open.pendingEntries.isEmpty, "провалені при штатному завершенні не пропонуються повторно")
        try journal.remove(recordID: rec.id)
        XCTAssertTrue(journal.unfinished().isEmpty)
    }

    func testCorruptFileIsTreatedAsEmpty() throws {
        let (journal, url) = makeJournal()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertTrue(journal.unfinished().isEmpty)
        try journal.start(record(entries: 1))
        XCTAssertEqual(journal.unfinished().count, 1)
    }

    /// v0.14.0: стабільна ідентичність у записі; старий JSON без поля декодується з nil.
    func testDeviceStableIDRoundTripAndLegacyDecode() throws {
        let (journal, _) = makeJournal()
        var rec = record()
        rec.deviceStableID = "a1b2c3d4e5f60718|SN1"
        try journal.start(rec)
        XCTAssertEqual(journal.unfinished().first?.deviceStableID, "a1b2c3d4e5f60718|SN1")

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        var object = try JSONSerialization.jsonObject(with: encoder.encode(rec)) as! [String: Any]
        object.removeValue(forKey: "deviceStableID")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(JournalRecord.self, from: legacy)
        XCTAssertNil(decoded.deviceStableID)
        XCTAssertEqual(decoded.serial, "S1")
    }
}
