import Foundation

/// Спільний контролер скасування для довгоживучих ADB-рушіїв (TransferEngine, PushEngine,
/// RemoteFileTransfer.export) — уникає дублювання трійки `cancelFlag`/`currentProcess`/
/// `trackProcess`/`cancel()` в кожному з них. Композиція (рушії тримають `let cancellation
/// = CancellationController()`), не наслідування — простіше й безпечніше для Swift 6 strict
/// concurrency: жоден рушій не змушений публічно наслідувати спільний базовий клас, жодних
/// питань про self escaping з designated init підкласів.
///
/// Уникає подвійного kill: гонка spawn-після-cancel у `trackProcess` (скасування прийшло
/// раніше, ніж процес устиг зареєструватись) веде до того самого
/// `ChildProcess.terminateWithEscalation()`, що й синхронний `cancel()`, а не лише до
/// `process.terminate()` без ескалації до SIGKILL за 3 с — інакше adb, що в цьому вузькому
/// вікні ігнорує SIGTERM, міг би лишитись висіти назавжди.
///
/// Одноразовість ескалації живе на самому `ChildProcess` (`terminateWithEscalation()`,
/// idempotent per-процес), не в цьому контролері: він лише просить процес самому подбати
/// про одноразовість, попри те, з якого з чотирьох незалежних джерел скасування прийшов
/// виклик.
public final class CancellationController: @unchecked Sendable {
    private let cancelFlagStorage = LockedFlag()
    private let currentProcessBox = LockedBox<ChildProcess>()

    public init() {}

    public var isCancelled: Bool { cancelFlagStorage.isSet }

    /// Реєструє щойно спородженний adb-процес — передається як `onSpawn:` у виклики
    /// `ADBClient`/`ProcessRunner`. Якщо скасування вже було запитане до цього моменту (гонка
    /// spawn-після-cancel) — негайно вбиває щойно зареєстрований процес тим самим шляхом
    /// ескалації, що й `cancel()`, а не лишає його жити до наступної точки перевірки.
    public var trackProcess: @Sendable (ChildProcess) -> Void {
        { [currentProcessBox, cancelFlagStorage] process in
            currentProcessBox.value = process
            if cancelFlagStorage.isSet { process.terminateWithEscalation() }
        }
    }

    /// SIGTERM негайно → SIGKILL через 3 с, якщо процес досі живий (adb іноді ігнорує
    /// SIGTERM у поганому стані) — вся ескалація й одноразовість живе в самому
    /// `ChildProcess.terminateWithEscalation()`, гарантія рівно одного SIGTERM попри гонку
    /// з `trackProcess` вище.
    public func cancel() {
        cancelFlagStorage.set()
        if let process = currentProcessBox.value {
            process.terminateWithEscalation()
        }
    }

    /// Скидає зареєстрований процес одразу після штатного завершення await-виклику, яким його
    /// зареєстрував `trackProcess`. Наступний `trackProcess` для нового процесу того самого
    /// елемента перезапише його знову.
    public func clearProcess() {
        currentProcessBox.value = nil
    }
}
