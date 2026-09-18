import Foundation
import Observation
import AndroidMoverCore

/// 2.1: сховище всього, що стосується ADB і фізичного пристрою — раніше жило в AppState.
/// Єдине джерело правди для `stage`; BrowserStore/TransferCoordinator/PreviewStore/FileActions
/// читають `client`/`activeDevice` звідси через явну (сильну, без циклів утримання) залежність.
@MainActor
@Observable
final class DeviceStore {
    enum Stage {
        case checkingADB
        case needADB
        case installingADB
        case noDevice
        case unauthorized
        case ready
    }

    var adbPath: String?
    private var checkedADB = false
    var installing = false
    var installError: String?
    var installProgress: Double?

    var devices: [ADBDevice] = []
    var selectedSerial: String?
    var devicesError: String?

    /// Викликається з `selectDevice(_:)` — миттєвий (без очікування поллера) сигнал
    /// BrowserStore-у скинути лістинг/виділення/storageInfo. Замикання захоплює BrowserStore
    /// СЛАБО (задається ззовні, з AppState.init) — щоб не утворити цикл утримання DeviceStore↔BrowserStore.
    var onDeviceSelected: (() -> Void)?

    /// Викликається після КОЖНОГО ОПУБЛІКОВАНОГО кадру `track-devices` (і після рестарту стріму
    /// з помилкою) — та сама інвалідація, що раніше жила у AppState.refreshDevicesQuietly():
    /// порожній список пристроїв скидає кеш листингу, зміна активного serial скидає storageInfo.
    var onDevicesUpdated: ((_ activeSerial: String?, _ isEmpty: Bool) -> Void)?

    /// 2.2/3.3: чи йде зараз transfer (Android → Mac) — задається AppState
    /// (`transfers.hasActiveTransfer`, TransferQueue.swift: є елемент черги в стані `.active`
    /// і це `.transfer`), ЛИШЕ transfer, НЕ push: стара поведінка (до v0.9.3-рефактору) не
    /// опитувала `adb devices`, доки transfer активний — тому зникнення телефона посеред
    /// pull/resume НЕ перемикало `stage` на `.noDevice` (TransferSheet лишався відкритим, B2
    /// сам чекав повернення пристрою всередині TransferEngine). Кадри, що приходять, доки це
    /// true, `applyFrame` кладе в `pendingFrame` і НЕ публікує.
    var isOperationActive: (() -> Bool)?

    // @ObservationIgnored (службовий Task, SwiftUI його не рендерить) + nonisolated(unsafe):
    // deinit (нонізольований контекст) мусить скасувати Task синхронно без стрибка на
    // MainActor; без @ObservationIgnored макро @Observable загортає властивість так, що
    // "nonisolated" на мутабельному stored property під макросом не приймається.
    @ObservationIgnored
    private nonisolated(unsafe) var trackTask: Task<Void, Never>?
    /// 3.8: момент останнього разу, коли `stage` був `.ready` — банер "телефон відпав"
    /// (`showDisconnectBanner` нижче) тримає detail на BrowserView 15с ПІСЛЯ того, як
    /// пристрій зник, ЛИШЕ якщо перед тим stage встиг побути .ready (nil == "нічого й не
    /// підключалось" — тоді одразу онбординг, банер не потрібен).
    private(set) var lastSeenReadyAt: Date?
    /// true рівно через 15с після того, як stage перестав бути .ready — після цього
    /// `showDisconnectBanner` гасне сам і detail перемикається на OnboardingView.
    private(set) var disconnectGracePeriodExpired = false
    @ObservationIgnored
    private nonisolated(unsafe) var disconnectTimeoutTask: Task<Void, Never>?
    /// Модель пристрою з кадру `track-devices` завжди nil (протокол її не передає) — кешуємо
    /// раз довантажену через `devices()` модель на serial, щоб displayName не деградував
    /// до голого serial після переходу на стрім.
    private var modelCache: [String: String] = [:]
    /// v0.14.0 (Wi-Fi): ідентичність телефона за serial (`android_id|ro.serialno`) — зондується раз
    /// на serial при першому `.ready`-кадрі, ДО публікації, щоб обране й журнал одразу мали
    /// стабільний ключ, однаковий по USB і по Wi-Fi.
    private(set) var identityBySerial: [String: DeviceIdentity] = [:]
    /// 2.2: останній ЗБАГАЧЕНИЙ (моделлю, де вдалось) кадр, що прийшов, доки `isOperationActive`
    /// був true — застосовується (публікується) через `flushPendingFrame()`, коли операція
    /// завершується. Наступний кадр, що приходить теж під час активної операції, перезаписує
    /// це значення — публікується лише НАЙСВІЖІШИЙ стан на момент завершення, не історія.
    private var pendingFrame: [ADBDevice]?

    var client: ADBClient? {
        adbPath.map { ADBClient(adbPath: $0) }
    }

