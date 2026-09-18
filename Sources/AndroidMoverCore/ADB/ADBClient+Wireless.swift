import Foundation

/// Сервіс, знайдений через `adb mdns services` (Android 11+, бездротове налагодження).
/// `_adb-tls-pairing._tcp` — телефон показує діалог спарювання (адреса для `pair`);
/// `_adb-tls-connect._tcp` — уже спарований, можна `connect`. Обидва порти ефемерні.
public struct MDNSService: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case pairing, connect, other(String) }
    public let name: String
    public let kind: Kind
    public let host: String
    public let port: Int
    public var hostPort: String { "\(host):\(port)" }

    public init(name: String, kind: Kind, host: String, port: Int) {
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
    }
}

/// Ідентичність телефона й бездротове налагодження. `pair`/`connect`/`mdns` — підкоманди
/// самого adb, не shell-скрипти, тому їхній вивід розбирається толерантно: між версіями
/// platform-tools текст пливе, стабільні лише ключові фрази.
extension ADBClient {
    static let wirelessTimeout: TimeInterval = 30

    // MARK: - Ідентичність

    /// Один shell-виклик: android_id, ro.serialno, ro.product.model — сентинел-префікси, порядок
    /// рядків неважливий. Недоступне значення (OEM-обмеження) — порожній рядок, не провал.
    public func deviceIdentity(on serial: String) async throws -> DeviceIdentity {
        let result = try await run(["-s", serial, "shell", ADBScripts.getProps().text], timeout: Self.listTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb shell getprop", code: result.exitCode, stderr: result.err)
        }
        return Self.parseDeviceIdentity(result.out, transportSerial: serial)
    }

    public static func parseDeviceIdentity(_ output: String, transportSerial: String) -> DeviceIdentity {
        var androidID: String?
        var hardwareSerial: String?
        var model: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "__AM_ID__": androidID = value
            case "__AM_SN__": hardwareSerial = value
            case "__AM_MODEL__": model = value
            default: break
            }
        }
        return DeviceIdentity.resolve(androidID: androidID, hardwareSerial: hardwareSerial, model: model, transportSerial: transportSerial)
    }

    // MARK: - mDNS

    /// `adb mdns check`: чи вміє цей adb шукати телефони в мережі. Відсутність — не помилка,
    /// а деградація до ручного вводу адреси.
    public func mdnsCheck() async -> Bool {
        guard let result = try? await run(["mdns", "check"], timeout: Self.wirelessTimeout) else { return false }
        let text = (result.out + result.err).lowercased()
        return result.exitCode == 0 && !text.contains("unavailable") && !text.contains("error")
    }

    public func mdnsServices() async throws -> [MDNSService] {
        let result = try await run(["mdns", "services"], timeout: Self.wirelessTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.wirelessFailed(Self.condense(result.err + result.out, fallback: "пошук у мережі не вдався"))
        }
        return Self.parseMDNSServices(result.out)
    }

    /// Рядки виду `adb-XXXX-abcdef\t_adb-tls-connect._tcp\t192.168.1.5:41567` — толерантно:
    /// ім'я — перший токен, тип — токен із `._tcp`, адреса — токен, що розбирається як host:port.
    public static func parseMDNSServices(_ output: String) -> [MDNSService] {
        var services: [MDNSService] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("List of") { continue }
            let tokens = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard tokens.count >= 2,
                  let type = tokens.first(where: { $0.contains("._tcp") }),
                  let address = tokens.compactMap({ ADBDevice.parseHostPort($0) }).first
            else { continue }
            let kind: MDNSService.Kind
            if type.hasPrefix("_adb-tls-pairing") { kind = .pairing }
            else if type.hasPrefix("_adb-tls-connect") { kind = .connect }
            else { kind = .other(type) }
            services.append(MDNSService(name: tokens[0], kind: kind, host: address.host, port: address.port))
        }
        return services
    }

    // MARK: - pair / connect / disconnect

    /// `adb pair host:port code` — порт і код беруться з діалогу «Спарювати пристрій за допомогою
    /// коду» на телефоні. Успіх лише за фразою «Successfully paired».
    public func pair(host: String, port: Int, code: String) async throws {
        let result = try await run(["pair", "\(host):\(port)", code], timeout: Self.wirelessTimeout)
        let text = result.out + result.err
        guard text.lowercased().contains("successfully paired") else {
            throw ADBError.wirelessFailed(Self.condense(text, fallback: "спарювання не вдалося"))
        }
    }

    /// `adb connect host:port` — порт для під'єднання інший, ніж для спарювання (обидва на екрані
    /// «Бездротове налагодження»). Повертає serial, яким телефон з'явиться в `track-devices`.
    @discardableResult
    public func connect(host: String, port: Int) async throws -> String {
        let result = try await run(["connect", "\(host):\(port)"], timeout: Self.wirelessTimeout)
        let text = result.out + result.err
        let lower = text.lowercased()
        guard lower.contains("connected to"), !lower.contains("failed"), !lower.contains("cannot") else {
            throw ADBError.wirelessFailed(Self.condense(text, fallback: "під'єднання не вдалося"))
        }
        return "\(host):\(port)"
    }

    public func disconnect(host: String, port: Int) async throws {
        _ = try await run(["disconnect", "\(host):\(port)"], timeout: Self.wirelessTimeout)
    }

    /// Перший непорожній рядок виводу adb (без службових «* daemon…») або запасний текст.
    static func condense(_ text: String, fallback: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("*") } ?? fallback
    }
}
