import SwiftUI
import AndroidMoverCore

/// Ліва колонка `NavigationSplitView` — три секції: "Пристрій" (усі підключені пристрої +
/// вільне місце активного), "Телефон" (швидкі місця + обране, лише коли stage == .ready) і
/// "Mac" (кілька збережених тек призначення). У не-ready станах (onboarding у detail) показує
/// лише "Mac" + порожню "Пристрій" з підказкою — секція "Телефон" без активного пристрою не має
/// сенсу (немає currentPath, який можна було б показувати як "поточний").
struct SidebarView: View {
    let state: AppState
    @State private var showingMacFolderPicker = false
    @State private var showingWireless = false

    var body: some View {
        List {
            deviceSection
            if state.devices.stage == .ready {
                phoneSection
            }
            macSection
        }
        .listStyle(.sidebar)
        .fileImporter(
            isPresented: $showingMacFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.transfers.addDestination(url)
            }
        }
        .sheet(isPresented: $showingWireless) {
            WirelessPairingView(state: state)
        }
    }

    // MARK: - Пристрій

    private var deviceSection: some View {
        Section("Пристрій") {
            if state.devices.devices.isEmpty {
                Text("Немає підключених пристроїв")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.devices.devices) { device in
                    deviceRow(device)
                }
                if state.devices.stage == .ready, let info = state.browser.storageInfo {
                    storageInfoRow(info)
                }
            }
            // Wi-Fi без кабеля — завжди доступно, і без жодного пристрою теж.
            Button {
                showingWireless = true
            } label: {
                Label("Wi-Fi без кабеля…", systemImage: "wifi")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .help("Спарити й під'єднати телефон через бездротове налагодження (Android 11 і новіші)")
        }
    }

    private func deviceRow(_ device: ADBDevice) -> some View {
        let isActive = device.serial == state.devices.activeDevice?.serial
        let badge = badgeInfo(for: device.state)
        return Button {
            state.devices.selectDevice(device.serial)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.isWireless ? "wifi" : "iphone.gen3")
                    .foregroundStyle(.tint)
                    .help(device.isWireless ? "Через Wi-Fi (\(device.serial)) — повільніше за USB" : "Через USB")
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.callout)
                    Label(badge.text, systemImage: badge.icon)
                        .font(.caption2)
                        .foregroundStyle(badge.color)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if device.isWireless {
                Button("Від'єднати Wi-Fi") {
                    Task { await state.wireless.disconnect(device: device) }
                }
            }
        }
    }

    private func badgeInfo(for state: ADBDevice.State) -> (text: String, color: Color, icon: String) {
        switch state {
        case .ready: return ("Підключено", .green, "checkmark.circle.fill")
        case .unauthorized: return ("Не авторизовано", .orange, "lock.circle.fill")
        case .offline: return ("Offline", .secondary, "xmark.circle.fill")
        case .other: return ("Невідомо", .secondary, "questionmark.circle.fill")
        }
    }

    private func storageInfoRow(_ info: RemoteStorageInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Вільно: \(Format.bytes(info.availableBytes)) з \(Format.bytes(info.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: info.usedFraction)
        }
        .padding(.vertical, 2)
        .help("Вільне місце на телефоні")
    }

    // MARK: - Телефон (швидкі місця + обране)

    /// Окремі простори id для швидких місць і обраного: спільний голий шлях як id у двох
    /// ForEach тієї самої List-секції означав би, що додавання в обране теки, яка збігається
    /// зі швидким місцем (/sdcard/Download), дає NSOutlineView два рядки з однаковим
    /// ідентифікатором — швидке місце «Завантаження» малювалось би як «★ Download», обране —
    /// як тека без зірки.
    private struct SidebarRowID: Identifiable {
        let path: String
        let scope: String
        var id: String { "\(scope):\(path)" }
    }

    private var phoneSection: some View {
        Section("Телефон") {
            ForEach(BrowserStore.quickPlaces.map { SidebarRowID(path: $0.path, scope: "quick") }) { row in
                let place = BrowserStore.quickPlaces.first { $0.path == row.path }!
                navigationRow(icon: "folder", title: place.title, path: place.path)
            }

            HStack {
                Text("Обране на телефоні")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.browser.addCurrentPathToFavorites()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                // Неактивно, коли поточна тека — швидке місце чи вже в обраному (замість
                // мовчазного «нічого не сталось»).
                .disabled(!state.browser.canAddCurrentPathToFavorites)
                .help(state.browser.canAddCurrentPathToFavorites
                      ? "Додати поточну теку в обране (⌘⇧A)"
                      : "Ця тека вже є у швидких місцях або в обраному")
                .accessibilityLabel("Додати поточну теку в обране")
            }

            ForEach(state.browser.favorites.map { SidebarRowID(path: $0, scope: "fav") }) { row in
                favoriteRow(row.path)
            }
        }
    }

    private func navigationRow(icon: String, title: String, path: String) -> some View {
        let isActive = state.browser.currentPath == path
        return Button {
            Task { await state.browser.navigate(to: path) }
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                Text(title)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func favoriteRow(_ path: String) -> some View {
        let isActive = state.browser.currentPath == path
        return Button {
            Task { await state.browser.navigate(to: path) }
        } label: {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(RemotePath.baseName(path))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .contextMenu {
            Button("Видалити з обраного", role: .destructive) {
                state.browser.removeFavorite(path)
            }
        }
    }

    // MARK: - Mac (теки призначення)

    private var macSection: some View {
        // Заголовок пояснює роль секції — це теки, куди копіювати з телефона.
        Section("Mac — куди копіювати") {
            ForEach(state.transfers.destinations, id: \.path) { url in
                destinationRow(url)
            }
            Button {
                showingMacFolderPicker = true
            } label: {
                Label("Обрати теку…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
        }
        // Дроп теки з Finder прямо в sidebar — додає її у список і робить активною (B1-подібна
        // Transferable-семантика URL, той самий підхід, що вже є в table push-дропі).
        .dropDestination(for: URL.self) { urls, _ in
            // Усі кинуті теки, не лише перша; файли (не теки) тихо пропускаються.
            let folders = urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard !folders.isEmpty else { return false }
            for folder in folders { state.transfers.addDestination(folder) }
            return true
        }
    }

    private func destinationRow(_ url: URL) -> some View {
        let isActive = state.transfers.destination?.path == url.path
        return Button {
            state.transfers.destination = url
        } label: {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.callout)
                    Text(url.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Диск від'єднано / лише читання — видно одразу, не після провалу.
                    if let problem = state.transfers.cachedProblem(for: url) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            Button("Видалити", role: .destructive) {
                state.transfers.removeDestination(url)
            }
        }
    }
}
