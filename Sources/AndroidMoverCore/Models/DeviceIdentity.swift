import Foundation

/// ХТО телефон — окремо від того, ДЕ він зараз відповідає.
/// adb-serial для USB — апаратний номер, для Wi-Fi — `ip:port`, який змінюється після кожного
/// (пере)запуску бездротового налагодження. Тому ідентичність будується з властивостей самого
/// телефона за драбиною впевненості: `android_id` + `ro.serialno` → лише `android_id` → лише
/// `ro.serialno` → транспортний serial (слабка: живе, доки телефон не змінить адресу).
public struct DeviceIdentity: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable { case androidID, hardwareSerial, transportSerial }

    public let stableID: String
    public let source: Source
    public let androidID: String?
    public let hardwareSerial: String?
    public let model: String?

    /// Слабка ідентичність (лише адреса транспорту): обране й журнал прив'язуються до неї, але
    /// автоматичне продовження руйнівних операцій після зміни адреси не дозволяється.
    public var isWeak: Bool { source == .transportSerial }

    public init(stableID: String, source: Source, androidID: String?, hardwareSerial: String?, model: String?) {
        self.stableID = stableID
        self.source = source
        self.androidID = androidID
        self.hardwareSerial = hardwareSerial
        self.model = model
    }

    /// Драбина: композит `android_id|ro.serialno` (щоб клоновані образи з однаковим android_id
    /// не зливалися) → android_id → ro.serialno → транспортний serial.
    public static func resolve(androidID: String?, hardwareSerial: String?, model: String?, transportSerial: String) -> DeviceIdentity {
        let id = clean(androidID, minLength: 8)
        let sn = clean(hardwareSerial, minLength: 4)
        let model = clean(model, minLength: 1)
        if let id, let sn {
            return DeviceIdentity(stableID: "\(id)|\(sn)", source: .androidID, androidID: id, hardwareSerial: sn, model: model)
        }
        if let id {
            return DeviceIdentity(stableID: id, source: .androidID, androidID: id, hardwareSerial: nil, model: model)
        }
        if let sn {
            return DeviceIdentity(stableID: "sn:\(sn)", source: .hardwareSerial, androidID: nil, hardwareSerial: sn, model: model)
        }
        return DeviceIdentity(stableID: "transport:\(transportSerial)", source: .transportSerial, androidID: nil, hardwareSerial: nil, model: model)
    }

    /// Слабка ідентичність для транспортного serial без зонда (напр. пристрій unauthorized).
    public static func weak(transportSerial: String, model: String? = nil) -> DeviceIdentity {
        resolve(androidID: nil, hardwareSerial: nil, model: model, transportSerial: transportSerial)
    }

    static func clean(_ value: String?, minLength: Int) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= minLength else { return nil }
        let lower = raw.lowercased()
        if lower == "null" || lower == "unknown" || lower == "none" || raw.allSatisfy({ $0 == "0" }) { return nil }
        return raw
    }
}
