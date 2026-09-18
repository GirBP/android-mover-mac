#!/usr/bin/env python3
"""Mock adb для тестів AndroidMoverCore.

Реалізує рівно той контракт, який генерує ADBClient:
  adb devices -l
  adb -s SERIAL shell "AM_P='...'; <LIST|FIND|DELETE script>"
  adb -s SERIAL pull -a REMOTE LOCALDIR

Env:
  MOCK_PHONE_ROOT       — тека на Mac, що вдає /sdcard (обов'язково для shell/pull)
  MOCK_STATE            — device | unauthorized | offline | none (default: device)
  MOCK_CORRUPT_PULL     — "1": після pull обрізати перший файл (тест верифікації), безлімітно
  MOCK_FAIL_DELETE      — "1": вдавати невдале видалення
  MOCK_FAIL_PUSH        — "1": push завершується кодом 1 (B1)
  MOCK_CORRUPT_PUSH     — "1": після push обрізати перший файл навпіл (тест push-верифікації, B1)

  B2 (resume/докачка після обриву) — стан лічильників між викликами (кожен виклик mock —
  окремий процес) живе у файлі MOCK_STATE_FILE, який тест виділяє в tmp:
  MOCK_STATE_FILE       — шлях до файлу стану (простий текст "key=value" по рядках,
                          атомарний перезапис через os.replace). Без нього лічильники
                          нижче — no-op (кожен виклик поводиться як звичайний pull).
  MOCK_PULL_FAIL_COUNT  — "n": перші n УСПІШНИХ pull-викликів (будь-яких — цілого елемента чи
                          докачки одного файла) натомість копіюють ЧАСТКОВО: для теки — перший
                          файл повністю, другий обрізаний навпіл, решту не чіпають; для
                          одиночного файла — обрізаний навпіл. Пишуть у stderr adb-подібну
                          помилку обриву з'єднання і завершуються кодом 1. Лічильник
                          декрементується з кожним спрацюванням.
  MOCK_CORRUPT_PULL_COUNT — "n": перші n pull-викликів завершуються УСПІШНО (exit 0), але
                          перший файл результату обрізаний навпіл (тиха побитість — verify
                          мусить сам її зловити). Той самий ефект, що MOCK_CORRUPT_PULL, але
                          лічений і скінченний — на n+1-й виклик пул знову чистий.
  MOCK_WAIT_HANG        — "1": `adb wait-for-device` засинає на 30 с замість негайного
                          exit 0 — для тестів скасування посеред очікування (не залежних
                          від таймауту).
  MOCK_FREE_BYTES       — "n": `stat -f` звітує рівно n вільних байтів (v0.12.2, тест
                          відмови push у повний телефон).
  MOCK_ANDROID_ID / MOCK_SERIALNO — значення зонда ідентичності (v0.14.0); порожній рядок =
                          недоступно на цьому OEM (драбина DeviceIdentity падає нижче).
  MOCK_MDNS             — "1": `adb mdns check` доступний; інакше «unavailable», exit 1.
  MOCK_MDNS_SERVICES    — "name,type,host:port;…" — рядки для `adb mdns services`.
  MOCK_PAIR_CODE        — код, який приймає `adb pair` (типово 123456); інший → провал.
  MOCK_CONNECT_FAIL     — "1": `adb connect` відмовляє («failed to connect…», exit 1).
  MOCK_LOG_FILE         — шлях до файлу, куди КОЖЕН виклик mock дописує один рядок —
                          JSON-масив свого argv (без argv[0]) — тести звіряють, скільки й
                          яких саме pull-викликів сталось (докачка мусить пулити лише
                          відсутній/битий файл, не весь елемент заново).

  1.2 (ідле-таймаут ProcessRunner) — обидві ручки діють лише в do_find (гілка "-type f",
  тобто ADBClient.recursiveFiles):
  MOCK_SLOW_STREAM      — "ms": рядки результату друкуються ПО ОДНОМУ з паузою ms між ними
                          (з flush після кожного) — емулює повільний, але живий потік виводу;
                          ідле-таймаут не мусить спрацьовувати, доки паузи коротші за нього.
  MOCK_SILENT_BEFORE    — "ms": спати ms ДО першого рядка виводу — емулює завислий процес;
                          з ідле-таймаутом коротшим за ms клієнт мусить обірвати виклик.

  1.6 (chaos-mock) — діють на БУДЬ-ЯКИЙ виклик mock (shell/pull/push/devices), рахуються
  через той самий MOCK_STATE_FILE, спільний лічильник "__CALL_INDEX__":
  MOCK_DISCONNECT_ON_CALL — "n": рівно n-й ЗА ЛІКОМ виклик mock (від 1, per-процес, тобто
                          рахуючи усі попередні adb-виклики тестового сценарію, якщо вони
                          теж бачили той самий MOCK_STATE_FILE) вдає обрив з'єднання: пише
                          у stderr "error: device 'MOCK001' not found" і завершується кодом
                          1 ДО будь-якої іншої обробки; решта викликів — штатні.
  MOCK_SLOW             — "ms": пауза ms ПЕРЕД КОЖНИМ викликом mock (для таймінг-тестів;
                          не обов'язково використовувати).

  2.4 (adb track-devices, ProcessRunner.stream()) — `adb track-devices` (БЕЗ "-s SERIAL",
  на відміну від shell/pull/push/wait-for-device): друкує кадри протоколу (4 hex-символи
  довжини + payload у форматі `adb devices` без заголовка) на КОЖНУ зміну підключення:
  MOCK_TRACK_FILE       — шлях до файлу "стану" (простий текст: device|unauthorized|offline|
                          none), який тест переписує, щоб емулювати підключення/відключення.
                          Перший кадр — за вмістом файлу (чи MOCK_STATE, якщо файла ще
                          нема), далі кожні 200 мс перечитується; при ЗМІНІ вмісту — новий
                          кадр. Завершується (exit 0), коли файл видалено. Без цієї ручки —
                          один кадр за MOCK_STATE, потім `sleep 1`, exit 0.
"""
import json
import os
import shutil
import stat as statmod
import sys
import time


