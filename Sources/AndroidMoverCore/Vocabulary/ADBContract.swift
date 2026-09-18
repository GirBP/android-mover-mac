import Foundation

/// Машинний контракт словника — на кожен опкод зразок скрипта з ворожими іменами,
/// сентинели й перелік argv-команд adb, які не є shell-скриптами. Комітиться у
/// `scripts/adb-contract.json`; `ContractTests` регенерують і порівнюють (дрейф = червоний тест),
/// а також перевіряють, що mock має гілку на кожен опкод.
public struct ADBContractEntry: Codable, Sendable, Equatable {
    public let opcode: String
    public let sentinels: [String]
    public let sample: String
}

public struct ADBContractManifest: Codable, Sendable, Equatable {
    public let version: Int
    public let marker: String
    public let scripts: [ADBContractEntry]
    public let argvCommands: [String]
}

public enum ADBContract {
    public static let version = 1
    public static let samplePath = "/sdcard/Приклад тека/it's файл й.txt"
    public static let sampleTarget = "/sdcard/Приклад тека/новий (1).txt"
    public static let sampleList = ["/sdcard/a b.jpg", "/sdcard/o'clock.mp4"]

    public static func entries() -> [ADBContractEntry] {
        ADBOpcode.allCases.map { opcode in
            let script = sample(for: opcode)
            return ADBContractEntry(
                opcode: opcode.rawValue,
                sentinels: script.sentinels.map(\.rawValue).sorted(),
                sample: script.text
            )
        }
    }

    public static func sample(for opcode: ADBOpcode) -> ADBScript {
        switch opcode {
        case .listDir: return ADBScripts.listDir(samplePath)
        case .findFiles: return ADBScripts.findFiles(samplePath)
        case .findDirs: return ADBScripts.findDirs(samplePath)
        case .statMTimes: return ADBScripts.statMTimes(samplePath)
        case .statFS: return ADBScripts.statFS(samplePath)
        case .md5One: return ADBScripts.md5One(samplePath)
        case .md5Batch: return ADBScripts.md5Batch(sampleList)
        case .rmOne: return ADBScripts.rmOne(samplePath)
        case .rmBatch: return ADBScripts.rmBatch(sampleList)
        case .rmdirBatch: return ADBScripts.rmdirBatch(sampleList)
        case .mkdir: return ADBScripts.mkdir(samplePath)
        case .mkdirP: return ADBScripts.mkdirP(samplePath)
        case .moveOrFail: return ADBScripts.moveOrFail(samplePath, to: sampleTarget)
        case .existsProbe: return ADBScripts.existsProbe(samplePath)
        case .rescanPaths: return ADBScripts.rescanPaths(sampleList)
        case .rescanVolume: return ADBScripts.rescanVolume()
        case .getProps: return ADBScripts.getProps()
        }
    }

    /// Команди adb, що йдуть argv, а не скриптом (форма для контракту й golden).
    public static let argvCommands: [String] = [
        "devices -l",
        "track-devices",
        "-s <serial> shell <script>",
        "-s <serial> exec-out toybox head -c <bytes> <quoted path>",
        "-s <serial> pull -a <remote>… <localDir>",
        "-s <serial> push <local> <remote>",
        "-s <serial> wait-for-device",
        "mdns check",
        "mdns services",
        "pair <host:port> <code>",
        "connect <host:port>",
        "disconnect <host:port>",
    ]

    public static func manifest() -> ADBContractManifest {
        ADBContractManifest(version: version, marker: ADBScript.marker, scripts: entries(), argvCommands: argvCommands)
    }

    public static func manifestJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest())
        data.append(0x0A)
        return data
    }
}
