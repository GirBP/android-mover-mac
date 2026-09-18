import Foundation

/// Байти й контрольні суми: перші байти файла (мініатюри), md5, батчевий pull, push.
extension ADBClient {
    /// Скільки шляхів іде в один батчевий `pull`/`rm` — 32 вкладаються в ARG_MAX з великим
    /// запасом навіть для довгих кириличних шляхів, а накладні спавну adb діляться на 32.
    public static let batchSize = 32

    static let headTimeout: TimeInterval = 30

    /// Idle-таймаут md5: телефон хешує ~50–200 МБ/с і мовчить, доки не завершить файл —
    /// 8 ГБ відео може не давати виводу кілька хвилин.
    public static let checksumTimeout: TimeInterval = 1800

    // MARK: - Перші байти файла (мініатюри)

    /// Перші `bytes` байтів файла без стягування цілого: `adb exec-out` віддає stdout команди
    /// байт-у-байт (на відміну від `shell`, що перекодовує \n). Шлях у POSIX-лапках, бо exec-out
    /// іде через shell телефона.
    public func readHead(_ path: String, bytes: Int, on serial: String) async throws -> Data {
        let result = try await run(
            ["-s", serial, "exec-out", "toybox", "head", "-c", String(bytes), RemotePath.shellQuote(path)],
            timeout: Self.headTimeout
        )
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb exec-out head", code: result.exitCode, stderr: result.err)
        }
        return result.stdout
    }

    // MARK: - Контрольні суми

    /// md5 файлів під `path`: файл → один рядок, тека → рекурсивно (`find -type f -exec md5sum +`,
    /// батчинг ARG_MAX — усередині find). Повертає remotePath → hex (шлях — сирі байти телефона).
    public func checksums(
        _ path: String,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> [String: String] {
        let p = RemotePath.normalized(path)
        let result = try await run(["-s", serial, "shell", ADBScripts.md5One(p).text], timeout: Self.checksumTimeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell md5sum", code: result.exitCode, stderr: result.err)
        }
        if Self.firstLine(of: result.out) == ADBSentinel.missing.rawValue { throw ADBError.notADirectory(p) }
        return Self.parseMD5Sums(result.out)
    }

    /// md5 кількох плоских файлів одним `adb shell` (батч ≤batchSize) — для батчевого шляху.
    public func checksumsMany(
        _ paths: [String],
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let script = ADBScripts.md5Batch(paths.map(RemotePath.normalized))
        let result = try await run(["-s", serial, "shell", script.text], timeout: Self.checksumTimeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell md5sum (batch)", code: result.exitCode, stderr: result.err)
        }
        return Self.parseMD5Sums(result.out)
    }

    /// Рядки `<32 hex>  <шлях>` (GNU-формат md5sum; toybox — так само). Шлях — усе після
    /// 32 символів і роздільника (два пробіли або " *"): імена з пробілами/«|» не ріжуться.
    public static func parseMD5Sums(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.count > 34 else { continue }
            let hash = String(line.prefix(32))
            guard hash.allSatisfy(\.isHexDigit) else { continue }
            var rest = Substring(line.dropFirst(32))
            if rest.hasPrefix("  ") || rest.hasPrefix(" *") { rest = rest.dropFirst(2) } else if rest.hasPrefix(" ") { rest = rest.dropFirst(1) }
            map[String(rest)] = hash.lowercased()
        }
        return map
    }

    // MARK: - Батчі і push

    /// `adb pull -a p1 … pN localDir` — один процес на батч замість одного на файл. Семантика як у
    /// `pull`: кожен файл лягає як `localDir/<basename>`; помилка будь-якого — exit ≠ 0, і викликач
    /// (TransferEngine+Batch) відкочується на поштучний шлях для тих файлів, що не приземлились.
    public func pullMany(
        _ remotePaths: [String],
        into localDir: URL,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws {
        guard !remotePaths.isEmpty else { return }
        let paths = remotePaths.map(RemotePath.normalized)
        let result = try await run(["-s", serial, "pull", "-a"] + paths + [localDir.path], timeout: nil, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb pull (batch \(paths.count))", code: result.exitCode, stderr: result.err)
        }
    }

    /// `adb push` — дзеркало `pull`: без таймауту (великі файли), процес віддається через
    /// onSpawn для скасування тим самим SIGTERM→SIGKILL патерном.
    public func push(
        _ localURL: URL,
        to remotePath: String,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws {
        let p = RemotePath.normalized(remotePath)
        let result = try await run(["-s", serial, "push", localURL.path, p], timeout: nil, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb push", code: result.exitCode, stderr: result.err)
        }
    }
}
