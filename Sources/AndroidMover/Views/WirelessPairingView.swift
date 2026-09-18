import SwiftUI
import AndroidMoverCore

/// Спарити й під'єднати телефон через бездротове налагодження (Android 11+). Два кроки з
/// двома різними адресами (спарювання і під'єднання) — як на екрані телефона; знайдені через mDNS
/// пристрої — лише прискорювач ручної форми.
struct WirelessPairingView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Wi-Fi без кабеля", systemImage: "wifi")
                    .font(.title2.bold())
                Spacer()
                if state.wireless.busy {
                    ProgressView().controlSize(.small)
                }
            }
            Text("На телефоні (Android 11 і новіші): Налаштування → Для розробників → «Бездротове налагодження». Спарювання робиться один раз. Адреса для під'єднання показана на тому ж екрані; її порт змінюється після перезавантаження телефона. Wi-Fi повільніший за USB.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            discoveredSection
            pairSection
            connectSection

            if let status = state.wireless.status {
                Text(status).font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.wireless.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Закрити") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { state.wireless.startDiscovery() }
        .onDisappear { state.wireless.stopDiscovery() }
    }

    private var discoveredSection: some View {
        GroupBox("Знайдено в мережі") {
            VStack(alignment: .leading, spacing: 6) {
                switch state.wireless.mdnsAvailable {
                case nil:
                    Text("Перевіряю автопошук…").font(.caption).foregroundStyle(.secondary)
                case .some(false):
                    Text("Автопошук (mDNS) недоступний у цій версії adb — введіть адресу вручну нижче.")
                        .font(.caption).foregroundStyle(.secondary)
                case .some(true):
                    if state.wireless.discovered.isEmpty {
                        Text("Поки нічого. Відкрийте на телефоні екран «Бездротове налагодження» — він має бути в тій самій мережі Wi-Fi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(state.wireless.discovered, id: \.self) { service in
                        discoveredRow(service)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func discoveredRow(_ service: MDNSService) -> some View {
        HStack(spacing: 8) {
            switch service.kind {
            case .connect:
                Image(systemName: "wifi").foregroundStyle(.tint)
                Text(service.hostPort).font(.callout.monospaced())
                Spacer()
                Button("Під'єднати") { Task { await state.wireless.connect(service: service) } }
                    .disabled(state.wireless.busy)
            case .pairing:
                Image(systemName: "lock.open").foregroundStyle(.orange)
                Text("\(service.hostPort) — очікує код спарювання").font(.callout)
                Spacer()
                Button("Спарити…") { state.wireless.fill(pairing: service) }
                    .disabled(state.wireless.busy)
            case .other(let type):
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("\(service.hostPort) (\(type))").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var pairSection: some View {
        GroupBox("1. Спарити (один раз)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("IP-адреса", text: $state.wireless.pairHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("порт", text: $state.wireless.pairPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    TextField("код (6 цифр)", text: $state.wireless.pairCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button("Спарити") { Task { await state.wireless.pair() } }
                        .disabled(state.wireless.busy)
                }
                Text("На телефоні натисніть «Спарювати пристрій за допомогою коду»: там адреса з портом і шестизначний код.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectSection: some View {
        GroupBox("2. Під'єднати") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("IP-адреса", text: $state.wireless.connectHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("порт", text: $state.wireless.connectPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Button("Під'єднати") { Task { await state.wireless.connect() } }
                        .disabled(state.wireless.busy)
                        .keyboardShortcut(.defaultAction)
                }
                Text("Адреса й порт — угорі екрана «Бездротове налагодження» (не з діалогу спарювання). Порт там щоразу інший.")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.wireless.pairedHosts.isEmpty {
                    Text("Раніше спарені: " + state.wireless.pairedHosts.map { $0.label == $0.host ? $0.host : "\($0.label) (\($0.host))" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
