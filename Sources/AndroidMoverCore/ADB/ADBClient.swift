import Foundation

/// Клієнт ADB. Кожна shell-команда — один канонічний рядок виду `AM_P=<quoted>; ...`,
/// зі службовими маркерами замість покладання на exit-коди (shell_v2 є не скрізь).
/// Mock для тестів (scripts/mock_adb.py) реалізує саме цей контракт.
///
/// 2.8: клас розбито на 4 файли (жоден не мав перевищувати ~400 рядків), без зміни поведінки:
/// цей файл — ядро (властивості/init/discover/run/devices); ADBClient+TrackDevices.swift —
/// `adb track-devices` (2.4) + waitForDevice (B2); ADBClient+Listing.swift — лістинг теки і
/// рекурсивний перелік файлів/тек (без -type — статMTimes лишається тут же); ADBClient+
/// FileOps.swift — мутуючі операції (delete/mkdir/move/rename/push/remoteExists/storage/
/// rescan). Усе — методи ОДНОГО типу через `extension`, розподілені по файлах лише для
/// читабельності; `private`/`internal` розставлено так, щоб extension у іншому файлі бачив усе,
/// що йому потрібно (Swift `private` — лише для same-file extensions того самого типу).
public final class ADBClient: @unchecked Sendable {
    public let adbPath: String
    public let extraEnvironment: [String: String]
    /// Єдиний вихід до процесу adb. Продакшн —
    /// `SpawnTransport(executable: adbPath)`; тести й golden-відтворення підставляють свій.
    public let transport: any ADBTransport

    // 1.2: усі таймаути нижче — IDLE-таймаути (ProcessRunner.run), не загальна тривалість
    // команди. Годинник скидається на КОЖЕН чанк виводу з adb (stdout чи stderr); команда, що
    // стабільно щось друкує (напр. find на теці з 50k файлів), може тривати як завгодно довго —
    // обривається лише та, що замовкла довше за вказане число секунд.
    public static let listTimeout: TimeInterval = 25
    public static let findTimeout: TimeInterval = 180
    public static let deleteTimeout: TimeInterval = 300
    public static let devicesTimeout: TimeInterval = 15
    /// Скільки чекати на повернення пристрою після обриву (B2) — довше за звичайні операції:
    /// користувач міг фізично відійти вставити кабель назад. `wait-for-device` за задумом мовчить
    /// (жодного виводу), доки пристрій не з'явиться, тож ідле-семантика тут збігається зі старою
    /// "загальною тривалістю" — це і є весь час очікування.
    public static let waitForDeviceTimeout: TimeInterval = 120

    /// 1.2: тестовий гачок — підміняє `Self.findTimeout` для ЦЬОГО клієнта (recursiveFiles/
    /// recursiveDirs/statMTimes). Мінімально інвазивний спосіб дати тестам короткий ідле-таймаут
    /// (секунда замість 180 с), не чіпаючи статичні константи, якими користується решта коду.
    let findTimeoutOverride: TimeInterval?

    public convenience init(adbPath: String, extraEnvironment: [String: String] = [:], findTimeoutOverride: TimeInterval? = nil) {
        self.init(transport: SpawnTransport(executable: adbPath), adbPath: adbPath,
                  extraEnvironment: extraEnvironment, findTimeoutOverride: findTimeoutOverride)
    }

    /// `adbPath` тут лише інформаційний (діагностика, `RemoteFileTransfer`); виконує — `transport`.
    public init(transport: any ADBTransport, adbPath: String = "", extraEnvironment: [String: String] = [:], findTimeoutOverride: TimeInterval? = nil) {
        self.transport = transport
        self.adbPath = adbPath
        self.extraEnvironment = extraEnvironment
        self.findTimeoutOverride = findTimeoutOverride
    }

    // MARK: - Пошук adb

    public static var managedADBPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AndroidMover/platform-tools/adb").path
    }

    /// Кандидати в порядку пріоритету: $ADB_PATH → наш встановлений → Homebrew → Android SDK → /usr/local.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [String] = []
        if let explicit = environment["ADB_PATH"], !explicit.isEmpty { candidates.append(explicit) }
        candidates.append(managedADBPath)
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        candidates.append("/usr/local/bin/adb")
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    // MARK: - Запуск

    /// internal (не private): усі inne extension-файли (Listing/FileOps/TrackDevices) кличуть
    /// цей метод для кожної своєї adb-команди.
    @discardableResult
    func run(
        _ arguments: [String],
        timeout: TimeInterval?,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await transport.run(
            ADBInvocation(arguments: arguments, environment: extraEnvironment.isEmpty ? nil : extraEnvironment, idleTimeout: timeout),
            onSpawn: onSpawn
        )
    }

    /// Сентинел завжди друкується скриптом сам-один першим рядком і одразу exit 0,
    /// тому перевіряємо ПЕРШИЙ РЯДОК цілком, а не підрядок (ім'я файлу може містити маркер).
    /// internal (не private): спільний для Listing- і FileOps-файлів.
    static func firstLine(of output: String) -> String {
        output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // MARK: - Пристрої

    public func devices() async throws -> [ADBDevice] {
        let result = try await run(["devices", "-l"], timeout: Self.devicesTimeout)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb devices", code: result.exitCode, stderr: result.err)
        }
        return Self.parseDevices(result.out)
    }
}
