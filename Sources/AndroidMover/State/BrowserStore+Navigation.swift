import Foundation
import AndroidMoverCore

/// Аудит-фікс (файл ≤400 рядків): навігація по теках телефона, поллер листингу, обране
/// (per-serial), персистенція сортування таблиці — винесено з BrowserStore.swift (той ліз за
/// 400-рядкову межу після критичного/high-фіксів v0.10.2, п. index-race/isIndexBuilding/
/// scheduleRefilter). Той самий патерн розбиття, що вже застосований до
/// BrowserView.swift/BrowserView+Toolbar.swift.
///
/// `lastListedKey`/`listGeneration`/`sweptRemoteKeys`/`lastStorageInfoAt`/
/// `lastKnownActiveSerial`/`pollTask` лишаються ОГОЛОШЕНІ (stored properties) у
/// BrowserStore.swift — Swift-екстеншени не можуть додавати stored-властивості — але
/// звужені з `private` до звичайного (internal, видимого лише в межах модуля) доступу, щоб
/// методи тут могли їх читати/писати; те саме зроблено з `loadSortOrder`/`persistSortOrder`
/// (були `fileprivate static func`) — на них є виклики з BrowserStore.swift (ініціалізатор
/// `sortOrder` і його didSet).
extension BrowserStore {
    /// Скидає кеш "останній залістований ключ" — щоб наступний refreshList() не був пропущений
    /// поллером як "нічого не змінилось". Викликається після transfer/push (2.1 переніс сюди
    /// пряме `lastListedKey = nil`, яке раніше жило в AppState.startTransfer/requestPush).
    func invalidateListingCache() {
        lastListedKey = nil
    }

    // MARK: - Поллер листингу (2.4: тригериться подією зміни пристрою від DeviceStore,
    // сам більше не питає `adb devices` — лише читає вже оновлений DeviceStore.activeDevice)

