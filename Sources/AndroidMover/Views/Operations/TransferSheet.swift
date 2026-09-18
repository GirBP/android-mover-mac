import SwiftUI
import AndroidMoverCore

/// 2.3: тонка обгортка над OperationSheet — конфігурація специфічна для перенесення
/// Android → Mac: заголовки, кнопка «Показати у Finder».
/// 3.3: більше НЕ модальний sheet — «Деталі…» на завершеному рядку OperationQueuePanel.
/// Сесія тут завжди вже `!isRunning` (результат є), тому `state` більше не потрібен —
/// «Закрити» просто закриває sheet (`@Environment(\.dismiss)`, як HistoryView), а не викликає
/// `closeTransfer()` (той метод пішов разом з одиночним `transfers.transfer`).
struct TransferSheet: View {
    let session: TransferSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OperationSheet(
            isRunning: session.isRunning,
            runningTitle: session.move ? "Переміщення на Mac" : "Копіювання на Mac",
            deviceLabel: session.targetDeviceLabel,
            phaseLabel: session.phaseLabel,
            progressFraction: session.progress.fraction,
            currentName: session.progress.currentName,
            bytesDone: session.progress.bytesDone,
            bytesTotal: session.progress.bytesTotal,
            itemsDone: session.progress.itemsDone,
            itemsTotal: session.progress.itemsTotal,
            throughputLabel: session.throughputLabel,
            cancelRequested: session.cancelRequested,
            onCancel: { session.cancel() },
            results: session.results ?? [],
            globalError: session.globalError,
            successTitle: { succeeded in
                session.move ? "Переміщено: \(succeeded)" : "Скопійовано: \(succeeded)"
            },
            showInFinderURLs: session.results?.compactMap(\.finalURL) ?? [],
            onClose: { dismiss() }
        )
    }
}