def log_call(argv):
    """B2: дописує один рядок (JSON-масив argv) у MOCK_LOG_FILE — якщо ручка не задана, no-op."""
    path = os.environ.get("MOCK_LOG_FILE")
    if not path:
        return
    with open(path, "a") as f:
        f.write(json.dumps(argv) + "\n")


def _state_path():
    return os.environ.get("MOCK_STATE_FILE")


def _read_state():
    path = _state_path()
    state = {}
    if not path or not os.path.exists(path):
        return state
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            state[k] = v
    return state


def _write_state(state):
    path = _state_path()
    if not path:
        return
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        for k, v in state.items():
            f.write(f"{k}={v}\n")
    os.replace(tmp, path)


def consume_counter(env_name):
    """B2: ручки MOCK_PULL_FAIL_COUNT / MOCK_CORRUPT_PULL_COUNT — файл-лічильник стану між
    викликами (кожен виклик mock — окремий процес, тому рахувати можна лише через диск).
    Перший виклик ініціалізує лічильник у MOCK_STATE_FILE значенням env-змінної, кожен
    наступний декрементує. Повертає True рівно n разів (n — значення env), потім False.
    Без MOCK_STATE_FILE ручка — свідомий no-op (інакше "порахувати" нема як, і виклик
    ризикує "спрацьовувати" вічно — небезпечний дефолт).
    """
    budget_raw = os.environ.get(env_name)
    if not budget_raw:
        return False
    path = _state_path()
    if not path:
        return False
    try:
        budget = int(budget_raw)
    except ValueError:
        return False
    if budget <= 0:
        return False
    state = _read_state()
    remaining_raw = state.get(env_name)
    if remaining_raw is None:
        remaining = budget
    else:
        try:
            remaining = int(remaining_raw)
        except ValueError:
            remaining = budget
    if remaining <= 0:
        return False
    state[env_name] = str(remaining - 1)
    _write_state(state)
    return True


def call_index_and_increment():
    """1.6: глобальний, наскрізний лічильник викликів mock (1-індексований), для
    MOCK_DISCONNECT_ON_CALL. На відміну від consume_counter (окремий бюджет на env-ім'я,
    декрементується) — це один спільний рахунок УСІХ викликів mock, що бачили той самий
    MOCK_STATE_FILE, під ключем "__CALL_INDEX__". Без MOCK_STATE_FILE — no-op (None):
    порахувати нема як, ручка, що на нього спирається, тоді теж мовчки бездіє.
    """
    path = _state_path()
    if not path:
        return None
    state = _read_state()
    try:
        idx = int(state.get("__CALL_INDEX__", "0")) + 1
    except ValueError:
        idx = 1
    state["__CALL_INDEX__"] = str(idx)
    _write_state(state)
    return idx


def phone_root():
    root = os.environ.get("MOCK_PHONE_ROOT")
    if not root:
        sys.stderr.write("mock_adb: MOCK_PHONE_ROOT is not set\n")
        sys.exit(2)
    return os.path.realpath(root)


def translate(phone_path):
    """'/sdcard/x' -> MOCK_PHONE_ROOT/x. Повертає None для шляхів поза /sdcard."""
    p = phone_path.rstrip("/") or "/"
    if p == "/sdcard":
        return phone_root()
    if p.startswith("/sdcard/"):
        return os.path.join(phone_root(), p[len("/sdcard/"):])
    return None


def parse_var(script, name):
    """Зчитує значення NAME=<shell-quoted>; ... (точна інверсія RemotePath.shellQuote)."""
    prefix = name + "="
    idx = script.find(prefix)
    if idx < 0:
        raise ValueError(f"script has no {prefix}")
    i = idx + len(prefix)
    out = []
    while i < len(script):
        c = script[i]
        if c == "'":
            j = script.index("'", i + 1)
            out.append(script[i + 1:j])
            i = j + 1
        elif script.startswith("\\'", i):
            out.append("'")
            i += 2
        elif c == ";":
            break
        else:
            raise ValueError(f"unexpected char in {name} at {i}: {c!r}")
    return "".join(out)


