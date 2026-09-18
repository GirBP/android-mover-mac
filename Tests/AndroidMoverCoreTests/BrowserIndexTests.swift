import Foundation
import XCTest
@testable import AndroidMoverCore

/// BrowserIndex — незмінний, побудований раз знімок відсортованої й відфільтрованої теки:
/// повний sort+filter на кожен доступ був би критичним багом на теках з десятками тисяч
/// файлів. Тут: коректність (теки зверху, натуральний сорт імен, приховані/tmp,
/// регістронезалежний пошук, стабільність сортування, узгодженість visibleIDs/byID) і
/// бенчмарк 50k елементів.
final class BrowserIndexTests: XCTestCase {

    private static let loneDate = Date(timeIntervalSince1970: 1_650_000_000)

    private func entry(
        _ name: String,
        isDirectory: Bool = false,
        size: Int64 = 100,
        modified: Date = loneDate
    ) -> RemoteEntry {
        RemoteEntry(
            path: "/sdcard/DCIM/\(name)", name: name, isDirectory: isDirectory,
            isSymlink: false, size: size, modified: modified
        )
    }

    // MARK: - Теки завжди зверху

    func testDirectoriesAlwaysFirstRegardlessOfSortField() {
        let entries = [
            entry("b.jpg", size: 500),
            entry("Альбом", isDirectory: true, size: 4096),
            entry("a.jpg", size: 900),
            entry("Заметки", isDirectory: true, size: 4096),
        ]
        // Сорт по .size, descending — теки все одно мусять бути першими, незалежно від
        // того, що їхній "розмір" (inode) менший/більший за файли.
        let spec = BrowserIndex.SortSpec(field: .size, ascending: false)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(index.visibleEntries.count, 4)
        XCTAssertTrue(index.visibleEntries[0].isDirectory)
        XCTAssertTrue(index.visibleEntries[1].isDirectory)
        XCTAssertFalse(index.visibleEntries[2].isDirectory)
        XCTAssertFalse(index.visibleEntries[3].isDirectory)
    }

    // MARK: - Натуральний (числовий) сорт імен

    func testNameNaturalSortOrdersNumericSuffixesNumerically() {
        let entries = [entry("IMG_10.jpg"), entry("IMG_2.jpg"), entry("IMG_1.jpg")].shuffled()
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(index.visibleEntries.map(\.name), ["IMG_1.jpg", "IMG_2.jpg", "IMG_10.jpg"],
                       "числовий порядок, не лексикографічний (IMG_1,IMG_10,IMG_2)")
    }

