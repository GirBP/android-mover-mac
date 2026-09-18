import Foundation

/// Поле сортування таблиці браузера — компактний, не-SwiftUI еквівалент
/// `KeyPathComparator<RemoteEntry>.keyPath`. BrowserStore (Sources/AndroidMover/State/) сам
/// мапить одне в інше; BrowserIndex і решта AndroidMoverCore НІКОЛИ не бачать
/// KeyPathComparator/SwiftUI (той таргет без залежностей UI, лише Foundation).
public enum BrowserSortField: Sendable, Equatable {
    case name, size, modified
}

extension BrowserIndex {
    public struct SortSpec: Sendable, Equatable {
        public var field: BrowserSortField
        public var ascending: Bool
        public init(field: BrowserSortField, ascending: Bool) {
            self.field = field
            self.ascending = ascending
        }
    }
}

/// Незмінний знімок "теки телефона, готової до показу": відсортовані+відфільтровані записи,
/// побудовані РАЗ (`build`), а не при кожному читанні. Вирішує проблему
/// `BrowserStore.sortedEntries`/`filteredEntries` (computed properties, що робили
/// `entries.sorted(using:)` + 2-4 проходи `filter` на КОЖЕН доступ — ForEach таблиці, overlay,
/// selectionSummary, canTransfer, AppCommands `.disabled` при кожній валідації меню, кожен
/// `didSet filterText`).
///
/// `Sendable` — усі поля Sendable-значеннєві типи (`RemoteEntry` сам `Sendable`), тож `build()`
/// можна кликати з БУДЬ-ЯКОГО потоку/актора, зокрема `Task.detached`.
public struct BrowserIndex: Sendable {
    /// Усі entries у порядку сортування, БЕЗ фільтра — приватно: єдиний спосіб зробити
    /// `refiltered(_:_:)` дешевим (без пересортування), не даючи зовнішньому коду плутати
    /// "усі відсортовані" з "видимі".
    private let sorted: [RemoteEntry]

    /// Те, що йде у ForEach таблиці — вже відсортовано (теки зверху) і відфільтровано
    /// (tmp-префікс завжди, showHidden, filterText).
    public let visibleEntries: [RemoteEntry]
    /// id усіх visibleEntries — O(1) membership (visibleSelection, requestDelete) замість
    /// `Set(filteredEntries.map(\.id))` на кожен виклик.
    public let visibleIDs: Set<String>
    /// O(1) доступ за id (selectedEntries, deleteTargets, openIfSingleDirectory,
    /// handleDoubleClick, контекстне меню, Space) замість `entries.first(where:)`/`filter`.
    public let byID: [String: RemoteEntry]

    public static let empty = BrowserIndex(sorted: [], visibleEntries: [], visibleIDs: [], byID: [:])

    /// Приватний — `build()`/`refiltered(_:_:)` єдині конструктори, гарантують, що
    /// visibleIDs/byID завжди узгоджені з visibleEntries (інваріант, не перевірка).
    private init(sorted: [RemoteEntry], visibleEntries: [RemoteEntry], visibleIDs: Set<String>, byID: [String: RemoteEntry]) {
        self.sorted = sorted
        self.visibleEntries = visibleEntries
        self.visibleIDs = visibleIDs
        self.byID = byID
    }

    /// Дорога частина (сортування) — кличеться ЛИШЕ коли entries/sortOrder реально змінились.
    /// Чиста функція, без побічних ефектів — безпечна для `Task.detached`
    /// (`BrowserStore.scheduleIndexRebuild`).
    public static func build(entries: [RemoteEntry], sortSpec: SortSpec, filterText: String, showHidden: Bool) -> BrowserIndex {
        let sorted = sortedEntries(entries, spec: sortSpec)
        return filtering(sorted: sorted, filterText: filterText, showHidden: showHidden)
    }

    /// Дешева перефільтрація (лінійний прохід, БЕЗ пересортування) — той самий `sorted`,
    /// новий filterText/showHidden. Синхронна, безпечна для виклику на MainActor при
    /// кожній зміні filterText/showHidden (бенчмарк: <30мс навіть на 50k).
    public func refiltered(filterText: String, showHidden: Bool) -> BrowserIndex {
        Self.filtering(sorted: sorted, filterText: filterText, showHidden: showHidden)
    }

