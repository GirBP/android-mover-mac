import SwiftUI
import AndroidMoverCore

extension Notification.Name {
    /// v0.10.2: історію очистили (Settings) — відкритий HistoryView перечитує список.
    static let androidMoverHistoryDidChange = Notification.Name("ua.bibo.android-mover.historyDidChange")
}

/// «Історія…» (A5) — sheet у стилі TransferSheet: список recent-записів, розгортання
/// рядка показує елементи операції, «Показати у Finder» для тих, що досі є на диску.
struct HistoryView: View {
    let state: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var records: [HistoryRecord] = []
    @State private var expandedIDs = Set<UUID>()
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Історія операцій")
                    .font(.headline)
                Spacer()
                Button("Очистити…", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(records.isEmpty)
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if records.isEmpty {
                ContentUnavailableView("Історія порожня", systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(records) { record in
                        recordRow(record)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 440)
        .onAppear { reload() }
        // v0.10.2: очищення історії з Settings (⌘,) оновлює вже відкритий список.
        .onReceive(NotificationCenter.default.publisher(for: .androidMoverHistoryDidChange)) { _ in reload() }
        .confirmationDialog(
            "Очистити всю історію операцій?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Очистити", role: .destructive) {
                try? state.transfers.historyStore.clear()
                reload()
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Дію не можна скасувати. Файли на Mac і телефоні не зачіпаються.")
        }
    }

    private func reload() {
        records = state.transfers.historyStore.recent()
    }

    @ViewBuilder
    private func recordRow(_ record: HistoryRecord) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedIDs.contains(record.id) },
                set: { expanded in
                    if expanded { expandedIDs.insert(record.id) } else { expandedIDs.remove(record.id) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.items, id: \.remotePath) { item in
                    itemRow(item)
                }
            }
            .padding(.leading, 26)
            .padding(.top, 4)
        } label: {
            recordLabel(record)
                // v0.10.2: клік по всьому рядку розгортає, не лише по трикутнику.
                .contentShape(Rectangle())
                .onTapGesture {
                    if expandedIDs.contains(record.id) { expandedIDs.remove(record.id) } else { expandedIDs.insert(record.id) }
                }
        }
    }

    private func recordLabel(_ record: HistoryRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: directionIcon(record.direction))
                .foregroundStyle(directionColor(record.direction))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(directionTitle(record.direction))
                    .font(.callout.weight(.medium))
                Text("\(record.deviceLabel) · \(Format.date(record.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("елем.: \(record.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let bytes = record.items.reduce(Int64(0)) { $0 + $1.bytes }
                if bytes > 0 {
                    Text(Format.bytes(bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func itemRow(_ item: HistoryItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: itemIcon(item.status))
                .foregroundStyle(itemColor(item.status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isPlainSuccess(item.status) {
                    Text(item.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if item.bytes > 0 {
                Text(Format.bytes(item.bytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let localPath = item.localPath, FileManager.default.fileExists(atPath: localPath) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: localPath)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Показати у Finder")
                .accessibilityLabel("Показати у Finder")
            }
        }
    }

    private func isPlainSuccess(_ status: String) -> Bool {
        status == "copied" || status == "moved" || status == "deleted" || status == "pushed"
    }

    private func directionIcon(_ direction: String) -> String {
        switch direction {
        case "move": return "arrow.right.doc.on.clipboard"
        case "delete": return "trash"
        case "push": return "arrow.up.doc"
        default: return "doc.on.doc"
        }
    }

    private func directionColor(_ direction: String) -> Color {
        direction == "delete" ? .red : .accentColor
    }

    private func directionTitle(_ direction: String) -> String {
        switch direction {
        case "move": return "Переміщення на Mac"
        case "delete": return "Видалення з телефона"
        case "push": return "На телефон"
        default: return "Копіювання на Mac"
        }
    }

    private func itemIcon(_ status: String) -> String {
        if status.hasPrefix("failed") { return "xmark.circle" }
        if status == "cancelled" { return "minus.circle" }
        if status.hasPrefix("copiedButDeleteFailed") { return "exclamationmark.circle" }
        return "checkmark.circle"
    }

    private func itemColor(_ status: String) -> Color {
        if status.hasPrefix("failed") { return .red }
        if status == "cancelled" { return .secondary }
        if status.hasPrefix("copiedButDeleteFailed") { return .orange }
        return .green
    }
}
