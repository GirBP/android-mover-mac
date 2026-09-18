import Foundation

/// Закритий словник усіх shell-скриптів, які застосунок
/// відправляє на телефон. Кожен скрипт починається з `AM_OP=<опкод>;` — mock диспетчить за ним
/// точним збігом (не підрядками у фіксованому порядку), контракт (`ADBContract`) і golden-транскрипти
/// звіряються за опкодом.
public enum ADBOpcode: String, CaseIterable, Codable, Sendable {
    case listDir, findFiles, findDirs, statMTimes, statFS
    case md5One, md5Batch
    case rmOne, rmBatch, rmdirBatch, mkdir, mkdirP, moveOrFail, existsProbe
    case rescanPaths, rescanVolume
    case getProps
}

/// Сентинели — перший рядок stdout (`ADBClient.firstLine`), adb shell завжди `exit 0`;
/// провал транспорту — окремо, через код виходу.
public enum ADBSentinel: String, CaseIterable, Sendable {
    case notADir = "__AM_NOT_A_DIR__"
    case noToybox = "__AM_NO_TOYBOX__"
    case missing = "__AM_MISSING__"
    case deleteFailed = "__AM_DELETE_FAILED__"
    case mkdirFailed = "__AM_MKDIR_FAILED__"
    case exists = "__AM_EXISTS__"
    case absent = "__AM_ABSENT__"
    case mvFailed = "__AM_MV_FAILED__"
    case statFailed = "__AM_STAT_FAILED__"
    case notEmpty = "__AM_NOT_EMPTY__"
    case scanDone = "__AM_SCAN_DONE__"
    case propID = "__AM_ID__"
    case propSerial = "__AM_SN__"
    case propModel = "__AM_MODEL__"
}

public struct ADBScript: Sendable, Equatable {
    public let opcode: ADBOpcode
    public let text: String
    public let sentinels: Set<ADBSentinel>

    /// Маркер, який mock і контракт читають з початку скрипта.
    public static let marker = "AM_OP="

    /// Тіло без префікса `AM_OP=<опкод>; ` — те, що виконує shell телефона по суті.
    public var body: String {
        let prefix = "\(Self.marker)\(opcode.rawValue); "
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }
}

/// Фабрики — одна на опкод. Шляхи приходять уже нормалізовані (`RemotePath.normalized`),
/// квотинг — лише тут, через `RemotePath.shellQuote` (unicode-скалярний).
public enum ADBScripts {
    private static func make(_ opcode: ADBOpcode, _ body: String, _ sentinels: Set<ADBSentinel>) -> ADBScript {
        ADBScript(opcode: opcode, text: "\(ADBScript.marker)\(opcode.rawValue); " + body, sentinels: sentinels)
    }

    private static func q(_ path: String) -> String { RemotePath.shellQuote(path) }
    private static func list(_ paths: [String]) -> String { paths.map(q).joined(separator: " ") }

    // MARK: - Читання

    public static func listDir(_ p: String) -> ADBScript {
        make(.listDir,
             "AM_P=\(q(p)); "
             + "command -v toybox >/dev/null 2>&1 || { echo __AM_NO_TOYBOX__; exit 0; }; "
             + "AM_R=$(toybox readlink -f \"$AM_P\" 2>/dev/null); [ -n \"$AM_R\" ] && AM_P=\"$AM_R\"; "
             + "if [ ! -d \"$AM_P\" ]; then echo __AM_NOT_A_DIR__; exit 0; fi; "
             + "toybox find \"$AM_P\" -mindepth 1 -maxdepth 1 -exec toybox stat -c '%F|%s|%Y|%n' {} + 2>/dev/null; exit 0",
             [.noToybox, .notADir])
    }

    public static func findFiles(_ p: String) -> ADBScript {
        make(.findFiles,
             "AM_P=\(q(p)); "
             + "if [ ! -e \"$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; "
             + "toybox find \"$AM_P\" -type f -exec toybox stat -c '%s|%n' {} + 2>/dev/null; exit 0",
             [.missing])
    }

    public static func findDirs(_ p: String) -> ADBScript {
        make(.findDirs,
             "AM_P=\(q(p)); "
             + "if [ ! -e \"$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; "
             + "toybox find \"$AM_P\" -type d -exec toybox stat -c '%Y|%n' {} + 2>/dev/null; exit 0",
             [.missing])
    }

    public static func statMTimes(_ p: String) -> ADBScript {
        make(.statMTimes,
             "AM_P=\(q(p)); "
             + "if [ ! -e \"$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; "
             + "toybox find \"$AM_P\" -exec toybox stat -c '%Y|%n' {} + 2>/dev/null; exit 0",
             [.missing])
    }

