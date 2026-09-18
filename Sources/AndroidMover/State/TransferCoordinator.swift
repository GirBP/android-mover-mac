import SwiftUI
import Observation
import Foundation
import AndroidMoverCore

/// 2.1: черга операцій перенесення/push — раніше жила в AppState (назва `TransferCoordinator`,
/// щоб не конфліктувати з Foundation.OperationQueue). Тримає СИЛЬНІ (однонапрямні) посилання
/// на DeviceStore/BrowserStore для client/serial/selection/currentPath; історія (A5) теж тут.
///
/// 3.3: цей файл — ядро (destination(s), canTransfer/canPush, requestTransfer, історія).
/// `queue`-механіка (enqueueTransfer/enqueuePush/cancel(id:)/remove(id:)/clearFinished(),
/// послідовний запуск) — TransferQueue.swift, той самий тип, інший файл (як 2.8 розбило
/// ADBClient/TransferEngine по файлах). `OperationItem` (обгортка над TransferSession/
/// PushSession для однорідного масиву `queue`) — OperationItem.swift.
@MainActor
@Observable
final class TransferCoordinator {
    let deviceStore: DeviceStore
    let browserStore: BrowserStore

    var destination: URL? {
        didSet {
            UserDefaults.standard.set(destination?.path, forKey: "destinationPath")
            sweepDestination()
        }
    }
    /// 3.1: кілька збережених тек призначення на Mac (sidebar, секція "Mac") — `destination`
    /// лишається "активною" текою серед них. Персистується окремо (масив шляхів, порядок
    /// додавання) від "destinationPath" — той ключ і далі тримає лише АКТИВНУ теку, для
    /// зворотної сумісності зі старими версіями, що читали лише його.
    var destinations: [URL] = []
    var confirmingMove = false
    /// v0.11.0 (P5): токен `ProcessInfo.beginActivity` (idle sleep вимкнено), доки є активна операція.
    @ObservationIgnored var sleepActivity: NSObjectProtocol?
    /// v0.10.1 (перф-фікс, п.5): к-ть елементів для confirmationDialog "Перемістити N елем.",
    /// ЗАФІКСОВАНА в момент requestTransfer(move: true) — раніше BrowserView.swift читав
    /// `state.browser.visibleSelection.count` НАПРЯМУ в title-параметрі, підв'язаному до
    /// `mainContent` (весь table+pathBar+bottomBar) — будь-яка зміна selection/entries/
    /// filterText інвалідовувала ввесь mainContent заради рядка, що здебільшого не показаний.
    private(set) var pendingMoveCount = 0

    /// 3.3: черга операцій (Safari Downloads-стиль) — замість одиничних `transfer`/`push`.
    /// Виконання послідовне: `TransferQueue.runNextIfNeeded()` стартує щонайбільше один
    /// елемент одночасно, решта чекають зі станом `.pending` (`OperationItem.rowState`).
    var queue: [OperationItem] = []
    /// 3.3: чи розгорнута `OperationQueuePanel` — авто-розгортається при постановці нового
    /// елемента в чергу (enqueueTransfer/enqueuePush), користувач може згорнути вручну; після
    /// цього лишається згорнутою, доки не додасться щось нове.
    var isQueuePanelExpanded = true

    /// 2.2: сигнал DeviceStore-у "transfer закінчився" — задається в AppState.init як
    /// `devices.flushPendingFrame` (слабко захоплений DeviceStore, як і решта міжсховищних
    /// замикань). DeviceStore заморожує кадри track-devices, доки `isOperationActive()`
    /// (3.3: `hasActiveTransfer`, TransferQueue.swift) каже true; цей виклик публікує
    /// найсвіжіший накопичений кадр, щойно АКТИВНИЙ transfer справді завершився (викликається
    /// з середини `enqueueTransfer`, не з push — та сама умова, що й раніше).
    var onOperationEnded: (() -> Void)?

    // Історія операцій (A5): JSON Lines у Application Support, спільна для всіх вікон.
    let historyStore = HistoryStore(fileURL: HistoryStore.defaultURL)

    /// v0.11.0 (P4): журнал НЕЗАВЕРШЕНИХ операцій — відновлення після краху/kill/вимкнення.
    let journal = OperationJournal(fileURL: OperationJournal.defaultURL)
    /// Записи, що потребують відновлення (банер RecoveryBanner). Завантажується на старті і
    /// після кожної завершеної операції.
    var recoverable: [JournalRecord] = []
    /// Записи операцій, що ВИКОНУЮТЬСЯ в цій сесії — не «незавершені з минулого», банер їх не показує.
    @ObservationIgnored var activeJournalIDs = Set<UUID>()
    /// Повідомлення банера відновлення («підключіть телефон X»), nil — усе гаразд.
    var recoveryMessage: String?