def parse_am_p(script):
    return parse_var(script, "AM_P")


def file_type(st):
    if statmod.S_ISLNK(st.st_mode):
        return "symbolic link"
    if statmod.S_ISDIR(st.st_mode):
        return "directory"
    if statmod.S_ISREG(st.st_mode):
        return "regular file"
    return "other"


def effective_local(script, am_p):
    """Локальний шлях + фонова (телефонна) база для друку %n.

    Емулює `AM_R=$(readlink -f ...)` зі скрипта клієнта: якщо скрипт містить readlink —
    розіменовуємо і повертаємо КАНОНІЧНУ телефонну базу (як зробив би реальний shell).
    """
    local = translate(am_p)
    base = am_p.rstrip("/") or "/"
    if local is None:
        return None, base
    if "readlink -f" in script:
        local = os.path.realpath(local)
        root = phone_root()
        if local == root:
            base = "/sdcard"
        elif local.startswith(root + os.sep):
            base = "/sdcard/" + os.path.relpath(local, root)
    return local, base


def do_list(script, am_p):
    """Емулює `find "$AM_P" -mindepth 1 -maxdepth 1 -exec stat -c '%F|%s|%Y|%n' {} +`."""
    local, base = effective_local(script, am_p)
    if local is None or not os.path.isdir(local):
        print("__AM_NOT_A_DIR__")
        return
    # POSIX find -P: symlink-аргумент не розіменовується — вивід порожній (test -d пройшов!).
    if os.path.islink(local):
        return
    for name in sorted(os.listdir(local)):
        full = os.path.join(local, name)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        print(f"{file_type(st)}|{st.st_size}|{int(st.st_mtime)}|{base}/{name}")


def do_find(am_p):
    """Емулює `find "$AM_P" -type f -exec stat -c '%s|%n' {} +` (ADBClient.recursiveFiles).

    1.2: MOCK_SILENT_BEFORE=ms — спати ms ДО першого рядка (тест ідле-таймауту, що вбиває
    завислий процес); MOCK_SLOW_STREAM=ms — друкувати результат рядок-за-рядком з паузою ms
    між ними, flush після кожного (щоб реально стрімити через пайп, а не осісти в буфері
    Python до самого виходу) — тест, що ідле-таймаут НЕ рве живий, хай і повільний, потік.
    """
    local = translate(am_p)
    if local is None or not os.path.lexists(local):
        print("__AM_MISSING__")
        return
    base = am_p.rstrip("/")
    if os.path.islink(local):
        return  # find -P не йде за symlink-аргументом

    silent_before = os.environ.get("MOCK_SILENT_BEFORE")
    if silent_before:
        try:
            time.sleep(int(silent_before) / 1000.0)
        except ValueError:
            pass
    slow_stream_raw = os.environ.get("MOCK_SLOW_STREAM")
    try:
        slow_stream = int(slow_stream_raw) / 1000.0 if slow_stream_raw else 0.0
    except ValueError:
        slow_stream = 0.0

    if os.path.isfile(local):
        print(f"{os.path.getsize(local)}|{base}")
        return
    first = True
    for dirpath, _dirnames, filenames in os.walk(local):
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            if slow_stream > 0 and not first:
                time.sleep(slow_stream)
            first = False
            rel = os.path.relpath(full, local)
            print(f"{os.path.getsize(full)}|{base}/{rel}", flush=True)


def do_dirs(am_p):
    """Емулює `find "$AM_P" -type d -exec stat -c '%Y|%n' {} +` (включно з коренем)."""
    local = translate(am_p)
    if local is None or not os.path.lexists(local):
        print("__AM_MISSING__")
        return
    base = am_p.rstrip("/")
    if not os.path.isdir(local) or os.path.islink(local):
        return  # find -P: symlink-аргумент не розіменовується
    print(f"{int(os.lstat(local).st_mtime)}|{base}")
    for dirpath, dirnames, _filenames in os.walk(local):
        for dn in sorted(dirnames):
            full = os.path.join(dirpath, dn)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, local)
            print(f"{int(os.lstat(full).st_mtime)}|{base}/{rel}")


def parse_quoted_list(text):
    """Розбирає список shell-квотованих ('…' з '\'' усередині) шляхів з deleteMany-скрипта —
    та сама інверсія RemotePath.shellQuote, що в parse_var, але для N значень."""
    items, i, n = [], 0, len(text)
    while i < n:
        if text[i] != "'":
            i += 1
            continue
        i += 1
        buf = []
        while i < n:
            if text.startswith("'\\''", i):
                buf.append("'"); i += 4; continue
            if text[i] == "'":
                i += 1; break
            buf.append(text[i]); i += 1
        items.append("".join(buf))
    return items


