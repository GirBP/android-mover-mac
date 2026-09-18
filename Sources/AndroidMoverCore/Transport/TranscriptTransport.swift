import Foundation

/// Один записаний виклик adb — argv, сирі байти stdout/stderr, код виходу.
/// Формат на диску — JSON Lines (один запис на рядок; `Data` кодується base64). Це майбутні
/// golden-транскрипти з реального телефона.
public struct TranscriptRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case run, stream }
    public let kind: Kind
    public let arguments: [String]
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let durationMs: Int

    public init(kind: Kind, arguments: [String], stdout: Data, stderr: Data, exitCode: Int32, durationMs: Int) {
        self.kind = kind
        self.arguments = arguments
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationMs = durationMs
    }
}

/// Пропускає кожен виклик до базового транспорту без змін і дописує запис у транскрипт.
/// Стрім записується цілком після завершення (усі чанки stdout підряд).
public final class RecordingTransport: ADBTransport, @unchecked Sendable {
    private let base: any ADBTransport
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    public init(base: any ADBTransport, fileURL: URL) {
        self.base = base
        self.fileURL = fileURL
    }

    public func run(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) async throws -> ProcessResult {
        let started = Date()
        let result = try await base.run(invocation, onSpawn: onSpawn)
        append(TranscriptRecord(kind: .run, arguments: invocation.arguments, stdout: result.stdout, stderr: result.stderr,
                                exitCode: result.exitCode, durationMs: Self.millis(since: started)))
        return result
    }

    public func stream(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) -> AsyncThrowingStream<Data, Error> {
        let inner = base.stream(invocation, onSpawn: onSpawn)
        let arguments = invocation.arguments
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                let started = Date()
                var collected = Data()
                do {
                    for try await chunk in inner {
                        collected.append(chunk)
                        continuation.yield(chunk)
                    }
                    append(TranscriptRecord(kind: .stream, arguments: arguments, stdout: collected, stderr: Data(),
                                            exitCode: 0, durationMs: Self.millis(since: started)))
                    continuation.finish()
                } catch {
                    append(TranscriptRecord(kind: .stream, arguments: arguments, stdout: collected,
                                            stderr: Data(String(describing: error).utf8), exitCode: -1,
                                            durationMs: Self.millis(since: started)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func millis(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    private func append(_ record: TranscriptRecord) {
        lock.lock(); defer { lock.unlock() }
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }
}

/// Відтворює записаний транскрипт без підпроцесу: збіг за точним argv, записи з однаковим argv
/// віддаються по черзі появи. На виклик, якого в транскрипті нема, кидає `Miss` — тихого
/// порожнього виводу не буває, інакше тест доводив би не те, що думає.
public final class TranscriptTransport: ADBTransport, @unchecked Sendable {
    public struct Miss: Error, LocalizedError, Sendable {
        public let arguments: [String]
        public var errorDescription: String? {
            "У транскрипті немає запису для argv: \(arguments)"
        }
    }

    private let lock = NSLock()
    private var records: [TranscriptRecord]

    public init(records: [TranscriptRecord]) {
        self.records = records
    }

    public convenience init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        var parsed: [TranscriptRecord] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            parsed.append(try decoder.decode(TranscriptRecord.self, from: Data(line)))
        }
        self.init(records: parsed)
    }

    /// Записи, які ще не було відтворено (порожньо = транскрипт спожито повністю).
    public var remaining: [TranscriptRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    public func run(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) async throws -> ProcessResult {
        guard let record = take(kind: .run, arguments: invocation.arguments) else {
            throw Miss(arguments: invocation.arguments)
        }
        return ProcessResult(stdout: record.stdout, stderr: record.stderr, exitCode: record.exitCode)
    }

    public func stream(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) -> AsyncThrowingStream<Data, Error> {
        let record = take(kind: .stream, arguments: invocation.arguments)
        let arguments = invocation.arguments
        return AsyncThrowingStream { continuation in
            guard let record else {
                continuation.finish(throwing: Miss(arguments: arguments))
                return
            }
            if !record.stdout.isEmpty { continuation.yield(record.stdout) }
            if record.exitCode == 0 {
                continuation.finish()
            } else {
                continuation.finish(throwing: Miss(arguments: arguments))
            }
        }
    }

    private func take(kind: TranscriptRecord.Kind, arguments: [String]) -> TranscriptRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.kind == kind && $0.arguments == arguments }) else { return nil }
        return records.remove(at: index)
    }
}
