import Foundation

/// Спільний стан завершення `stream()` — фінішуємо лише коли обидва пайпи (stdout і
/// stderr) віддали EOF. Обидва пайпи читаються з окремих внутрішніх dispatch-черг
/// `readabilityHandler`, і немає гарантії, що вони віддають EOF одночасно чи в якомусь
/// певному порядку. Якщо дитина дописує текст помилки в stderr (напр.
/// `echo err-late >&2; exit 2`) уже після того, як stdout закрився, фінішувати на EOF
/// самого лише stdout означало б загубити цей текст. Той з двох `readabilityHandler`-ів,
/// що дійшов до EOF другим (обидва прапорці стали true), і робить єдиний `waitpid` +
/// `finish`.
private final class StreamEOFGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outDone = false
    private var errDone = false

    /// Позначає EOF свого пайпа; повертає `true` рівно один раз на пару викликів — коли цей
    /// виклик застає обидва пайпи вже завершеними (тобто цей виклик — другий за ліком).
    func markOutEOF() -> Bool {
        lock.lock(); defer { lock.unlock() }
        outDone = true
        return outDone && errDone
    }

    func markErrEOF() -> Bool {
        lock.lock(); defer { lock.unlock() }
        errDone = true
        return outDone && errDone
    }
}

extension ProcessRunner {
    // MARK: - stream() — довгоживучий процес, stdout чанками (adb track-devices тощо)

    /// Довгоживучий процес: stdout віддається асинхронно, чанками, у міру появи — на відміну
    /// від `run()`, який чекає повного завершення і акумулює один `ProcessResult`. Призначено
    /// для процесів без природного кінця (`adb track-devices`), тому немає idle-таймауту:
    /// єдиний спосіб зупинити — скасувати `Task`, що ітерує стрім (чи саму AsyncThrowingStream-
    /// послідовність), або вбити процес напряму через `ChildProcess`, отриманий з `onSpawn`.
    ///
    /// Завершення дитини природним шляхом (закрила stdout/вийшла) фінішує стрім: exitCode == 0
    /// → без помилки; exitCode != 0 і це не наслідок нашого ж скасування — `ADBError.commandFailed`
    /// з накопиченим stderr. Скасування ітерації (`Task` скасовано, чи стрім деінікалізовано)
    /// термінує процес тим самим SIGTERM → 3 с → SIGKILL патерном, що й cancel() рушіїв — і
    /// саме тому не вважається помилкою, попри ненульовий exit-код від сигналу.
    ///
    /// Фінішує лише коли обидва пайпи (stdout і stderr) віддали EOF — `StreamEOFGate`
    /// вище; інакше пізній текст stderr (дитина ще пише в stderr після закриття stdout) міг
    /// би загубитись, не встигнувши потрапити в `ADBError.commandFailed`.
    public static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let spawned: SpawnedChild
                do {
                    spawned = try spawnChild(executable: executable, arguments: arguments, environment: environment)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let child = spawned.child
                onSpawn?(child)

                // stderr не стрімиться назовні (стрім віддає лише stdout) — накопичується
                // мовчки, лише для тексту помилки, якщо процес завершиться ненульовим кодом.
                let errAccumulator = ChunkAccumulator()
                // `true`, якщо процес термінувався через скасування (onTermination(.cancelled)),
                // а не сам по собі — тоді ненульовий exit-код (128+SIGTERM/SIGKILL) очікуваний
                // і не є помилкою: стрім фінішує чисто, без throw.
                let weCancelled = LockedFlag()
                // Обидва readabilityHandler-и (stdout і stderr, нижче) звертаються сюди —
                // фінішує рівно той, хто застав обидва пайпи вже EOF.
                let eofGate = StreamEOFGate()

                // Єдина точка фінішу стріму: викликається рівно раз, тим з двох
                // readabilityHandler-ів (stdout чи stderr), що дійшов до свого EOF другим —
                // гарантія StreamEOFGate вище. waitpid тут (а не раніше) — обидва пайпи вже
                // закриті, тож дитина напевно вже завершилась чи ось-ось завершиться.
                @Sendable func finishStream() {
                    var status: Int32 = 0
                    waitpid(child.pid, &status, 0)
                    let exitCode = decodeExitCode(status)
                    child.markReaped(exitCode: exitCode)
                    if exitCode == 0 || weCancelled.isSet {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ADBError.commandFailed(
                            command: ([executable] + arguments).joined(separator: " "),
                            code: exitCode,
                            stderr: errAccumulator.data.isEmpty
                                ? ""
                                : String(decoding: errAccumulator.data, as: UTF8.self)
                        ))
                    }
                }

                // [spawned] у обох readabilityHandler-ах нижче — навмисний, обов'язковий
                // capture: на відміну від run() (де outHandle/errHandle просто лишаються
                // локальними змінними зовнішнього синхронно-блокуючого скоупу, живого аж до
                // group.wait()), тут спороджувальний DispatchQueue.global().async-блок
                // повертається одразу після встановлення handler-ів — нічого далі не тримає
                // FileHandle-и живими (readabilityHandler не тримає власний FileHandle сам по
                // собі — той самий інваріант, що задокументований у spawnChild). Без явного
                // захоплення `spawned` тут ARC звільняє outHandle/errHandle одразу по
                // поверненню з цього блоку, знімаючи dispatch-source до EOF — стрім готовий
                // назавжди зависнути (жоден чанк, жодне finish; відтворено і полагоджено:
                // ProcessRunnerTests.testStream* висіли без цього фіксу). Кожен handler
                // captured-копію `spawned` (значення-структуру, обидва FileHandle-класи
                // всередині — той самий інстанс) звільняє через `fh.readabilityHandler = nil`
                // на своєму ж EOF — цикл тимчасовий і самостійно рветься, не витік.
                spawned.errHandle.readabilityHandler = { [spawned] fh in
                    _ = spawned
                    let chunk = fh.availableData
                    if chunk.isEmpty {
                        fh.readabilityHandler = nil
                        if eofGate.markErrEOF() { finishStream() }
                        return
                    }
                    errAccumulator.append(chunk)
                }

                continuation.onTermination = { @Sendable termination in
                    guard case .cancelled = termination else { return }
                    weCancelled.set()
                    // Одноразова ескалація живе на самому ChildProcess — idempotent попри
                    // паралельну гонку з idle-таймаутом/CancellationController.
                    child.terminateWithEscalation()
                }

                spawned.outHandle.readabilityHandler = { [spawned] fh in
                    _ = spawned
                    let chunk = fh.availableData
                    guard !chunk.isEmpty else {
                        // EOF на stdout — процес завершився (чи сам закрив дескриптор), але
                        // фінішуємо лише якщо stderr теж уже EOF (StreamEOFGate).
                        fh.readabilityHandler = nil
                        if eofGate.markOutEOF() { finishStream() }
                        return
                    }
                    continuation.yield(chunk)
                }
            }
        }
    }
}