def _md5_line(local, remote_path):
    import hashlib
    h = hashlib.md5()
    with open(local, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    print(f"{h.hexdigest()}  {remote_path}")


def do_md5(am_p):
    """v0.11.0: емулює checksums — файл: один рядок; тека: рекурсивно (GNU-формат `hash  path`)."""
    local = translate(am_p)
    if local is None or not os.path.lexists(local):
        print("__AM_MISSING__")
        return
    base = am_p.rstrip("/")
    if os.path.isfile(local):
        _md5_line(local, base)
        return
    for dirpath, _d, filenames in os.walk(local):
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            _md5_line(full, f"{base}/{os.path.relpath(full, local)}")


def do_md5_many(paths):
    for p in paths:
        local = translate(p)
        if local is not None and os.path.isfile(local):
            _md5_line(local, p)


def do_rmdir_many(paths):
    """v0.11.0: removeEmptyDirectories — rmdir лише порожніх; непорожні → __AM_NOT_EMPTY__|path."""
    for p in paths:
        local = translate(p)
        if local is None:
            continue
        try:
            os.rmdir(local)
        except OSError:
            pass
        if os.path.isdir(local):
            print(f"__AM_NOT_EMPTY__|{p}")


def do_delete_many(paths):
    """v0.10.2: емулює deleteMany — на кожен шлях, що НЕ вдалося видалити, рядок
    `__AM_DELETE_FAILED__|<шлях>` (шлях останнім). MOCK_FAIL_DELETE=1 — провал усіх."""
    for p in paths:
        if not delete_one(p):
            print(f"__AM_DELETE_FAILED__|{p}")


def do_delete(am_p):
    if not delete_one(am_p):
        print("__AM_DELETE_FAILED__")


def delete_one(am_p):
    """True — видалено (чи вже не існує), False — провал (guard кореня, MOCK_FAIL_DELETE)."""
    if os.environ.get("MOCK_FAIL_DELETE") == "1":
        return False
    local = translate(am_p)
    if local is None:
        return False
    root = phone_root()
    rp = os.path.realpath(local)
    if not (rp == root or rp.startswith(root + os.sep)):
        return False
    if os.path.isdir(local) and not os.path.islink(local):
        shutil.rmtree(local, ignore_errors=True)
    elif os.path.lexists(local):
        os.remove(local)
    return not os.path.lexists(local)


def do_mkdir_p(am_p):
    """v0.11.0: makeDirectories (mkdir -p)."""
    local = translate(am_p)
    if local is not None:
        os.makedirs(local, exist_ok=True)
    if local is None or not os.path.isdir(local):
        print("__AM_MKDIR_FAILED__")


def do_mkdir(am_p):
    local = translate(am_p)
    if local is not None:
        try:
            os.mkdir(local)
        except OSError:
            pass
    if local is None or not os.path.isdir(local):
        print("__AM_MKDIR_FAILED__")


def do_rename(am_p, am_q):
    src = translate(am_p)
    dst = translate(am_q)
    if dst is not None and os.path.lexists(dst):
        print("__AM_EXISTS__")
        return
    if src is not None and dst is not None and os.path.lexists(src):
        try:
            os.rename(src, dst)
        except OSError:
            pass
    if dst is None or not os.path.lexists(dst):
        print("__AM_MV_FAILED__")


def do_remote_exists(am_p):
    """Емулює `if [ -e "$AM_P" ]; then echo __AM_EXISTS__; else echo __AM_ABSENT__; fi` (B1)."""
    local = translate(am_p)
    if local is not None and os.path.exists(local):  # -e стежить за symlink, як os.path.exists
        print("__AM_EXISTS__")
    else:
        print("__AM_ABSENT__")


def do_stat_mtimes(am_p):
    """Емулює `find "$AM_P" -exec stat -c '%Y|%n' {} +` — файли І теки, БЕЗ -type (B1).

    На відміну від do_dirs (-type d) і do_find (-type f, %s|%n), тут немає фільтра типу:
    і корінь, і кожна вкладена тека, і кожен файл друкуються з тим самим форматом '%Y|%n'.
    """
    local = translate(am_p)
    if local is None or not os.path.lexists(local):
        print("__AM_MISSING__")
        return
    base = am_p.rstrip("/")
    if os.path.islink(local):
        return  # find -P: symlink-аргумент не розіменовується
    print(f"{int(os.lstat(local).st_mtime)}|{base}")
    if not os.path.isdir(local):
        return
    for dirpath, dirnames, filenames in os.walk(local):
        for dn in sorted(dirnames):
            full = os.path.join(dirpath, dn)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, local)
            print(f"{int(os.lstat(full).st_mtime)}|{base}/{rel}")
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, local)
            print(f"{int(os.lstat(full).st_mtime)}|{base}/{rel}")


def do_statfs(am_p):
    """Емулює `toybox stat -f -c '%a|%b|%S' "$AM_P"` через os.statvfs (A2)."""
    local = translate(am_p)
    if local is None or not os.path.exists(local):
        print("__AM_STAT_FAILED__")
        return
    # v0.12.2 (M1): MOCK_FREE_BYTES — підмінити вільне місце (тест «повний телефон» для push).
    override = os.environ.get("MOCK_FREE_BYTES")
    if override is not None:
        frsize = 4096
        avail = int(override) // frsize
        print(f"{avail}|{max(avail, 1) * 4}|{frsize}")
        return
    try:
        st = os.statvfs(local)
    except OSError:
        print("__AM_STAT_FAILED__")
        return
    print(f"{st.f_bavail}|{st.f_blocks}|{st.f_frsize}")