    /// Аудит-фікс (п.5а): реєстр УСІХ живих координаторів (одне вікно — один координатор) —
    /// AppDelegate.applicationShouldTerminate (Sources/AndroidMover/AppDelegate.swift)
    /// перевіряє чергу КОЖНОГО вікна перед виходом з додатка, не лише активного.
    /// `.weakObjects()`: реєстрація НЕ тримає координатор живим — закрите вікно (і його
    /// AppState) звільняється як завжди, сам випадає з реєстру.
    static let live = NSHashTable<TransferCoordinator>.weakObjects()

    init(deviceStore: DeviceStore, browserStore: BrowserStore) {
        self.deviceStore = deviceStore
        self.browserStore = browserStore
        TransferCoordinator.live.add(self)
        if let saved = UserDefaults.standard.string(forKey: "destinationPath") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory), isDirectory.boolValue {
                destination = URL(fileURLWithPath: saved, isDirectory: true)
            }
        }
        destinations = Self.loadDestinations()
        // Міграція зі старих версій (лише "destinationPath", без списку): активна тека,
        // відновлена вище, має з'явитись і в sidebar-списку, навіть якщо його ще нема.
        if let destination, !destinations.contains(where: { $0.path == destination.path }) {
            destinations.append(destination)
            Self.persistDestinations(destinations)
        }
        observeVolumeChanges()
    }

    /// 1.5: sweep сиріт на диску призначення — викликається і з `destination`.didSet (щойно
    /// обрана тека), і окремо з AppState.bootstrap() (didSet НЕ спрацьовує для значення,
    /// відновленого прямим присвоєнням усередині init — Swift не викликає спостерігачі
    /// властивості під час її ж власного init). Best-effort, фонова черга, ніколи не блокує UI.
    func sweepDestination() {
        if let destination {
            Task.detached(priority: .utility) {
                OrphanSweeper.sweepLocal(in: destination, olderThan: 3600)
            }
        }
    }

    // MARK: - 3.1: кілька тек призначення на Mac (sidebar)

    private static let destinationsKey = "destinationPaths"

    private static func loadDestinations() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: destinationsKey) ?? []
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private static func persistDestinations(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: destinationsKey)
    }

    /// Додає теку в збережений список (fileImporter "Обрати теку…" у sidebar чи drag&drop
    /// із Finder туди ж) і, за замовчуванням, одразу робить її активною (`destination`) — та
    /// сама поведінка, що раніше мала кнопка "Тека на Mac…" у bottomBar.
    func addDestination(_ url: URL, makeActive: Bool = true) {
        if !destinations.contains(where: { $0.path == url.path }) {
            destinations.append(url)
            Self.persistDestinations(destinations)
        }
        if makeActive { destination = url }
    }

    func removeDestination(_ url: URL) {
        destinations.removeAll { $0.path == url.path }
        Self.persistDestinations(destinations)
        if destination?.path == url.path {
            destination = destinations.first
        }
    }

    // MARK: - Похідний стан

    /// 3.3: більше НЕ гейтується активною операцією (`transfer == nil && push == nil` пішло
    /// разом з одиночними сесіями) — лише вибір/пристрій/призначення. Додавати в чергу можна
    /// й посеред виконання іншої операції.
    /// Аудит-фікс (п.4): `visibleSelection`, не голий `selection` — кнопка/меню "Копіювати"/
    /// "Перемістити" не активуються, коли вибрані елементи всі приховані (тумблером/фільтром);
    /// `startTransfer` однаково бере `selectedEntries` (теж уже `visibleSelection`), тож без
    /// цього кнопка була б "увімкнена", але нічого не робила б.
    var canTransfer: Bool {
        deviceStore.stage == .ready && !browserStore.visibleSelection.isEmpty && destination != nil
            && destinationProblem == nil
    }

    /// v0.10.3: чому активна тека призначення непридатна (диск від'єднано, лише читання), або nil.
    var destinationProblem: String? {
        destination.flatMap { cachedProblem(for: $0) }
    }

    // v0.12.2 (M1, аудит M6): `problem(for:)` робить синхронні fileExists/isWritableFile — на
    // зовнішньому диску, що заснув, чи на мережевому томі це блокує main, а викликалось воно
    // ~9 разів на кожен рендер нижньої панелі й на кожен рядок секції «Mac». Тепер результат
    // живе ~2 с і скидається за подіями монтування/розмонтування томів.
    @ObservationIgnored private var problemCache: [String: (checkedAt: Date, problem: String?)] = [:]
    @ObservationIgnored nonisolated(unsafe) private var volumeObservers: [any NSObjectProtocol] = []
    private static let problemCacheTTL: TimeInterval = 2

    func cachedProblem(for url: URL) -> String? {
        let now = Date()
        if let hit = problemCache[url.path], now.timeIntervalSince(hit.checkedAt) < Self.problemCacheTTL {
            return hit.problem
        }
        let problem = Self.problem(for: url)
        problemCache[url.path] = (now, problem)
        return problem
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.willUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.problemCache.removeAll() }
            })
        }
    }

    deinit {
        for observer in volumeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Та сама перевірка для будь-якої теки зі списку (сайдбар показує попередження на рядку).
    static func problem(for url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return String(localized: "Тека недоступна — диск від'єднано або теку видалено")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return String(localized: "Лише для читання — сюди не можна записувати (NTFS?)")
        }
        return nil
    }

    /// v0.10.2: чому «Копіювати/Перемістити» неактивні — для `.help` на кнопках і в меню;
    /// nil, коли активні. Той самий порядок перевірок, що в canTransfer.
    var transferDisabledReason: String? {
        if deviceStore.stage != .ready { return String(localized: "Підключіть телефон") }
        if browserStore.visibleSelection.isEmpty { return String(localized: "Виберіть файли або теки в таблиці") }
        if destination == nil { return String(localized: "Оберіть теку призначення на Mac («Куди:» унизу або сайдбар → Mac)") }
        if let problem = destinationProblem { return problem }
        return nil
    }

    /// 3.3: те саме послаблення, що й canTransfer — push більше не блокується активною
    /// operацією, лише готовністю пристрою.
    var canPush: Bool {
        deviceStore.stage == .ready
    }

    // MARK: - Перенесення Android → Mac

    func requestTransfer(move: Bool) {
        guard canTransfer else { return }
        if move {
            pendingMoveCount = browserStore.visibleSelection.count
            confirmingMove = true
        } else {
            startTransfer(move: false)
        }
    }

    /// Тонкий вхідний метод, викликаний і напряму (копіювання), і з confirmationDialog
    /// (переміщення, після підтвердження) — збирає поточні параметри (вибір, призначення) і
    /// ставить елемент у чергу (`enqueueTransfer`, TransferQueue.swift). Сама робота — там.
    func startTransfer(move: Bool) {
        guard canTransfer, let destination, let device = deviceStore.activeDevice else { return }
        let chosen = browserStore.selectedEntries
        guard !chosen.isEmpty else { return }
        enqueueTransfer(entries: chosen, destination: destination, move: move,
                        serial: device.serial, deviceLabel: device.displayName)
    }

    // MARK: - Push Mac → Android (B1)

    /// `urls` — файли й/або теки з Finder (кнопка «На телефон…» чи дроп у таблицю). Ціль push
    /// — ПОТОЧНА відкрита тека телефона на момент виклику (знімок, як і destination вище —
    /// елемент у черзі не "пливе" за подальшою навігацією користувача по телефону).
    func requestPush(urls: [URL]) {
        guard canPush, !urls.isEmpty, let device = deviceStore.activeDevice else { return }
        enqueuePush(urls: urls, destDir: browserStore.currentPath, serial: device.serial, deviceLabel: device.displayName)
    }

    // MARK: - Історія операцій (A5)

    /// Поважає тумблер «Вести історію операцій» (Settings, @AppStorage "history.enabled");
    /// best-effort — `try?` ніколи не блокує основний флоу. Internal (не private) — FileActions
    /// теж дописує сюди записи про видалення, TransferQueue.swift — про copy/move/push.
    func appendHistory(direction: String, items: [HistoryItem]) {
        guard !items.isEmpty, UserDefaults.standard.bool(forKey: "history.enabled") else { return }
        let deviceLabel = deviceStore.activeDevice?.displayName ?? String(localized: "Пристрій")
        let record = HistoryRecord(direction: direction, deviceLabel: deviceLabel, items: items)
        try? historyStore.append(record)
    }

    /// Internal (не private): TransferQueue.swift (інший файл, той самий тип) мапує ними
    /// результати перед appendHistory.
    static func historyItem(for result: TransferItemResult) -> HistoryItem {
        let status: String
        switch result.status {
        case .copied: status = "copied"
        case .moved: status = "moved"
        case .failed(let message): status = "failed: \(message)"
        case .copiedButDeleteFailed(let message): status = "copiedButDeleteFailed: \(message)"
        case .cancelled: status = "cancelled"
        }
        return HistoryItem(
            name: result.entry.name, remotePath: result.entry.path, bytes: result.bytes,
            status: status, localPath: result.finalURL?.path
        )
    }

    static func historyItem(forPush result: PushItemResult) -> HistoryItem {
        let status: String
        switch result.status {
        case .pushed: status = "pushed"
        case .failed(let message): status = "failed: \(message)"
        case .cancelled: status = "cancelled"
        }
        return HistoryItem(
            name: result.name, remotePath: result.remotePath ?? "",
            bytes: result.bytes, status: status, localPath: result.localURL.path
        )
    }
}
