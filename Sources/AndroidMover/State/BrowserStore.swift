import Foundation
import Observation
import AndroidMoverCore

/// 2.1: навігація, лістинг, сортування/фільтр, вільне місце — раніше жило в AppState.
/// Тримає СИЛЬНЕ (однонапрямне, без циклу) посилання на DeviceStore, щоб читати
/// client/activeDevice; сам про пристрій нічого не питає — DeviceStore сигналізує через
/// deviceWasExplicitlySelected()/devicesContextDidChange(), а не власним `adb devices`.
@MainActor
@Observable
final class BrowserStore {
    let deviceStore: DeviceStore

    var currentPath = "/sdcard"
    var pathField = "/sdcard"
    // Аудит-фікс (п.4): при КОЖНІЙ зміні — виділення обмежується тим, що ще видиме.
    // v0.10.1 (перф-фікс, п.1/12): didSet планує перебудову `index` (scheduleIndexRebuild
    // нижче) замість перерахунку похідних властивостей на кожен доступ; сама перебудова й
    // обрізає selection наприкінці.
    var entries: [RemoteEntry] = [] {
        didSet { scheduleIndexRebuild() }
    }
    var isLoading = false
    var listError: String?
    // Аудит-фікс (high): didSet тепер оновлює закешований `selectionSummary` (нижче) РАЗ, на
    // реальну зміну виділення — не при кожному читанні з bottomBar.
    var selection = Set<String>() {
        didSet {
            guard selection != oldValue else { return }
            refreshSelectionSummary()
        }
    }
    // 3.8: сортування переживає перезапуск — персиститься в UserDefaults як пара
    // (поле, зростання), бо KeyPathComparator сам по собі не Codable. Дефолт відновлює
    // збережене на момент конструювання (BrowserStore.loadSortOrder(), MARK: - Персистенція).
    // v0.10.1: didSet тепер ще й планує перебудову index (нова сортувальна спеца).
    var sortOrder: [KeyPathComparator<RemoteEntry>] = BrowserStore.loadSortOrder() {
        didSet {
            BrowserStore.persistSortOrder(sortOrder)
            scheduleIndexRebuild()
        }
    }
    // 3.5: тумблер прихованих файлів (default off) — `.androidmover-tmp-*` ховається
    // ЗАВЖДИ, незалежно від цього прапорця.
    // v0.10.1: showHidden НЕ міняє порядок, лише видимість — дешева refiltered() (без
    // пересортування, без повного scheduleIndexRebuild()).
    // Аудит-фікс (medium): і ця refiltered(), і filterText нижче, планують її ОФФ-main
    // (scheduleRefilter()) — раніше кликали `index.refiltered(...)` СИНХРОННО на MainActor
    // у тілі didSet, тобто на КОЖЕН натиск клавіші в пошуку весь ICU-прохід
    // (`localizedCaseInsensitiveContains` на кожен видимий елемент, до 50k) блокував головний
    // потік (виміряно: ~55-60мс на 50k, і DEBUG, і RELEASE — 3+ пропущені кадри на
    // keystroke).
    var showHidden = UserDefaults.standard.bool(forKey: "browser.showHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "browser.showHidden")
            scheduleRefilter()
        }
    }
    // internal (не private): BrowserStore+Navigation.swift (інший файл, той самий тип) читає
    // й пише обидва — refreshList/pollTick/deviceWasExplicitlySelected/devicesContextDidChange.
    var lastListedKey: String?
    var listGeneration = 0
    // v0.10.1: генерація перебудови index — Task.detached (scheduleIndexRebuild) міг
    // стартувати на застарілому знімку entries; MainActor.run звіряє це значення і
    // відкидає застарілий build, якщо стартувала новіша.
    private var indexGeneration = 0
    // Аудит-фікс (критично): true від моменту, коли scheduleIndexRebuild() СТАРТУВАВ
    // асинхронну побудову (Task.detached), і аж до приземлення MainActor.run — BrowserView
    // гейтить спінер і на це, не лише на isLoading (BrowserView.swift, overlay). Інакше є
    // вікно (виміряно ~80-300мс на 50k) де entries/isLoading вже вказують на НОВУ теку, а
    // `index` (і, відповідно, filteredEntries/selectedEntries/byID, куди йдуть клік і
    // Cmd+A) ще старий — таблиця показує вміст СТАРОЇ теки чи хибне "Нічого не знайдено" на
    // реально непорожній.
    private(set) var isIndexBuilding = false
    // Аудит-фікс (medium): генерація scheduleRefilter() — той самий "останній старт
    // виграє" патерн, що indexGeneration вище, але для дешевшого шляху filterText/
    // showHidden (без повного пересорту).
    private var filterGeneration = 0
    @ObservationIgnored
    private nonisolated(unsafe) var refilterTask: Task<Void, Never>?

    // 3.1: обране на телефоні — теки, додані користувачем для АКТИВНОГО пристрою. У пам'яті
    // тримається лише список поточного serial (перезавантажується при зміні пристрою, нижче);
    // персиститься per-serial у UserDefaults, щоб не змішувати обране різних телефонів.
    var favorites: [String] = []

    // 1.5: sweep сиріт (.androidmover-tmp-*) на телефоні — раз на serial|path за сесію.
    // internal (не private): sweepRemoteOrphansIfNeeded — BrowserStore+Navigation.swift.
    var sweptRemoteKeys = Set<String>()

    // Пошук/фільтр по імені в поточній теці (A1).
    // Аудит-фікс (п.4): приховане фільтром знімається з виділення — інваріант "деструктивні
    // дії лише над тим, що користувач БАЧИТЬ" (як у Finder).
    // v0.10.1 (перф-фікс, п.2/4): та сама дешева refiltered(), що showHidden вище — жодного
    // пересортування 50k елементів на КОЖЕН натиск клавіші (як робив старий
    // sortedEntries.filter(...) на кожен доступ).
    var filterText: String = "" {
        didSet {
            guard filterText != oldValue else { return }
            scheduleRefilter()
        }
    }

    // Вільне місце телефона (A2).
    var storageInfo: RemoteStorageInfo?
    // internal (не private): refreshStorageInfo/deviceWasExplicitlySelected/
    // devicesContextDidChange — BrowserStore+Navigation.swift.
    var lastStorageInfoAt: Date?
    static let storageInfoInterval: TimeInterval = 30

    // internal (не private): deviceWasExplicitlySelected/devicesContextDidChange —
    // BrowserStore+Navigation.swift.
    var lastKnownActiveSerial: String?
    /// v0.14.0: ключ обраного, під яким воно зараз завантажене (перечитати, коли ідентичність
    /// того самого serial щойно резолвилась: unauthorized → ready).
    var lastFavoritesKey: String?
    // @ObservationIgnored + nonisolated(unsafe): те саме обґрунтування, що й
    // DeviceStore.trackTask — deinit мусить скасувати Task синхронно, поза MainActor.
    // internal (не private): startPolling — BrowserStore+Navigation.swift; deinit лишається тут.
    @ObservationIgnored
    nonisolated(unsafe) var pollTask: Task<Void, Never>?

    /// 3.3: TransferCoordinator підключає тут `hasActiveTransfer` (TransferQueue.swift, в
    /// AppState.init) — щоб поллер листингу не турбував теку, доки в черзі активний саме
    /// transfer (НЕ push), точнісінько як стара умова одиночного `transfer == nil`.
    var isOperationActive: () -> Bool = { false }

    // 3.7: String(localized:) — SidebarView показує ці через Text(title) з ДИНАМІЧНОЮ
    // змінною (не літералом), тож самé Text не локалізувало б title автоматично.
    static let quickPlaces: [(title: String, path: String)] = [
        (String(localized: "Камера"), "/sdcard/DCIM"),
        (String(localized: "Завантаження"), "/sdcard/Download"),
        (String(localized: "Зображення"), "/sdcard/Pictures"),
        (String(localized: "Корінь"), "/sdcard"),
    ]

    init(deviceStore: DeviceStore) {
        self.deviceStore = deviceStore
    }

    deinit {
        pollTask?.cancel()
        refilterTask?.cancel()
    }

    // MARK: - Похідний стан (v0.10.1: закешовано в `index`, БЕЗ перерахунку на кожен доступ)

    // v0.10.1 (п.1-3/12-16): sortedEntries/filteredEntries БУЛИ computed без кешу — повне
    // сортування+фільтр на кожен доступ. Тепер — незмінний BrowserIndex (AndroidMoverCore/
    // BrowserIndex.swift), побудований РАЗ у scheduleIndexRebuild(), читаний як O(1)/O(|selection|).
    private(set) var index: BrowserIndex = .empty

    /// Дорога частина (повне пересортування) — планується лише коли `entries`/`sortOrder`
    /// РЕАЛЬНО змінились, не на кожен доступ до похідних властивостей. Виконується ПОЗА
    /// MainActor (`Task.detached`); `indexGeneration`-guard відкидає результат, якщо новіший
    /// rebuild уже стартував.
    ///
    /// Аудит-фікс (критично): filterText/showHidden БІЛЬШЕ НЕ капчуряться тут на момент
    /// планування — раніше build() ішов у Task.detached зі знімком `filter`/`hidden`,
    /// зробленим ЗАРАЗ, а `filterText`/`showHidden`'s didSet (нижче) тим часом синхронно
    /// оновлюють `index` НАПРЯМУ (`index.refiltered(...)`), без жодного зв'язку з
    /// `indexGeneration`. Якщо користувач набирав у пошуку, поки ця async-побудова ще
    /// летіла, її приземлення (MainActor.run) тихо ЗАТИРАЛО свіжий результат пошуку
    /// застарілим filterText/showHidden — generation-guard рятує лише від застарілих
    /// entries/sortOrder, не від showHidden/filterText. Тепер офф-main будуємо БЕЗ фільтра
    /// (сортування — єдина дорога частина), а на MainActor, у момент приземлення, ЖИВІ
    /// (поточні) `self.filterText`/`self.showHidden` застосовуються через дешевий
    /// `refiltered(...)` — що б користувач не набрав, доки будувався сорт, саме це й піде у
    /// фінальний index.
    private func scheduleIndexRebuild() {
        indexGeneration += 1
        let generation = indexGeneration
        guard !entries.isEmpty else {
            // Швидкий шлях — не варто спавнити Task заради порожньої теки.
            index = .empty
            isIndexBuilding = false
            trimSelectionToVisible()
            return
        }
        isIndexBuilding = true
        let snapshot = entries
        let spec = currentSortSpec()
        // v0.12.1: важка побудова — у Task.detached ЛИШЕ над Sendable-значеннями (snapshot, spec),
        // а `self` читається вже в MainActor-задачі після await. Попередній варіант (weak self
        // усередині detached + MainActor.run) Swift 6.1 (CI, macos-15) відкидав як «sending
        // 'self' risks causing data races»; Swift 6.3 приймав. Поведінка та сама: сорт поза main,
        // приземлення на main із ЖИВИМИ filterText/showHidden і generation-guard.
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                BrowserIndex.build(entries: snapshot, sortSpec: spec, filterText: "", showHidden: true)
            }.value
            guard let self, generation == self.indexGeneration else { return }
            self.index = built.refiltered(filterText: self.filterText, showHidden: self.showHidden)
            self.isIndexBuilding = false
            self.trimSelectionToVisible()
        }
    }

    /// Аудит-фікс (medium): дешевий шлях (filterText/showHidden) — БЕЗ пересорту, лише
    /// повторна фільтрація вже відсортованого `index`, тому не потребує повного
    /// `Task.detached` з нуля щоразу, ЛИШЕ офф-main ICU-прохід (`RemoteEntry.matches` →
    /// `localizedCaseInsensitiveContains`, свідомо ICU-коректний заради кирилиці — див.
    /// BrowserIndex.swift). Guard на приземленні перевіряє ОБИДВІ генерації:
    /// `filterGeneration` (відкидає застарілий keystroke, якщо новіший уже стартував) і
    /// `indexGeneration`+`isIndexBuilding` (відкидає результат, порахований проти ЗАСТАРІЛОГО
    /// `index` — знімок тут узятий ДО того, як паралельний scheduleIndexRebuild() приземлив
    /// новіший; той рано чи пізно сам застосує ЖИВИЙ filterText/showHidden, тож застосовувати
    /// тут — саме затирання, від якого вже рятує finding №1).
    private func scheduleRefilter() {
        filterGeneration += 1
        let generation = filterGeneration
        let baseIndexGeneration = indexGeneration
        let baseIndex = index
        let filter = filterText
        let hidden = showHidden
        refilterTask?.cancel()
        // v0.12.1: той самий переносимий шаблон, що в scheduleIndexRebuild (Swift 6.1 на CI).
        // Скасування зовнішньої задачі перевіряється до старту і після приземлення; сам
        // ICU-прохід у detached-задачі не переривається (для одного keystroke це дешево).
        refilterTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let refiltered = await Task.detached(priority: .userInitiated) {
                baseIndex.refiltered(filterText: filter, showHidden: hidden)
            }.value
            guard !Task.isCancelled, let self,
                  generation == self.filterGeneration,
                  baseIndexGeneration == self.indexGeneration,
                  !self.isIndexBuilding
            else { return }
            self.index = refiltered
            self.trimSelectionToVisible()
        }
    }

    /// `KeyPathComparator<RemoteEntry>` → `BrowserIndex.SortSpec` (чистий тип без SwiftUI,
    /// який бачить AndroidMoverCore). Той самий свіч, що `sortFieldName(_:)` нижче.
    private func currentSortSpec() -> BrowserIndex.SortSpec {
        guard let first = sortOrder.first else { return .init(field: .name, ascending: true) }
        let ascending = first.order == .forward
        switch first.keyPath {
        case \RemoteEntry.size: return .init(field: .size, ascending: ascending)
        case \RemoteEntry.modified: return .init(field: .modified, ascending: ascending)
        default: return .init(field: .name, ascending: ascending)
        }
    }

    /// 3.5: приховані файли ("." на початку імені) — лише якщо `showHidden == false`;
    /// `.androidmover-tmp-*` ховається ЗАВЖДИ. Фільтр по імені (A1) поверх результату.
    /// O(1) — тонка forward-сумісність до `index.visibleEntries`, щоб BrowserView.swift/
    /// FileActions.swift не чіпати.
    var filteredEntries: [RemoteEntry] { index.visibleEntries }

    /// Аудит-фікс (п.4): перетин `selection` із видимими id — незалежний другий бар'єр від
    /// `trimSelectionToVisible()`. O(|selection|) — `index.visibleIDs` уже готовий Set.
    var visibleSelection: Set<String> {
        selection.intersection(index.visibleIDs)
    }

    /// Обрізає `selection` до видимого — з didSet showHidden/filterText і з
    /// scheduleIndexRebuild. Guard на `isSubset` — уникає зайвого reassign/re-render.
    private func trimSelectionToVisible() {
        if !selection.isSubset(of: index.visibleIDs) {
            // Присвоєння тут спрацьовує через `selection`'s didSet вище — саме воно й
            // оновить selectionSummary.
            selection = selection.intersection(index.visibleIDs)
        } else {
            // `index` міг змінитись (нове сортування/рефільтр) БЕЗ зміни самого selection
            // (той самий набір id усе ще видимий) — а RemoteEntry-дані за цими id (розмір,
            // дата) теоретично могли оновитись (напр. після refreshList). selection's didSet
            // тут не спрацює (набір id той самий), тож освіжаємо явно.
            refreshSelectionSummary()
        }
    }

    /// Аудит-фікс (п.4): приховане тумблером/фільтром ніколи не потрапляє у "Вибрано: N" чи в
    /// entries, які підуть у transfer. Фільтрує `index.visibleEntries` (лише видимі, не всі
    /// до 50k) — і, на відміну від `Set.compactMap`, зберігає порядок таким, яким його бачить
    /// користувач у таблиці (той порядок іде в TransferEngine і показується в TransferSheet).
    var selectedEntries: [RemoteEntry] {
        guard !selection.isEmpty else { return [] }
        return index.visibleEntries.filter { selection.contains($0.id) }
    }

    /// Аудит-фікс (high): БУВ computed property, що робив O(|visibleEntries|)-прохід
    /// (`selectedEntries`) на КОЖЕН доступ — а `bottomBar` (BrowserView.swift) читає його
    /// напряму в тілі `mainContent`, куди інлайновані pathBar/table/bottomBar РАЗОМ (одна
    /// `var body`), тож Observation інструментує залежності на рівні ВСЬОГО body: будь-яка
    /// незалежна зміна деінде в цьому дереві (previewLoadingName під час Quick Look,
    /// showDisconnectBanner, isLoading) інвалідовувала body і повторно ганяла цей O(n)
    /// фільтр, навіть коли ні selection, ні index не змінювались. Тепер — закешоване
    /// значення, що перераховується РАЗ через `refreshSelectionSummary()`, викликану лише
    /// коли selection (didSet вище) чи index (кінець trimSelectionToVisible) РЕАЛЬНО
    /// змінились — той самий патерн, що вже застосований до `pendingMoveCount`
    /// (TransferCoordinator.swift).
    private(set) var selectionSummary: String?

    private func refreshSelectionSummary() {
        let chosen = selectedEntries
        guard !chosen.isEmpty else {
            selectionSummary = nil
            return
        }
        let files = chosen.filter { !$0.isDirectory }
        let dirs = chosen.count - files.count
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        var parts: [String] = ["Вибрано: \(chosen.count)"]
        if bytes > 0 { parts.append(Format.bytes(bytes)) }
        if dirs > 0 { parts.append("тек: \(dirs)") }
        selectionSummary = parts.joined(separator: " · ")
    }
}