    var stage: Stage {
        if installing { return .installingADB }
        if !checkedADB { return .checkingADB }
        guard adbPath != nil else { return .needADB }
        guard let device = activeDevice else { return .noDevice }
        switch device.state {
        case .ready: return .ready
        case .unauthorized: return .unauthorized
        case .offline, .other: return .noDevice
        }
    }

    var activeDevice: ADBDevice? {
        if let selectedSerial, let device = devices.first(where: { $0.serial == selectedSerial }) {
            return device
        }
        return devices.first(where: { $0.state == .ready }) ?? devices.first
    }

    /// 3.8: показувати тонкий банер "телефон відпав" замість миттєвого переходу на
    /// OnboardingView — лише коли пристрій РАНІШЕ вже був готовий (lastSeenReadyAt != nil,
    /// інакше це перший запуск без жодного підключення — одразу онбординг) і 15с грейс-період
    /// ще не сплив.
    var showDisconnectBanner: Bool {
        stage != .ready && lastSeenReadyAt != nil && !disconnectGracePeriodExpired
    }

    deinit {
        trackTask?.cancel()
        disconnectTimeoutTask?.cancel()
    }

    // MARK: - Життєвий цикл

    func bootstrap() {
        adbPath = ADBClient.discover()
        checkedADB = true
        startTrackingIfNeeded()
        noteStageChanged()
    }

    func installADB() {
        guard !installing else { return }
        installing = true
        installError = nil
        installProgress = nil
        Task {
            do {
                let path = try await ADBInstaller().install(onProgress: { fraction in
                    Task { @MainActor [weak self] in self?.installProgress = fraction }
                })
                adbPath = path
                startTrackingIfNeeded()
            } catch {
                installError = error.localizedDescription
            }
            installing = false
            installProgress = nil
            noteStageChanged()
        }
    }

    func selectDevice(_ serial: String) {
        guard serial != activeDevice?.serial else { return }
        selectedSerial = serial
        onDeviceSelected?()
        noteStageChanged()
    }

    // MARK: - 2.4: track-devices замість поллінгу `adb devices`

