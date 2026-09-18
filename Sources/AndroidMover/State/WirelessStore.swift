import Foundation
import Observation
import AndroidMoverCore

/// Бездротове налагодження Android 11+ — спарити один
/// раз кодом з екрана телефона, далі під'єднуватися за адресою. Порти ефемерні й не зберігаються:
/// лишається лише хост і мітка для підказки в ручній формі. Ручний ввід — основний шлях; mDNS
/// (`adb mdns services`) — прискорювач, чия відсутність є деградацією, а не помилкою.
@MainActor
@Observable
final class WirelessStore {
    struct PairedHost: Codable, Hashable {
        let host: String
        var label: String
        let pairedAt: Date
    }

    let deviceStore: DeviceStore

    /// nil — ще не перевіряли; false — цей adb не вміє mDNS (лишається ручна форма).
    var mdnsAvailable: Bool?
    var discovered: [MDNSService] = []
    var pairHost = ""
    var pairPort = ""
    var pairCode = ""
    var connectHost = ""
    var connectPort = ""
    var busy = false
    var status: String?
    var errorMessage: String?
    private(set) var pairedHosts: [PairedHost] = []

    private static let pairedHostsKey = "wireless.pairedHosts"
    @ObservationIgnored
    private nonisolated(unsafe) var discoveryTask: Task<Void, Never>?

    init(deviceStore: DeviceStore) {
        self.deviceStore = deviceStore
        pairedHosts = Self.loadPairedHosts()
        if let last = pairedHosts.max(by: { $0.pairedAt < $1.pairedAt }) {
            connectHost = last.host
            pairHost = last.host
        }
    }

    deinit {
        discoveryTask?.cancel()
    }

    // MARK: - mDNS (лише поки відкрите вікно)

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            guard let client = self?.deviceStore.client else { return }
            let available = await client.mdnsCheck()
            self?.mdnsAvailable = available
            while !Task.isCancelled {
                if available {
                    let services = (try? await client.mdnsServices()) ?? []
                    guard !Task.isCancelled, let self else { return }
                    self.discovered = services.sorted { $0.hostPort < $1.hostPort }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    /// Знайдений сервіс спарювання → у ручну форму (код усе одно вводить людина).
    func fill(pairing service: MDNSService) {
        pairHost = service.host
        pairPort = String(service.port)
        status = nil
        errorMessage = nil
    }

    // MARK: - Спарити / під'єднати / від'єднати

    func pair() async {
        guard let address = Self.address(host: pairHost, port: pairPort) else {
            return fail("Адреса для спарювання: IP-адреса і порт з діалогу «Спарювати пристрій за допомогою коду».")
        }
        let code = pairCode.trimmingCharacters(in: .whitespaces)
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            return fail("Код спарювання — шість цифр з екрана телефона.")
        }
        await perform { client in
            try await client.pair(host: address.host, port: address.port, code: code)
            self.remember(host: address.host)
            self.connectHost = address.host
            self.pairCode = ""
            self.status = "Спаровано з \(address.host). Тепер під'єднайтеся: адреса з портом угорі екрана «Бездротове налагодження» — порт інший, ніж для спарювання."
            if let service = self.discovered.first(where: { $0.kind == .connect && $0.host == address.host }) {
                try await self.connectRaw(client: client, host: service.host, port: service.port)
            }
        }
    }

    func connect() async {
        guard let address = Self.address(host: connectHost, port: connectPort) else {
            return fail("Адреса для під'єднання: IP-адреса і порт угорі екрана «Бездротове налагодження».")
        }
        await perform { client in
            try await self.connectRaw(client: client, host: address.host, port: address.port)
        }
    }

    func connect(service: MDNSService) async {
        await perform { client in
            try await self.connectRaw(client: client, host: service.host, port: service.port)
        }
    }

    func disconnect(device: ADBDevice) async {
        guard let address = ADBDevice.parseHostPort(device.serial) else { return }
        await perform { client in
            try await client.disconnect(host: address.host, port: address.port)
            self.status = "Від'єднано \(device.serial)."
        }
    }

    func forget(host: String) {
        pairedHosts.removeAll { $0.host == host }
        persist()
    }

    // MARK: - Приватне

    private func connectRaw(client: ADBClient, host: String, port: Int) async throws {
        let serial = try await client.connect(host: host, port: port)
        remember(host: host)
        status = "Під'єднано: \(serial). Wi-Fi повільніший за USB — великі переноси краще кабелем."
        // Телефон з'явиться в track-devices за мить — вибрати його, щойно з'явиться (до ~5 с).
        for _ in 0..<16 {
            if let device = deviceStore.devices.first(where: { $0.serial == serial }) {
                deviceStore.selectDevice(serial)
                updateLabel(host: host, label: device.displayName)
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func perform(_ body: (ADBClient) async throws -> Void) async {
        guard let client = deviceStore.client else { return fail("ADB не готовий.") }
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await body(client)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        status = nil
    }

    /// «192.168.1.5» + «41567», або все разом у полі адреси («192.168.1.5:41567»).
    static func address(host: String, port: String) -> (host: String, port: Int)? {
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = port.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return ADBDevice.parseHostPort(h) }
        guard !h.isEmpty, let portNumber = Int(p), (1...65535).contains(portNumber) else { return nil }
        return (h, portNumber)
    }

    private func remember(host: String) {
        guard !pairedHosts.contains(where: { $0.host == host }) else { return }
        pairedHosts.append(PairedHost(host: host, label: host, pairedAt: Date()))
        persist()
    }

    private func updateLabel(host: String, label: String) {
        guard let index = pairedHosts.firstIndex(where: { $0.host == host }), pairedHosts[index].label != label else { return }
        pairedHosts[index].label = label
        persist()
    }

    private static func loadPairedHosts() -> [PairedHost] {
        guard let data = UserDefaults.standard.data(forKey: pairedHostsKey),
              let hosts = try? JSONDecoder().decode([PairedHost].self, from: data) else { return [] }
        return hosts
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairedHosts), forKey: Self.pairedHostsKey)
    }
}
