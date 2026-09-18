import SwiftUI
import AndroidMoverCore

/// 3.4: гарячі клавіші через `.commands` у App.swift. Кожне вікно (⌘N) має власний AppState —
/// команди читають стан АКТИВНОГО вікна через `@FocusedValue` (не `@Environment`, який дав би
/// один спільний екземпляр): RootView публікує `.focusedSceneValue(\.appState, state)` на
/// себе, тож при перемиканні між вікнами (⌘~/клік) `appState` тут автоматично вказує на
/// сховища саме того вікна, що зараз активне.
private struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

/// Дії, яким потрібен ЛОКАЛЬНИЙ UI-стан BrowserView (фокус пошуку, перемикач шлях↔TextField,
/// відкриття fileImporter-а push) — не частина AppState (сховища), тому окремий
/// focused-value, публікується лише поки BrowserView видима (детейл у stage == .ready).
/// nil, коли активне вікно показує OnboardingView — відповідні пункти меню самі задизейбляться.
private struct BrowserUIActionsFocusedValueKey: FocusedValueKey {
    typealias Value = BrowserUIActions
}

struct BrowserUIActions {
    let focusSearch: () -> Void
    let editPath: () -> Void
    let showPushImporter: () -> Void
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
    var browserUIActions: BrowserUIActions? {
        get { self[BrowserUIActionsFocusedValueKey.self] }
        set { self[BrowserUIActionsFocusedValueKey.self] = newValue }
    }
}

/// `.disabled` тут дзеркалить ТІ САМІ умови, що відповідні кнопки в BrowserView/toolbar —
/// жодної нової логіки, лише альтернативний вхід до тих самих методів сховищ.
struct AppCommands: Commands {
    @FocusedValue(\.appState) private var appState
    @FocusedValue(\.browserUIActions) private var browserUI

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()

            // Аудит-фікс (критично, п.2): БУВ ⌘C (без Shift) — перехоплював системний Copy в
            // КОЖНОМУ TextField (пошук, шлях, перейменування): виділення тексту й ⌘C для
            // копіювання в буфер обміну натомість стартували трансфер файлів. ⌘C лишається
            // системним, тут не чіпаємо; наш шорткат — ⌘⇧C.
            Button("Копіювати на Mac") {
                appState?.transfers.requestTransfer(move: false)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!(appState?.transfers.canTransfer ?? false))

            Button("Перемістити на Mac") {
                appState?.transfers.requestTransfer(move: true)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!(appState?.transfers.canTransfer ?? false))

            Button("На телефон…") {
                browserUI?.showPushImporter()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(browserUI == nil || !(appState?.transfers.canPush ?? false))

            // Аудит-фікс (high, п.3): БУВ голий ⌫ (без модифікатора) — перехоплював Backspace
            // у КОЖНОМУ TextField (пошук/шлях/перейменування): звичайне стирання символу
            // натомість відкривало підтвердження видалення з телефона. ⌘⌫ — як «Move to
            // Trash» у Finder. Аудит-фікс (п.4): visibleSelection, не голий selection —
            // приховане тумблером/фільтром ніколи не потрапляє в підтвердження видалення
            // (FileActions.requestDelete теж додатково валідує це саме, другий бар'єр).
            Button("Видалити з телефона…") {
                guard let appState else { return }
                appState.files.requestDelete(appState.browser.visibleSelection)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(appState?.browser.visibleSelection.isEmpty ?? true)

            Divider()

            Button("Вгору") {
                guard let browser = appState?.browser else { return }
                Task { await browser.goUp() }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(appState == nil || RemotePath.normalized(appState?.browser.currentPath ?? "/") == "/")

            Button("Оновити") {
                guard let browser = appState?.browser else { return }
                Task { await browser.refreshList() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState == nil)
        }

        // `.toolbar`-плейсмент = "View"-меню (той самий, куди NavigationSplitView додає
        // системний пункт "Показати/Сховати бічну панель", ⌘⌥S — стандартний, коду не
        // потребує).
        CommandGroup(after: .toolbar) {
            Divider()

            Button(appState?.browser.showHidden == true ? "Сховати приховані файли" : "Показати приховані файли") {
                appState?.browser.showHidden.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Button("Знайти") {
                browserUI?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(browserUI == nil)

            Button("Редагувати шлях") {
                browserUI?.editPath()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(browserUI == nil)

            Button("Додати в обране") {
                appState?.browser.addCurrentPathToFavorites()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(appState?.devices.activeDevice == nil)
        }
    }
}