    /// Один довгоживучий Task на життя сховища — не запускається вдруге і не запускається
    /// взагалі, доки нема adb-шляху. Скасовується у deinit (вікно/сховище зникло) —
    /// скасування Task-консюмера каскадом термінує adb-процес усередині ADBClient.trackDevices().
    ///
    /// 2.2-фікс (витік): раніше `while let self, !Task.isCancelled` тримало СИЛЬНИЙ `self`
    /// на ВЕСЬ час тіла ОДНІЄЇ ітерації — включно з усім вкладеним `for try await frame in
    /// client.trackDevices()`, який може стрімити кадри практично вічно (доки стрім не
    /// впаде/не скасується). Тобто `self` фактично був живий, доки живе стрім — deinit
    /// ніколи не спрацьовував, вікно закривалось, а adb track-devices лишався висіти. Тепер
    /// `self` захоплюється СЛАБО (`[weak self]`) і зв'язується в СИЛЬНИЙ локальний лише на
    /// момент застосування ОДНОГО кадру (`guard let self else { return }` усередині `for`) —
    /// між кадрами, поки Task чекає наступний елемент стріму, жодного сильного посилання нема.
    private func startTrackingIfNeeded() {
        guard trackTask == nil, let client else { return }
        trackTask = Task { [weak self] in
            var backoff: TimeInterval = 2
            while !Task.isCancelled {
                do {
                    for try await frame in client.trackDevices() {
                        guard !Task.isCancelled else { return }
                        guard let self else { return }
                        await self.applyFrame(frame, client: client)
                        backoff = 2
                    }
                } catch {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.devicesError = error.localizedDescription
                }
                if Task.isCancelled { return }
                // Стрім завершився (сервер adb зупинився чи впав) — пристроїв більше нема,
                // доки не піднімемо нове з'єднання; рестарт з експоненційним відступом до 10 с.
                // `self` звільняється ТУТ (кінець `if let`), ДО Task.sleep нижче — сон не
                // тримає сховище живим.
                if let self {
                    if !self.devices.isEmpty {
                        self.devices = []
                        self.onDevicesUpdated?(nil, true)
                    }
                } else {
                    return
                }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 10)
            }
        }
    }

    /// 2.2: кадри, що приходять, доки `isOperationActive` каже true (йде transfer), кладуться
    /// у `pendingFrame` і НЕ публікуються — `stage`/`devices` лишаються замороженими на стані
    /// до початку операції, TransferSheet не зникає, попри зникнення пристрою посеред pull/
    /// resume (B2 сам чекає повернення всередині TransferEngine). `flushPendingFrame()`
    /// (нижче) публікує найсвіжіший такий кадр, коли TransferCoordinator сигналізує кінець
    /// операції.
    ///
    /// 2.7: збагачення моделлю ТЕПЕР чекається ТУТ (async), а не фонується fire-and-forget —
    /// інакше displayName спершу показував голий serial, а за мить (коли фоновий `devices()`
    /// долітав) стрибав на модель — "блимання". Порядок кадрів зберігається: `applyFrame`
    /// викликається СЕКВЕНЦІЙНО з `for try await` вище (кожен виклик дочекується, перш ніж
    /// цикл забере наступний кадр), тож паралельних збагачень для різних кадрів не буває.
    private func applyFrame(_ frame: [ADBDevice], client: ADBClient) async {
        var enriched = frame
        for index in enriched.indices where enriched[index].model == nil {
            let serial = enriched[index].serial
            if let cachedModel = modelCache[serial] {
                enriched[index] = ADBDevice(serial: serial, state: enriched[index].state, model: cachedModel)
            } else if let found = try? await client.devices(),
                      let match = found.first(where: { $0.serial == serial }),
                      let model = match.model {
                modelCache[serial] = model
                enriched[index] = ADBDevice(serial: serial, state: enriched[index].state, model: model)
            }
            // Провал best-effort довантаження моделі — не критично: enriched[index] лишається
            // з model == nil, displayName далі показує serial (як і раніше).
        }

        // v0.14.0: зонд ідентичності — раз на serial, лише для готових пристроїв (unauthorized
        // shell не запустить). Провал — best-effort: лишається слабка ідентичність за serial.
        for device in enriched where device.state == .ready && identityBySerial[device.serial] == nil {
            if let identity = try? await client.deviceIdentity(on: device.serial) {
                identityBySerial[device.serial] = identity
            }
        }
        // Модель із зонда, якщо `devices -l` її не дав (Wi-Fi-пристрої часто без `model:`).
        for index in enriched.indices where enriched[index].model == nil {
            if let model = identityBySerial[enriched[index].serial]?.model {
                modelCache[enriched[index].serial] = model
                enriched[index] = ADBDevice(serial: enriched[index].serial, state: enriched[index].state, model: model)
            }
        }

        if isOperationActive?() == true {
            pendingFrame = enriched
            return
        }
        publish(enriched)
    }

    // MARK: - v0.14.0: стабільна ідентичність

    func identity(for serial: String) -> DeviceIdentity? {
        identityBySerial[serial]
    }

    /// Ключ для обраного/журналу: стабільна ідентичність, а без зонда — слабка (`transport:<serial>`).
    func stableID(for serial: String) -> String {
        identityBySerial[serial]?.stableID ?? DeviceIdentity.weak(transportSerial: serial).stableID
    }

    /// Підключений і готовий пристрій із такою ідентичністю — USB чи Wi-Fi, байдуже.
    func connectedSerial(forStableID stableID: String) -> String? {
        devices.first { $0.state == .ready && self.stableID(for: $0.serial) == stableID }?.serial
    }

    /// Публікує вже збагачений (моделлю, де вдалось) кадр — спільний хвіст і для звичайного
    /// шляху (applyFrame, коли операція неактивна), і для flushPendingFrame() нижче.
    private func publish(_ enriched: [ADBDevice]) {
        devices = enriched
        devicesError = nil
        if let selectedSerial, !enriched.contains(where: { $0.serial == selectedSerial }) {
            self.selectedSerial = nil
        }
        onDevicesUpdated?(activeDevice?.serial, enriched.isEmpty)
        noteStageChanged()
    }

    /// 3.8: єдине місце, що зважує `stage` після КОЖНОЇ мутації, яка на нього впливає
    /// (bootstrap/installADB/selectDevice/publish) — оновлює `lastSeenReadyAt` при поверненні
    /// в .ready і заводить одноразовий 15с Task при виході з .ready (не таймер, що цокає:
    /// рівно один відкладений виклик на "епізод" відключення, скасовується, якщо пристрій
    /// повернувся раніше).
    private func noteStageChanged() {
        if stage == .ready {
            lastSeenReadyAt = Date()
            disconnectGracePeriodExpired = false
            disconnectTimeoutTask?.cancel()
            disconnectTimeoutTask = nil
        } else if lastSeenReadyAt != nil, disconnectTimeoutTask == nil, !disconnectGracePeriodExpired {
            disconnectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.disconnectGracePeriodExpired = true
                self.disconnectTimeoutTask = nil
            }
        }
    }

    /// 2.2: викликається TransferCoordinator-ом (через замикання `onOperationEnded`, задане в
    /// AppState.init), коли transfer завершується — публікує найсвіжіший кадр, що накопичився,
    /// доки track-devices був "заморожений" на час операції. Немає накопиченого кадру (операція
    /// пройшла без жодної зміни підключення) — тихий no-op.
    func flushPendingFrame() {
        guard let pending = pendingFrame else { return }
        pendingFrame = nil
        publish(pending)
    }
}
