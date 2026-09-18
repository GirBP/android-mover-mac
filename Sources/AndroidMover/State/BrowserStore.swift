import Foundation
import Observation
import AndroidMoverCore

/// Керує навігацією, лістингом, сортуванням і фільтром, вільним місцем на пристрої.
/// Тримає сильне однонапрямне посилання на DeviceStore, щоб читати client/activeDevice;
/// про пристрій не питає сам — DeviceStore сигналізує через deviceWasExplicitlySelected()/
/// devicesContextDidChange(), а не власним `adb devices`.
@MainActor
@Observable
final class BrowserStore {
    let deviceStore: DeviceStore

    var currentPath = "/sdcard"
    var pathField = "/sdcard"
    // Виділення завжди обмежується видимим після кожної зміни entries. didSet планує
    // перебудову `index` (scheduleIndexRebuild нижче) замість перерахунку похідних
    // властивостей на кожен доступ; сама перебудова й обрізає selection наприкінці.
    var entries: [RemoteEntry] = [] {
        didSet { scheduleIndexRebuild() }
    }
    var isLoading = false
    var listError: String?
    // didSet оновлює закешований `selectionSummary` (нижче) лише на реальну зміну
    // виділення — не при кожному читанні з bottomBar.
    var selection = Set<String>() {
        didSet {
            guard selection != oldValue else { return }
            refreshSelectionSummary()
        }
    }
    // Сортування переживає перезапуск — персиститься в UserDefaults як пара (поле,
    // зростання), бо KeyPathComparator сам по собі не Codable. Дефолт відновлює
    // збережене на момент конструювання (BrowserStore.loadSortOrder(), MARK: -
    // Персистенція). didSet планує перебудову index.
    var sortOrder: [KeyPathComparator<RemoteEntry>] = BrowserStore.loadSortOrder() {
        didSet {
            BrowserStore.persistSortOrder(sortOrder)
            scheduleIndexRebuild()
        }
    }
    // Тумблер прихованих файлів (типово вимкнено); `.androidmover-tmp-*` ховається
    // завжди, незалежно від прапорця. showHidden не змінює порядок — лише дешева
    // refiltered() без пересортування. Фільтрація завжди йде поза main
    // (scheduleRefilter()): синхронний виклик на кожен натиск клавіші блокує потік —
    // ICU-прохід (`localizedCaseInsensitiveContains` на елемент, до 50k) займає
    // ~55-60 мс і в DEBUG, і в RELEASE, тобто губить 3+ кадри на keystroke.
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
    // Генерація перебудови index: Task.detached (scheduleIndexRebuild) може стартувати
    // на застарілому знімку entries; MainActor.run звіряє це значення і відкидає
    // застарілий build, якщо стартувала новіша.
    private var indexGeneration = 0
    // true від моменту, коли scheduleIndexRebuild() запускає асинхронну побудову
    // (Task.detached), і до приземлення MainActor.run. BrowserView гейтить спінер і на
    // це, не лише на isLoading (BrowserView.swift, overlay) — інакше є вікно (~80-300 мс
    // на 50k), де entries/isLoading вже вказують на нову теку, а `index` (і похідні
    // filteredEntries/selectedEntries/byID, куди йдуть клік і Cmd+A) ще старий: таблиця
    // показує вміст старої теки або хибне «Нічого не знайдено» на непорожній.
    private(set) var isIndexBuilding = false
    // Генерація scheduleRefilter() — той самий патерн «останній старт виграє», що
    // indexGeneration вище, але для дешевшого шляху filterText/showHidden без повного
    // пересорту.
    private var filterGeneration = 0
    @ObservationIgnored
    private nonisolated(unsafe) var refilterTask: Task<Void, Never>?

    // Обране на телефоні — теки, додані користувачем для активного пристрою. У пам'яті
    // тримається лише список поточного serial (перезавантажується при зміні пристрою,
    // нижче); персиститься per-serial у UserDefaults, щоб не змішувати обране різних
    // телефонів.
    var favorites: [String] = []