    func testNameNaturalSortDescending() {
        let entries = [entry("IMG_1.jpg"), entry("IMG_2.jpg"), entry("IMG_10.jpg")]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: false)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(index.visibleEntries.map(\.name), ["IMG_10.jpg", "IMG_2.jpg", "IMG_1.jpg"])
    }

    // MARK: - Українська колація — Ґ/Є/І/Ї на алфавітних місцях

    /// Регресійний тест: порівняння нецифрових символів сирим Unicode code point-ом кидає
    /// Ґ/Є/І/Ї (U+0490/0404/0406/0407, поза основним кириличним блоком U+0430-044F) у кінець
    /// списку замість їхніх алфавітних місць. Очікуваний порядок нижче звірено з реальним
    /// ICU-порівнянням (`String.compare(locale: "uk")`), а не переписаний "на око".
    func testNameNaturalSortOrdersUkrainianCyrillicByAlphabetNotCodePoint() {
        let words = ["Айстри", "Груша", "Ґудзик", "Дерево", "Європа", "Жито", "Зима", "Их", "Їжак", "Йога", "Індія"]
        let entries = words.shuffled().map { entry($0) }
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)

        let expected = words.sorted {
            $0.compare($1, options: [], range: nil, locale: Locale(identifier: "uk")) == .orderedAscending
        }
        XCTAssertEqual(index.visibleEntries.map(\.name), expected,
                       "порядок мусить збігатись із реальним ICU-порівнянням локалі uk, не з сирим code point")
        // Конкретно: Ґ одразу після Г (не в кінці), Є/Ж/З/И/І/Ї — по порядку, не всі "и" разом.
        XCTAssertEqual(index.visibleEntries.map(\.name),
                       ["Айстри", "Груша", "Ґудзик", "Дерево", "Європа", "Жито", "Зима", "Их", "Індія", "Їжак", "Йога"])
    }

    /// Латинські літери з діакритикою (à, é…) мусять групуватись поряд із базовою літерою
    /// (тим самим порядком, що дає ICU), а не за сирим code point (де вони лежать в окремому
    /// Unicode-блоці After 'z').
    func testNameNaturalSortFoldsAccentedLatinNearBaseLetter() {
        let entries = [entry("banana.jpg"), entry("äpple.jpg"), entry("cherry.jpg")]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(index.visibleEntries.map(\.name), ["äpple.jpg", "banana.jpg", "cherry.jpg"],
                       "ä мусить лягти біля 'a' (перед banana), не в кінці за сирим code point (після z)")
    }

    // MARK: - Стабільність сортування (tie-break зберігає вхідний порядок)

    func testSortIsStableTieBreaksPreserveInputOrder() {
        let entries = [
            entry("одинаковий-1", size: 500),
            entry("одинаковий-2", size: 500),
            entry("одинаковий-3", size: 500),
        ]
        let spec = BrowserIndex.SortSpec(field: .size, ascending: true)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(index.visibleEntries.map(\.name), entries.map(\.name),
                       "однаковий size — відносний порядок мусить лишитись, як у вхідному масиві")
    }

    // MARK: - .androidmover-tmp-* завжди приховані

    func testAndroidMoverTmpAlwaysHiddenRegardlessOfShowHidden() {
        let entries = [entry(".androidmover-tmp-abc123", isDirectory: true), entry("normal.jpg")]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let hiddenOff = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: false)
        let hiddenOn = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertFalse(hiddenOff.visibleEntries.contains { $0.name.hasPrefix(".androidmover-tmp-") })
        XCTAssertFalse(hiddenOn.visibleEntries.contains { $0.name.hasPrefix(".androidmover-tmp-") })
        XCTAssertEqual(hiddenOff.visibleEntries.count, 1)
        XCTAssertEqual(hiddenOn.visibleEntries.count, 1)
    }

    // MARK: - Приховані файли керуються showHidden

    func testDotFilesHiddenUnlessShowHidden() {
        let entries = [entry(".foo"), entry("bar.jpg")]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let hiddenOff = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: false)
        XCTAssertEqual(hiddenOff.visibleEntries.map(\.name), ["bar.jpg"])
        let hiddenOn = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(Set(hiddenOn.visibleEntries.map(\.name)), [".foo", "bar.jpg"])
    }

    // MARK: - Пошук — регістронезалежний, підрядок, кирилиця

    func testFilterTextUsesLocalizedCaseInsensitiveMatch() {
        let entries = [entry("Фото Відпустки.jpg"), entry("Документ.pdf")]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "відпуст", showHidden: true)
        XCTAssertEqual(index.visibleEntries.map(\.name), ["Фото Відпустки.jpg"])
    }

    // MARK: - refiltered ніколи не пересортовує

    func testRefilteredNeverResorts() {
        let entries = [entry("c.jpg", size: 300), entry("a.jpg", size: 100), entry("b.jpg", size: 200)]
        let spec = BrowserIndex.SortSpec(field: .size, ascending: true)
        let built = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(built.visibleEntries.map(\.name), ["a.jpg", "b.jpg", "c.jpg"])

        // Кілька рефільтрацій з різним filterText/showHidden — відносний порядок серед
        // елементів, що лишились видимими, усі рази строго відповідає порядку build() (за
        // size, не за назвою — якби refiltered пересортовувала, "b" опинилась би перед "c"
        // за size, але порядок за назвою збігається тут випадково, тож перевіряємо явно
        // через .jpg-набір, де size-порядок ("a","c") відрізнявся б від name-порядку).
        let refiltered = built.refiltered(filterText: "", showHidden: false)
        XCTAssertEqual(refiltered.visibleEntries.map(\.name), ["a.jpg", "b.jpg", "c.jpg"])

        let acEntries = [entry("c.jpg", size: 100), entry("a.jpg", size: 300)]
        let acBuilt = BrowserIndex.build(entries: acEntries, sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(acBuilt.visibleEntries.map(\.name), ["c.jpg", "a.jpg"], "за size: c(100) < a(300)")
        let acRefiltered = acBuilt.refiltered(filterText: "", showHidden: true)
        XCTAssertEqual(acRefiltered.visibleEntries.map(\.name), ["c.jpg", "a.jpg"],
                       "refiltered НЕ пересортовує назад до алфавітного порядку")
    }

    // MARK: - build()'s filterText/showHidden — лише знімок, фінальний видимий результат
    // визначає останній refiltered(), не аргументи build()

    /// Захищає інваріант, на якому тримається BrowserStore.scheduleIndexRebuild: `build()`
    /// сортує з порожнім фільтром, а на приземленні `Task.detached` застосовує живий
    /// filterText/showHidden через `refiltered(...)` — захоплення filterText/showHidden на
    /// момент планування тихо затирало б новіший результат пошуку. Тест звіряє:
    /// `build(filterText:hidden:)` з будь-якими аргументами, а потім `.refiltered(...)` з
    /// іншими, дає той самий результат, що прямий `build()` з тими самими фінальними
    /// аргументами — тобто аргументи build() ніяк не "просочуються" у фінальний видимий стан
    /// повз refiltered().
    func testRefilteredResultIsIndependentOfBuildTimeFilterArguments() {
        let entries = [
            entry("Фото Відпустки.jpg"), entry("Документ.pdf"), entry(".hidden.jpg"),
            entry("IMG_2.jpg"), entry("IMG_10.jpg"),
        ]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)

        // Знімок побудований із "неправильними" (застарілими) filterText/showHidden —
        // імітує те, що якийсь давній keystroke міг захопити на момент планування.
        let staleBuilt = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "документ", showHidden: false)
        let appliedLive = staleBuilt.refiltered(filterText: "відпуст", showHidden: true)

        // Прямий build() одразу з фінальними (живими) аргументами.
        let directBuilt = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "відпуст", showHidden: true)

        XCTAssertEqual(appliedLive.visibleEntries.map(\.name), directBuilt.visibleEntries.map(\.name))
        XCTAssertEqual(appliedLive.visibleIDs, directBuilt.visibleIDs)
        XCTAssertEqual(appliedLive.visibleEntries.map(\.name), ["Фото Відпустки.jpg"])
    }

    // MARK: - visibleIDs/byID узгоджені з visibleEntries

    func testVisibleIDsAndByIDConsistentWithVisibleEntries() {
        let entries = (0..<50).map { entry("файл-\($0).bin", size: Int64.random(in: 1...1000)) }
            + [entry(".hidden-\(0)"), entry(".androidmover-tmp-x", isDirectory: true)]
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let index = BrowserIndex.build(entries: entries.shuffled(), sortSpec: spec, filterText: "", showHidden: true)
        XCTAssertEqual(index.visibleIDs, Set(index.visibleEntries.map(\.id)))
        XCTAssertEqual(index.byID.count, index.visibleEntries.count)
        for e in index.visibleEntries {
            XCTAssertEqual(index.byID[e.id], e)
        }
    }

    // MARK: - Порожній індекс

    func testEmptyIndexHasEmptyFields() {
        let index = BrowserIndex.empty
        XCTAssertTrue(index.visibleEntries.isEmpty)
        XCTAssertTrue(index.visibleIDs.isEmpty)
        XCTAssertTrue(index.byID.isEmpty)
    }

    // MARK: - Бенчмарк 50k елементів

    /// ~5% тек, решта "IMG_<i>.jpg", розміри/дати випадкові, .shuffled() на виході — щоб не
    /// тестувати "вже відсортований вхід" (найлегший випадок для sort).
    private func makeSyntheticEntries(count: Int) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        entries.reserveCapacity(count)
        let dirCount = count / 20
        for i in 0..<count {
            let isDir = i < dirCount
            let name = isDir ? "Album \(i)" : "IMG_\(i).jpg"
            entries.append(RemoteEntry(
                path: "/sdcard/DCIM/Camera/\(name)", name: name, isDirectory: isDir, isSymlink: false,
                size: Int64.random(in: 1_000...20_000_000),
                modified: Date(timeIntervalSince1970: 1_600_000_000 + Double(i))
            ))
        }
        return entries.shuffled()
    }

    /// Ціль: < 150 мс на M-серії (RELEASE) — виміряно фактично ~122-129 мс (`swift test -c
    /// release`, Apple M2, 5 прогонів); `characterWeights` (колація Ґ/Є/І/Ї/діакритики,
    /// BrowserIndex.swift) додає dictionary-lookup на кожен нецифровий символ під час
    /// генерації ключа, тому й лишається помітний запас до межі. `swift test` за
    /// замовчуванням — DEBUG build (без оптимізацій, виміряно ~309-318 мс, 5 прогонів), тож
    /// ліміт тут м'якший; фактичний час логується в XCTAssert-повідомленні незалежно від
    /// результату.
    func testBuildPerformanceOn50kEntries() {
        let entries = makeSyntheticEntries(count: 50_000)
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let start = Date()
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: false)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(index.visibleEntries.count, 50_000)
        // 1.0 с — під паралельною збіркою/іншими тестами DEBUG-прогін флейкає на меншому
        // порозі, тож 1 с лишається жорсткою межею.
        XCTAssertLessThanOrEqual(elapsed, 1.0, "побудова індексу на 50k мала вкластись у розумний час (\(elapsed) с, DEBUG build)")
    }

    /// Ціль: < 30 мс на M-серії (RELEASE) — виміряно фактично ~56-57 мс (`swift test -c
    /// release`, 5 прогонів; трохи вище цілі: `localizedCaseInsensitiveContains` — ICU-порівняння
    /// з підтримкою кирилиці, свідомо не замінене на дешевший ASCII-only fast-path, щоб не
    /// зламати коректний пошук по кирилиці, testFilterTextUsesLocalizedCaseInsensitiveMatch).
    /// Лінійний прохід (без сортування) — набагато дешевший за build(). `BrowserStore.
    /// scheduleRefilter()` кличе цю функцію офф-main (`Task.detached`, з generation-guard —
    /// BrowserStore.swift), тож ці ~56 мс не блокують MainActor на кожен keystroke — число тут
    /// лишається як цільовий бенчмарк самої (чистої) роботи.
    func testRefilterPerformanceOn50kEntries() {
        let entries = makeSyntheticEntries(count: 50_000)
        let spec = BrowserIndex.SortSpec(field: .name, ascending: true)
        let index = BrowserIndex.build(entries: entries, sortSpec: spec, filterText: "", showHidden: false)
        let start = Date()
        // "IMG_<i>.jpg" — підкреслення між "img" і цифрою, тож запит мусить мати той самий
        // підкреслення, щоб localizedCaseInsensitiveContains знайшов збіги.
        let refiltered = index.refiltered(filterText: "img_5", showHidden: true)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(refiltered.visibleEntries.isEmpty)
        XCTAssertLessThanOrEqual(elapsed, 0.3, "рефільтрація на 50k мала вкластись у розумний час (\(elapsed) с, DEBUG build)")
    }
}
