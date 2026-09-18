import Foundation

// Sendable — усі властивості вже Sendable-типи (Data/Int32); без цього
// `Task { try await ProcessRunner.run(...) }.value` не компілюється під Swift 6 strict
// при переході межі Task.
public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public var out: String { String(decoding: stdout, as: UTF8.self) }
    public var err: String { String(decoding: stderr, as: UTF8.self) }
}

/// Помилка самого `posix_spawn` (ще до того, як щось узагалі запустилось) — напр. ENOENT, якщо
/// виконуваний файл не існує чи не має прав на виконання. На відміну від ненульового
/// `ProcessResult.exitCode` (уже запущеного й завершеного процесу), ця помилка означає, що
/// дитина не спородилась узагалі — викликачі (ADBInstaller, ADBClient) ловлять її як звичайний
/// `Error` і показують `.localizedDescription`, без розбору на конкретний тип.
public struct ProcessSpawnError: LocalizedError, Sendable {
    public let code: Int32
    public let executable: String

    public var errorDescription: String? {
        "Не вдалося запустити «\(executable)»: \(String(cString: strerror(code)))"
    }
}

/// Живий дескриптор дочірнього процесу, спородженого `ProcessRunner` через `posix_spawn` —
/// заміна `Foundation.Process`, яка на Darwin передає `arguments`/`environment` через
/// `fileSystemRepresentation` і тим мовчки NFD-декомпонує канонічно-композиційні символи
/// ("й" → "и"+U+0306 тощо; підтверджено ізольованим тестом, докладніше — ProcessRunner.run).
/// Тонка обгортка над `pid_t`: `terminate`/`forceKill` шлють сигнал напряму в ядро;
/// `isRunning`/`terminationStatus` читають внутрішній кеш, який виставляє лише `ProcessRunner`
/// одразу після власного `waitpid` (не «живий» опит ядра після reap-у).
public final class ChildProcess: @unchecked Sendable {
    public let pid: pid_t

    private let lock = NSLock()
    private var reaped = false
    private var exitCode: Int32 = -1
    /// Одноразовість самої ескалації (SIGTERM→3с→SIGKILL) — єдине джерело правди
    /// per-процес, попри те, скільки незалежних джерел скасування (cancel() користувача,
    /// гонка spawn-після-cancel у trackProcess, idle-таймаут, скасування Task-консюмера
    /// стріму) намагаються вбити той самий процес одночасно.
    private var escalationIssued = false

    init(pid: pid_t) {
        self.pid = pid
    }

    /// SIGTERM — м'яке прохання завершитись, перший крок ескалації скасування.
    /// Інваріант: після reap (`markReaped` уже викликаний) жоден сигнал не йде — PID уже не
    /// наш, ядро могло встигнути перевикористати його для геть іншого процесу (вузьке вікно
    /// між `markReaped` у ProcessRunner і `currentProcess.value = nil` у TransferEngine/
    /// PushEngine/RemoteFileTransfer — cancel(), що прийшов рівно в цю мить, інакше міг би
    /// вбити чужий процес).
    public func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return }
        kill(pid, SIGTERM)
    }

    /// SIGKILL — безумовне вбивство (ескалація, коли SIGTERM не подіяв за кілька секунд). Той
    /// самий інваріант, що й terminate(): no-op після reap.
    public func forceKill() {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return }
        kill(pid, SIGKILL)
    }

    /// SIGTERM негайно → SIGKILL через 3 с, якщо процес досі живий — і, на відміну від
    /// голого `terminate()`, одноразово: другий і подальші виклики (попри те, з якого
    /// джерела скасування — `CancellationController.cancel()`, гонка spawn-після-cancel у
    /// `trackProcess`, idle-таймаут `ProcessRunner.run`, `onTermination` у
    /// `ProcessRunner.stream`) — тихий no-op, ескалацію вже видано. Замінює комбінацію
    /// `terminate() + DispatchQueue.global().asyncAfter(3с) { forceKill() }` з одним спільним
    /// прапорцем одноразовості замість окремого прапорця в кожного викликача.
    public func terminateWithEscalation() {
        lock.lock()
        guard !reaped, !escalationIssued else {
            lock.unlock()
            return
        }
        escalationIssued = true
        lock.unlock()
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if isRunning { forceKill() }
        }
    }

    /// `false` одразу після того, як `ProcessRunner` сам реапнув процес (`markReaped`) — до
    /// цього моменту питає ядро напряму (`kill(pid, 0)`), що поверне `true` і для щойно
    /// завершеного, ще не реапнутого zombie (вузьке, невідворотне вікно між `exit()` у дитини
    /// і власним `waitpid()` у ProcessRunner, що працює паралельно в іншій черзі).
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        if reaped { return false }
        return kill(pid, 0) == 0
    }

    /// Код завершення після WIFEXITED/WEXITSTATUS-розбору (`ProcessRunner.decodeExitCode`).
    /// `-1` доти, доки процес не реапнутий — не має сенсу читати до завершення виклику
    /// `ProcessRunner.run`, що його спородив.
    public var terminationStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        return exitCode
    }

    func markReaped(exitCode: Int32) {
        lock.lock(); defer { lock.unlock() }
        reaped = true
        self.exitCode = exitCode
        // Реап — природний кінець життя процесу, більше нема чого термінувати при виході
        // додатка — знімаємо себе з реєстру-бекстопу (ChildProcessRegistry.swift).
        ChildProcessRegistry.shared.unregister(self)
    }
}
