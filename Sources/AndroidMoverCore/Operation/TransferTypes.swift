import Foundation

// Типи прогресу/результату TransferEngine — винесено з TransferEngine.swift (DoD ≤400 рядків).

public struct TransferProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case counting
        case pulling
        case settingDates
        case verifying
        /// v0.11.0 (P1): звірка md5 з телефоном перед видаленням/за політикою.
        case checksumming
        /// B2: pull або verify провалились — чекаємо повернення пристрою перед новою спробою.
        case waitingForDevice
        /// B2: пристрій повернувся — дотягуємо лише відсутні/биті файли елемента.
        case resuming
        case deleting
        case finished
    }

    public init() {}

    public var phase: Phase = .counting
    public var itemsTotal: Int = 0
    public var itemsDone: Int = 0
    public var currentName: String = ""
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    /// v0.11.0: номер спроби докачки (0 — перша, штатна) — UI показує «(спроба N)».
    public var attempt: Int = 0

    public var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1.0, Double(bytesDone) / Double(bytesTotal))
    }
}

public struct TransferItemResult: Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case copied
        case moved
        case failed(String)
        case copiedButDeleteFailed(String)
        case cancelled
    }

    public let id = UUID()
    public let entry: RemoteEntry
    public let status: Status
    public let finalURL: URL?
    public let bytes: Int64
    public let warning: String?

    public var isSuccess: Bool {
        switch status {
        case .copied, .moved, .copiedButDeleteFailed: return true
        case .failed, .cancelled: return false
        }
    }
}

