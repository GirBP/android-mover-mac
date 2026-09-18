import Foundation

/// 2.2: спільний контролер скасування для довгоживучих ADB-рушіїв (TransferEngine, PushEngine,
/// RemoteFileTransfer.export) — витягнутий з дубльованої трійки `cancelFlag`/`currentProcess`/
/// `trackProcess`/`cancel()`, яка раніше жила окремо в кожному з них (байт-у-байт та сама
/// логіка в трьох місцях). Композиція (рушії тримають `let cancellation = CancellationController()`),
/// не наслідування — простіше й безпечніше для Swift 6 strict concurrency: жоден рушій не
/// змушений публічно наслідувати спільний базовий клас, жодних питань про self escaping з
/// designated init підкласів.
///
/// Закриває латентний баг подвійного kill, що раніше свідомо лишався в backlog:
/// `trackProcess` (гонка spawn-після-cancel — скасування прийшло РАНІШЕ, ніж процес устиг
/// зареєструватись) раніше в TransferEngine/PushEngine викликала ЛИШЕ `process.terminate()`,
/// без ескалації до SIGKILL за 3 с, — на відміну від `cancel()`, яка цю ескалацію планувала.
/// Якщо adb у цьому вузькому вікні ігнорував SIGTERM, процес міг лишитись висіти назавжди.
/// Тут обидва шляхи (синхронний `cancel()` і асинхронна гонка в `trackProcess`) ведуть у той
/// самий `ChildProcess.terminateWithEscalation()`.
///
/// 2.3: одноразовість ескалації (раніше — `killIssuedFlag` тут-таки, окремо від ІДЕНТИЧНОЇ
/// логіки, дубльованої в ProcessRunner.run (idle-таймаут) і ProcessRunner.stream
/// (onTermination)) — перенесена на сам `ChildProcess` (`terminateWithEscalation()`,
/// idempotent per-процес). Цей контролер більше не тримає власного прапорця "чи вже вбивали":
/// просто просить процес самому подбати про одноразовість, popри те, з якого з чотирьох
/// незалежних джерел скасування прийшов виклик.
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
    /// SIGTERM у поганому стані) — вся ескалація й одноразовість тепер у самому
    /// `ChildProcess.terminateWithEscalation()`, гарантія рівно одного SIGTERM попри гонку
    /// з `trackProcess` вище.
    public func cancel() {
        cancelFlagStorage.set()
        if let process = currentProcessBox.value {
            process.terminateWithEscalation()
        }
    }

    /// Скидає зареєстрований процес одразу після штатного завершення await-виклику, яким його
    /// зареєстрував `trackProcess` — той самий момент, коли рушії раніше писали
    /// `currentProcess.value = nil` напряму. Наступний `trackProcess` для нового процесу того
    /// самого елемента перезапише його знову.
    public func clearProcess() {
        currentProcessBox.value = nil
    }
}
