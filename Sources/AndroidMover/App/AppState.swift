import SwiftUI
import Observation
import Foundation
import AndroidMoverCore

/// 2.1: тонкий композитор п'яти сховищ (Sources/AndroidMover/State/) — сам не тримає
/// жодного стану, лише конструює й з'єднує їх. Кожне вікно (⌘N) отримує власний AppState,
/// тож і власний незалежний набір сховищ/поллерів (App.swift: `@State private var state = AppState()`).
@MainActor
@Observable
final class AppState {
    let devices = DeviceStore()
    // 2.5 (Swift 6 strict): @Bindable-дінамік-мемберний доступ ($state.browser.pathField
    // тощо з View-ів) вимагає ReferenceWritableKeyPath через КОЖЕН сегмент шляху, тому ці
    // чотири — `var`, а не `let`; попри це, кожне присвоюється рівно раз, у init() нижче.
    var browser: BrowserStore
    var transfers: TransferCoordinator
    var preview: PreviewStore
    var files: FileActions
    /// v0.14.0: Wi-Fi (спарювання/під'єднання) — тримає лише DeviceStore.
    var wireless: WirelessStore

    init() {
        let browser = BrowserStore(deviceStore: devices)
        let transfers = TransferCoordinator(deviceStore: devices, browserStore: browser)
        self.browser = browser
        self.transfers = transfers
        self.preview = PreviewStore(deviceStore: devices, browserStore: browser)
        self.files = FileActions(deviceStore: devices, browserStore: browser, transfers: transfers)
        self.wireless = WirelessStore(deviceStore: devices)

        // 2.6/3.3: поллер листингу (BrowserStore) не турбує теку, доки в черзі є АКТИВНИЙ
        // transfer (`hasActiveTransfer`, TransferQueue.swift) — та сама умова, що раніше
        // давав одиночний `transfer != nil`, тепер по черзі. Push (B1) ніколи не блокував
        // лістинг/storageInfo — власна тимчасова тека push-у на телефоні
        // (.androidmover-tmp-*) не заважає читати решту вмісту поточного каталогу.
        browser.isOperationActive = { [weak transfers] in
            transfers?.hasActiveTransfer ?? false
        }
        // 2.2/3.3: DeviceStore заморожує кадри track-devices (не публікує їх одразу — stage
        // не мав переключатись на .noDevice посеред pull/resume), доки є АКТИВНИЙ transfer у
        // черзі — та сама умова, що й browser.isOperationActive вище, БЕЗ push.
        devices.isOperationActive = { [weak transfers] in
            transfers?.hasActiveTransfer ?? false
        }
        // 2.2: коли transfer завершується, DeviceStore публікує найсвіжіший кадр, накопичений
        // за час заморозки.
        transfers.onOperationEnded = { [weak devices] in
            devices?.flushPendingFrame()
        }
        // DeviceStore не тримає BrowserStore напряму (щоб не утворити цикл утримання) —
        // сигналізує про зміну пристрою через слабко захоплені замикання, задані тут.
        devices.onDeviceSelected = { [weak browser] in
            browser?.deviceWasExplicitlySelected()
        }
        devices.onDevicesUpdated = { [weak browser] activeSerial, isEmpty in
            browser?.devicesContextDidChange(activeSerial: activeSerial, isEmpty: isEmpty)
        }
    }

    /// Викликається раз із `.task` у RootView (App.swift). Сама async-функція нічого не
    /// зациклює — довгоживучі поллери тепер живуть у власних Task-ах DeviceStore/BrowserStore
    /// і скасовуються в їхніх deinit, коли вікно закривається (AppState звільняється).
    func bootstrap() async {
        PreviewStore.cleanCachesAtStartup()
        // 1.5: sweep сиріт на диску призначення від попереднього (можливо, аварійно
        // завершеного) запуску — didSet тут не спрацював би (значення відновлюється прямим
        // присвоєнням усередині TransferCoordinator.init).
        transfers.sweepDestination()
        // v0.11.0 (P4): незавершені операції з попереднього запуску → банер відновлення.
        transfers.loadRecoverable()
        devices.bootstrap()
        browser.startPolling()
    }
}
