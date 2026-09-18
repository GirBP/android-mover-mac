import Foundation

/// Один виклик adb як значення. `ADBClient` будує його з
/// argv + оточення + ідле-таймауту; транспорт вирішує, ЯК його виконати (справжній posix_spawn,
/// запис у транскрипт, відтворення транскрипта без підпроцесу).
public struct ADBInvocation: Sendable, Equatable {
    public let arguments: [String]
    public let environment: [String: String]?
    /// Ідле-таймаут (семантика `ProcessRunner.run`): nil — без обмеження (pull/push/track-devices).
    public let idleTimeout: TimeInterval?

    public init(arguments: [String], environment: [String: String]? = nil, idleTimeout: TimeInterval? = nil) {
        self.arguments = arguments
        self.environment = environment
        self.idleTimeout = idleTimeout
    }
}

/// Єдиний шов, через який застосунок торкається зовнішнього процесу adb. Дві операції: разовий
/// запуск із повним результатом і довгоживучий стрім (`track-devices`). Реалізації:
/// `SpawnTransport` (продакшн, байт-у-байт posix_spawn), `RecordingTransport` (запис
/// транскрипта), `TranscriptTransport` (відтворення golden без підпроцесу).
public protocol ADBTransport: Sendable {
    func run(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) async throws -> ProcessResult
    func stream(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) -> AsyncThrowingStream<Data, Error>
}

/// Продакшн-транспорт: делегує незмінному `ProcessRunner` (posix_spawn, argv/env байт-у-байт,
/// ідле-таймаут, SIGTERM → 3 с → SIGKILL через `ChildProcess.terminateWithEscalation`). Нічого не
/// перекодовує і не додає — інваріанти ARCHITECTURE.md живуть нижче цього шва.
public struct SpawnTransport: ADBTransport {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public func run(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            timeout: invocation.idleTimeout,
            onSpawn: onSpawn
        )
    }

    public func stream(_ invocation: ADBInvocation, onSpawn: (@Sendable (ChildProcess) -> Void)?) -> AsyncThrowingStream<Data, Error> {
        ProcessRunner.stream(
            executable: executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            onSpawn: onSpawn
        )
    }
}
