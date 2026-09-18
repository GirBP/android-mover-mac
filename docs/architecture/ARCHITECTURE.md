# ARCHITECTURE

Android Mover — SwiftUI + SPM (macOS 14+), два таргети: `AndroidMoverCore` (без UI,
Swift 6 strict, юніт-тестований) і `AndroidMover` (SwiftUI, з 2.5 теж Swift 6 strict).
Жодна зовнішня залежність — увесь транспорт іде через системний `adb`.

## Шари

```
ProcessRunner / ChildProcess   (posix_spawn, idle-timeout, SIGTERM→3с→SIGKILL)
        ↓
ADBClient                      (сентинел-контракт __AM_*, RemotePath, ADBError)
        │  дзеркалиться скриптом ↔ scripts/mock_adb.py
        ↓
TransferEngine / PushEngine    (CancellationController — спільна база скасування)
        ↓
5 сховищ (Sources/AndroidMover/State/)
        ↓
SwiftUI View (BrowserView, OperationSheet, OnboardingView, …)
```

**ProcessRunner/ChildProcess** — `posix_spawn`-обгортка над adb-процесом: байт-у-байт
argv/env (НЕ `Foundation.Process` — той NFD-декомпозує українські імена), idle-timeout
(годинник скидається на кожен chunk виводу), `stream()` для довгоживучих команд
(`track-devices`; фінішує лише коли ОБИДВА пайпи — stdout і stderr — віддали EOF, інакше
пізній текст stderr губився), cancel через SIGTERM→3с→SIGKILL. `ChildProcess.swift`
(процес-дескриптор), `ProcessRunner.swift` (spawnChild/run), `ProcessRunner+Stream.swift`
(stream()) — той самий тип/поведінка, розбиті по файлах.

`ChildProcess.terminateWithEscalation()` — ЄДИНЕ джерело правди для ескалації
SIGTERM→3с→SIGKILL, idempotent (`escalationIssued` під lock, per-процес): другий і
подальші виклики — no-op, попри те, з якого з чотирьох незалежних джерел скасування
прийшов виклик (`CancellationController.cancel()`, гонка spawn-після-cancel у
`trackProcess`, idle-таймаут `ProcessRunner.run`, `onTermination` у
`ProcessRunner.stream`). Раніше кожне з цих чотирьох місць дублювало `terminate() +
DispatchQueue.asyncAfter(3с) { forceKill() }` окремо, кожне зі своїм прапорцем
одноразовості — тепер лише `child.terminateWithEscalation()`.

**ADBClient** — один клас-фасад над усіма adb-командами. Кожна shell-операція друкує
сентинел `__AM_*` як ПЕРШИЙ РЯДОК виводу (`ADBClient.firstLine`) — успіх/провал
розрізняється по ньому, а не по exit-коду (adb сам завжди повертає 0, доки не впав
процес). Шляхи йдуть через `RemotePath` (`shellQuote`, `normalized`, `isUnsafeToDelete`,
`isAllowedPushTarget`) — порівняння/квотинг лише на `unicodeScalars`, бо
`String.split`/`replacingOccurrences` працюють по grapheme-кластерах і ламають
комбіновані символи (й/ї + модифікатор). `ADBClient.swift` (ядро: властивості/init/
discover/run/devices), `ADBClient+TrackDevices.swift` (`trackDevices()` + `parseTrack-
DevicesFrames` — невалідний hex-префікс резинхронізується побайтово, а не зупиняє розбір
назавжди; запобіжник на >64 КБ буфера без жодного розібраного кадру + `waitForDevice`),
`ADBClient+Listing.swift` (лістинг/рекурсивний перелік/pull), `ADBClient+FileOps.swift`
(delete/mkdir/move/rename/push/remoteExists/statMTimes/storageInfo/rescan) — той самий
тип, той самий контракт `__AM_*`, розбиті по файлах.

