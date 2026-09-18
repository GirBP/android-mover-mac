import Foundation

/// `adb track-devices` (стрім змін підключення) + `wait-for-device` — усе, що стосується
/// присутності пристрою, а не вмісту файлової системи на ньому.
extension ADBClient {
    // MARK: - adb track-devices (стрім змін підключення)

    /// `adb track-devices`: стрімить список пристроїв заново при кожній зміні підключення
    /// (замість поллінгу `devices()` — той лишається для одноразових перевірок, напр. bootstrap).
    /// Кожен елемент — повний знімок усіх пристроїв на момент кадру (не дельта). `model` тут
    /// завжди `nil` — протокол track-devices, на відміну від `devices -l`, не передає модель;
    /// довантаження `devices -l` — окреме рішення UI-коду, коли саме показувати назву моделі.
    public func trackDevices(
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) -> AsyncThrowingStream<[ADBDevice], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    let dataStream = transport.stream(
                        ADBInvocation(arguments: ["track-devices"], environment: extraEnvironment.isEmpty ? nil : extraEnvironment),
                        onSpawn: onSpawn
                    )
                    for try await chunk in dataStream {
                        buffer.append(chunk)
                        let (frames, remainder) = Self.parseTrackDevicesFrames(buffer: buffer)
                        buffer = remainder
                        for frame in frames {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Скасування ITERATION цього стріму (Task consumer-а скасовано, чи сам стрім
            // деінікалізовано) — скасовує внутрішній Task, що зупиняє `for try await` вище;
            // те саме скасування каскадом доходить до ProcessRunner.stream(), яка вже сама
            // термінує adb-процес (SIGTERM → 3с → SIGKILL) через власний onTermination.
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Розбирає буфер на завершені кадри протоколу `adb track-devices`: кожен кадр — 4
    /// HEX-символи довжини payload + сам payload (рядки `serial\tstate`, той самий формат, що
    /// `adb devices` без заголовка "List of devices attached" — тому парситься тим самим
    /// `parseDevices`, який мовчки пропускає порожні/сторонні рядки). Повертає розібрані кадри
    /// (у порядку появи) і `remainder` — хвіст буфера без повного кадру (порожній рядок довжини
    /// чи розрізаний між чанками payload) для приліплення до наступного чанку викликачем.
    ///
    /// Некоректний (не-hex) префікс довжини не зупиняє розбір на місці: відкидається рівно 1
    /// байт, і пошук валідного кадру продовжується з наступної позиції — ресинхронізація, а
    /// не глухий кут, де `break` лишав би "поламаний" байт на початку remainder назавжди
    /// (наступний виклик бачив би той самий невалідний префікс знову, буфер ріс би без
    /// обмежень з кожним новим чанком). Запобіжник: якщо після повного проходу лишається
    /// >64 КБ, з яких не вдалось розібрати жодного кадру (чужорідний потік, що ніколи не
    /// резинхронізується — напр. валідний на вигляд, але величезний hex-префікс, що заявляє
    /// кадр більший за все, що коли-небудь прийде) — буфер очищується цілком, а не росте вічно.
    static func parseTrackDevicesFrames(buffer: Data) -> (frames: [[ADBDevice]], remainder: Data) {
        var frames: [[ADBDevice]] = []
        var remaining = buffer
        while remaining.count >= 4 {
            let lengthPrefix = remaining.prefix(4)
            guard let lengthString = String(data: lengthPrefix, encoding: .ascii),
                  let length = Int(lengthString, radix: 16)
            else {
                // Невалідний (не-hex) префікс — відкидаємо 1 байт і пробуємо ресинхронізуватись
                // з наступної позиції, замість застрягання на місці.
                remaining = remaining.dropFirst()
                continue
            }
            guard remaining.count >= 4 + length else { break } // кадр розрізаний між чанками
            let payloadStart = remaining.index(remaining.startIndex, offsetBy: 4)
            let payloadEnd = remaining.index(payloadStart, offsetBy: length)
            let payload = String(decoding: remaining[payloadStart..<payloadEnd], as: UTF8.self)
            frames.append(Self.parseDevices(payload))
            remaining = remaining[payloadEnd...]
        }
        if remaining.count > 64 * 1024 {
            remaining = Data()
        }
        return (frames, Data(remaining))
    }

    public static func parseDevices(_ output: String) -> [ADBDevice] {
        var devices: [ADBDevice] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") { continue }
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens[0]
            let state: ADBDevice.State
            switch tokens[1] {
            case "device": state = .ready
            case "unauthorized": state = .unauthorized
            case "offline": state = .offline
            default: state = .other(tokens[1])
            }
            let model = tokens.first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            devices.append(ADBDevice(serial: serial, state: state, model: model))
        }
        return devices
    }

    /// `adb -s SERIAL wait-for-device`: блокується, доки adb-сервер знову не побачить пристрій
    /// (обрив кабеля/висмикування посеред pull — B2). Exit 0 = пристрій готовий; якщо не
    /// повернувся за `timeout` — ProcessRunner сам кидає ADBError.timeout, викликач (TransferEngine)
    /// трактує це як провал цієї спроби докачки, не як фатальний збій усього перенесення.
    /// onSpawn реєструє Process, щоб cancel() міг перервати очікування, а не чекати весь timeout.
    public func waitForDevice(
        _ serial: String,
        timeout: TimeInterval,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws {
        let result = try await run(["-s", serial, "wait-for-device"], timeout: timeout, onSpawn: onSpawn)
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(command: "adb wait-for-device", code: result.exitCode, stderr: result.err)
        }
    }
}
