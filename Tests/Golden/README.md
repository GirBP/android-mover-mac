# Tests/Golden — golden-транскрипти реального adb

Ця тека — знімки реального виводу shell-команд, які генерує `ADBClient`
(`Sources/AndroidMoverCore/ADB/ADBClient.swift`), знятого проти справжнього Android-телефона.
`scripts/mock_adb.py` емулює цей самий контракт програмно (`EngineTests`, `AM_TEST_ADB=mock`,
CI) — golden-файли тут потрібні, щоб періодично звіряти, що емуляція mock'а досі відповідає
поведінці справжнього `toybox`/`adb` на реальному пристрої (парсинг `stat -c`, `find -exec +`,
`stat -f`, вивід `adb push`), а не лише припущенням з коду.

## Як з'являються файли

`scripts/e2e_device.sh`:
1. Створює на телефоні `/sdcard/AndroidMoverE2E/golden` з файлами-приманками — кирилиця
   з пробілом (`Фото 1.jpg`), апостроф (`it's.txt`), підтека з окремою датою через
   `toybox touch -t` (`підтека з датами/файл.txt`).
2. Ганяє ті самі shell-скрипти, що складає сам `ADBClient` (дослівно скопійовані в
   e2e-скрипт із відповідних методів), і зберігає stdout у файли нижче.
3. Прибирає `/sdcard/AndroidMoverE2E` з телефона наприкінці (навіть при провалі — `trap … EXIT`).

Файли з'являються лише після реального прогону `scripts/e2e_device.sh` з підключеним
телефоном — до того в теці може не бути жодного `*.txt`, це очікувано.

## Файли

| Файл | Метод ADBClient | Скрипт (`find`/`stat`) |
|---|---|---|
| `listing.txt` | `listDirectory` | `find -mindepth 1 -maxdepth 1 -exec stat -c '%F\|%s\|%Y\|%n'` |
| `recursive_files.txt` | `recursiveFiles` | `find -type f -exec stat -c '%s\|%n'` |
| `recursive_dirs.txt` | `recursiveDirs` | `find -type d -exec stat -c '%Y\|%n'` |
| `stat_mtimes.txt` | `statMTimes` | `find -exec stat -c '%Y\|%n'` (без `-type`) |
| `storage_info.txt` | `storageInfo` | `stat -f -c '%a\|%b\|%S'` |
| `push.txt` | `push` | вивід самого `adb push` (не shell-скрипт) |

**`md5sum.txt`:** checksum-верифікація (`ADBClient.checksums`) поки без golden-кроку.
З'явиться разом з `amctl capture`.

## Як оновлювати

Просто перезапусти `scripts/e2e_device.sh` з підключеним і авторизованим телефоном — файли
перезапишуться. Перед комітом глянь `git diff Tests/Golden/` і переконайся, що зміни
пояснювані (нова версія Android/toybox, а не випадкова помилка в e2e-скрипті).

Формат — сирий stdout adb (може містити маркери `__AM_MISSING__`/`__AM_NOT_A_DIR__`/
`__AM_NO_TOYBOX__` замість листингу — так само, як бачить їх `ADBClient.firstLine`).

## `amctl capture`

Транскрипти пише сам застосунковий будівник argv (`RecordingTransport`), без ручного
копіювання скриптів у bash:

```bash
swift build && .build/debug/amctl capture --out Tests/Golden/nothing-a063.jsonl --root /sdcard/DCIM
```

Формат — JSON Lines (`TranscriptRecord`: argv, stdout/stderr у base64, код виходу). Відтворення —
`TranscriptTransport` (див. `TransportTests`). `e2e_device.sh` лишається до появи перших golden.
