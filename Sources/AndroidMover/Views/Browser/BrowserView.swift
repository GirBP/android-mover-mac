import SwiftUI
import QuickLook
import AndroidMoverCore

struct BrowserView: View {
    @Bindable var state: AppState
    @State var showingDestinationPicker = false
    // internal (не private): BrowserView+Toolbar.swift (окремий файл — інакше BrowserView.swift
    // ліз за 400-рядкову межу) читає й пише це в toolbarContent.
    @State var showingHistory = false
    @State var showingPushImporter = false
    // «Деталі…» на завершеному рядку OperationQueuePanel — TransferSheet/PushSheet
    // лишаються конкретно типізованими sheet-ами (не модальними), тому тримаємо два окремі
    // @State замість одного спільного посилання, спільного для transfer/push.
    @State private var detailsTransfer: TransferSession?
    @State private var detailsPush: PushSession?
    // Перемикач pathBar між breadcrumb-рядком і TextField (клік по порожньому місцю рядка
    // чи ⌘⇧G, тут лише сам state). onSubmit/Escape повертає false.
    @State private var focusedPathField = false
    @FocusState private var pathFieldFocus: Bool
    // ⌘F фокусує сюди (focusSearch у browserUIActions нижче).
    @FocusState private var searchFieldFocused: Bool
    // Ширини колонок таблиці переживають перезапуск — TableColumnCustomization сам
    // Codable, SwiftUI дає готовий @AppStorage-ініціалізатор саме під нього.
    @AppStorage("browser.columnCustomization") private var columnCustomization = TableColumnCustomization<RemoteEntry>()

    var body: some View {
        attachFileActionAlerts(to: mainContent)
    }

    /// Alert-и FileActions (перейменувати/нова тека/помилка дії) винесені в
    /// BrowserView+Alerts.swift, toolbar — у BrowserView+Toolbar.swift, щоб BrowserView.swift
    /// не переростав розумну довжину файлу.
    private var mainContent: some View {
        VStack(spacing: 0) {
            if state.devices.showDisconnectBanner {
                DisconnectBanner()
            }
            // Незавершена операція з попереднього запуску — продовжити/відхилити.
            if let record = state.transfers.recoverable.first {
                RecoveryBanner(
                    record: record,
                    message: state.transfers.recoveryMessage,
                    onResume: { state.transfers.resumeRecovery(record) },
                    onDismiss: { state.transfers.dismissRecovery(record) }
                )
            }
            pathBar
            Divider()
            table
            Divider()
            // Немодальна черга — порожня черга не показує нічого, браузинг (таблиця,
            // поллер) працює під час операцій.
            OperationQueuePanel(transfers: state.transfers) { item in
                switch item {
                case .transfer(let session): detailsTransfer = session
                case .push(let session): detailsPush = session
                }
            }
            bottomBar
        }
        .toolbar { toolbarContent }
        // Публікує дії, що потребують локального UI-стану цієї BrowserView (фокус
        // пошуку/редагування шляху/push-importer) для AppCommands.swift.
        .focusedSceneValue(\.browserUIActions, browserUIActions)
        .confirmationDialog(
            // Те саме число, що реально піде в enqueueTransfer (startTransfer бере
            // browserStore.selectedEntries, вже відфільтровані до видимого).
            // `pendingMoveCount` — зафіксований у requestTransfer, не жива
            // `visibleSelection.count` — та підв'язувала б увесь mainContent (нижче) до
            // selection/entries/filterText лише заради рядка, що здебільшого не показаний.
            "Перемістити \(state.transfers.pendingMoveCount) елем. на Mac?",
            isPresented: $state.transfers.confirmingMove,
            titleVisibility: .visible
        ) {
            Button("Перемістити (видалить з телефона)", role: .destructive) {
                state.transfers.startTransfer(move: true)
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Файли буде видалено з телефона лише після успішного копіювання та перевірки розмірів.")
        }
        .fileImporter(
            isPresented: $showingDestinationPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.transfers.addDestination(url)
            }
        }
        .sheet(item: $detailsTransfer) { session in
            TransferSheet(session: session)
        }
        .sheet(item: $detailsPush) { session in
            PushSheet(session: session)
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(state: state)
        }
        .fileImporter(
            isPresented: $showingPushImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                state.transfers.requestPush(urls: urls)
            }
        }
        .alert(
            "Не вдалося показати превʼю",
            isPresented: Binding(
                get: { state.preview.previewError != nil },
                set: { if !$0 { state.preview.previewError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.preview.previewError ?? "")
        }
        .confirmationDialog(
            "Видалити \(state.files.deleteTargetIDs.count) елем. з телефона?",
            isPresented: $state.files.confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Видалити безповоротно", role: .destructive) {
                state.files.deleteConfirmed()
            }
            Button("Скасувати", role: .cancel) { state.files.deleteTargetIDs = [] }
        } message: {
            Text("Файли буде видалено з телефона без копіювання на Mac. Дію не можна скасувати.")
        }
    }

