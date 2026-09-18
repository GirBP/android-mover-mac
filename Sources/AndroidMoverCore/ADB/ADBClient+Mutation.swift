import Foundation

/// Мутуючі операції на телефоні: delete/deleteMany/rmdir/mkdir/rename/move. Кожна — під guard-ом
/// `RemotePath` ДО будь-якого виклику. v0.15.0 (M3): скрипти зі словника `ADBScripts`.
extension ADBClient {
    // MARK: - Видалення

    public func delete(
        _ path: String,
        on serial: String,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws {
        let p = RemotePath.normalized(path)
        guard !RemotePath.isUnsafeToDelete(p) else { throw ADBError.unsafeDeletePath(p) }
        let result = try await run(["-s", serial, "shell", ADBScripts.rmOne(p).text], timeout: Self.deleteTimeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell rm", code: result.exitCode, stderr: result.err)
        }
        if Self.firstLine(of: result.out) == ADBSentinel.deleteFailed.rawValue { throw ADBError.deleteFailed(p) }
    }

    /// Батчеве видалення: один `adb shell` на ≤`batchSize` шляхів. Повертає шляхи, які НЕ вдалося
    /// видалити (`__AM_DELETE_FAILED__|<шлях>`, шлях останнім — може містити "|"). Свідомо без
    /// onSpawn: обрив `rm` посеред батчу лишив би півдороги — видалення йде до кінця, як і в `delete`.
    public func deleteMany(_ paths: [String], on serial: String) async throws -> Set<String> {
        let normalized = paths.map(RemotePath.normalized)
        if let unsafe = normalized.first(where: RemotePath.isUnsafeToDelete) {
            throw ADBError.unsafeDeletePath(unsafe)
        }
        guard !normalized.isEmpty else { return [] }
        let result = try await run(["-s", serial, "shell", ADBScripts.rmBatch(normalized).text], timeout: Self.deleteTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell rm (batch)", code: result.exitCode, stderr: result.err)
        }
        return Self.markedPaths(in: result.out, marker: ADBSentinel.deleteFailed.rawValue + "|")
    }

    /// v0.11.0 (P3): прибирає ЛИШЕ порожні теки (`rmdir`), знизу вгору за глибиною. Тека, де
    /// з'явились чужі файли, лишається — повертається у результаті, щоб користувач знав.
    public func removeEmptyDirectories(_ paths: [String], on serial: String) async throws -> Set<String> {
        let normalized = paths.map(RemotePath.normalized)
        if let unsafe = normalized.first(where: RemotePath.isUnsafeToDelete) {
            throw ADBError.unsafeDeletePath(unsafe)
        }
        guard !normalized.isEmpty else { return [] }
        // Глибші першими — щоб батько став порожнім до своєї черги.
        let ordered = Array(Set(normalized)).sorted { $0.count > $1.count }
        var notEmpty = Set<String>()
        for chunk in Self.chunked(ordered, size: Self.batchSize) {
            let result = try await run(["-s", serial, "shell", ADBScripts.rmdirBatch(chunk).text], timeout: Self.deleteTimeout)
            guard result.exitCode == 0 else {
                throw ADBError.commandFailed(command: "adb shell rmdir (batch)", code: result.exitCode, stderr: result.err)
            }
            notEmpty.formUnion(Self.markedPaths(in: result.out, marker: ADBSentinel.notEmpty.rawValue + "|"))
        }
        return notEmpty
    }

    /// Рядки `<маркер>|<шлях>` батчевих скриптів — шлях останнім, може містити "|".
    static func markedPaths(in output: String, marker: String) -> Set<String> {
        var paths = Set<String>()
        for line in output.split(separator: "\n") where line.hasPrefix(marker) {
            paths.insert(String(line.dropFirst(marker.count)))
        }
        return paths
    }

    // MARK: - Створення теки та перейменування

    /// v0.11.0 (P2): `mkdir -p` — вкладені теки для докачки push (батьки могли не приземлитись).
    public func makeDirectories(_ path: String, on serial: String) async throws {
        let p = RemotePath.normalized(path)
        guard RemotePath.isAllowedPushTarget(p) else { throw ADBError.unsafePushTarget(p) }
        let result = try await run(["-s", serial, "shell", ADBScripts.mkdirP(p).text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell mkdir -p", code: result.exitCode, stderr: result.err)
        }
        if Self.firstLine(of: result.out) == ADBSentinel.mkdirFailed.rawValue { throw ADBError.mkdirFailed(p) }
    }

    public func makeDirectory(_ path: String, on serial: String) async throws {
        let p = RemotePath.normalized(path)
        // Той самий guard, що для видалення: пишемо лише всередині користувацького сховища.
        guard !RemotePath.isUnsafeToDelete(p) else { throw ADBError.unsafeDeletePath(p) }
        let result = try await run(["-s", serial, "shell", ADBScripts.mkdir(p).text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell mkdir", code: result.exitCode, stderr: result.err)
        }
        if Self.firstLine(of: result.out) == ADBSentinel.mkdirFailed.rawValue { throw ADBError.mkdirFailed(p) }
    }

    /// Спільний скрипт `mv`, яким користуються і rename (у межах тієї самої теки), і move
    /// (довільний абсолютний target, B1 push): зайнята ціль → __AM_EXISTS__, невдалий mv →
    /// __AM_MV_FAILED__. Guard-и безпеки — відповідальність викликача (різні для rename і move).
    private func moveRaw(from path: String, to target: String, on serial: String) async throws {
        let p = RemotePath.normalized(path)
        let t = RemotePath.normalized(target)
        let result = try await run(["-s", serial, "shell", ADBScripts.moveOrFail(p, to: t).text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell mv", code: result.exitCode, stderr: result.err)
        }
        switch Self.firstLine(of: result.out) {
        case ADBSentinel.exists.rawValue: throw ADBError.alreadyExists(RemotePath.baseName(t))
        case ADBSentinel.mvFailed.rawValue: throw ADBError.renameFailed(p)
        default: return
        }
    }

    /// Перейменовує в межах тієї самої теки. Повертає новий повний шлях.
    public func rename(_ path: String, to newName: String, on serial: String) async throws -> String {
        let p = RemotePath.normalized(path)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\n"),
              trimmed != ".", trimmed != ".." else {
            throw ADBError.invalidName(newName)
        }
        let target = RemotePath.join(RemotePath.parent(p), trimmed)
        guard !RemotePath.isUnsafeToDelete(p), !RemotePath.isUnsafeToDelete(target) else {
            throw ADBError.unsafeDeletePath(p)
        }
        guard target != p else { return p }
        try await moveRaw(from: p, to: target, on: serial)
        return target
    }

    /// Переміщує елемент у довільний абсолютний шлях (B1 push: з тимчасової теки у видиме
    /// місце). Джерело захищене isUnsafeToDelete (як delete/rename), ціль — isAllowedPushTarget.
    public func move(_ path: String, to targetPath: String, on serial: String) async throws {
        let p = RemotePath.normalized(path)
        let target = RemotePath.normalized(targetPath)
        guard !RemotePath.isUnsafeToDelete(p) else { throw ADBError.unsafeDeletePath(p) }
        guard RemotePath.isAllowedPushTarget(target) else { throw ADBError.unsafePushTarget(target) }
        guard target != p else { return }
        try await moveRaw(from: p, to: target, on: serial)
    }
}