**TransferEngine / PushEngine** — рушії high-level операцій (рахує → тягне/штовхає →
верифікує → (move) видаляє). Обидва успадковують скасування від
`CancellationController` (`CancellableADBOperation.swift`): `trackProcess` реєструє
щойно спородженний adb-процес, `cancel()` → `ChildProcess.terminateWithEscalation()` —
одноразовий (idempotent, дивись вище) SIGTERM→3с→SIGKILL, з закритою гонкою spawn-після-
cancel (якщо `cancel()` викликали до `trackProcess`, щойно зареєстрований процес
вбивається негайно). `TransferEngine.swift` (ядро: `transfer`/`transferOne`),
`TransferEngine+Resume.swift` (докачка: `pullWholeEntry`/`resumeMissing`/
`finishAfterPull`/`sleepCancellably`), `TransferEngine+Verify.swift` (верифікація/дати/
колізії/статичні допоміжні) — той самий тип, розбитий по файлах.

**5 сховищ** (`Sources/AndroidMover/State/`, кожне `@MainActor @Observable`, 2.1) —
композиція, не спадкування; кожне тримає СИЛЬНЕ однонапрямне посилання лише на те, що
йому реально треба (граф без циклів):

```
DeviceStore  ←  BrowserStore  ←  TransferCoordinator
                     ↑                    ↑
                     └──────── PreviewStore
                     └──────── FileActions ──→ TransferCoordinator (appendHistory)
```

- `DeviceStore` — adb-шлях, встановлення, `stage`, список пристроїв через
  `ADBClient.trackDevices()` (один довгоживучий Task, а не поллінг `adb devices`
  кожні 2.5 с; модель пристрою кадру track-devices завжди nil — довантажується раз на
  serial через `devices()`, чекається ІНЛАЙН перед публікацією кадру, щоб displayName не
  "блимав" serial→модель, і кешується). Довгоживучий `trackTask` захоплює `self` СЛАБО і
  зв'язує в сильний локальний лише на момент застосування ОДНОГО кадру (`guard let self`
  усередині `for try await frame in ...`), а не на весь час стріму — інакше `self`
  лишався б живим, доки стрім жує кадри (практично вічно), і `deinit` ніколи не
  спрацьовував би. Кадри, що приходять, доки `isOperationActive()` (== `transfers.transfer
  != nil`, задає AppState) каже true, НЕ публікуються одразу — кладуться в `pendingFrame`
  (stage не мав переключатись на `.noDevice` посеред pull/resume, TransferSheet лишається
  відкритим, докачка сама чекає повернення пристрою всередині TransferEngine); `flushPendingFrame()`
  публікує найсвіжіший накопичений кадр, коли `TransferCoordinator.onOperationEnded`
  сигналізує кінець операції.
- `BrowserStore` — навігація/лістинг/сортування/фільтр/вільне місце; власний поллер
  (2.5 с, той самий weak-self-per-iteration патерн, що `DeviceStore.trackTask`) лише для
  «чи змінився каталог», реагує на зміну пристрою через
  `deviceWasExplicitlySelected()`/`devicesContextDidChange(...)`, які викликає
  DeviceStore через слабко захоплені замикання (без власного `adb devices`).
  `isOperationActive` тут — ЛИШЕ `transfer != nil` (push НЕ блокує лістинг/storageInfo).
- `TransferCoordinator` (не `OperationQueue` — конфлікт імені з `Foundation`) — черга
  copy/move/push, `destination`, історія операцій (`HistoryStore`).
- `PreviewStore` — Quick Look, мініатюри (`ThumbnailCache`), кеші (`previewCacheRoot`,
  `dragCacheRoot`).
- `FileActions` — видалити/перейменувати/нова тека; дописує в історію через
  `transfers.appendHistory(...)`.

`AppState` — тонкий композитор: конструює 5 сховищ і зв'язує їх замиканнями (без
retain-циклів: `[weak browser]`/`[weak transfers]` там, де сховище нижче за графом
мусило б тримати те, що вже тримає його самого).

## Інваріанти (не ламати)

- **Видалення лише після verify.** Move завжди: pull → перевірка розмірів/дат → лише
  ТОДІ `rm` на телефоні. Ніколи не видаляти до підтвердженої копії.