    /// Пристрій/вільне місце — у SidebarView (секція "Пристрій"), Історія/Оновити/Нова
    /// тека — у `.toolbar` вище. pathBar без quick-place-чіпів (ті в sidebar) і без TextField
    /// за замовчуванням — замість нього клікабельні breadcrumbs (BreadcrumbBar), TextField
    /// з'являється лише за кліком по порожньому місцю рядка (focusedPathField).
    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await state.browser.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(RemotePath.normalized(state.browser.currentPath) == "/")
            .help("Вгору")
            .accessibilityLabel("Вгору")

            if focusedPathField {
                TextField("Шлях на телефоні", text: $state.browser.pathField)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($pathFieldFocus)
                    .onAppear { pathFieldFocus = true }
                    .onSubmit {
                        Task { await state.browser.navigateFromField() }
                        focusedPathField = false
                    }
                    .onExitCommand {
                        state.browser.pathField = state.browser.currentPath
                        focusedPathField = false
                    }
            } else {
                BreadcrumbBar(
                    path: state.browser.currentPath,
                    onNavigate: { path in Task { await state.browser.navigate(to: path) } },
                    onEditRequested: { focusedPathField = true },
                    onAddFavorite: state.devices.activeDevice == nil ? nil : { state.browser.addCurrentPathToFavorites() }
                )
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Пошук у теці", text: $state.browser.filterText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    // Escape очищає пошук і віддає фокус таблиці — як у полі шляху.
                    .onExitCommand {
                        state.browser.filterText = ""
                        searchFieldFocused = false
                    }
                if !state.browser.filterText.isEmpty {
                    Button {
                        state.browser.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Очистити пошук")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(
            of: RemoteEntry.self,
            selection: $state.browser.selection,
            sortOrder: $state.browser.sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Назва", value: \.name) { entry in
                Label {
                    Text(entry.name)
                } icon: {
                    nameIcon(for: entry)
                }
                .task(id: entry.id) {
                    // З preview-кешу (миттєвий no-op, якщо там нема); інакше — вбудована
                    // EXIF-мініатюра з перших 64 КБ файла на телефоні, лише поки рядок видимий.
                    state.preview.thumbnails.requestThumbnail(for: entry)
                    await state.preview.thumbnails.loadRemoteThumbnail(for: entry)
                }
                // Table подає кожну колонку окремим accessibility-елементом — повний
                // опис (ім'я+тип+розмір+дата, BrowserView+Accessibility.swift) вішаємо на
                // клітинку "Назва" (.ignore ховає окремо Text/іконку всередині Label), а
                // "Розмір"/"Змінено" нижче ховаємо зовсім, щоб VoiceOver не читав те саме двічі.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(rowAccessibilityLabel(for: entry))
            }
            .width(min: 260)
            .customizationID("name")

            TableColumn("Розмір", value: \.size) { entry in
                Text(entry.isDirectory ? "—" : Format.bytes(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .width(min: 70, ideal: 100)
            .customizationID("size")

            TableColumn("Змінено", value: \.modified) { entry in
                Text(Format.date(entry.modified))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .width(min: 100, ideal: 150)
            .customizationID("modified")
        } rows: {
            ForEach(state.browser.filteredEntries) { entry in
                // Drag — на рівні рядка (TableRowContent.draggable), не на вмісті клітинок:
                // `.draggable` на Text/Label перехоплював би mouseDown, і клік по назві/іконці
                // не вибирав би рядок (працював би лише клік у порожню частину клітинки),
                // подвійний клік по назві не відкривав би теку. Бонус: тягнуться всі виділені рядки.
                TableRow(entry).draggable(rowDragPayload(for: entry))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            // `index.byID` — O(1) замість `entries.first(where:)` (O(n) на відкриття
            // контекстного меню).
            if ids.count == 1, let id = ids.first, let entry = state.browser.index.byID[id] {
                if entry.isDirectory {
                    Button("Відкрити") { state.browser.openIfSingleDirectory(ids) }
                } else if !entry.isSymlink {
                    Button("Переглянути") { state.preview.previewFile(entry) }
                }
                Button("Перейменувати…") { state.files.beginRename(entry) }
            }
            if !ids.isEmpty {
                Divider()
                Button("Видалити з телефона…", role: .destructive) {
                    state.files.requestDelete(ids)
                }
            }
        } primaryAction: { ids in
            state.preview.handleDoubleClick(ids)
        }
        .quickLookPreview($state.preview.previewURL)
        // Space — Quick Look одного вибраного файла (Finder-конвенція).
        .onKeyPress(.space) { quickLookOnSpace() }
        // Дроп із Finder — push у поточну відкриту теку телефона. Сам дроп нічого не
        // тягне, доки не відпущено кнопку миші (Transferable-семантика URL вбудована в SwiftUI).
        .dropDestination(for: URL.self) { urls, _ in
            guard state.transfers.canPush else { return false }
            state.transfers.requestPush(urls: urls)
            return true
        }
        .overlay {
            // `isIndexBuilding` — не лише `isLoading`. `entries` приземляється (і `isLoading`
            // гаситься) синхронно в refreshList(), тоді як `index` (те, що реально показує
            // таблиця нижче — filteredEntries/byID) ще будується офф-main
            // (scheduleIndexRebuild); без цієї другої умови таблиця на це вікно могла б
            // показати вміст старої теки (і приймати кліки по ньому), або хибно "Нічого не
            // знайдено" на реально непорожній новій.
            if state.browser.isLoading || state.browser.isIndexBuilding {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.opacity(0.6))
            } else if let error = state.browser.listError {
                ContentUnavailableView {
                    Label("Не вдалося відкрити теку", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Спробувати ще раз") { Task { await state.browser.refreshList() } }
                }
            } else if state.browser.entries.isEmpty {
                ContentUnavailableView("Тека порожня", systemImage: "folder")
            } else if state.browser.filteredEntries.isEmpty {
                ContentUnavailableView("Нічого не знайдено", systemImage: "magnifyingglass")
            }
        }
    }


    /// Space на таблиці — тека/symlink/множинний вибір ігноруємо (.ignored пропускає
    /// подію далі, як і без обробника — не з'їдає Space деінде, напр. у пошуку).
    /// `index.byID` — O(1) замість `entries.first(where:)` (O(n) на кожен Space).
    private func quickLookOnSpace() -> KeyPress.Result {
        guard state.browser.selection.count == 1, let id = state.browser.selection.first,
              let entry = state.browser.index.byID[id],
              !entry.isDirectory, !entry.isSymlink
        else { return .ignored }
        state.preview.previewFile(entry)
        return .handled
    }

    /// Дії AppCommands.swift, що потребують локального UI-стану цієї BrowserView.
    private var browserUIActions: BrowserUIActions {
        BrowserUIActions(
            focusSearch: { searchFieldFocused = true },
            editPath: { focusedPathField = true },
            showPushImporter: { showingPushImporter = true }
        )
    }

    /// "…/батько/тека" (2 останні компоненти) замість голого lastPathComponent — повний
    /// шлях лишається доступним через `.help` вище. Однокомпонентний шлях (напр. том-корінь)
    /// показує лише його, без "…/" префікса.
    private static func shortDestinationLabel(_ url: URL) -> String {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count > 1 else { return components.last ?? url.lastPathComponent }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