    /// 2.2-фікс (той самий патерн, що DeviceStore.startTrackingIfNeeded): БЕЗ
    /// `while let self` — той бинд тримав би СИЛЬНИЙ `self` на весь час тіла ітерації,
    /// включно з `Task.sleep(2.5с)`, тобто `self` (і BrowserStore, і транзитивно все, що
    /// він тримає) лишався б живим на весь сон, навіть коли вікно вже закрилось. Замість
    /// цього `self` зв'язується в СИЛЬНИЙ локальний лише на момент застосування
    /// (`if let self { await self.pollTick() }` — тіло if вужче за тіло while) — сон нижче
    /// вже поза цим зв'язуванням, self звільняється до нього.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                if let self {
                    await self.pollTick()
                }
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    private func pollTick() async {
        guard deviceStore.adbPath != nil, !isOperationActive() else { return }
        guard deviceStore.stage == .ready, !isLoading, let serial = deviceStore.activeDevice?.serial else { return }
        let key = "\(serial)|\(currentPath)"
        if key != lastListedKey {
            await refreshList()
        }
        await refreshStorageInfo(force: false)
    }

    /// DeviceStore.onDeviceSelected — миттєвий повний скид без очікування поллера (та сама
    /// поведінка, що раніше була в AppState.selectDevice()).
    func deviceWasExplicitlySelected() {
        listGeneration += 1
        isLoading = false
        lastListedKey = nil
        entries = []
        selection = []
        listError = nil
        filterText = ""
        storageInfo = nil
        lastStorageInfoAt = nil
        lastKnownActiveSerial = deviceStore.activeDevice?.serial
        favorites = loadFavorites(for: lastKnownActiveSerial)
        lastFavoritesKey = lastKnownActiveSerial.map { favoritesKey(for: $0) }
    }

    /// DeviceStore.onDevicesUpdated — та сама інвалідація, що раніше жила у кінці
    /// AppState.refreshDevicesQuietly(). 3.1: обране теж перечитується тут — це єдине
    /// місце, що ловить і автоматичне перепідключення (не лише явний вибір користувача вище).
    func devicesContextDidChange(activeSerial: String?, isEmpty: Bool) {
        if isEmpty { lastListedKey = nil }
        if activeSerial != lastKnownActiveSerial {
            storageInfo = nil
            lastStorageInfoAt = nil
        }
        // v0.14.0: обране ключоване стабільною ідентичністю — перечитати і при зміні serial, і коли
        // ідентичність того самого serial щойно резолвилась.
        let key = activeSerial.map { favoritesKey(for: $0) }
        if activeSerial != lastKnownActiveSerial || key != lastFavoritesKey {
            favorites = loadFavorites(for: activeSerial)
            lastFavoritesKey = key
        }
        lastKnownActiveSerial = activeSerial
    }

    // MARK: - 3.1: обране на телефоні (per-serial UserDefaults)

    /// v0.14.0: ключ за стабільною ідентичністю (`android_id|serial`), не за adb-serial — той самий
    /// телефон по USB і по Wi-Fi має одне обране; адреса `ip:port` після перезавантаження інша.
    private func favoritesKey(for serial: String) -> String { "phoneFavorites.\(deviceStore.stableID(for: serial))" }

    private func loadFavorites(for serial: String?) -> [String] {
        guard let serial else { return [] }
        let key = favoritesKey(for: serial)
        if let saved = UserDefaults.standard.stringArray(forKey: key) { return saved }
        // Одноразова міграція зі старого ключа за serial (v0.10–v0.13).
        let legacyKey = "phoneFavorites.\(serial)"
        if legacyKey != key, let legacy = UserDefaults.standard.stringArray(forKey: legacyKey) {
            UserDefaults.standard.set(legacy, forKey: key)
            return legacy
        }
        return []
    }

    /// Додає ПОТОЧНУ відкриту теку в обране активного пристрою — виклик і з кнопки "+" у
    /// сайдбарі, і з контекстного меню "Додати в обране" на breadcrumb-рядку.
    /// v0.10.2: чи є сенс додавати поточну теку в обране (є пристрій, не швидке місце, ще не в
    /// обраному) — сайдбар вимикає «+» і пояснює чому, замість мовчазного «нічого не сталось».
    var canAddCurrentPathToFavorites: Bool {
        deviceStore.activeDevice != nil
            && !favorites.contains(currentPath)
            && !Self.quickPlaces.contains { $0.path == currentPath }
    }

    func addCurrentPathToFavorites() {
        guard canAddCurrentPathToFavorites, let serial = deviceStore.activeDevice?.serial else { return }
        favorites.append(currentPath)
        UserDefaults.standard.set(favorites, forKey: favoritesKey(for: serial))
    }

    func removeFavorite(_ path: String) {
        guard let serial = deviceStore.activeDevice?.serial else { return }
        favorites.removeAll { $0 == path }
        UserDefaults.standard.set(favorites, forKey: favoritesKey(for: serial))
    }

    // MARK: - 3.8: персистенція сортування таблиці

    private static let sortFieldKey = "browser.sortField"
    private static let sortAscendingKey = "browser.sortAscending"

    private static func sortFieldName(_ comparator: KeyPathComparator<RemoteEntry>) -> String? {
        switch comparator.keyPath {
        case \RemoteEntry.name: return "name"
        case \RemoteEntry.size: return "size"
        case \RemoteEntry.modified: return "modified"
        default: return nil
        }
    }

    static func persistSortOrder(_ order: [KeyPathComparator<RemoteEntry>]) {
        guard let first = order.first, let field = sortFieldName(first) else { return }
        UserDefaults.standard.set(field, forKey: sortFieldKey)
        UserDefaults.standard.set(first.order == .forward, forKey: sortAscendingKey)
    }

    static func loadSortOrder() -> [KeyPathComparator<RemoteEntry>] {
        guard let field = UserDefaults.standard.string(forKey: sortFieldKey) else {
            return [KeyPathComparator(\.name)]
        }
        let order: SortOrder = UserDefaults.standard.bool(forKey: sortAscendingKey) ? .forward : .reverse
        switch field {
        case "size": return [KeyPathComparator(\.size, order: order)]
        case "modified": return [KeyPathComparator(\.modified, order: order)]
        default: return [KeyPathComparator(\.name, order: order)]
        }
    }

    // MARK: - Навігація

    func navigate(to path: String) async {
        // v0.10.2: клік по вже відкритій теці (швидке місце, обране, крихта) — не скидати
        // пошук і виділення; для примусового перечитування є «Оновити» (⌘R).
        guard RemotePath.normalized(path) != currentPath else { return }
        currentPath = RemotePath.normalized(path)
        pathField = currentPath
        filterText = ""
        await refreshList()
        await refreshStorageInfo(force: true)
    }

    /// Шлях, введений руками: обрізаємо випадкові пробіли (на відміну від шляхів з листингу).
    func navigateFromField() async {
        await navigate(to: RemotePath.userInput(pathField))
    }

    func goUp() async {
        await navigate(to: RemotePath.parent(currentPath))
    }

    /// Конкурентні виклики (поллер + навігація + кнопка «Оновити») не топчуть один одного:
    /// застосовується лише результат останнього.
    func refreshList() async {
        guard let client = deviceStore.client, let serial = deviceStore.activeDevice?.serial else { return }
        listGeneration += 1
        let generation = listGeneration
        let path = currentPath
        isLoading = true
        listError = nil
        do {
            let listed = try await client.listDirectory(path, on: serial)
            guard generation == listGeneration else { return }
            entries = listed
            sweepRemoteOrphansIfNeeded(dir: path, client: client, serial: serial)
        } catch {
            guard generation == listGeneration else { return }
            entries = []
            listError = error.localizedDescription
        }
        lastListedKey = "\(serial)|\(path)"
        selection = []
        isLoading = false
    }

    /// 1.5: fire-and-forget sweep сиріт (.androidmover-tmp-*) на телефоні — рівно раз на
    /// serial|path за сесію (сесія — час життя BrowserStore, не окремого запуску-полінгу), лише
    /// після УСПІШНОГО лістингу. Ніколи не блокує UI і не показує помилку — best-effort.
    private func sweepRemoteOrphansIfNeeded(dir: String, client: ADBClient, serial: String) {
        let key = "\(serial)|\(dir)"
        guard !sweptRemoteKeys.contains(key) else { return }
        sweptRemoteKeys.insert(key)
        Task {
            _ = await OrphanSweeper.sweepRemote(in: dir, olderThan: 3600, client: client, serial: serial)
        }
    }

    /// `force: true` — завжди оновлює (виклик з navigate); `force: false` — лише якщо
    /// минуло ≥30 с від останнього оновлення (виклик з поллера). Best-effort: провал
    /// тихо ховає індикатор, а не показує помилку — це другорядна інформація.
    func refreshStorageInfo(force: Bool) async {
        guard let client = deviceStore.client, let serial = deviceStore.activeDevice?.serial else { return }
        if !force, let last = lastStorageInfoAt, Date().timeIntervalSince(last) < Self.storageInfoInterval {
            return
        }
        lastStorageInfoAt = Date()
        let path = currentPath
        let info = try? await client.storageInfo(for: path, on: serial)
        // Пізній результат для вже неактуального пристрою/шляху (користувач встиг
        // перемкнути пристрій чи перейти в інший каталог) відкидаємо.
        guard serial == deviceStore.activeDevice?.serial, path == currentPath else { return }
        storageInfo = info
    }

    /// v0.10.1: `index.byID[id]` — O(1) замість `entries.first(where:)` (O(n) на клік).
    func openIfSingleDirectory(_ ids: Set<String>) {
        guard ids.count == 1, let id = ids.first,
              let entry = index.byID[id],
              entry.isDirectory else { return }
        Task { await navigate(to: entry.path) }
    }
}