- **Cancel-ескалація.** SIGTERM → 3с очікування → SIGKILL, одноразово — ЄДИНЕ джерело
  правди: `ChildProcess.terminateWithEscalation()` (лічильник під `NSLock`, не
  `LockedFlag`). Не дублювати `terminate() + asyncAfter(3с) { forceKill() }` окремо в
  жодному новому місці — завжди через `child.terminateWithEscalation()`, попри те, з
  якого джерела прийшло скасування (`CancellationController`, idle-таймаут, onTermination
  стріму).
- **Байт-у-байт шляхи.** `posix_spawn`, не `Foundation.Process` (NFD-декомпозує й/ї/é;
  APFS-мок цього не покаже — він нормалізаційно-нечутливий).
- **unicodeScalars для шляхів/квотингу**, ніколи grapheme-рівень (`Character`/`split`).
- **Мок дзеркалить кожен shell-скрипт.** `scripts/mock_adb.py` — той самий if/elif-
  диспетчер, у ТОМУ Ж ПОРЯДКУ гілок (підрядок однієї гілки може збігтися з іншою).
- **Swift 6 strict в обох таргетах** (з 2.5): `@MainActor`-ізоляція сховищ,
  `nonisolated(unsafe)` + `@ObservationIgnored` лише для `Task`-хендлів, які deinit
  мусить скасувати синхронно поза MainActor.

## Як додати нову adb-операцію — 3 місця

Приклад: `ADBClient.makeDirectory` (спрощено).

1. **`Sources/AndroidMoverCore/ADB/ADBClient.swift`** — новий метод: скрипт друкує
   `__AM_*_FAILED__` першим рядком при провалі, `Self.firstLine(of:)` його ловить і кидає
   `ADBError`. Приклад — `makeDirectory`: `mkdir -- "$AM_P" 2>/dev/null; if [ ! -d "$AM_P" ];
   then echo __AM_MKDIR_FAILED__; fi; exit 0`, далі `if firstLine == "__AM_MKDIR_FAILED__"
   { throw ADBError.mkdirFailed(p) }`.
2. **`scripts/mock_adb.py`** — дзеркальна гілка в тому самому if/elif-диспетчері
   (`elif "mkdir --" in script: do_mkdir(am_p)`), яка відтворює і успіх, і сентинел-провал.
3. **`Tests/AndroidMoverCoreTests/EngineTests.swift`** — тест на обидва шляхи (успіх +
   `mkdirFailed`), проти мока (`testMakeDirectoryAndListIt`).

Якщо операція викликається з UI — четверте місце: відповідне сховище (`FileActions` для
дій з файлами, `TransferCoordinator` для копіювання/переміщення/push).

## Потоки скасування

Кнопка «Скасувати» у `OperationSheet` → `session.cancel()` (`TransferSession`/
`PushSession`, `Sources/AndroidMover/State/TransferCoordinator.swift`) →
`engine.cancel()` → `CancellationController.cancel()` →
`ChildProcess.terminateWithEscalation()` — SIGTERM поточному зареєстрованому
adb-процесу, SIGKILL через 3с якщо не відреагував (idempotent — той самий шлях, яким
ідуть idle-таймаут `ProcessRunner.run` і `onTermination` `ProcessRunner.stream`).
`DeviceStore`/`BrowserStore` скасовують СВОЇ довгоживучі Task (track-devices стрім,
поллер листингу) у власному `deinit`, коли вікно (і його `AppState`) звільняється —
обидва Task захоплюють `self` слабо і зв'язують у сильний локальний лише на момент
застосування одного кадру/тіку, ніколи на весь час очікування наступного.

## Кеші та історія

Preview-кеш і drag-кеш (`PreviewStore.previewCacheRoot`/`dragCacheRoot`) — теки в
`FileManager.temporaryDirectory`, чистяться при кожному `AppState.bootstrap()`.
Мініатюри (`ThumbnailCache`) — лише in-memory, той самий ключ (шлях|розмір|mtime),
нуль додаткового трафіку з телефона. Історія операцій (`HistoryStore`) — JSON Lines
у Application Support, спільна для всіх вікон; власник — `TransferCoordinator.historyStore`.