    // Sweep сиріт (.androidmover-tmp-*) на телефоні — раз на serial|path за сесію.
    // internal (не private): sweepRemoteOrphansIfNeeded — BrowserStore+Navigation.swift.
    var sweptRemoteKeys = Set<String>()

    // Пошук/фільтр по імені в поточній теці. Приховане фільтром знімається з
    // виділення — інваріант «деструктивні дії лише над тим, що користувач бачить» (як у
    // Finder). Та сама дешева refiltered(), що showHidden вище — без пересортування 50k
    // елементів на кожен натиск клавіші.
    var filterText: String = "" {
        didSet {
            guard filterText != oldValue else { return }
            scheduleRefilter()
        }
    }

    // Вільне місце телефона.
    var storageInfo: RemoteStorageInfo?
    // internal (не private): refreshStorageInfo/deviceWasExplicitlySelected/
    // devicesContextDidChange — BrowserStore+Navigation.swift.
    var lastStorageInfoAt: Date?
    static let storageInfoInterval: TimeInterval = 30

    // internal (не private): deviceWasExplicitlySelected/devicesContextDidChange —
    // BrowserStore+Navigation.swift.
    var lastKnownActiveSerial: String?
    /// Ключ обраного, під яким воно зараз завантажене — перечитати, коли ідентичність
    /// того самого serial щойно резолвилась: unauthorized → ready.
    var lastFavoritesKey: String?
    // @ObservationIgnored + nonisolated(unsafe): те саме обґрунтування, що й
    // DeviceStore.trackTask — deinit мусить скасувати Task синхронно, поза MainActor.
    // internal (не private): startPolling — BrowserStore+Navigation.swift; deinit лишається тут.
    @ObservationIgnored
    nonisolated(unsafe) var pollTask: Task<Void, Never>?

    /// TransferCoordinator підключає тут `hasActiveTransfer` (TransferQueue.swift, в
    /// AppState.init), щоб поллер листингу не турбував теку, доки в черзі активний саме
    /// transfer, а не push.
    var isOperationActive: () -> Bool = { false }

    // String(localized:): SidebarView показує ці через Text(title) з динамічною
    // змінною, не літералом, тож саме Text не локалізувало б title автоматично.
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

    // MARK: - Похідний стан (закешовано в `index`, без перерахунку на кожен доступ)

    // sortedEntries/filteredEntries спираються на незмінний BrowserIndex
    // (AndroidMoverCore/BrowserIndex.swift), побудований раз у scheduleIndexRebuild() і
    // читаний як O(1)/O(|selection|) — уникає повного сортування й фільтра на кожен доступ.
    private(set) var index: BrowserIndex = .empty

    /// Дорога частина (повне пересортування) планується лише коли `entries`/`sortOrder`
    /// реально змінились, не на кожен доступ до похідних властивостей. Виконується поза
    /// MainActor (`Task.detached`); `indexGeneration`-guard відкидає результат, якщо
    /// новіший rebuild уже стартував.
    ///
    /// filterText/showHidden не захоплюються на момент планування: build() будує
    /// офф-main без фільтра (сортування — єдина дорога частина), а
    /// `self.filterText`/`self.showHidden` застосовуються через дешевий
    /// `refiltered(...)` на MainActor у момент приземлення. Якщо capture'нути фільтр
    /// заздалегідь, а didSet тим часом синхронно оновлює `index` напряму через
    /// `index.refiltered(...)` без зв'язку з `indexGeneration`, приземлення
    /// async-побудови тихо затирає свіжий результат пошуку застарілим значенням —
    /// generation-guard рятує лише від застарілих entries/sortOrder, не від
    /// showHidden/filterText. Застосування живих значень на приземленні усуває це
    /// вікно: що б користувач не набрав, доки тривало сортування, саме це піде у
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
        // Важка побудова йде в Task.detached лише над Sendable-значеннями (snapshot,
        // spec), а `self` читається в MainActor-задачі після await: варіант з weak self
        // усередині detached і MainActor.run компілятор Swift 6.1 (CI, macos-15)
        // відкидає як «sending 'self' risks causing data races», хоч Swift 6.3 його
        // приймає. Поведінка та сама: сорт поза main, приземлення на main із живими
        // filterText/showHidden і generation-guard.
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

