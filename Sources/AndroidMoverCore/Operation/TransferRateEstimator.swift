import Foundation

/// v0.10.4: швидкість передачі й орієнтовний залишок часу з відліків прогресу (bytesDone, час).
/// Чистий значеннєвий тип без таймерів — сесія (UI) годує його кожним оновленням `progress`,
/// а панель/sheet читають `bytesPerSecond`/`estimatedSecondsRemaining`.
///
/// Швидкість — за ковзним вікном (`windowSeconds`) з експоненційним згладжуванням: миттєві
/// стрибки (прогрес-поллер міряє розмір теки раз на 1–3 с, adb пише файл нерівномірно) не
/// смикають цифру, а після паузи (wait-for-device, verify) вона чесно спадає. Перші
/// `minimumSamples` відліки — nil (краще нічого, ніж «999 MB/s» з першого тіку).
public struct TransferRateEstimator: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let bytesDone: Int64
        public let time: TimeInterval   // секунди від довільного початку (Date().timeIntervalSinceReferenceDate)
        public init(bytesDone: Int64, time: TimeInterval) {
            self.bytesDone = bytesDone
            self.time = time
        }
    }

    public var windowSeconds: TimeInterval = 8
    public var minimumSamples = 2
    /// Вага нового вікна в EMA: 0.5 — половина від нового заміру, половина від історії.
    public var smoothing: Double = 0.5

    private var samples: [Sample] = []
    private var smoothedRate: Double?
    private var lastTotal: Int64 = 0
    private var lastDone: Int64 = 0

    public init() {}

    /// Годувати кожним оновленням прогресу. Немонотонний `bytesDone` (новий елемент батчу,
    /// докачка після обриву) — вікно скидається, щоб не рахувати «від'ємну» швидкість.
    public mutating func record(bytesDone: Int64, bytesTotal: Int64, at time: TimeInterval) {
        lastTotal = bytesTotal
        if bytesDone < lastDone {
            samples.removeAll()
            smoothedRate = nil
        }
        lastDone = bytesDone
        samples.append(Sample(bytesDone: bytesDone, time: time))
        // Тримаємо лише вікно.
        let cutoff = time - windowSeconds
        if let firstInside = samples.firstIndex(where: { $0.time >= cutoff }), firstInside > 0 {
            // Лишаємо один відлік ДО вікна як опору для різниці.
            samples.removeFirst(firstInside - 1)
        }
        guard samples.count >= minimumSamples,
              let first = samples.first, let last = samples.last,
              last.time > first.time else { return }
        let instantaneous = Double(last.bytesDone - first.bytesDone) / (last.time - first.time)
        guard instantaneous >= 0 else { return }
        smoothedRate = smoothedRate.map { $0 * (1 - smoothing) + instantaneous * smoothing } ?? instantaneous
    }

    /// Байт/с або nil, доки замало даних (чи після скидання вікна).
    public var bytesPerSecond: Double? {
        guard let rate = smoothedRate, rate > 0 else { return nil }
        return rate
    }

    /// Секунди до завершення або nil (нема швидкості чи невідомий обсяг).
    public var estimatedSecondsRemaining: TimeInterval? {
        guard let rate = bytesPerSecond, lastTotal > 0, lastDone <= lastTotal else { return nil }
        return Double(lastTotal - lastDone) / rate
    }

    public mutating func reset() {
        samples.removeAll()
        smoothedRate = nil
        lastDone = 0
        lastTotal = 0
    }
}
