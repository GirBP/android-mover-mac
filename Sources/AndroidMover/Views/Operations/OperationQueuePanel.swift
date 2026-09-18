import SwiftUI

/// Немодальна панель черги операцій (Safari Downloads-стиль) — сідає між таблицею й
/// bottomBar у BrowserView, лише коли `transfers.queue` непорожня. Не блокує браузинг:
/// таблиця й поллер листингу (BrowserStore) продовжують працювати, доки показана ця панель.
struct OperationQueuePanel: View {
    let transfers: TransferCoordinator
    /// BrowserView вирішує, у який саме `@State` (detailsTransfer/detailsPush) покласти
    /// конкретно типізовану сесію — тут лишається лише exhaustive switch по OperationItem.
    let onShowDetails: (OperationItem) -> Void
    // Анімація згортання/розгортання — лише коли користувач не просив менше руху.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !transfers.queue.isEmpty {
            VStack(spacing: 0) {
                header
                if transfers.isQueuePanelExpanded {
                    Divider()
                    rows
                }
            }
            // Звичайний фон вікна, не .thinMaterial — той матеріал «просвічує» під
            // сусідній сайдбар NavigationSplitView і забарвлює його низ.
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var hasActive: Bool {
        transfers.queue.contains { $0.rowState == .active }
    }

    private var hasFinished: Bool {
        transfers.queue.contains { $0.rowState == .finished }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                // Reduce Motion — без withAnimation, коли користувач просив менше руху.
                if reduceMotion {
                    transfers.isQueuePanelExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        transfers.isQueuePanelExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if hasActive {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tray.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                    Text("Операції: \(transfers.queue.count)")
                        .font(.callout.weight(.medium))
                    // Декоративні (текст вище вже несе весь сенс кнопки для VoiceOver).
                    Image(systemName: transfers.isQueuePanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                // Клік по всьому вільному простору шапки згортає/розгортає, не лише по бейджу.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transfers.isQueuePanelExpanded ? "Згорнути чергу операцій" : "Розгорнути чергу операцій")
            .accessibilityValue("\(transfers.queue.count)")

            Spacer()

            if hasFinished {
                Button("Очистити завершені") {
                    transfers.clearFinished()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Висота — за вмістом (ScrollView з maxHeight розтягувався б на всі 220 pt навіть
    /// під один рядок і з'їдав би півтаблиці); скрол з'являється лише від 4 елементів.
    @ViewBuilder
    private var rows: some View {
        if transfers.queue.count <= 3 {
            rowsStack
        } else {
            ScrollView { rowsStack }
                .frame(height: 220)
        }
    }

    private var rowsStack: some View {
        VStack(spacing: 0) {
            ForEach(transfers.queue) { item in
                row(for: item)
                if item.id != transfers.queue.last?.id {
                    Divider().padding(.leading, 40)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: OperationItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.directionIcon)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                // "· <пристрій>" — той, для кого елемент поставлено в чергу
                // (targetDeviceLabel), не поточний активний — вони можуть розійтись, поки
                // елемент чекав своєї черги.
                Text("\(item.title) · \(item.itemCount) елем. · \(item.targetDeviceLabel)")
                    .font(.callout)
                rowDetail(for: item)
            }

            Spacer()

            rowActions(for: item)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowDetail(for item: OperationItem) -> some View {
        switch item.rowState {
        case .pending:
            Text("У черзі")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .active:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: item.progressFraction)
                    .progressViewStyle(.linear)
                    // Фаза — label ("Копіюю з телефона…"), відсоток — value.
                    .accessibilityLabel(item.phaseLabel)
                    .accessibilityValue("\(Int(item.progressFraction * 100))%")
                HStack(spacing: 6) {
                    Text(item.phaseLabel)
                    if !item.currentName.isEmpty {
                        Text(item.currentName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    // Швидкість і орієнтовний залишок часу.
                    if let throughput = item.throughputLabel {
                        Text(throughput)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .finished:
            VStack(alignment: .leading, spacing: 2) {
                Text(item.summaryTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Причина провалу — тут, а не лише за «Деталі…», щоб не лишати «Не вдалося
                // почати перенесення» без пояснення.
                if let error = item.globalError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func rowActions(for item: OperationItem) -> some View {
        switch item.rowState {
        case .pending, .active:
            Button(item.cancelRequested ? "Скасовую…" : "Скасувати") {
                transfers.cancel(id: item.id)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(item.cancelRequested)
            .font(.caption)
        case .finished:
            HStack(spacing: 10) {
                if !item.showInFinderURLs.isEmpty {
                    Button("Показати у Finder") {
                        // Виділяє всі перенесені файли пакету, не лише перший.
                        NSWorkspace.shared.activateFileViewerSelecting(item.showInFinderURLs)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                }
                Button("Деталі…") {
                    onShowDetails(item)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .font(.caption)
                Button {
                    transfers.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Прибрати з черги")
                .accessibilityLabel("Прибрати з черги")
            }
        }
    }
}
