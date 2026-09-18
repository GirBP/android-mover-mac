import Foundation

/// Потокобезпечний накопичувач байтів одного пайпа (stdout чи stderr) — заповнюється чанками
/// з readabilityHandler, можливо конкурентно з читанням ІНШОГО пайпа (не цього самого).
/// 2.8: internal (не private) — потрібен і тут (run()), і в ProcessRunner+Stream.swift (stream()).
final class ChunkAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

public enum ProcessRunner {
    /// Байт-у-байт C-рядок з UTF8 Swift String — БЕЗ жодного проходу через
    /// `fileSystemRepresentation`/`URL`/`FileManager`, тому жодної unicode-нормалізації. Це і є
    /// корінь фіксу: `Foundation.Process` на Darwin для `arguments`/`environment` внутрішньо йде
    /// саме через filesystem-representation і мовчки НФД-декомпонує канонічно-композиційні
    /// символи в дочірньому процесі (підтверджено ізольовано: `Process(arguments: ["й"])`
    /// дитина бачить "и"+U+0306, не "й"). `Array(string.utf8)` (як і `String.withCString`,
    /// використаний нижче для самого шляху виконуваного файла) віддає РІВНО ті байти, що
    /// зберігає Swift String — ніякої decomposition-логіки тут узагалі немає.
    private static func byteExactCString(_ string: String) -> UnsafeMutablePointer<CChar> {
        let bytes = Array(string.utf8)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
        for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
        pointer[bytes.count] = 0
        return pointer
    }

