import Foundation

/// Метадані й best-effort допоміжні: існування шляху, mtime дерева, вільне місце,
/// MediaStore-рескан. Скрипти зі словника `ADBScripts`.
extension ADBClient {
    /// Скільки шляхів рескану MediaStore влазить в один `adb shell` виклик.
    static let rescanBatchSize = 150

    // MARK: - Перевірка існування (push: колізієвільне ім'я на телефоні)

    /// `true`, якщо шлях існує на телефоні (файл чи тека). Без guard-ів — читання, не запис.
    public func remoteExists(_ path: String, on serial: String) async throws -> Bool {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.existsProbe(p).text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell test -e", code: result.exitCode, stderr: result.err)
        }
        return Self.firstLine(of: result.out) == ADBSentinel.exists.rawValue
    }

    /// Рекурсивно mtime усіх файлів І тек під шляхом (без `-type`) — для best-effort звірки дат
    /// після push (FUSE-поведінка `adb push` неоднорідна по OEM).
    public func statMTimes(
        _ path: String,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> [String: Date] {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.statMTimes(p).text],
                                   timeout: findTimeoutOverride ?? Self.findTimeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell find stat mtime", code: result.exitCode, stderr: result.err)
        }
        let out = result.out
        if Self.firstLine(of: out) == ADBSentinel.missing.rawValue { throw ADBError.notADirectory(p) }
        var mtimes: [String: Date] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let epoch = TimeInterval(parts[0]) else { continue }
            mtimes[String(parts[1])] = Date(timeIntervalSince1970: epoch)
        }
        return mtimes
    }

    // MARK: - Вільне місце

    /// `toybox stat -f` друкує статистику тому, що містить шлях, — тому працює і на кореневій
    /// `/sdcard`, і на будь-якій підтеці.
    public func storageInfo(for path: String, on serial: String) async throws -> RemoteStorageInfo {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.statFS(p).text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell stat -f", code: result.exitCode, stderr: result.err)
        }
        let out = result.out
        switch Self.firstLine(of: out) {
        case ADBSentinel.noToybox.rawValue: throw ADBError.toyboxMissing
        case ADBSentinel.statFailed.rawValue: throw ADBError.statFailed(p)
        default: break
        }
        guard let info = Self.parseStorageInfo(out) else { throw ADBError.statFailed(p) }
        return info
    }

    /// Рядок формату `%a|%b|%S` — вільні_блоки|усього_блоків|розмір_блоку → байти.
    public static func parseStorageInfo(_ output: String) -> RemoteStorageInfo? {
        let parts = firstLine(of: output).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let availableBlocks = Int64(parts[0]),
              let totalBlocks = Int64(parts[1]),
              let blockSize = Int64(parts[2]),
              availableBlocks >= 0, totalBlocks >= 0, blockSize > 0
        else { return nil }
        return RemoteStorageInfo(totalBytes: totalBlocks * blockSize, availableBytes: availableBlocks * blockSize)
    }

    // MARK: - MediaStore-рескан (best-effort)

    /// Просить MediaStore пере-проіндексувати шляхи. Broadcast deprecated і ненадійний по OEM —
    /// провал самого broadcast не кидає помилку, кидає лише транспортний збій adb.
    public func rescanMedia(_ paths: [String], on serial: String) async throws {
        guard !paths.isEmpty else { return }
        for batch in Self.chunked(paths.map(RemotePath.normalized), size: Self.rescanBatchSize) {
            let result = try await run(["-s", serial, "shell", ADBScripts.rescanPaths(batch).text], timeout: Self.listTimeout)
            guard result.exitCode == 0 else {
                throw ADBError.commandFailed(command: "adb shell am broadcast", code: result.exitCode, stderr: result.err)
            }
        }
    }

    /// Фолбек: рескан усього зовнішнього тому. Так само best-effort.
    public func rescanVolume(on serial: String) async throws {
        let result = try await run(["-s", serial, "shell", ADBScripts.rescanVolume().text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell content call scan_volume", code: result.exitCode, stderr: result.err)
        }
    }

    static func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return array.isEmpty ? [] : [array] }
        var result: [[T]] = []
        var index = 0
        while index < array.count {
            let end = min(index + size, array.count)
            result.append(Array(array[index..<end]))
            index = end
        }
        return result
    }
}