    public static func statFS(_ p: String) -> ADBScript {
        make(.statFS,
             "AM_P=\(q(p)); "
             + "command -v toybox >/dev/null 2>&1 || { echo __AM_NO_TOYBOX__; exit 0; }; "
             + "toybox stat -f -c '%a|%b|%S' \"$AM_P\" 2>/dev/null || echo __AM_STAT_FAILED__; exit 0",
             [.noToybox, .statFailed])
    }

    public static func md5One(_ p: String) -> ADBScript {
        make(.md5One,
             "AM_P=\(q(p)); "
             + "if [ ! -e \"$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; "
             + "if [ -d \"$AM_P\" ]; then toybox find \"$AM_P\" -type f -exec toybox md5sum {} + 2>/dev/null; "
             + "else toybox md5sum \"$AM_P\" 2>/dev/null; fi; exit 0",
             [.missing])
    }

    public static func md5Batch(_ paths: [String]) -> ADBScript {
        make(.md5Batch, "for AM_P in \(list(paths)); do toybox md5sum \"$AM_P\" 2>/dev/null; done; exit 0", [])
    }

    // MARK: - Мутації

    public static func rmOne(_ p: String) -> ADBScript {
        make(.rmOne,
             "AM_P=\(q(p)); "
             + "rm -rf -- \"$AM_P\" 2>/dev/null; "
             + "if [ -e \"$AM_P\" ]; then echo __AM_DELETE_FAILED__; fi; exit 0",
             [.deleteFailed])
    }

    public static func rmBatch(_ paths: [String]) -> ADBScript {
        make(.rmBatch,
             "for AM_P in \(list(paths)); do rm -rf -- \"$AM_P\" 2>/dev/null; "
             + "if [ -e \"$AM_P\" ]; then printf '__AM_DELETE_FAILED__|%s\\n' \"$AM_P\"; fi; done; exit 0",
             [.deleteFailed])
    }

    public static func rmdirBatch(_ paths: [String]) -> ADBScript {
        make(.rmdirBatch,
             "for AM_P in \(list(paths)); do toybox rmdir -- \"$AM_P\" 2>/dev/null; "
             + "if [ -d \"$AM_P\" ]; then printf '__AM_NOT_EMPTY__|%s\\n' \"$AM_P\"; fi; done; exit 0",
             [.notEmpty])
    }

    public static func mkdir(_ p: String) -> ADBScript {
        make(.mkdir,
             "AM_P=\(q(p)); "
             + "mkdir -- \"$AM_P\" 2>/dev/null; "
             + "if [ ! -d \"$AM_P\" ]; then echo __AM_MKDIR_FAILED__; fi; exit 0",
             [.mkdirFailed])
    }

    public static func mkdirP(_ p: String) -> ADBScript {
        make(.mkdirP,
             "AM_P=\(q(p)); "
             + "mkdir -p -- \"$AM_P\" 2>/dev/null; "
             + "if [ ! -d \"$AM_P\" ]; then echo __AM_MKDIR_FAILED__; fi; exit 0",
             [.mkdirFailed])
    }

    public static func moveOrFail(_ p: String, to t: String) -> ADBScript {
        make(.moveOrFail,
             "AM_P=\(q(p)); AM_Q=\(q(t)); "
             + "if [ -e \"$AM_Q\" ]; then echo __AM_EXISTS__; exit 0; fi; "
             + "mv -- \"$AM_P\" \"$AM_Q\" 2>/dev/null; "
             + "if [ ! -e \"$AM_Q\" ]; then echo __AM_MV_FAILED__; fi; exit 0",
             [.exists, .mvFailed])
    }

    public static func existsProbe(_ p: String) -> ADBScript {
        make(.existsProbe,
             "AM_P=\(q(p)); "
             + "if [ -e \"$AM_P\" ]; then echo __AM_EXISTS__; else echo __AM_ABSENT__; fi; exit 0",
             [.exists, .absent])
    }

    // MARK: - MediaStore

    public static func rescanPaths(_ paths: [String]) -> ADBScript {
        var body = ""
        for p in paths {
            body += "AM_F=\(q(p)); "
                + "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \"file://$AM_F\" >/dev/null 2>&1; "
        }
        body += "echo __AM_SCAN_DONE__; exit 0"
        return make(.rescanPaths, body, [.scanDone])
    }

    public static func rescanVolume() -> ADBScript {
        make(.rescanVolume,
             "content call --uri content://media/external/file --method scan_volume "
             + "--arg external_primary >/dev/null 2>&1; echo __AM_SCAN_DONE__; exit 0",
             [.scanDone])
    }

    // MARK: - Ідентичність

    public static func getProps() -> ADBScript {
        make(.getProps,
             "printf '__AM_ID__|%s\\n' \"$(settings get secure android_id 2>/dev/null)\"; "
             + "printf '__AM_SN__|%s\\n' \"$(getprop ro.serialno 2>/dev/null)\"; "
             + "printf '__AM_MODEL__|%s\\n' \"$(getprop ro.product.model 2>/dev/null)\"; exit 0",
             [.propID, .propSerial, .propModel])
    }
}
