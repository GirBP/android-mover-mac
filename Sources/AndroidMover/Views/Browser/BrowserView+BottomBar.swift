import SwiftUI
import AndroidMoverCore

/// Нижня панель BrowserView («Куди:», вибрано, превʼю, дії) — винесено з BrowserView.swift (≤400).
extension BrowserView {
    var bottomBar: some View {
        HStack(spacing: 12) {
            // v0.10.3: явне «Куди:» + меню всіх збережених тек — власник не розумів, що це за
            // лейба і як вибрати теку (галочка в сайдбарі неочевидна).
            Menu {
                ForEach(state.transfers.destinations, id: \.path) { url in
                    Button {
                        state.transfers.destination = url
                    } label: {
                        if state.transfers.destination?.path == url.path {
                            Label(url.lastPathComponent, systemImage: "checkmark")
                        } else {
                            Text(url.lastPathComponent)
                        }
                    }
                }
                if !state.transfers.destinations.isEmpty { Divider() }
                Button("Обрати іншу теку…") { showingDestinationPicker = true }
                if let destination = state.transfers.destination {
                    Button("Показати у Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                }
            } label: {
                // Один конкатенований Text: borderedButton-меню показує лише перший текстовий
                // елемент лейби (перевірено на mock — назва теки зникала).
                Label {
                    Text("Куди: ").foregroundStyle(.secondary)
                        + Text(state.transfers.destination.map { $0.lastPathComponent } ?? "оберіть теку…").fontWeight(.medium)
                } icon: {
                    Image(systemName: state.transfers.destinationProblem == nil ? "folder.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.transfers.destinationProblem == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help(state.transfers.destinationProblem
                  ?? state.transfers.destination?.path
                  ?? "Оберіть теку на Mac, куди копіювати/переміщувати з телефона")
            .accessibilityLabel("Тека призначення на Mac")

            if let summary = state.browser.selectionSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let name = state.preview.previewLoadingName {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Превʼю: \(name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                    Button {
                        state.preview.cancelPreview()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Скасувати перегляд")
                    .accessibilityLabel("Скасувати перегляд")
                }
            }

            Spacer()

            Button {
                showingPushImporter = true
            } label: {
                Label("На телефон…", systemImage: "arrow.up.doc")
            }
            .disabled(!state.transfers.canPush)
            .help("Скопіювати файли чи теки з Mac у поточну теку телефона")

            Button {
                state.transfers.requestTransfer(move: false)
            } label: {
                Label("Копіювати", systemImage: "doc.on.doc")
            }
            .disabled(!state.transfers.canTransfer)
            // v0.10.2: неактивна кнопка пояснює ЧОМУ (підказка при наведенні).
            .help(state.transfers.transferDisabledReason ?? String(localized: "Скопіювати вибране на Mac (⌘⇧C)"))

            Button {
                state.transfers.requestTransfer(move: true)
            } label: {
                Label("Перемістити", systemImage: "arrow.right.doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.transfers.canTransfer)
            .help(state.transfers.transferDisabledReason ?? String(localized: "Перемістити вибране на Mac — видалить з телефона після перевірки копії (⌘⇧M)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

}