    private static func filtering(sorted: [RemoteEntry], filterText: String, showHidden: Bool) -> BrowserIndex {
        var ids = Set<String>(minimumCapacity: sorted.count)
        var map = [String: RemoteEntry](minimumCapacity: sorted.count)
        var visible: [RemoteEntry] = []
        visible.reserveCapacity(sorted.count)
        let query = filterText.isEmpty ? nil : filterText
        for entry in sorted {
            if entry.name.hasPrefix(".androidmover-tmp-") { continue }   // ЗАВЖДИ, як і сьогодні
            if !showHidden, entry.name.hasPrefix(".") { continue }
            if let query, !entry.matches(query: query) { continue }       // RemoteEntry.matches, Models.swift
            visible.append(entry)
            ids.insert(entry.id)
            map[entry.id] = entry
        }
        return BrowserIndex(sorted: sorted, visibleEntries: visible, visibleIDs: ids, byID: map)
    }

    /// Стабільний сорт (`Array.sorted(by:)` гарантовано стабільний з Swift 5) із "теки завжди
    /// зверху" як первинним ключем — той самий результат, що старе
    /// `entries.sorted(using: sortOrder)`, потім `.filter(\.isDirectory) + .filter { !$0.isDirectory }`
    /// (filter зберігає відносний порядок, тож розбиття після повного сорту == сортування з
    /// isDirectory як первинним ключем).
    ///
    /// Навмисне ПОКРАЩЕННЯ видимої поведінки для поля `.name`: натуральний (числовий) порядок
    /// "IMG_2.jpg" < "IMG_10.jpg" замість лексикографічного String `<`, яким сортувало старе
    /// KeyPathComparator(\.name) — той самий видимий ефект, що дає `localizedStandardCompare`,
    /// але БЕЗ ICU-порівняння в гарячому компараторі (рахувалось би на кожне порівняння під
    /// час sort — O(n log n) ICU-викликів; тут — один розбір ключа на елемент, порівняння
    /// далі — плоский String `<`, naturalSortKey(_:) нижче).
    ///
    /// Аудит-фікс (severity: high): перша версія кодувала нецифрові символи СИРИМ Unicode
    /// code point-ом — це ламало колацію для кирилиці й діакритики: українські Ґ/Є/І/Ї
    /// (U+0490/0404/0406/0407) лежать поза основним кириличним блоком (U+0430-044F) і при
    /// порівнянні "як є" стрибали в кінець замість своїх алфавітних місць (Ґудзик — в кінець
    /// списку, Європа/Індія/Їжак — після всього а-я); латинські літери з діакритикою (à, é…)
    /// так само не групувались із базовою літерою. Виправлено через `characterWeights` —
    /// ICU-коректний ранг символу, обчислений РАЗ (лениво, на маленькому фіксованому
    /// алфавіті), а не через ICU-порівняння на кожне з O(n log n) порівнянь під час сорту.
    ///
    /// Сортує ІНДЕКСИ, не самі `RemoteEntry` — той має 2 String-поля (path/name), тож фізичні
    /// свопи повних структур під час `Array.sorted` (introsort свопає елементи на кожен крок
    /// партиціонування) тягнуть ARC retain/release на КОЖЕН своп, а не лише на порівняння.
    /// Масив `Int` свопається без жодного ARC; фінальний permutation-гатер (`entries[$0]`)
    /// копіює кожен елемент РІВНО ОДИН РАЗ. Вимірювано (M2): у DEBUG-збірці (`swift test`,
    /// без оптимізацій) — у ~3× швидше, ніж decorate-sort-undecorate повних структур
    /// (BrowserIndexTests.testBuildPerformanceOn50kEntries).
    private static func sortedEntries(_ entries: [RemoteEntry], spec: SortSpec) -> [RemoteEntry] {
        guard entries.count > 1 else { return entries }
        let isDir = entries.map(\.isDirectory)
        var order = Array(entries.indices)
        switch spec.field {
        case .name:
            let keys = entries.map { naturalSortKey($0.name) }
            order.sort { i, j in
                if isDir[i] != isDir[j] { return isDir[i] }
                return spec.ascending ? keys[i] < keys[j] : keys[i] > keys[j]
            }
        case .size:
            let sizes = entries.map(\.size)
            order.sort { i, j in
                if isDir[i] != isDir[j] { return isDir[i] }
                return spec.ascending ? sizes[i] < sizes[j] : sizes[i] > sizes[j]
            }
        case .modified:
            let mtimes = entries.map(\.modified)
            order.sort { i, j in
                if isDir[i] != isDir[j] { return isDir[i] }
                return spec.ascending ? mtimes[i] < mtimes[j] : mtimes[i] > mtimes[j]
            }
        }
        return order.map { entries[$0] }
    }