    /// Дешевий шлях (filterText/showHidden) — без пересорту, лише повторна фільтрація
    /// вже відсортованого `index`, тому не потребує повного `Task.detached` з нуля
    /// щоразу, лише офф-main ICU-прохід (`RemoteEntry.matches` →
    /// `localizedCaseInsensitiveContains`, свідомо ICU-коректний заради кирилиці — див.
    /// BrowserIndex.swift). Guard на приземленні перевіряє обидві генерації:
    /// `filterGeneration` відкидає застарілий keystroke, якщо новіший уже стартував, а
    /// `indexGeneration`+`isIndexBuilding` відкидає результат, порахований проти
    /// застарілого `index` — знімок тут узятий до того, як паралельний
    /// scheduleIndexRebuild() приземлив новіший; той сам застосує живий
    /// filterText/showHidden, тож застосовувати тут означало б затерти його.
    private func scheduleRefilter() {
        filterGeneration += 1
        let generation = filterGeneration
        let baseIndexGeneration = indexGeneration
        let baseIndex = index
        let filter = filterText
        let hidden = showHidden
        refilterTask?.cancel()
        // Той самий переносимий шаблон, що в scheduleIndexRebuild (сумісний зі Swift
        // 6.1 на CI). Скасування зовнішньої задачі перевіряється до старту і після
        // приземлення; сам ICU-прохід у detached-задачі не переривається — для одного
        // keystroke це дешево.
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

    /// Приховані файли («.» на початку імені) — лише якщо `showHidden == false`;
    /// `.androidmover-tmp-*` ховається завжди. Фільтр по імені — поверх результату. O(1) —
    /// тонка обгортка над `index.visibleEntries`, щоб BrowserView.swift/FileActions.swift
    /// не чіпати.
    var filteredEntries: [RemoteEntry] { index.visibleEntries }

    /// Перетин `selection` із видимими id — незалежний другий бар'єр від
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
            // `index` міг змінитись (нове сортування/рефільтр) без зміни самого selection
            // (той самий набір id усе ще видимий) — а RemoteEntry-дані за цими id (розмір,
            // дата) теоретично могли оновитись (напр. після refreshList). selection's didSet
            // тут не спрацює (набір id той самий), тож освіжаємо явно.
            refreshSelectionSummary()
        }
    }

    /// Приховане тумблером чи фільтром ніколи не потрапляє у «Вибрано: N» чи в entries,
    /// які підуть у transfer. Фільтрує `index.visibleEntries` (лише видимі, не всі до
    /// 50k) — і, на відміну від `Set.compactMap`, зберігає порядок таким, яким його
    /// бачить користувач у таблиці (той порядок іде в TransferEngine і показується в
    /// TransferSheet).
    var selectedEntries: [RemoteEntry] {
        guard !selection.isEmpty else { return [] }
        return index.visibleEntries.filter { selection.contains($0.id) }
    }

    /// Закешоване значення — уникає O(|visibleEntries|)-проходу (`selectedEntries`) на
    /// кожен доступ. `bottomBar` (BrowserView.swift) читає його напряму в тілі
    /// `mainContent`, куди інлайновані pathBar/table/bottomBar разом (одна `var body`),
    /// тож Observation інструментує залежності на рівні всього body: будь-яка незалежна
    /// зміна деінде в цьому дереві (previewLoadingName під час Quick Look,
    /// showDisconnectBanner, isLoading) інвалідує body і без кешу повторно ганяла б цей
    /// O(n) фільтр, навіть коли ні selection, ні index не змінювались. Перераховується
    /// лише через `refreshSelectionSummary()`, викликану коли selection (didSet вище) чи
    /// index (кінець trimSelectionToVisible) реально змінились — той самий патерн, що в
    /// `pendingMoveCount` (TransferCoordinator.swift).
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