    /// NULL-термінований argv/envp з масиву C-рядків, виділених `byteExactCString`. Викликач
    /// відповідає за звільнення (`freeCStringArray`) ПІСЛЯ того, як `posix_spawn` повернувся
    /// (POSIX гарантує, що posix_spawn синхронно скопіював вміст до породження дитини).
    private static func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = strings.map { byteExactCString($0) }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array where pointer != nil {
            free(pointer)
        }
    }

    /// `pipe(2)` — пара дескрипторів (читання, запису) чи `nil` при провалі (виклик перевіряє
    /// `errno` одразу після).
    private static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
        guard rc == 0 else { return nil }
        return (fds[0], fds[1])
    }

    /// Розбирає статус `waitpid`: нормальний вихід → код виходу (еквівалент WEXITSTATUS);
    /// вбитий сигналом → 128+сигнал (конвенція shell/Unix, задокументована тут же — викликачі
    /// на цей код не покладаються, лише на `== 0`); інакше (STOPPED тощо — не мав би статись
    /// після блокуючого `waitpid` без `WUNTRACED`) → -1. Ручний розбір біт замість
    /// WIFEXITED/WEXITSTATUS: Swift НЕ імпортує функцієподібні C-макроси sys/wait.h
    /// ("function like macros not supported" — підтверджено спробою компіляції).
    /// 2.8: internal (не private) — потрібен і тут (run()), і в ProcessRunner+Stream.swift (stream()).
    static func decodeExitCode(_ status: Int32) -> Int32 {
        let low7Bits = status & 0x7f
        if low7Bits == 0 {
            return (status >> 8) & 0xff
        } else if low7Bits != 0x7f {
            return 128 + low7Bits
        }
        return -1
    }

    /// Спородженний процес одразу після успішного `posix_spawn`: `ChildProcess`-дескриптор і
    /// живі `FileHandle`-и НАШИХ (батьківських) read-кінців обох пайпів stdout/stderr.
    /// 2.8: internal (не private) — повертається з spawnChild() і споживається і тут (run()),
    /// і в ProcessRunner+Stream.swift (stream()).
    struct SpawnedChild {
        let child: ChildProcess
        let outHandle: FileHandle
        let errHandle: FileHandle
    }

    /// 2.4/2.8: спільний "хребет" `posix_spawn` — той самий код (argv/envp байт-у-байт, пайпи,
    /// file_actions/attr із CLOEXEC+SETSIGDEF+SETSIGMASK), яким користуються і `run` (акумулює
    /// один `ProcessResult`), і `stream` (ProcessRunner+Stream.swift; довгоживучий процес,
    /// стрімить stdout чанками) — щоб не дублювати його один в одного. internal (не private):
    /// `stream()` викликає його з ІНШОГО файлу. Викликається СИНХРОННО у фоновій черзі
    /// викликача (`run`/`stream` самі відповідають за DispatchQueue.global()) — сама функція
    /// нічого не диспетчерізує.
    static func spawnChild(
        executable: String,
        arguments: [String],
        environment: [String: String]?
    ) throws -> SpawnedChild {
        // 1. argv/envp — байт-у-байт (byteExactCString), звільняються в кінці незалежно
        //    від того, яким шляхом функція завершиться нижче.
        let argv = makeCStringArray([executable] + arguments)
        // Оточення: як і раніше (`process.environment = nil` за відсутності override
        // успадковувало поточне) — базою завжди служить ProcessInfo.processInfo.environment
        // (сама по собі байт-у-байт з реального environ — перевірено ізольовано, вона НЕ
        // йде через filesystem-representation), зверху — override, якщо є.
        var envDict = ProcessInfo.processInfo.environment
        if let environment { envDict.merge(environment) { _, new in new } }
        let envp = makeCStringArray(envDict.map { "\($0.key)=\($0.value)" })
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        // 2. Пайпи stdout/stderr (stdin — окремо, нижче, через file_actions/addopen).
        guard let outPipe = makePipe() else {
            throw ProcessSpawnError(code: errno, executable: executable)
        }
        guard let errPipe = makePipe() else {
            close(outPipe.read); close(outPipe.write)
            throw ProcessSpawnError(code: errno, executable: executable)
        }

        // 3. file_actions: stdin ← /dev/null, stdout/stderr ← write-кінці пайпів вище.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.write, 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.write, 2)

        // 4. attr: POSIX_SPAWN_CLOEXEC_DEFAULT (Darwin-розширення) — дитина успадковує
        //    ЛИШЕ дескриптори, явно продубльовані вище (0/1/2), решта (у т.ч. read-кінці
        //    обох пайпів) закриваються автоматично, без ручного перебору. SETSIGDEF +
        //    SETSIGMASK — скидає диспозиції сигналів і маску до дефолту: інакше дитина
        //    могла б успадкувати заблокований SIGTERM від потоку GCD, що спавнить, і
        //    cancel()/idle-timeout нижче переставали б діяти.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        var fullSignalMask = sigset_t()
        sigfillset(&fullSignalMask)
        posix_spawnattr_setsigdefault(&attr, &fullSignalMask)
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        posix_spawnattr_setsigmask(&attr, &emptySignalMask)
        posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)

        // Батьківські write-кінці більше не потрібні і МУСЯТЬ закритись тут, а не пізніше:
        // якщо наш власний дескриптор лишиться відкритим, пайп ніколи не віддасть EOF
        // читачу нижче, навіть коли дитина вже давно завершилась.
        close(outPipe.write)
        close(errPipe.write)

        guard spawnResult == 0 else {
            close(outPipe.read)
            close(errPipe.read)
            throw ProcessSpawnError(code: spawnResult, executable: executable)
        }

        // FileHandle-и МУСЯТЬ жити доти, доки живе SpawnedChild: .readabilityHandler НЕ
        // тримає власний FileHandle живим сам по собі — якби FileHandle був лише локальною
        // змінною, ARC міг би звільнити його одразу, знявши dispatch-source ДО EOF (той самий
        // баг, що й раніше документований нижче в run() — тепер актуальний і для stream()).
        let outHandle = FileHandle(fileDescriptor: outPipe.read, closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errPipe.read, closeOnDealloc: true)
        let child = ChildProcess(pid: pid)
        // 6: реєстр-бекстоп (ChildProcessRegistry.swift) — єдина точка спавну і для run(), і
        // для stream(), тож реєструє все без винятку; markReaped() знімає себе сама.
        ChildProcessRegistry.shared.register(child)
        return SpawnedChild(child: child, outHandle: outHandle, errHandle: errHandle)
    }

    /// 6: викликається з App-таргету (AppDelegate: SIGTERM/SIGINT-обробник,
    /// `applicationWillTerminate`) — ескалює (SIGTERM→3с→SIGKILL) УСІ ще живі дочірні процеси,
    /// попри те, що сам App-таргут не тримає жодного `ChildProcess` напряму (той живе лише
    /// всередині DeviceStore/TransferEngine/PushEngine-замикань). Без цього виклику дочірні
    /// adb-процеси (напр. `adb track-devices`) лишаються сиротами після SIGTERM/SIGINT/kill
    /// самого додатка — стандартна Unix-поведінка, сигнал батькові не каскадується сам.
    public static func terminateAllChildren() {
        ChildProcessRegistry.shared.terminateAll()
    }

    /// Запускає процес через `posix_spawn` (НЕ `Foundation.Process` — див. `byteExactCString`
    /// вище), читає обидва пайпи ЧАНКАМИ через readabilityHandler в окремих чергах (без
    /// deadlock на великих виводах — обидва пайпи дренуються паралельно й асинхронно, дитина
    /// ніколи не блокується на заповненому пайпі), і віддає `ChildProcess` через onSpawn для
    /// скасування.
    ///
    /// `timeout` — це IDLE-таймаут (пауза БЕЗ виводу), НЕ загальна тривалість команди: кожен
    /// отриманий чанк (stdout чи stderr) переносить дедлайн на `timeout` секунд наперед. Команда,
    /// що стабільно щось друкує (напр. рекурсивний find на 50k файлів), може тривати як завгодно
    /// довго; обривається лише та, що замовкла — жодного виводу довше за `timeout`. Якщо дедлайн
    /// настав — процес убивається (SIGTERM → 3 с потому, якщо ще живий, SIGKILL) і кидається
    /// ADBError.timeout, як і раніше.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        onSpawn: (@Sendable (ChildProcess) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let spawned: SpawnedChild
                do {
                    spawned = try spawnChild(executable: executable, arguments: arguments, environment: environment)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let child = spawned.child
                onSpawn?(child)

                let timedOut = LockedFlag()
                // Дедлайн — один спільний стан, що його рухає вперед КОЖЕН отриманий чанк з
                // будь-якого пайпа; один таймер-цикл нижче лише читає й порівнює з "зараз".
                let deadline = LockedBox<Date>()
                var timerSource: DispatchSourceTimer?
                if let timeout {
                    deadline.value = Date().addingTimeInterval(timeout)
                    // Перевіряємо частіше за сам таймаут, щоб не проґавити дедлайн надовго —
                    // але не частіше за 20 разів на секунду, це лише сторожовий цикл, не лічильник.
                    let checkInterval = max(0.05, min(timeout / 4, 0.5))
                    let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                    source.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
                    source.setEventHandler {
                        guard let current = deadline.value, Date() >= current else { return }
                        // Рацо-фікс: перевіряємо isRunning ПЕРШИМ, до ескалації. Якщо дитина вже
                        // завершилась (напр. рівно на дедлайні) — це НЕ таймаут: старий порядок
                        // (спершу позначити timedOut, лише ПОТІМ isRunning) міг позначити
                        // timedOut=true й для процесу, що встиг успішно завершитись саме в цю
                        // мить, хибно перетворюючи вдалий прогін на ADBError.timeout.
                        guard child.isRunning else { return }
                        guard timedOut.trySet() else { return }
                        // 2.3: одноразова ескалація (SIGTERM→3с→SIGKILL) тепер живе на самому
                        // ChildProcess — idempotent попри паралельну гонку з cancel() через
                        // onSpawn/CancellationController.
                        child.terminateWithEscalation()
                    }
                    source.resume()
                    timerSource = source
                }

                let outAccumulator = ChunkAccumulator()
                let errAccumulator = ChunkAccumulator()
                let group = DispatchGroup()

                // FileHandle-и (spawned.outHandle/errHandle) МУСЯТЬ жити доти, доки триває
                // читання — вони й живуть, як stored properties SpawnedChild, повернутого
                // spawnChild() вище, аж до кінця цієї функції (той самий інваріант, що раніше
                // документувався тут інлайново: .readabilityHandler НЕ тримає FileHandle живим
                // сам по собі — локальна змінна, звільнена ARC ДО EOF, знімає dispatch-source
                // передчасно, і group.leave() для цього пайпа ніколи не викликається —
                // group.wait() нижче зависає назавжди).
                let outHandle = spawned.outHandle
                let errHandle = spawned.errHandle

                func attach(_ handle: FileHandle, to accumulator: ChunkAccumulator) {
                    group.enter()
                    handle.readabilityHandler = { fh in
                        let chunk = fh.availableData
                        if chunk.isEmpty {
                            // EOF — пайп закрито (процес завершився чи закрив дескриптор).
                            fh.readabilityHandler = nil
                            group.leave()
                            return
                        }
                        accumulator.append(chunk)
                        if let timeout {
                            deadline.value = Date().addingTimeInterval(timeout)
                        }
                    }
                }
                attach(outHandle, to: outAccumulator)
                attach(errHandle, to: errAccumulator)

                // waitpid у фоновій черзі (та сама, що спавнить — блокує ЇЇ, не readabilityHandler-и
                // пайпів, які крутяться на власних internal dispatch-чергах) — той самий патерн,
                // що раніше був process.waitUntilExit().
                var status: Int32 = 0
                waitpid(child.pid, &status, 0)
                let exitCode = decodeExitCode(status)
                child.markReaped(exitCode: exitCode)

                group.wait()
                timerSource?.cancel()

                if timedOut.isSet {
                    continuation.resume(throwing: ADBError.timeout(arguments.joined(separator: " ")))
                    return
                }
                continuation.resume(returning: ProcessResult(
                    stdout: outAccumulator.data, stderr: errAccumulator.data, exitCode: exitCode
                ))
            }
        }
    }
}
