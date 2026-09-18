import Foundation

/// Читання файлової системи телефона: лістинг однієї теки і рекурсивний перелік файлів/тек
/// (для підрахунку прогресу й верифікації), плюс `pull` (копіювання з телефона).
/// v0.15.0 (M3): скрипти беруться зі словника `ADBScripts`; тут — лише виклик і розбір виводу.
extension ADBClient {
    // MARK: - Список теки

    /// Лістинг через `find -mindepth 1 -maxdepth 1`, а не glob: glob розкривається в argv
    /// і на теках з тисячами файлів (DCIM/Camera) падає з E2BIG; find сам батчить `-exec +`.
    /// Перед find шлях розіменовується (`readlink -f`): find у POSIX-режимі -P не спускається
    /// в symlink-аргумент, а /sdcard на реальних пристроях — саме symlink. Повернуті шляхи
    /// відтак канонічні (/storage/emulated/0/...), і вся решта конвеєра працює з ними.
    public func listDirectory(_ path: String, on serial: String) async throws -> [RemoteEntry] {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.listDir(p).text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell stat", code: result.exitCode, stderr: result.err)
        }
        let out = result.out
        switch Self.firstLine(of: out) {
        case ADBSentinel.noToybox.rawValue: throw ADBError.toyboxMissing
        case ADBSentinel.notADir.rawValue: throw ADBError.notADirectory(p)
        default: break
        }
        return Self.parseListing(out, directory: p)
    }

    /// Рядок формату `%F|%s|%Y|%n` — тип|розмір|epoch|повний шлях (ім'я останнім, бо може містити "|").
    ///
    /// v0.10.1: БЕЗ сортування тут — повертає "сирий" порядок `find`; єдиний споживач
    /// (`BrowserStore`/`BrowserIndex`) однаково пересортовує за `sortOrder`.
    public static func parseListing(_ output: String, directory: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            let type = parts[0].lowercased()
            guard let size = Int64(parts[1]), let epoch = TimeInterval(parts[2]) else { continue }
            let fullPath = RemotePath.normalized(String(parts[3]))
            let name = RemotePath.baseName(fullPath)
            if name == "." || name == ".." || name.isEmpty { continue }
            let isDirectory = type.contains("directory")
            let isSymlink = type.contains("link")
            entries.append(RemoteEntry(
                path: fullPath,
                name: name,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: size,
                modified: Date(timeIntervalSince1970: epoch)
            ))
        }
        return entries
    }

    // MARK: - Рекурсивний перелік файлів (для прогресу та верифікації)

    public func recursiveFiles(
        _ path: String,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> [RemoteFileRecord] {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.findFiles(p).text],
                                   timeout: findTimeoutOverride ?? Self.findTimeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell find", code: result.exitCode, stderr: result.err)
        }
        let out = result.out
        if Self.firstLine(of: out) == ADBSentinel.missing.rawValue { throw ADBError.notADirectory(p) }
        var records: [RemoteFileRecord] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            records.append(RemoteFileRecord(path: String(parts[1]), size: size))
        }
        return records
    }

    /// Рекурсивний перелік ТЕК з їхніми mtime (включно з самим коренем): `adb pull -a`
    /// зберігає дати лише файлів, дати тек рушій відновлює сам після копіювання.
    public func recursiveDirs(
        _ path: String,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> [(path: String, modified: Date)] {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.findDirs(p).text],
                                   timeout: findTimeoutOverride ?? Self.findTimeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell find -d", code: result.exitCode, stderr: result.err)
        }
        let out = result.out
        if Self.firstLine(of: out) == ADBSentinel.missing.rawValue { throw ADBError.notADirectory(p) }
        var records: [(path: String, modified: Date)] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let epoch = TimeInterval(parts[0]) else { continue }
            records.append((path: String(parts[1]), modified: Date(timeIntervalSince1970: epoch)))
        }
        return records
    }

    // MARK: - Копіювання з телефона

    /// `adb pull -a` зберігає час модифікації файлів. Створює `localDir/<basename(remote)>`.
    public func pull(
        _ remotePath: String,
        into localDir: URL,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws {
        let p = RemotePath.normalized(remotePath)
        let result = try await run(["-s", serial, "pull", "-a", p, localDir.path], timeout: nil, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb pull", code: result.exitCode, stderr: result.err)
        }
    }
}
