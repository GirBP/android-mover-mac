import SwiftUI
import AppKit

/// Аудит-фікс (п.5б): закриття ОДНОГО вікна (червона кнопка, ⌘W) — SwiftUI сам не дає гачка
/// "чи можна закрити це вікно" (на відміну від `applicationShouldTerminate` для виходу з
/// усього додатка, AppDelegate.swift). Місток: NSViewRepresentable, що знаходить NSWindow
/// цього SwiftUI-вікна (через `viewDidMoveToWindow`, надійніше за голий `DispatchQueue.main.
/// async` — спрацьовує рівно в момент, коли вікно РЕАЛЬНО стало доступне) і ставить
/// `CloseGuardWindowDelegate` нижче — той самий alert, що й підтвердження виходу, але лише
/// для черги ЦЬОГО вікна.
struct WindowAccessor: NSViewRepresentable {
    let coordinator: TransferCoordinator

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = { [coordinator] window in
            guard context.coordinator.retainedDelegate == nil else { return }
            let guardDelegate = CloseGuardWindowDelegate(coordinator: coordinator, previous: window.delegate)
            // NSWindow.delegate — weak: без сильного посилання ТУТ (Coordinator, що живе,
            // доки живий цей SwiftUI-view) ARC звільнив би guardDelegate одразу.
            context.coordinator.retainedDelegate = guardDelegate
            window.delegate = guardDelegate
        }
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var retainedDelegate: NSWindowDelegate?
    }

    /// Порожній NSView — жодного власного вмісту чи розміру (`.background(WindowAccessor(...))`
    /// у BrowserView-контейнері), лише спостерігач моменту "вікно стало доступне".
    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Перехоплює `windowShouldClose` для ОДНОГО вікна — усі інші виклики NSWindowDelegate
/// пересилає далі (`forwardingTarget(for:)`) до попереднього делегата (SwiftUI-власного), щоб
/// не зламати те, на що сам SwiftUI покладається (стан вікна, life-cycle сцени тощо). Якщо
/// попередній делегат САМ мав би заборонити закриття — поважаємо це першим, ДО власної
/// перевірки черги.
private final class CloseGuardWindowDelegate: NSObject, NSWindowDelegate {
    let coordinator: TransferCoordinator
    private weak var previous: NSWindowDelegate?

    init(coordinator: TransferCoordinator, previous: NSWindowDelegate?) {
        self.coordinator = coordinator
        self.previous = previous
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let previous, previous.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           previous.windowShouldClose?(sender) == false {
            return false
        }
        guard coordinator.hasQueueWork else { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Операція триває — скасувати і закрити?")
        alert.informativeText = String(localized: "У цьому вікні є незавершене перенесення чи push. Закриття скасує їх.")
        // v0.10.2: Enter/default — безпечна дія («Продовжити роботу»), деструктивна — друга.
        alert.addButton(withTitle: String(localized: "Продовжити роботу"))
        let closeButton = alert.addButton(withTitle: String(localized: "Скасувати і закрити"))
        closeButton.hasDestructiveAction = true
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return false }
        coordinator.cancelAll()
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (previous?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        super.responds(to: aSelector) ? nil : previous
    }
}