def do_rescan():
    """MediaStore-рескан (A6) — best-effort, ефект на реальному телефоні не емулюємо."""
    print("__AM_SCAN_DONE__")


def do_props():
    """v0.14.0 (Wi-Fi): зонд ідентичності — MOCK_ANDROID_ID / MOCK_SERIALNO ('' = недоступно)."""
    print(f"__AM_ID__|{os.environ.get('MOCK_ANDROID_ID', 'a1b2c3d4e5f60718')}")
    print(f"__AM_SN__|{os.environ.get('MOCK_SERIALNO', 'MOCKSN001')}")
    print("__AM_MODEL__|Mock Phone 9")


def parse_opcode(script):
    """v0.15.0 (M3): `AM_OP=<опкод>; …` — перший рядок кожного скрипта ADBScripts (Swift)."""
    if not script.startswith("AM_OP="):
        return None
    end = script.find(";")
    return script[len("AM_OP="):end] if end > 0 else None


def batch_items(script):
    body = script[script.index("; ") + 2:]
    return parse_quoted_list(body[len("for AM_P in "):body.index("; do")])


# v0.15.0 (M3): диспетчер за опкодом — точний збіг, порядок гілок більше не має значення.
# ContractTests (Swift) перевіряють, що тут є гілка на КОЖЕН ADBOpcode.
OPCODE_HANDLERS = {
    "getProps": lambda s: do_props(),
    "rescanPaths": lambda s: do_rescan(),
    "rescanVolume": lambda s: do_rescan(),
    "statFS": lambda s: do_statfs(parse_am_p(s)),
    "existsProbe": lambda s: do_remote_exists(parse_am_p(s)),
    "md5Batch": lambda s: do_md5_many(batch_items(s)),
    "rmdirBatch": lambda s: do_rmdir_many(batch_items(s)),
    "rmBatch": lambda s: do_delete_many(batch_items(s)),
    "md5One": lambda s: do_md5(parse_am_p(s)),
    "listDir": lambda s: do_list(s, parse_am_p(s)),
    "findFiles": lambda s: do_find(parse_am_p(s)),
    "findDirs": lambda s: do_dirs(parse_am_p(s)),
    "statMTimes": lambda s: do_stat_mtimes(parse_am_p(s)),
    "rmOne": lambda s: do_delete(parse_am_p(s)),
    "mkdirP": lambda s: do_mkdir_p(parse_am_p(s)),
    "mkdir": lambda s: do_mkdir(parse_am_p(s)),
    "moveOrFail": lambda s: do_rename(parse_am_p(s), parse_var(s, "AM_Q")),
}


def do_shell(script):
    # v0.15.0 (M3): опкод — точний збіг; старий ланцюжок підрядків нижче лишається запасним
    # на один випуск (скрипти без AM_OP= — напр. з golden e2e_device.sh).
    opcode = parse_opcode(script)
    if opcode is not None:
        handler = OPCODE_HANDLERS.get(opcode)
        if handler is None:
            sys.stderr.write(f"mock_adb: unknown opcode {opcode!r}\n")
            sys.exit(2)
        handler(script)
        return
    # v0.14.0: зонд ідентичності (сентинел-префікси, без AM_P=) — найперша гілка.
    if "__AM_ID__" in script:
        do_props()
        return
    # Ці два маркери — ДО parse_am_p: скрипти рескану взагалі не містять AM_P=.
    if "MEDIA_SCANNER_SCAN_FILE" in script or "scan_volume" in script:
        do_rescan()
        return
    # "stat -f" — ДО загальної гілки "__AM_NO_TOYBOX__" (обидва скрипти містять цей сентинел
    # у своєму тексті: маркер stat -f мусить перехопити запит першим).
    if "stat -f" in script:
        do_statfs(parse_am_p(script))
        return
    # remoteExists (B1) — унікальний маркер __AM_ABSENT__ ДО всіх інших гілок: скрипт містить
    # і __AM_EXISTS__ (як moveRaw), тож розрізняти можна лише за __AM_ABSENT__.
    if "__AM_ABSENT__" in script:
        do_remote_exists(parse_am_p(script))
        return
    if script.startswith("for AM_P in "):
        # v0.10.2/v0.11.0: батчеві скрипти без `AM_P=` на початку — ДО parse_am_p:
        # deleteMany (rm -rf), removeEmptyDirectories (rmdir), checksumsMany (md5sum).
        items = parse_quoted_list(script[len("for AM_P in "):script.index("; do")])
        if "md5sum" in script:
            do_md5_many(items)
        elif "rmdir" in script:
            do_rmdir_many(items)
        else:
            do_delete_many(items)
        return
    am_p = parse_am_p(script)
    if "md5sum" in script:
        # v0.11.0: checksums(path) — містить і "-type f", тому ДО гілки recursiveFiles.
        do_md5(am_p)
        return
    if "__AM_NO_TOYBOX__" in script:
        do_list(script, am_p)
    elif "-type f" in script:
        do_find(am_p)
    elif "-type d" in script:
        do_dirs(am_p)
    elif "'%Y|%n'" in script:
        # statMTimes (B1): той самий формат '%Y|%n', що recursiveDirs, але БЕЗ -type d/-type f
        # (перевірено вище за чергою — обидві гілки з -type вже мали б перехопити свій випадок).
        do_stat_mtimes(am_p)
    elif "rm -rf" in script:
        do_delete(am_p)
    elif "mkdir -p --" in script:
        do_mkdir_p(am_p)
    elif "mkdir --" in script:
        do_mkdir(am_p)
    elif "mv --" in script:
        do_rename(am_p, parse_var(script, "AM_Q"))
    else:
        sys.stderr.write(f"mock_adb: unknown shell script: {script}\n")
        sys.exit(2)


