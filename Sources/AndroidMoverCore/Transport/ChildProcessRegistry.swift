import Foundation

/// Дочірні adb-процеси (`posix_spawn`-жені, напр. `adb track-devices`) не гинуть разом із
/// батьком на SIGTERM/SIGINT/kill — стандартна Unix-поведінка, сигнал батькові не
/// каскадується автоматично на дітей, вони репарентяться до launchd і лишаються сиротами
/// (підтверджено емпірично: `ps aux` після смоук-тесту `build_app.sh`, що вбиває головний
/// процес, показував живий `adb track-devices`).
///
/// Реєстр усіх живих `ChildProcess` — бекстоп на такий випадок: `ProcessRunner.spawnChild`
/// реєструє кожну щойно спороджену дитину тут (єдина точка спавну для `run()` і `stream()`),
/// `ChildProcess.markReaped` знімає її звідси сама (реап — природний кінець життя процесу,
/// більше нема чого термінувати). `ProcessRunner.terminateAllChildren()` — публічний вхід для
/// App-таргету (AppDelegate: SIGTERM/SIGINT-обробник і `applicationWillTerminate`) — ескалює
/// (SIGTERM→3с→SIGKILL) усе, що досі живе.
///
/// `[ObjectIdentifier: Weak]` під `NSLock`, не `NSHashTable.weakObjects()`: `ChildProcess` —
/// `final class`, `ObjectIdentifier` дає O(1) видалення в `unregister` без сканування всього
/// реєстру (NSHashTable теж підійшов би, але explicit dict простіше верифікувати).
final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()

    private struct WeakChild {
        weak var process: ChildProcess?
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: WeakChild] = [:]

    private init() {}

    func register(_ process: ChildProcess) {
        lock.lock(); defer { lock.unlock() }
        entries[ObjectIdentifier(process)] = WeakChild(process: process)
    }

    func unregister(_ process: ChildProcess) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: ObjectIdentifier(process))
    }

    /// Ескалація для кожного досі живого зареєстрованого процесу — `terminateWithEscalation()`
    /// сам ідемпотентний (лічильник під lock, per-процес, той самий шлях, яким іде звичайне
    /// «Скасувати»/idle-таймаут), тож безпечно кликати кілька разів (SIGTERM-обробник і
    /// `applicationWillTerminate` теоретично можуть спрацювати обидва).
    func terminateAll() {
        lock.lock()
        let live = entries.values.compactMap(\.process)
        lock.unlock()
        for process in live {
            process.terminateWithEscalation()
        }
    }
}
