import Foundation
import XCTest
@testable import AndroidMoverCore

/// Тести самого ProcessRunner (posix_spawn-рушій, не adb/mock) — окремо від EngineTests, які
/// перевіряють поведінку крізь ADBClient/mock_adb.py. Головне тут: байт-у-байт передача
/// аргументів і оточення (`Foundation.Process` на Darwin мовчки NFD-декомпонує "й"/"ї"/"é"
/// тощо через fileSystemRepresentation, посилаючи дитині "и"+U+0306 замість "й", а
/// ProcessRunner — ні), коректний exitCode/stderr, ідле-таймаут, що й справді вбиває процес,
/// чесна помилка на неіснучому виконуваному файлі і скасування через onSpawn (той самий
/// гачок, яким TransferEngine/PushEngine/RemoteFileTransfer реалізують cancel()).
final class ProcessRunnerTests: XCTestCase {

    /// U+0439 CYRILLIC SMALL LETTER SHORT I, прекомпонована форма ("й" одним кодпойнтом) —
    /// саме той символ, що фазз-тест EngineTests.FuzzNames свідомо виключає з алфавіту через
    /// цей самий ризик нормалізації. Явний `\u{0439}` замість друкованого літерала в коді —
    /// гарантія, що джерело тесту само не проковтнуло якусь редакторську нормалізацію.
    private static let precomposedI = "\u{0439}"

    // MARK: - Байт-у-байт аргументи й оточення

