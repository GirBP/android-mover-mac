import SwiftUI
import Observation
import Foundation
import AndroidMoverCore

// Сесії операцій (TransferSession/PushSession) — винесено з TransferCoordinator.swift, щоб той не переростав розумну довжину файлу.

@MainActor
@Observable
final class TransferSession: Identifiable {
    // nonisolated — Identifiable-вимога має лишатись доступною поза MainActor
    // (OperationItem.id, State/OperationItem.swift); UUID лише читається, ніколи не
    // мутується після init, тому це безпечно.
    nonisolated let id = UUID()
    let engine: TransferEngine
    let move: Bool
    let itemCount: Int
    var progress = TransferProgress() {
        didSet { rate.record(bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal, at: Date().timeIntervalSinceReferenceDate) }
    }
    /// Швидкість/залишок часу — з кожного оновлення progress (TransferRateEstimator, Core).
    var rate = TransferRateEstimator()
    var results: [TransferItemResult]?
    var globalError: String?
    var cancelRequested = false
    /// true щойно `TransferQueue.runNextIfNeeded()` фактично запустив Task для цього
    /// елемента черги (не просто додав його в `queue`). `isRunning` (нижче) сама по собі не
    /// розрізняє "ще не стартувала" від "виконується" (обидві мають `results == nil`) — тому
    /// `OperationItem.rowState` дивиться на `started`+`results` разом.
    var started = false
    /// Відкладений запуск. `enqueueTransfer` (TransferQueue.swift) конструює сесію одразу
    /// (щоб рядок з'явився в черзі миттєво), але саму роботу — Task, що читає
    /// `deviceStore.activeDevice?.serial` і кличе `engine.transfer(...)` — відкладає сюди.
    /// Завдяки цьому serial для кожного елемента резолвиться актуальним на момент його
    /// власного старту, а не на момент постановки в чергу (item міг чекати своєї черги,
    /// доки виконувались попередні). `runNextIfNeeded()` викликає це рівно один раз і одразу
    /// звільняє (`= nil`) — інакше сесія тримала б замикання (і, транзитивно, `self`) вічно.
    var launch: (() -> Void)?
    /// Serial+назва пристрою, зафіксовані на момент постановки в чергу (enqueueTransfer) —
    /// той самий момент, що дав `entries`/`destination`. Якщо читати serial лише в launch
    /// (момент старту, а не enqueue), і між постановкою в чергу і фактичним стартом
    /// користувач перемкне активний пристрій, launch тягнув би pull чужих шляхів (entries —
    /// зі старого пристрою) і, для move, видаляв би файли не на тому телефоні. Тому launch
    /// лише перевіряє, що саме цей serial усе ще підключений і ready — інакше чесний
    /// провал, а не мовчазна робота не з тим пристроєм.
    let targetSerial: String
    let targetDeviceLabel: String

    init(engine: TransferEngine, move: Bool, itemCount: Int, targetSerial: String, targetDeviceLabel: String) {
        self.engine = engine
        self.move = move
        self.itemCount = itemCount
        self.targetSerial = targetSerial
        self.targetDeviceLabel = targetDeviceLabel
    }

    var isRunning: Bool { results == nil }

    /// «45,2 MB/s · ~3 хв» — лише під час фактичного копіювання (pull/докачка); у фазах
    /// verify/дати/rm байти не рухаються, і цифра лише вводила б в оману.
    var throughputLabel: String? {
        switch progress.phase {
        case .pulling, .resuming: break
        default: return nil
        }
        return Self.throughputText(rate)
    }

    static func throughputText(_ rate: TransferRateEstimator) -> String? {
        guard let bytesPerSecond = rate.bytesPerSecond, bytesPerSecond >= 1024 else { return nil }
        var text = "\(Format.bytes(Int64(bytesPerSecond)))/с"
        if let eta = rate.estimatedSecondsRemaining, eta.isFinite, eta < 48 * 3600 {
            text += " · ~\(Format.duration(eta))"
        }
        return text
    }

    func cancel() {
        cancelRequested = true
        engine.cancel()
    }

    /// Підпис фази — тут, бо той самий текст потрібен і в OperationQueuePanel (рядок
    /// активної операції в черзі), не лише в "Деталі…"-sheet.
    var phaseLabel: String {
        switch progress.phase {
        case .counting: return String(localized: "Рахую файли…")
        case .pulling: return String(localized: "Копіюю з телефона…")
        case .settingDates: return String(localized: "Виставляю дати файлів…")
        case .verifying: return String(localized: "Перевіряю копію…")
        case .checksumming: return String(localized: "Звіряю контрольні суми…")
        case .waitingForDevice:
            return progress.attempt > 0
                ? String(localized: "Чекаю на телефон… (спроба \(progress.attempt))")
                : String(localized: "Чекаю на телефон…")
        case .resuming: return String(localized: "Докачую після обриву…")
        case .deleting: return String(localized: "Видаляю з телефона…")
        case .finished: return String(localized: "Завершення…")
        }
    }
}

/// Сесія push Mac → Android (B1) — близнюк TransferSession, той самий isRunning/cancel/
/// started/launch/phaseLabel патерн.
@MainActor
@Observable
final class PushSession: Identifiable {
    nonisolated let id = UUID()
    let engine: PushEngine
    let itemCount: Int
    var progress = PushProgress() {
        didSet { rate.record(bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal, at: Date().timeIntervalSinceReferenceDate) }
    }
    var rate = TransferRateEstimator()
    var throughputLabel: String? {
        guard progress.phase == .pushing else { return nil }
        return TransferSession.throughputText(rate)
    }
    var results: [PushItemResult]?
    var globalError: String?
    var cancelRequested = false
    var started = false
    var launch: (() -> Void)?
    /// Те саме, що в TransferSession, дивись коментар там.
    let targetSerial: String
    let targetDeviceLabel: String

    init(engine: PushEngine, itemCount: Int, targetSerial: String, targetDeviceLabel: String) {
        self.engine = engine
        self.itemCount = itemCount
        self.targetSerial = targetSerial
        self.targetDeviceLabel = targetDeviceLabel
    }

    var isRunning: Bool { results == nil }

    func cancel() {
        cancelRequested = true
        engine.cancel()
    }

    var phaseLabel: String {
        switch progress.phase {
        case .counting: return String(localized: "Рахую файли…")
        case .pushing: return String(localized: "Копіюю на телефон…")
        case .waitingForDevice:
            return progress.attempt > 0
                ? String(localized: "Чекаю на телефон… (спроба \(progress.attempt))")
                : String(localized: "Чекаю на телефон…")
        case .resuming: return String(localized: "Допушую після обриву…")
        case .verifying: return String(localized: "Перевіряю копію…")
        case .finishing: return String(localized: "Завершення…")
        }
    }
}

