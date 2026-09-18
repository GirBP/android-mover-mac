import SwiftUI
import AndroidMoverCore

/// 2.3: тонка обгортка над OperationSheet, дзеркало TransferSheet — без «Показати у
/// Finder» (результат push лишається на телефоні, не на Mac).
/// 3.3: більше НЕ модальний sheet — див. коментар у TransferSheet.swift.
struct PushSheet: View {
    let session: PushSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OperationSheet(
            isRunning: session.isRunning,
            runningTitle: "Копіювання на телефон",
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
            successTitle: { succeeded in "Надіслано на телефон: \(succeeded)" },
            showInFinderURLs: [],
            onClose: { dismiss() }
        )
    }
}
