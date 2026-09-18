import Foundation
import XCTest
@testable import AndroidMoverCore

/// v0.15.0 (M3): словник скриптів ↔ контракт ↔ mock. Дрейф між Swift і mock тепер — червоний тест,
/// а не мовчазна розбіжність.
final class ContractTests: XCTestCase {
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryOpcodeHasSampleStartingWithMarker() {
        let entries = ADBContract.entries()
        XCTAssertEqual(entries.count, ADBOpcode.allCases.count)
        for entry in entries {
            XCTAssertTrue(entry.sample.hasPrefix("AM_OP=\(entry.opcode); "), entry.opcode)
        }
    }

    /// Тіла скриптів — дослівно ті, що ADBClient відправляв до v0.15.0 (переїзд у словник
    /// механічний). Кілька ключових перевіряються проти літералів, скопійованих з коду v0.14.0.
    func testScriptBodiesMatchPreMigrationLiterals() {
        let p = "/sdcard/DCIM/o'clock файл.txt"
        let q = RemotePath.shellQuote(p)
        XCTAssertEqual(ADBScripts.listDir(p).body,
            "AM_P=\(q); command -v toybox >/dev/null 2>&1 || { echo __AM_NO_TOYBOX__; exit 0; }; "
            + "AM_R=$(toybox readlink -f \"$AM_P\" 2>/dev/null); [ -n \"$AM_R\" ] && AM_P=\"$AM_R\"; "
            + "if [ ! -d \"$AM_P\" ]; then echo __AM_NOT_A_DIR__; exit 0; fi; "
            + "toybox find \"$AM_P\" -mindepth 1 -maxdepth 1 -exec toybox stat -c '%F|%s|%Y|%n' {} + 2>/dev/null; exit 0")
        XCTAssertEqual(ADBScripts.findFiles(p).body,
            "AM_P=\(q); if [ ! -e \"$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; "
            + "toybox find \"$AM_P\" -type f -exec toybox stat -c '%s|%n' {} + 2>/dev/null; exit 0")
        XCTAssertEqual(ADBScripts.rmOne(p).body,
            "AM_P=\(q); rm -rf -- \"$AM_P\" 2>/dev/null; if [ -e \"$AM_P\" ]; then echo __AM_DELETE_FAILED__; fi; exit 0")
        XCTAssertEqual(ADBScripts.rmBatch([p, "/sdcard/b"]).body,
            "for AM_P in \(q) '/sdcard/b'; do rm -rf -- \"$AM_P\" 2>/dev/null; "
            + "if [ -e \"$AM_P\" ]; then printf '__AM_DELETE_FAILED__|%s\\n' \"$AM_P\"; fi; done; exit 0")
        XCTAssertEqual(ADBScripts.moveOrFail(p, to: "/sdcard/x").body,
            "AM_P=\(q); AM_Q='/sdcard/x'; if [ -e \"$AM_Q\" ]; then echo __AM_EXISTS__; exit 0; fi; "
            + "mv -- \"$AM_P\" \"$AM_Q\" 2>/dev/null; if [ ! -e \"$AM_Q\" ]; then echo __AM_MV_FAILED__; fi; exit 0")
        XCTAssertEqual(ADBScripts.existsProbe(p).body,
            "AM_P=\(q); if [ -e \"$AM_P\" ]; then echo __AM_EXISTS__; else echo __AM_ABSENT__; fi; exit 0")
        XCTAssertEqual(ADBScripts.statFS(p).body,
            "AM_P=\(q); command -v toybox >/dev/null 2>&1 || { echo __AM_NO_TOYBOX__; exit 0; }; "
            + "toybox stat -f -c '%a|%b|%S' \"$AM_P\" 2>/dev/null || echo __AM_STAT_FAILED__; exit 0")
        XCTAssertEqual(ADBScripts.getProps().body,
            "printf '__AM_ID__|%s\\n' \"$(settings get secure android_id 2>/dev/null)\"; "
            + "printf '__AM_SN__|%s\\n' \"$(getprop ro.serialno 2>/dev/null)\"; "
            + "printf '__AM_MODEL__|%s\\n' \"$(getprop ro.product.model 2>/dev/null)\"; exit 0")
    }

    func testMockHasHandlerForEveryOpcode() throws {
        let mock = try String(contentsOf: Self.packageRoot.appendingPathComponent("scripts/mock_adb.py"), encoding: .utf8)
        for opcode in ADBOpcode.allCases {
            XCTAssertTrue(mock.contains("\"\(opcode.rawValue)\": lambda"), "mock_adb.py: нема гілки для опкоду \(opcode.rawValue)")
        }
    }

    func testCommittedContractFileIsUpToDate() throws {
        let url = Self.packageRoot.appendingPathComponent("scripts/adb-contract.json")
        let committed = try Data(contentsOf: url)
        let fresh = try ADBContract.manifestJSON()
        XCTAssertEqual(committed, fresh, "scripts/adb-contract.json застарів — перегенеруйте: `.build/debug/amctl contract dump > scripts/adb-contract.json`")
    }

    func testLegacyScriptWithoutMarkerStillDispatchesInMock() async throws {
        let mockPath = Self.packageRoot.appendingPathComponent("scripts/mock_adb.py").path
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockPath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("am-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = "AM_P='/sdcard/nope'; if [ -e \"$AM_P\" ]; then echo __AM_EXISTS__; else echo __AM_ABSENT__; fi; exit 0"
        let result = try await ProcessRunner.run(executable: mockPath, arguments: ["-s", "MOCK001", "shell", legacy],
                                                 environment: ["MOCK_PHONE_ROOT": root.path], timeout: 10)
        XCTAssertEqual(result.exitCode, 0, result.err)
        XCTAssertEqual(ADBClient.firstLine(of: result.out), "__AM_ABSENT__")
    }

    func testUnknownOpcodeIsRefusedByMock() async throws {
        let mockPath = Self.packageRoot.appendingPathComponent("scripts/mock_adb.py").path
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("am-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await ProcessRunner.run(executable: mockPath, arguments: ["-s", "MOCK001", "shell", "AM_OP=noSuchThing; exit 0"],
                                                 environment: ["MOCK_PHONE_ROOT": root.path], timeout: 10)
        XCTAssertEqual(result.exitCode, 2)
    }
}