    // MARK: - Природний ключ сортування імені (обчислюється РАЗ на елемент, не в компараторі)

    /// Ширина, до якої padить кожен цифровий забіг нулями зліва — 20 символів вкладає навіть
    /// `Int64.max` (19 цифр) із запасом; довші забіги (на практиці не трапляються в іменах
    /// файлів) лишаються НЕ обрізаними — порівняння між собою лишається коректним (однаково
    /// довші, тож перше розходження все одно вирішує), просто без гарантії проти більш
    /// коротких, вже НЕ-padded цифр деінде, що на практиці для імен файлів не трапляється.
    private static let digitPadWidth = 20

    /// Ширина, до якої падиться нулями закодована "вага" нецифрового символу (нижче) —
    /// 7 знаків вкладає й ранг у `characterWeights` (сотні), і fallback-гілку
    /// `10000 + unicodeScalar.value` (Unicode-скаляр максимум 0x10FFFF ≈ 1 114 111, разом з
    /// офсетом — до ~1 124 111, 7 цифр вистачає із запасом).
    private static let charWeightWidth = 7

    /// ICU-коректний ранг символу для колації — обчислюється РАЗ (лениво, статично), а не
    /// на кожне з O(n log n) порівнянь під час сорту: алфавіт тут МАЛЕНЬКИЙ (літери
    /// латиниці+діакритики й української кирилиці, ~90 символів), тож один прохід
    /// `String.compare(locale:)` по ньому — на відміну від виклику ICU на кожне порівняння
    /// імен файлів (виміряно: ~260мс/RELEASE на 50k імен проти ~90-110мс тут) — практично
    /// безкоштовний. Локаль ЯВНО "uk" (не `Locale.current`) — застосунок україномовний
    /// (`defaultLocalization: "uk"`, Package.swift), і сортування не повинно залежати від
    /// системної локалі користувача Mac (яка може бути en-US і з українськими іменами
    /// файлів).
    private static let characterWeights: [Character: Int] = {
        let alphabet: [Character] = Array(Set(
            "abcdefghijklmnopqrstuvwxyz"
            + "àáâãäåāăąæçćĉċčďđèéêëēĕėęěĝğġģĥħìíîïĩīĭįıĵķĺļľŀłñńņňòóôõöøōŏőœŕŗřśŝşšţťŧùúûüũūŭůűųŵýÿŷźżž"
            + "абвгґдеєжзийіїклмнопрстуфхцчшщъыьэюя"
        ))
        let sorted = alphabet.sorted { lhs, rhs in
            String(lhs).compare(String(rhs), options: [], range: nil, locale: Locale(identifier: "uk")) == .orderedAscending
        }
        var weights: [Character: Int] = [:]
        weights.reserveCapacity(sorted.count)
        for (rank, ch) in sorted.enumerated() { weights[ch] = rank }
        return weights
    }()

    /// Перетворює ім'я на один ключ-`String`, де кожен забіг цифр замінено на
    /// нуль-доповнений до `digitPadWidth` (числовий порядок "IMG_2.jpg" < "IMG_10.jpg"), а
    /// кожен нецифровий символ — на нуль-доповнену `characterWeights`-вагу (ICU-коректний
    /// алфавітний порядок замість сирого code point). Звичайне лексикографічне порівняння
    /// `String <` результату відтак дає І числовий, І локаль-коректний порядок. Швидше за
    /// токенізацію в `[NameToken]`-масив з enum-компаратором — один розбір рядка на елемент,
    /// далі — нативне порівняння String (без ICU у самому порівнянні).
    private static func naturalSortKey(_ name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count + 8)
        var digits = ""
        func flushDigits() {
            guard !digits.isEmpty else { return }
            if digits.count < digitPadWidth {
                result += String(repeating: "0", count: digitPadWidth - digits.count)
            }
            result += digits
            digits = ""
        }
        for ch in name.lowercased() {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
            } else {
                flushDigits()
                let weight = characterWeights[ch] ?? (10_000 + Int(ch.unicodeScalars.first?.value ?? 0))
                let encoded = String(weight)
                result += String(repeating: "0", count: max(0, charWeightWidth - encoded.count))
                result += encoded
            }
        }
        flushDigits()
        return result
    }
}
