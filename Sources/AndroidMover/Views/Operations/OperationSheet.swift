import SwiftUI
import AndroidMoverCore

/// 2.3: спільний контракт рядка результату — TransferItemResult (Android → Mac) і
/// PushItemResult (Mac → Android, B1) конформлять через retroactive-розширення нижче
/// (обидва типи живуть у Core, який цей спринт не чіпає).
protocol OperationResultRow: Identifiable {
    var rowName: String { get }
    var isSuccess: Bool { get }
    var isCancelled: Bool { get }
    var statusIcon: String { get }
    var statusColor: Color { get }
    var failureMessage: String? { get }
    var warningMessage: String? { get }
}

extension TransferItemResult: OperationResultRow {
    var rowName: String { entry.name }
    var isCancelled: Bool { status == .cancelled }
    var warningMessage: String? { warning }

    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    var statusIcon: String {
        switch status {
        case .copied, .moved: return "checkmark.circle"
        case .copiedButDeleteFailed: return "exclamationmark.circle"
        case .failed: return "xmark.circle"
        case .cancelled: return "minus.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case .copied, .moved: return .green
        case .copiedButDeleteFailed: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

extension PushItemResult: OperationResultRow {
    var rowName: String { name }
    var isCancelled: Bool { status == .cancelled }
    var warningMessage: String? { warning }

    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    var statusIcon: String {
        switch status {
        case .pushed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .cancelled: return "minus.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case .pushed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

/// 2.3: один view для TransferSheet/PushSheet — раніше майже ідентичні файли різнились лише
/// заголовками, фазовими підписами й кнопкою «Показати у Finder» (лише transfer). Усе спільне
/// (running/summary-структура, іконки, підсумковий текст) живе тут; різне — параметри й
/// замикання, які передає тонка обгортка (TransferSheet.swift/PushSheet.swift, ≤40 рядків).
struct OperationSheet<Row: OperationResultRow>: View {
    let isRunning: Bool
    let runningTitle: String
    /// Аудит-фікс (п.1): пристрій, ДЛЯ ЯКОГО цю операцію поставлено в чергу (зафіксований на
    /// момент enqueue) — показуємо завжди, попри те, що активний пристрій міг відтоді
    /// змінитись (TransferQueue.swift, TransferSession/PushSession.targetDeviceLabel).
    let deviceLabel: String
    let phaseLabel: String
    let progressFraction: Double
    let currentName: String
    let bytesDone: Int64
    let bytesTotal: Int64
    let itemsDone: Int
    let itemsTotal: Int
    /// v0.10.4: «45,2 MB/s · ~3 хв» або nil поза фазою копіювання.
    let throughputLabel: String?
    let cancelRequested: Bool
    let onCancel: () -> Void

    let results: [Row]
    let globalError: String?
    /// Викликається лише коли succeeded > 0 і нема ані провалів, ані скасувань — рядок
    /// «Переміщено: N» / «Скопійовано: N» / «Надіслано на телефон: N» різниться за флейвором.
    let successTitle: (_ succeeded: Int) -> String
    /// nil — кнопка «Показати у Finder» не показується (push: результат лишається на телефоні).
    /// v0.10.2: усі перенесені файли пакету — «Показати у Finder» виділяє їх разом.
    let showInFinderURLs: [URL]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isRunning {
                runningView
            } else {
                summaryView
            }
        }
        .padding(24)
        .frame(width: 460)
        // 3.3: більше НЕ модальний sheet ("Деталі…" відкривається лише для завершених
        // елементів черги, isRunning тут завжди false) — interactiveDismissDisabled прибрано,
        // sheet можна закрити свайпом/Esc так само вільно, як HistoryView.
    }

    private var runningView: some View {
        VStack(spacing: 14) {
            Text(runningTitle)
                .font(.headline)
            Text(deviceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)

            VStack(spacing: 4) {
                Text(phaseLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !currentName.isEmpty {
                    Text(currentName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if bytesTotal > 0 {
                    Text("\(Format.bytes(bytesDone)) з \(Format.bytes(bytesTotal)) · елемент \(min(itemsDone + 1, itemsTotal)) з \(itemsTotal)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let throughputLabel {
                    Text(throughputLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button(cancelRequested ? "Скасовую…" : "Скасувати") {
                onCancel()
            }
            .disabled(cancelRequested)
        }
    }

    private var summaryView: some View {
        VStack(spacing: 14) {
            let succeeded = results.filter(\.isSuccess)
            let cancelled = results.filter(\.isCancelled)
            let failed = results.filter { !$0.isSuccess && !$0.isCancelled }

            summaryIcon(failedCount: failed.count, cancelledCount: cancelled.count)

            Text(titleText(succeeded: succeeded.count, failed: failed.count, cancelled: cancelled.count))
                .font(.headline)
            Text(deviceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let globalError {
                Text(globalError)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                if !showInFinderURLs.isEmpty {
                    Button("Показати у Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(showInFinderURLs)
                    }
                }
                Spacer()
                Button("Закрити") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func summaryIcon(failedCount: Int, cancelledCount: Int) -> some View {
        if globalError != nil || failedCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
        } else if cancelledCount > 0 {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
        }
    }

    private func titleText(succeeded: Int, failed: Int, cancelled: Int) -> String {
        if globalError != nil { return "Не вдалося почати перенесення" }
        if failed == 0 && cancelled == 0 {
            return successTitle(succeeded)
        }
        var parts: [String] = ["Успішно: \(succeeded)"]
        if cancelled > 0 { parts.append("скасовано: \(cancelled)") }
        if failed > 0 { parts.append("з помилками: \(failed)") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func resultRow(_ result: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.statusIcon)
                .foregroundStyle(result.statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.rowName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failureMessage = result.failureMessage {
                    Text(failureMessage).font(.caption).foregroundStyle(.red)
                }
                if let warningMessage = result.warningMessage {
                    Text(warningMessage).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
