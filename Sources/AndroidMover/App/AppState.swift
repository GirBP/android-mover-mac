import SwiftUI
import Observation
import Foundation
import AndroidMoverCore

/// Тонкий композитор п'яти сховищ (Sources/AndroidMover/State/) — сам не тримає жодного
/// стану, лише конструює й з'єднує їх. Кожне вікно (⌘N) отримує власний AppState, тож і
/// власний незалежний набір сховищ/поллерів (App.swift: `@State private var state = AppState()`).
@MainActor
@Observable
final class AppState {
    let devices = DeviceStore()
    // @Bindable-дінамік-мемберний доступ ($state.browser.pathField тощо з View-ів)
    // вимагає ReferenceWritableKeyPath через кожен сегмент шляху (Swift 6 strict
    // concurrency), тому ці чотири — `var`, а не `let`; попри це, кожне присвоюється рівно
    // раз, у init() нижче.
    var browser: BrowserStore
    var transfers: TransferCoordinator
    var preview: PreviewStore
    var files: FileActions
    /// Wi-Fi (спарювання/під'єднання) — тримає лише DeviceStore.
    var wireless: WirelessStore

    init() {
        let browser = BrowserStore(deviceStore: devices)
        let transfers = TransferCoordinator(deviceStore: devices, browserStore: browser)
        self.browser = browser
        self.transfers = transfers
        self.preview = PreviewStore(deviceStore: devices, browserStore: browser)
        self.files = FileActions(deviceStore: devices, browserStore: browser, transfers: transfers)
        self.wireless = WirelessStore(deviceStore: devices)

        // Поллер листингу (BrowserStore) не турбує теку, доки в черзі є активний
        // transfer (`hasActiveTransfer`, TransferQueue.swift). Push ніколи не блокував
        // лістинг/storageInfo — власна тимчасова тека push-у на телефоні
        // (.androidmover-tmp-*) не заважає читати решту вмісту поточного каталогу.
        browser.isOperationActive = { [weak transfers] in
            transfers?.hasActiveTransfer ?? false
        }
        // DeviceStore заморожує кадри track-devices (не публікує їх одразу — stage
        // не має переключатись на .noDevice посеред pull/resume), доки є активний transfer у
        // черзі — та сама умова, що й browser.isOperationActive вище, без push.
        devices.isOperationActive = { [weak transfers] in
            transfers?.hasActiveTransfer ?? false
        }
        // Коли transfer завершується, DeviceStore публікує найсвіжіший кадр, накопичений
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
        // Sweep сиріт на диску призначення від попереднього (можливо, аварійно
        // завершеного) запуску — didSet тут не спрацював би (значення відновлюється прямим
        // присвоєнням усередині TransferCoordinator.init).
        transfers.sweepDestination()
        // Незавершені операції з попереднього запуску → банер відновлення.
        transfers.loadRecoverable()
        devices.bootstrap()
        browser.startPolling()
    }
}
