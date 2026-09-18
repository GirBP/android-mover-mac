import Foundation

/// Потокобезпечний прапорець (для скасування/таймауту між чергами).
public final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    public var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Атомарний test-and-set: піднімає прапорець і повертає true, якщо він ще не стояв;
    /// якщо вже стояв — лишає без змін і повертає false. Для дій, які мають статись рівно
    /// один раз попри гонку кількох викликачів (наприклад, подвійний kill adb-процесу).
    @discardableResult
    public func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// Потокобезпечний контейнер для одного значення (наприклад, поточного Process).
public final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    public init() {}

    public var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
