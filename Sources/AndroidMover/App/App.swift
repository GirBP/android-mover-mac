import SwiftUI

@main
struct AndroidMoverApp: App {
    // 5а/6: applicationShouldTerminate (підтвердження виходу при активній черзі) і
    // SIGTERM/SIGINT-обробник (сирітські дочірні adb-процеси) — AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Дефолт для тумблера «Вести історію операцій» (Settings) — щоб AppState міг читати
        // той самий ключ напряму з UserDefaults без дублювання літералу-дефолту.
        UserDefaults.standard.register(defaults: ["history.enabled": true])
        // Щоб вікно показувалось і при запуску бінарника без .app-бандла (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Android Mover") {
            RootView()
        }
        // 3.4: гарячі клавіші — AppCommands.swift читає AppState активного вікна через
        // @FocusedValue (RootView публікує його нижче), не через один спільний примірник.
        .commands {
            AppCommands()
        }
        Settings {
            SettingsView()
        }
    }
}

struct RootView: View {
    // Стан на КОЖНЕ вікно окремо (⌘N відкриває незалежний браузер зі своїм поллером).
    @State private var state = AppState()

    var body: some View {
        // 3.1: NavigationSplitView — sidebar (SidebarView) завжди видимий (окрім згорнутого
        // користувачем стану — системна кнопка в тулбарі), detail перемикається між
        // BrowserView і OnboardingView. 3.8: банер "телефон відпав" тримає detail на
        // BrowserView ще 15с після зникнення пристрою (showDisconnectBanner) — лише ПІСЛЯ
        // грейс-періоду detail падає на OnboardingView.
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            if state.devices.stage == .ready || state.devices.showDisconnectBanner {
                BrowserView(state: state)
            } else {
                OnboardingView(state: state)
            }
        }
        .frame(minWidth: 880, minHeight: 540)
        // 3.4: публікує AppState ЦЬОГО вікна для AppCommands.swift (@FocusedValue) — кожне
        // вікно (⌘N) публікує своє, тож меню завжди діє на активне.
        .focusedSceneValue(\.appState, state)
        // 5б: підтвердження закриття ЦЬОГО вікна, коли в його черзі є активна/pending
        // операція — WindowAccessor.swift.
        .background(WindowAccessor(coordinator: state.transfers))
        .task {
            await state.bootstrap()
        }
    }
}
