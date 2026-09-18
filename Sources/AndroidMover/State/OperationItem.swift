import Foundation
import AndroidMoverCore

/// Три стани рядка в `OperationQueuePanel` — `OperationItem.rowState` рахує його з
/// `started`+`results` конкретної сесії (жодна з них сама по собі цього не розрізняє:
/// `isRunning == (results == nil)` каже правду і для "ще не стартувала", і для "виконується").
enum QueueRowState {
    case pending
    case active
    case finished
}

/// Обгортка над TransferSession/PushSession, що дозволяє тримати обидва типи в одному
/// масиві (`TransferCoordinator.queue`) — enum, не `protocol OperationSessionProtocol`
/// з existential-типами: "Деталі…" (OperationQueuePanel → BrowserView) відкриває конкретно
/// типізований TransferSheet/PushSheet, а existential довелось би `as?`-кастити назад до
/// конкретного типу в тому самому місці — enum дає це безкоштовно через exhaustive switch.
/// `@MainActor`: TransferSession/PushSession самі MainActor-ізольовані (той самий клас, що й
/// TransferCoordinator), тож будь-який доступ до їхніх властивостей звідси мусить теж бути
/// на MainActor — усі виклики й так ідуть із View body чи з TransferCoordinator/TransferQueue
/// (обидва MainActor), тож це не додає жодного нового стрибка контексту.
@MainActor
enum OperationItem: Identifiable {
    case transfer(TransferSession)
    case push(PushSession)

    // nonisolated: session.id (TransferSession/PushSession) сам nonisolated (див. коментар
    // там) — Identifiable-вимога лишається доступною поза MainActor, попри @MainActor на
    // решті цього enum-у.
    nonisolated var id: UUID {
        switch self {
        case .transfer(let session): return session.id
        case .push(let session): return session.id
        }
    }

    var rowState: QueueRowState {
        let started: Bool
        let finished: Bool
        switch self {
        case .transfer(let session):
            started = session.started
            finished = session.results != nil
        case .push(let session):
            started = session.started
            finished = session.results != nil
        }
        if finished { return .finished }
        return started ? .active : .pending
    }

    /// Викликається лише з `TransferQueue.runNextIfNeeded()`, лише для елемента в стані
    /// `.pending` — переводить його в `.active` (`started = true`) і запускає відкладену
    /// роботу (`session.launch`), одразу звільняючи саме замикання (див. коментар при
    /// `TransferSession.launch`).
    func start() {
        switch self {
        case .transfer(let session):
            guard !session.started else { return }
            session.started = true
            let launch = session.launch
            session.launch = nil
            launch?()
        case .push(let session):
            guard !session.started else { return }
            session.started = true
            let launch = session.launch
            session.launch = nil
            launch?()
        }
    }

    /// Кнопка «Скасувати» для рядка в стані `.active` (для `.pending` координатор просто
    /// прибирає елемент із черги — див. `TransferCoordinator.cancel(id:)`).
    func requestCancel() {
        switch self {
        case .transfer(let session): session.cancel()
        case .push(let session): session.cancel()
        }
    }

    // MARK: - Відображення (OperationQueuePanel)

    var itemCount: Int {
        switch self {
        case .transfer(let session): return session.itemCount
        case .push(let session): return session.itemCount
        }
    }

    /// Модель/serial пристрою, зафіксованого для цього елемента при постановці в чергу (не
    /// поточного активного) — рядок панелі й "Деталі…" показують, про який саме пристрій цей
    /// елемент, попри те, що активний пристрій міг відтоді змінитись.
    var targetDeviceLabel: String {
        switch self {
        case .transfer(let session): return session.targetDeviceLabel
        case .push(let session): return session.targetDeviceLabel
        }
    }

    var title: String {
        switch self {
        case .transfer(let session):
            return session.move ? String(localized: "Переміщення на Mac") : String(localized: "Копіювання на Mac")
        case .push: return String(localized: "Копіювання на телефон")
        }
    }

    /// Той самий SF Symbol, що й відповідна кнопка в bottomBar (BrowserView) — копіювати/
    /// перемістити/на телефон — щоб напрямок операції впізнавався з першого погляду.
    var directionIcon: String {
        switch self {
        case .transfer(let session): return session.move ? "arrow.right.doc.on.clipboard" : "doc.on.doc"
        case .push: return "arrow.up.doc"
        }
    }

    var progressFraction: Double {
        switch self {
        case .transfer(let session): return session.progress.fraction
        case .push(let session): return session.progress.fraction
        }
    }

    var phaseLabel: String {
        switch self {
        case .transfer(let session): return session.phaseLabel
        case .push(let session): return session.phaseLabel
        }
    }

    var currentName: String {
        switch self {
        case .transfer(let session): return session.progress.currentName
        case .push(let session): return session.progress.currentName
        }
    }

    /// «45,2 MB/s · ~3 хв» під час копіювання, nil в інших фазах.
    var throughputLabel: String? {
        switch self {
        case .transfer(let session): return session.throughputLabel
        case .push(let session): return session.throughputLabel
        }
    }

    var cancelRequested: Bool {
        switch self {
        case .transfer(let session): return session.cancelRequested
        case .push(let session): return session.cancelRequested
        }
    }

    // MARK: - Підсумок (лише .finished)

    private var counts: (succeeded: Int, failed: Int, cancelled: Int) {
        switch self {
        case .transfer(let session): return Self.counts(session.results)
        case .push(let session): return Self.counts(session.results)
        }
    }

    private static func counts<Row: OperationResultRow>(_ results: [Row]?) -> (succeeded: Int, failed: Int, cancelled: Int) {
        guard let results else { return (0, 0, 0) }
        let succeeded = results.filter(\.isSuccess).count
        let cancelled = results.filter(\.isCancelled).count
        return (succeeded, results.count - succeeded - cancelled, cancelled)
    }

    var globalError: String? {
        switch self {
        case .transfer(let session): return session.globalError
        case .push(let session): return session.globalError
        }
    }

    /// Той самий текст, що показує `OperationSheet.titleText` у "Деталі…" — рядок панелі й
    /// заголовок sheet-а мають узгоджуватись.
    var summaryTitle: String {
        let (succeeded, failed, cancelled) = counts
        if globalError != nil { return String(localized: "Не вдалося почати перенесення") }
        if failed == 0 && cancelled == 0 { return successTitle(succeeded: succeeded) }
        var parts = ["Успішно: \(succeeded)"]
        if cancelled > 0 { parts.append("скасовано: \(cancelled)") }
        if failed > 0 { parts.append("з помилками: \(failed)") }
        return parts.joined(separator: ", ")
    }

    private func successTitle(succeeded: Int) -> String {
        switch self {
        case .transfer(let session): return session.move ? "Переміщено: \(succeeded)" : "Скопійовано: \(succeeded)"
        case .push: return "Надіслано на телефон: \(succeeded)"
        }
    }

    /// nil для push (результат лишається на телефоні) і для transfer без жодного успішного
    /// елемента.
    var showInFinderURL: URL? { showInFinderURLs.first }

    /// Усі фінальні URL пакету — «Показати у Finder» виділяє їх разом.
    var showInFinderURLs: [URL] {
        switch self {
        case .transfer(let session): return session.results?.compactMap(\.finalURL) ?? []
        case .push: return []
        }
    }
}
