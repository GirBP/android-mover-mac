import SwiftUI
import AndroidMoverCore

struct OnboardingView: View {
    let state: AppState
    @State private var showingWireless = false

    var body: some View {
        VStack(spacing: 18) {
            switch state.devices.stage {
            case .checkingADB:
                ProgressView("Пошук ADB…")

            case .needADB:
                icon("wrench.and.screwdriver.fill")
                Text("Потрібен ADB (одноразово)")
                    .font(.title2.bold())
                Text("Для роботи з Android macOS потребує Android Debug Bridge — офіційний інструмент Google. Додаток завантажить його сам (~13 МБ з dl.google.com) у службову теку.")
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    state.devices.installADB()
                } label: {
                    Label("Завантажити і встановити ADB", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if let error = state.devices.installError {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 460)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 4) {
                    Text("Альтернатива через Homebrew:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("brew install --cask android-platform-tools")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

            case .installingADB:
                if let fraction = state.devices.installProgress {
                    ProgressView(value: fraction) {
                        Text("Завантаження platform-tools… \(Int(fraction * 100))%")
                    }
                    .frame(maxWidth: 320)
                } else {
                    ProgressView("Завантаження platform-tools…")
                }
                Text("Зазвичай це кілька секунд.")
                    .foregroundStyle(.secondary)

            case .noDevice:
                icon("iphone.gen3.slash")
                Text("Підключіть Android-телефон")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Підключіть телефон кабелем USB (найкраще — рідним).")
                    step(2, "Один раз увімкніть режим розробника: Налаштування → Про телефон → 7 разів торкніться «Номер збірки».")
                    step(3, "У «Для розробників» увімкніть «Налагодження USB».")
                    step(4, "Якщо телефон питає про режим USB — виберіть «Передавання файлів».")
                }
                .frame(maxWidth: 480, alignment: .leading)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Очікую пристрій…").foregroundStyle(.secondary)
                }
                // v0.14.0: без кабеля — спарювання через бездротове налагодження.
                Button {
                    showingWireless = true
                } label: {
                    Label("Або під'єднати через Wi-Fi…", systemImage: "wifi")
                }
                .buttonStyle(.bordered)
                if let error = state.devices.devicesError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

            case .unauthorized:
                icon("lock.iphone")
                Text("Підтвердьте на телефоні")
                    .font(.title2.bold())
                Text("Телефон показує запит «Дозволити налагодження USB?». Поставте галочку «Завжди дозволяти з цього комп'ютера» і натисніть «Дозволити».")
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Очікую підтвердження…").foregroundStyle(.secondary)
                }

            case .ready:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingWireless) {
            WirelessPairingView(state: state)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 52))
            .foregroundStyle(.tint)
            .padding(.bottom, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.15)))
            Text(text)
        }
    }
}
