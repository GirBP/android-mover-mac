import SwiftUI
import AndroidMoverCore

/// Аудит-фікс (п.5а, п.6): чистий SwiftUI `App`-lifecycle не дає гачків ані на "вихід із
/// додатка" (⌘Q/меню — щоб спитати підтвердження, коли черга операцій ще не порожня), ані на
/// SIGTERM/SIGINT (`kill`, Ctrl-C з термінала — щоб устигнути вбити дочірні adb-процеси перед
/// смертю самого додатка). Обидва потребують справжнього `NSApplicationDelegate` —
/// підключається через `@NSApplicationDelegateAdaptor` в App.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Тримає `DispatchSourceSignal`-и живими на весь час роботи додатка — без сильного
    /// посилання ARC звільнив би джерело одразу по виході з `installSignalHandler`, знявши
    /// обробник (джерело саме по собі не тримає себе живим).
    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    // MARK: - 5а: підтвердження виходу з додатка (⌘Q/меню), коли черга ще не порожня

    /// Перевіряє чергу КОЖНОГО вікна (`TransferCoordinator.live`, реєстр слабких посилань —
    /// TransferCoordinator.swift), не лише активного — вихід з додатка стосується ВСІХ вікон
    /// одразу.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = TransferCoordinator.live.allObjects.filter { $0.hasQueueWork }
        guard !busy.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Операція триває — скасувати і вийти?")
        alert.informativeText = String(localized: "У черзі є незавершене перенесення чи push. Вихід скасує їх — телефон нічого не видаляє без підтвердженої копії.")
        // v0.10.2: Enter/default — безпечна дія («Продовжити роботу»), деструктивна — друга.
        alert.addButton(withTitle: String(localized: "Продовжити роботу"))
        let quitButton = alert.addButton(withTitle: String(localized: "Скасувати і вийти"))
        quitButton.hasDestructiveAction = true
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return .terminateCancel }

        for coordinator in busy { coordinator.cancelAll() }
        return .terminateNow
    }

    // MARK: - 6: SIGTERM/SIGINT — прибрати дочірні adb-процеси перед смертю додатка

    /// `kill <pid>` (SIGTERM) чи Ctrl-C в терміналі (SIGINT) за замовчуванням убивають процес
    /// БЕЗ жодного шансу прибрати за собою — дочірні `posix_spawn`-жені adb-процеси (напр.
    /// `adb track-devices`, DeviceStore) НЕ гинуть разом (репарентяться до launchd, звичайна
    /// Unix-поведінка). Ігноруємо default disposition (`signal(sig, SIG_IGN)`) і слухаємо сам
    /// сигнал через `DispatchSource` (GCD-рекомендований спосіб — обробник виконується як
    /// звичайний код на `.main`, а не в обмеженому async-signal-safe контексті класичного
    /// POSIX signal-handler'а): термінуємо все зареєстроване (`ProcessRunner.
    /// terminateAllChildren()`, ChildProcessRegistry у Core) і ЛИШЕ ПОТІМ віддаємо керування
    /// звичайному `NSApp.terminate` (який іде крізь applicationShouldTerminate/
    /// applicationWillTerminate вище/нижче як завжди — тобто підтвердження виходу спрацює й
    /// тут, якщо є активна операція).
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.installSignalHandler(SIGTERM)
        Self.installSignalHandler(SIGINT)
    }

    private static func installSignalHandler(_ sig: Int32) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            ProcessRunner.terminateAllChildren()
            // MainActor.assumeIsolated: обробник ГАРАНТОВАНО виконується на main queue
            // (queue: .main вище), але `setEventHandler` типізований як звичайний
            // неізольований `() -> Void` — компілятор цього не знає. assumeIsolated —
            // стандартний спосіб сказати "я вже на MainActor" без async-стрибка (впав би,
            // якби гарантія була хибною, але тут вона з побудови dispatch source).
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
        source.resume()
        signalSources.append(source)
    }

    /// Звичайний вихід (підтверджено вище чи черга й так була порожня) — той самий бекстоп:
    /// DeviceStore.trackTask (track-devices) живе доти, доки вікно не звільнилось, а deinit
    /// сховищ під час самого виходу з процесу може не встигнути відпрацювати — цей виклик
    /// гарантує прибирання незалежно від того.
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRunner.terminateAllChildren()
    }
}