def corrupt_first_file(dest):
    targets = []
    if os.path.isfile(dest):
        targets = [dest]
    else:
        for dirpath, _d, filenames in os.walk(dest):
            for fn in sorted(filenames):
                targets.append(os.path.join(dirpath, fn))
    if targets:
        target = targets[0]
        size = os.path.getsize(target)
        with open(target, "r+b") as f:
            f.truncate(size // 2)


def flip_first_byte_keep_size(dest):
    """Інвертує перший байт першого файла (розмір той самий) — тест md5-верифікації."""
    target = dest
    if os.path.isdir(dest):
        for dirpath, _d, filenames in os.walk(dest):
            names = sorted(filenames)
            if names:
                target = os.path.join(dirpath, names[0])
                break
    if os.path.isfile(target) and os.path.getsize(target) > 0:
        with open(target, "r+b") as f:
            b = f.read(1)
            f.seek(0)
            f.write(bytes([b[0] ^ 0xFF]))


def truncate_half(path):
    size = os.path.getsize(path)
    with open(path, "r+b") as f:
        f.truncate(size // 2)


def partial_copy_for_failure(local, dest):
    """B2 (MOCK_PULL_FAIL_COUNT): емулює обрив з'єднання посеред `adb pull -a`. Для теки —
    перший файл (за відносним шляхом, сортовано) лягає повністю, другий обрізається навпіл,
    решта взагалі не копіюється; для одиночного файла — сам файл обрізається навпіл. dest
    лишається у ЧАСТКОВОМУ стані навмисно — саме це TransferEngine.resumeMissing() і мусить
    добрати наступним викликом.
    """
    if os.path.isdir(local) and not os.path.islink(local):
        os.makedirs(dest, exist_ok=True)
        files = []
        for dirpath, _d, filenames in os.walk(local):
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                if os.path.islink(full):
                    continue
                files.append((full, os.path.relpath(full, local)))
        files.sort(key=lambda pair: pair[1])
        for i, (full, rel) in enumerate(files):
            if i >= 2:
                break
            dest_full = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(dest_full), exist_ok=True)
            shutil.copy2(full, dest_full)
            if i == 1:
                truncate_half(dest_full)
    else:
        shutil.copy2(local, dest)
        truncate_half(dest)


def do_exec_out(words):
    """4.1: `exec-out toybox head -c N 'path'` — перші N байтів файла байт-у-байт у stdout.
    Реальний adb склеює аргументи пробілами і віддає shell на телефоні, тому шлях приходить
    у POSIX-лапках — розбираємо shlex-ом, як зробив би sh."""
    import shlex
    try:
        parsed = shlex.split(" ".join(words))
    except ValueError:
        sys.stderr.write("mock_adb: bad quoting in exec-out\n")
        sys.exit(2)
    if len(parsed) == 5 and parsed[:3] == ["toybox", "head", "-c"]:
        count = int(parsed[3])
        local = translate(parsed[4])
        if local is None or not os.path.isfile(local):
            sys.stderr.write(f"head: {parsed[4]}: No such file or directory\n")
            sys.exit(1)
        with open(local, "rb") as f:
            sys.stdout.buffer.write(f.read(count))
        sys.stdout.flush()
        return
    sys.stderr.write(f"mock_adb: unsupported exec-out: {words}\n")
    sys.exit(2)


def do_pull(remote, local_dir):
    local = translate(remote)
    if local is None or not os.path.lexists(local):
        sys.stderr.write(f"adb: error: remote object '{remote}' does not exist\n")
        sys.exit(1)
    base = os.path.basename(local.rstrip("/"))
    dest = os.path.join(local_dir, base)

    # v0.11.0: MOCK_GROW_ON_PULL_COUNT — перед копіюванням дописати 3 байти в ДЖЕРЕЛО (файл
    # «дописується» на телефоні після лістингу → verify за розміром провалюється, доки рушій
    # не перечитає розміри). MOCK_ADD_FILE_ON_PULL — створити ЧУЖИЙ файл у теці-джерелі
    # (з'явився під час переносу → безпечне видалення має лишити його і саму теку).
    if consume_counter("MOCK_GROW_ON_PULL_COUNT") and os.path.isfile(local):
        with open(local, "ab") as f:
            f.write(b"+++")
    if os.environ.get("MOCK_ADD_FILE_ON_PULL") and os.path.isdir(local):
        with open(os.path.join(local, os.environ["MOCK_ADD_FILE_ON_PULL"]), "wb") as f:
            f.write(b"foreign")

    if consume_counter("MOCK_PULL_FAIL_COUNT"):
        partial_copy_for_failure(local, dest)
        sys.stderr.write(f"adb: error: failed to copy '{remote}' : Connection reset by peer\n")
        sys.exit(1)

    if os.path.isdir(local) and not os.path.islink(local):
        shutil.copytree(local, dest, symlinks=True)
        # Реальний `adb pull -a` зберігає mtime лише ФАЙЛІВ; теки отримують поточний час.
        # Емулюємо, щоб тести ловили відновлення дат тек рушієм.
        os.utime(dest, None)
        for dirpath, dirnames, _f in os.walk(dest):
            for dn in dirnames:
                os.utime(os.path.join(dirpath, dn), None)
    else:
        shutil.copy2(local, dest)
    if os.environ.get("MOCK_CORRUPT_PULL") == "1" or consume_counter("MOCK_CORRUPT_PULL_COUNT"):
        corrupt_first_file(dest)
    # v0.11.0: той самий розмір, інший вміст — ловиться лише md5.
    if consume_counter("MOCK_CORRUPT_CHECKSUM_COUNT"):
        flip_first_byte_keep_size(dest)
    print(f"{remote}: pulled")


def do_wait_for_device():
    """`adb -s SERIAL wait-for-device` (B2). За замовчуванням пристрій "готовий" одразу —
    MOCK_WAIT_HANG=1 емулює завислий обрив (тест скасування посеред очікування)."""
    if os.environ.get("MOCK_WAIT_HANG") == "1":
        time.sleep(30)
    sys.exit(0)


def do_push(local, remote):
    """Емулює `adb -s SERIAL push LOCAL REMOTE` (B1). LOCAL — реальний шлях на Mac (НЕ
    через translate — це не телефонний шлях), REMOTE — телефонний шлях (через translate).
    Як справжній adb push у наявну теку: копіює LOCAL всередину REMOTE під тим самим basename.
    """
    if os.environ.get("MOCK_FAIL_PUSH") == "1":
        sys.stderr.write("adb: error: mock forced push failure\n")
        sys.exit(1)
    if not os.path.lexists(local):
        sys.stderr.write(f"adb: error: cannot stat '{local}': No such file or directory\n")
        sys.exit(1)
    remote_local = translate(remote)
    if remote_local is None:
        sys.stderr.write(f"adb: error: remote path '{remote}' is not supported by mock\n")
        sys.exit(1)
    base = os.path.basename(local.rstrip("/"))
    dest = os.path.join(remote_local, base) if os.path.isdir(remote_local) else remote_local
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    # v0.11.0 (P2): MOCK_PUSH_FAIL_COUNT=n — перші n push-ів кладуть ЧАСТКОВО (тека: перший
    # файл цілий, другий обрізаний, решта — ні; файл — обрізаний) і exit 1 — обрив посеред push.
    if consume_counter("MOCK_PUSH_FAIL_COUNT"):
        if os.path.exists(dest):
            shutil.rmtree(dest) if os.path.isdir(dest) else os.remove(dest)
        partial_copy_for_failure(local, dest)
        sys.stderr.write(f"adb: error: failed to copy '{local}' : Connection reset by peer\n")
        sys.exit(1)
    if os.path.isdir(local):
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        shutil.copytree(local, dest, symlinks=True)
    else:
        shutil.copy2(local, dest)
    if os.environ.get("MOCK_CORRUPT_PUSH") == "1":
        corrupt_first_file(dest)
    print("1 file pushed")


def do_devices():
    state = os.environ.get("MOCK_STATE", "device")
    print("List of devices attached")
    if state != "none":
        print(f"MOCK001\t{state} usb:0-1 product:mockphone model:Mock_Phone_9 device:mock")
    print()


def _track_frame_payload(state):
    """Один рядок пристрою (той самий формат, що do_devices(), АЛЕ без -l/model — track-devices
    протокол моделі не передає) чи порожній payload, коли пристрою нема."""
    if not state or state == "none":
        return ""
    return f"MOCK001\t{state}\n"


def _write_track_frame(state):
    """Друкує ОДИН кадр track-devices: 4 hex-символи довжини payload (нижній регістр, як
    справжній adb) одразу перед самим payload, без роздільників і БЕЗ зайвого \\n після
    довжини — payload сам несе свій завершальний \\n (чи порожній, коли пристрою нема)."""
    payload = _track_frame_payload(state)
    length_hex = format(len(payload.encode("utf-8")), "04x")
    sys.stdout.write(length_hex + payload)
    sys.stdout.flush()


def do_track_devices():
    """Емулює `adb track-devices` (2.4, ProcessRunner.stream()): довгоживучий процес без
    природного кінця, друкує новий кадр на КОЖНУ зміну підключення.

    Без MOCK_TRACK_FILE: один кадр за поточним MOCK_STATE, потім `sleep 1` і exit 0 —
    достатньо для тесту, що перевіряє лише перший кадр і швидко скасовує стрім.

    З MOCK_TRACK_FILE=<шлях>: перший кадр — за вмістом файлу (чи MOCK_STATE, якщо файл ще
    не існує в момент старту); далі кожні 200 мс перечитує файл і при ЗМІНІ вмісту друкує
    новий кадр (тест "підключає"/"відключає" пристрій, переписуючи файл рядком
    device|unauthorized|offline|none) — завершується (exit 0), коли файл видалено.
    """
    track_file = os.environ.get("MOCK_TRACK_FILE")
    initial_state = os.environ.get("MOCK_STATE", "device")

    if not track_file:
        _write_track_frame(initial_state)
        time.sleep(1)
        sys.exit(0)

    last_content = None
    if os.path.exists(track_file):
        with open(track_file) as f:
            last_content = f.read().strip()
    _write_track_frame(last_content if last_content is not None else initial_state)

    while True:
        time.sleep(0.2)
        if not os.path.exists(track_file):
            sys.exit(0)
        with open(track_file) as f:
            content = f.read().strip()
        if content != last_content:
            last_content = content
            _write_track_frame(content)


def main():
    args = sys.argv[1:]
    log_call(args)

    # 1.6 (chaos-mock): рахуємо ЦЕЙ виклик у наскрізному лічильнику ДО будь-якого диспетчеру —
    # обрив мусить вдавати повний обрив adb-сервера, байдуже, яку саме команду клієнт саме
    # намагався виконати (shell/pull/push/devices/wait-for-device).
    call_index = call_index_and_increment()
    disconnect_on_raw = os.environ.get("MOCK_DISCONNECT_ON_CALL")
    if disconnect_on_raw and call_index is not None:
        try:
            disconnect_on = int(disconnect_on_raw)
        except ValueError:
            disconnect_on = None
        if disconnect_on is not None and call_index == disconnect_on:
            sys.stderr.write("error: device 'MOCK001' not found\n")
            sys.exit(1)

    slow_raw = os.environ.get("MOCK_SLOW")
    if slow_raw:
        try:
            time.sleep(int(slow_raw) / 1000.0)
        except ValueError:
            pass

    # v0.14.0 (Wi-Fi): підкоманди adb (не shell) — mdns/pair/connect/disconnect.
    if args[:2] == ["mdns", "check"]:
        if os.environ.get("MOCK_MDNS") == "1":
            print("mdns daemon version [libadbmdns]")
            return
        print("ERROR: mdns discovery unavailable")
        sys.exit(1)
    if args[:2] == ["mdns", "services"]:
        print("List of discovered mdns services")
        for item in filter(None, os.environ.get("MOCK_MDNS_SERVICES", "").split(";")):
            name, kind, addr = item.split(",")
            print(f"{name}\t{kind}\t{addr}")
        return
    if len(args) == 3 and args[0] == "pair":
        if args[2] == os.environ.get("MOCK_PAIR_CODE", "123456"):
            print(f"Successfully paired to {args[1]} [guid=adb-MOCK001-abc]")
            return
        print("Failed: Wrong password or connection was dropped.")
        sys.exit(1)
    if len(args) == 2 and args[0] == "connect":
        if os.environ.get("MOCK_CONNECT_FAIL"):
            print(f"failed to connect to '{args[1]}': Connection refused")
            sys.exit(1)
        print(f"connected to {args[1]}")
        return
    if len(args) == 2 and args[0] == "disconnect":
        print(f"disconnected {args[1]}")
        return

    if args[:2] == ["devices", "-l"]:
        do_devices()
        return
    if args == ["track-devices"]:
        do_track_devices()
        return
    if len(args) >= 2 and args[0] == "-s":
        rest = args[2:]
        if rest and rest[0] == "shell":
            do_shell(" ".join(rest[1:]))
            return
        if rest and rest[0] == "exec-out":
            do_exec_out(rest[1:])
            return
        if len(rest) >= 4 and rest[0] == "pull" and rest[1] == "-a":
            # v0.10.2: `pull -a r1 … rN localDir` (батч) — як реальний adb: файли по черзі,
            # перша помилка (напр. MOCK_PULL_FAIL_COUNT) обриває решту з exit 1 — файли, що
            # встигли лягти, лишаються (TransferEngine+Batch добирає решту поштучно).
            local_dir = rest[-1]
            for remote in rest[2:-1]:
                do_pull(remote, local_dir)
            return
        if len(rest) == 3 and rest[0] == "push":
            do_push(rest[1], rest[2])
            return
        if len(rest) == 1 and rest[0] == "wait-for-device":
            do_wait_for_device()
            return
    sys.stderr.write(f"mock_adb: unsupported invocation: {args}\n")
    sys.exit(2)


if __name__ == "__main__":
    main()