    func testArgumentsArePassedByteExact() async throws {
        // /bin/sh -c 'printf %s "$1" | xxd -p' _ "й" → дитина мусить надрукувати рівно d0b9
        // (UTF-8 прекомпонованого U+0439), не d0b8cc86 (и+U+0306 — НФД-декомпозиція, якою
        // страждає `Foundation.Process`).
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$1\" | xxd -p", "_", Self.precomposedI]
        )
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.err)")
        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "d0b9")
    }

    func testEnvironmentIsPassedByteExact() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$AM_P\" | xxd -p"],
            environment: ["AM_P": Self.precomposedI]
        )
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.err)")
        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "d0b9")
    }

    // MARK: - exitCode / stderr

    func testExitCodeAndStderr() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo err >&2; exit 3"]
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.err.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    // MARK: - Ідле-таймаут

    func testIdleTimeoutKillsSilentProcess() async throws {
        let capturedChild = LockedBox<ChildProcess>()
        let start = Date()
        do {
            _ = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                timeout: 0.5,
                onSpawn: { child in capturedChild.value = child }
            )
            XCTFail("очікувався ADBError.timeout")
        } catch let error as ADBError {
            guard case .timeout = error else {
                XCTFail("очікувався .timeout, отримано \(error)")
                return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(elapsed, 2.5, "ідле-таймаут мав спрацювати швидко (\(elapsed) с)")

        guard let child = capturedChild.value else {
            XCTFail("onSpawn не викликався")
            return
        }
        // ProcessRunner мусив реально вбити процес (SIGTERM), не лише кинути помилку нагору.
        XCTAssertFalse(child.isRunning, "процес мав бути мертвим після ідле-таймауту")
    }

    // MARK: - Провал самого spawn

    func testSpawnMissingExecutableThrows() async throws {
        do {
            _ = try await ProcessRunner.run(
                executable: "/no/such/executable-\(UUID().uuidString)",
                arguments: []
            )
            XCTFail("очікувалась помилка запуску неіснуючого виконуваного файла")
        } catch {
            // Тип помилки не критичний для викликачів (ADBInstaller/ADBClient show
            // .localizedDescription без розбору на конкретний case) — головне, що throw
            // стався, а не мовчки повернувся якийсь ProcessResult.
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    // MARK: - Скасування через onSpawn

    func testCancelViaOnSpawnTerminates() async throws {
        let capturedChild = LockedBox<ChildProcess>()
        let start = Date()
        // Без timeout — скасування має спрацювати через onSpawn (той самий гачок, яким
        // TransferEngine.trackProcess/PushEngine.trackProcess/RemoteFileTransfer реєструють
        // процес для cancel()), а не через ідле-таймаут.
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 10"],
            onSpawn: { child in
                capturedChild.value = child
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    child.terminate()
                }
            }
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(elapsed, 3.0, "terminate() через onSpawn мав перервати sleep 10 швидко")
        XCTAssertNotEqual(result.exitCode, 0, "процес, вбитий SIGTERM, не мав завершитись кодом 0")

        guard let child = capturedChild.value else {
            XCTFail("onSpawn не викликався")
            return
        }
        XCTAssertFalse(child.isRunning)
    }

    // MARK: - Сигнали після reap — no-op (PID міг бути перевикористаний ядром)

    /// Без перевірки `reaped` terminate()/forceKill() слали б kill(pid, ...) і після того, як
    /// ProcessRunner уже зробив власний waitpid — а до цього моменту `pid` (число) могло
    /// встигнути перевикористатись ядром для зовсім іншого процесу (вузьке мікровікно між
    /// markReaped у ProcessRunner і `currentProcess.value = nil` у
    /// TransferEngine/PushEngine/RemoteFileTransfer). ChildProcess мусить після reap
    /// перетворювати обидва методи на no-op — сигнал більше нікуди не йде.
    func testSignalsAfterReapAreNoOps() async throws {
        let capturedChild = LockedBox<ChildProcess>()
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            onSpawn: { child in capturedChild.value = child }
        )
        XCTAssertEqual(result.exitCode, 0)

        guard let child = capturedChild.value else {
            XCTFail("onSpawn не викликався")
            return
        }
        // Процес уже реапнутий (run() повернувся) — обидва виклики мають бути тихими no-op:
        // ні падіння, ні (теоретично, якби PID перевикористався) удару по чужому процесу.
        child.terminate()
        child.forceKill()

        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationStatus, 0)
    }

    // MARK: - Одноразова ескалація на ChildProcess

    /// Два виклики `terminateWithEscalation()` на один процес мають послати рівно один
    /// SIGTERM — другий виклик мусить бути тихим no-op (idempotent, `escalationIssued` під
    /// lock). `trap ... TERM; while :; do :; done` рахує самі отримані сигнали: якщо б SIGTERM
    /// прийшов двічі, trap надрукував би "T" двічі, перш ніж встиг exit 0 після першого.
    /// Зайнятий цикл (`while :; do :; done`), а не `sleep N` — bash перевіряє pending-сигнали
    /// між виконанням простих команд інтерпретатора значно частіше й надійніше, ніж переривання
    /// блокуючого `wait4()` на дочірньому `sleep`-процесі (емпірично: `sleep`-варіант дає
    /// помітний відсоток пропущених/запізнілих сигналів навіть при ручному запуску тим самим
    /// bash поза цим тестом).
    func testTerminateWithEscalationIsIdempotent() async throws {
        let capturedChild = LockedBox<ChildProcess>()
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap 'echo T; exit 0' TERM; while :; do :; done"],
            onSpawn: { child in
                capturedChild.value = child
                // Дай shell реально встановити trap і зайти в цикл, перш ніж слати сигнал.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    child.terminateWithEscalation()
                    child.terminateWithEscalation()
                }
            }
        )
        XCTAssertEqual(result.exitCode, 0, "trap мав перехопити SIGTERM і вийти кодом 0; stderr: \(result.err)")
        XCTAssertEqual(
            result.out.trimmingCharacters(in: .whitespacesAndNewlines), "T",
            "рівно одне 'T' — другий terminateWithEscalation() мав бути no-op"
        )
    }

    // MARK: - stream() — довгоживучий процес, stdout чанками

    func testStreamDeliversChunksAndFinishes() async throws {
        var chunks: [Data] = []
        for try await chunk in ProcessRunner.stream(
            executable: "/bin/sh",
            arguments: ["-c", "echo a; sleep 0.2; echo b"]
        ) {
            chunks.append(chunk)
        }
        XCTAssertFalse(chunks.isEmpty, "stream() мав віддати хоча б один чанк")
        let combined = chunks.reduce(Data(), +)
        XCTAssertEqual(String(decoding: combined, as: UTF8.self), "a\nb\n")
    }

    func testStreamCancellationKillsProcess() async throws {
        let capturedChild = LockedBox<ChildProcess>()
        let task = Task {
            for try await _ in ProcessRunner.stream(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 10"],
                onSpawn: { child in capturedChild.value = child }
            ) {
                // "sleep 10" нічого не пише в stdout — цикл просто чекає на EOF чи скасування.
            }
        }

        // Дай процесу реально спородитись, перш ніж скасовувати Task.
        let spawnDeadline = Date().addingTimeInterval(2)
        while capturedChild.value == nil, Date() < spawnDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let child = capturedChild.value else {
            XCTFail("onSpawn не викликався")
            task.cancel()
            return
        }

        let start = Date()
        task.cancel()
        _ = try? await task.value

        let deadline = Date().addingTimeInterval(3.5)
        while child.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(child.isRunning, "процес мав завершитись після скасування Task (\(elapsed) с)")
        XCTAssertLessThanOrEqual(elapsed, 3.5)
    }

    // MARK: - ChildProcessRegistry / terminateAllChildren — бекстоп проти сиріт

    /// SIGTERM/SIGINT/kill самого додатка не каскадується на дочірні adb-процеси
    /// (posix_spawn-дитина репарентиться до launchd, не гине разом із батьком — стандартна
    /// Unix-поведінка) — `ProcessRunner.terminateAllChildren()` (AppDelegate-обробник
    /// SIGTERM/SIGINT і `applicationWillTerminate`) мусить убити всі ще живі зареєстровані
    /// процеси. На відміну від testCancelViaOnSpawnTerminates (де тест сам кличе
    /// `child.terminate()` напряму) — тут навмисно термінуємо через реєстр
    /// (ChildProcessRegistry.swift), не через captured `child`, щоб довести: реєстр сам
    /// знаходить і вбиває процес без жодного явного посилання ззовні.
    func testTerminateAllChildrenKillsSpawnedProcess() async throws {
        let capturedChild = LockedBox<ChildProcess>()
        let task = Task {
            try await ProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["30"],
                onSpawn: { child in capturedChild.value = child }
            )
        }

        let spawnDeadline = Date().addingTimeInterval(2)
        while capturedChild.value == nil, Date() < spawnDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let child = capturedChild.value else {
            XCTFail("onSpawn не викликався")
            task.cancel()
            return
        }

        let start = Date()
        ProcessRunner.terminateAllChildren()

        let result = try await task.value
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(elapsed, 3.5, "SIGTERM→3с→SIGKILL ескалація мала вбити sleep 30 (\(elapsed) с)")
        XCTAssertNotEqual(result.exitCode, 0, "sleep, вбитий сигналом, не мав завершитись кодом 0")
        XCTAssertFalse(child.isRunning, "процес мав бути мертвим після terminateAllChildren()")
    }

    // MARK: - stream() фінішує лише після EOF обох пайпів (stdout і stderr)

    /// `echo out; echo err-late >&2; exit 2` — stdout закривається раніше stderr (stderr
    /// дописується вже після stdout). Без очікування EOF обох пайпів `finish(throwing:)` міг
    /// би статись одразу на EOF stdout, ще до того, як readabilityHandler stderr встиг
    /// прочитати "err-late" — помилка тоді летіла б із порожнім/неповним stderr. Повторено
    /// 20 разів:
    /// гонка між двома незалежними internal dispatch-чергами readabilityHandler-а не завжди
    /// відтворюється з першого разу.
    func testStreamWaitsForBothPipesBeforeFinishing() async throws {
        for attempt in 0..<20 {
            do {
                for try await _ in ProcessRunner.stream(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo out; echo err-late >&2; exit 2"]
                ) {
                    // Чанки stdout нецікаві тут — важлива лише фінальна помилка й її stderr.
                }
                XCTFail("спроба \(attempt): очікувалась помилка (exit 2)")
            } catch let error as ADBError {
                guard case .commandFailed(_, let code, let stderr) = error else {
                    XCTFail("спроба \(attempt): очікувався .commandFailed, отримано \(error)")
                    continue
                }
                XCTAssertEqual(code, 2, "спроба \(attempt)")
                XCTAssertTrue(
                    stderr.contains("err-late"),
                    "спроба \(attempt): stderr мав містити 'err-late', отримано: \(stderr)"
                )
            }
        }
    }
}
