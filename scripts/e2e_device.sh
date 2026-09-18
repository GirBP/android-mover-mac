#!/usr/bin/env bash
# scripts/e2e_device.sh — E2E-прогін проти РЕАЛЬНОГО телефона (0.2, спринт 0 "Ґрунт").
#
# Що робить:
#   1. Знаходить adb і серійник авторизованого пристрою (або бере з env).
#   2. Ганяє `AM_TEST_ADB=real swift test` — той самий XCTest-набір, що на mock (0.6),
#      але проти живого adb (корінь тестових даних рушій створює сам:
#      /sdcard/AndroidMoverE2E/<uuid>, прибирає після себе).
#   3. Створює свою окрему теку /sdcard/AndroidMoverE2E/golden з файлами-приманками
#      (кирилиця, пробіл, апостроф, дата через touch -t) і ганяє РІВНО ТІ Ж shell-скрипти,
#      які сам ADBClient генерує для listing/find/stat -f (скопійовані дослівно з
#      Sources/AndroidMoverCore/ADB/ADBClient.swift) — реальний вивід осідає в Tests/Golden/*.txt.
#   4. Прибирає /sdcard/AndroidMoverE2E повністю (trap на EXIT — і при провалі теж).
#
# Вхід (env, усе опційне):
#   ADB_PATH          — шлях до adb. За замовчуванням — та сама черга кандидатів, що й
#                        ADBClient.discover() (Sources/AndroidMoverCore/ADB/ADBClient.swift):
#                        $ADB_PATH → ~/Library/Application Support/AndroidMover/platform-tools/adb
#                        → /opt/homebrew/bin/adb → ~/Library/Android/sdk/platform-tools/adb
#                        → /usr/local/bin/adb.
#   AM_DEVICE_SERIAL  — серійник пристрою. За замовчуванням — перший рядок зі станом
#                        "device" з `adb devices`.
#
# Golden-файл, якого тут НЕМА: md5sum — checksum-верифікація реалізована у v0.11.0
# (ADBClient.checksums), але крок захоплення ще не доданий; з'явиться разом з `amctl capture`
# який замінить ручне копіювання скриптів у цей bash.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# 1. adb і серійник пристрою
# ---------------------------------------------------------------------------

discover_adb() {
  local candidates=()
  if [ -n "${ADB_PATH:-}" ]; then
    candidates+=("$ADB_PATH")
  fi
  candidates+=(
    "$HOME/Library/Application Support/AndroidMover/platform-tools/adb"
    "/opt/homebrew/bin/adb"
    "$HOME/Library/Android/sdk/platform-tools/adb"
    "/usr/local/bin/adb"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

if [ -z "${ADB_PATH:-}" ]; then
  if ! ADB_PATH="$(discover_adb)"; then
    echo "e2e_device: adb не знайдено (задай ADB_PATH або постав platform-tools)." >&2
    exit 1
  fi
fi
if [ ! -x "$ADB_PATH" ]; then
  echo "e2e_device: ADB_PATH='$ADB_PATH' не виконуваний файл." >&2
  exit 1
fi
export ADB_PATH
echo "==> adb: $ADB_PATH"

if [ -z "${AM_DEVICE_SERIAL:-}" ]; then
  AM_DEVICE_SERIAL="$("$ADB_PATH" devices | awk '$2 == "device" { print $1; exit }')"
fi
if [ -z "$AM_DEVICE_SERIAL" ]; then
  echo "e2e_device: жодного авторизованого пристрою в 'adb devices' (стан 'device')." >&2
  echo "            Перевір кабель, 'Дозволити налагодження USB?' на телефоні, і що USB-режим не 'лише заряджання'." >&2
  exit 1
fi
export AM_DEVICE_SERIAL
echo "==> пристрій: $AM_DEVICE_SERIAL"

ADB=("$ADB_PATH" -s "$AM_DEVICE_SERIAL")
GOLDEN_ROOT="/sdcard/AndroidMoverE2E/golden"
LOCAL_FIXTURES="$(mktemp -d)"

cleanup() {
  "${ADB[@]}" shell "rm -rf -- '/sdcard/AndroidMoverE2E'" >/dev/null 2>&1 || true
  rm -rf "$LOCAL_FIXTURES"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 2. XCTest проти реального бекенду (0.6): той самий набір, що mock, AM_TEST_ADB=real.
# ---------------------------------------------------------------------------

echo "==> AM_TEST_ADB=real swift test"
AM_TEST_ADB=real ADB_PATH="$ADB_PATH" AM_DEVICE_SERIAL="$AM_DEVICE_SERIAL" swift test

# ---------------------------------------------------------------------------
# 3. Golden-транскрипти: дослівні скрипти з ADBClient.swift проти реальних файлів.
# ---------------------------------------------------------------------------

GOLDEN_DIR="Tests/Golden"
mkdir -p "$GOLDEN_DIR"

# Інверсія RemotePath.shellQuote (Sources/AndroidMoverCore/Models/Models.swift): одинарні лапки,
# "'" всередині -> "'\''".
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

"${ADB[@]}" shell "mkdir -p -- $(shell_quote "$GOLDEN_ROOT")"

# Файли-приманки: кирилиця+пробіл, апостроф, підтека з окремою датою (touch -t) — саме те,
# на чому ламається наївне цитування шляхів чи парсинг stat.
printf 'фото' > "$LOCAL_FIXTURES/Фото 1.jpg"
apostrophe_name="it's.txt"
printf 'апостроф' > "$LOCAL_FIXTURES/$apostrophe_name"
mkdir -p "$LOCAL_FIXTURES/підтека з датами"
printf 'вкладений файл' > "$LOCAL_FIXTURES/підтека з датами/файл.txt"

"$ADB_PATH" -s "$AM_DEVICE_SERIAL" push "$LOCAL_FIXTURES/Фото 1.jpg" "$GOLDEN_ROOT/" >/dev/null
"$ADB_PATH" -s "$AM_DEVICE_SERIAL" push "$LOCAL_FIXTURES/$apostrophe_name" "$GOLDEN_ROOT/" >/dev/null
"$ADB_PATH" -s "$AM_DEVICE_SERIAL" push "$LOCAL_FIXTURES/підтека з датами" "$GOLDEN_ROOT/" >/dev/null

# Фіксована дата на вкладеному файлі (toybox touch -t YYYYMMDDhhmm.ss) — 2020-01-15 10:30:45.
"${ADB[@]}" shell "toybox touch -t 202001151030.45 -- $(shell_quote "$GOLDEN_ROOT/підтека з датами/файл.txt")" \
  >/dev/null 2>&1 || echo "!! touch -t не спрацював (toybox старий?) — golden лишиться з поточною датою" >&2

capture() {
  local name=$1 script=$2
  echo "==> golden: $name"
  "${ADB[@]}" shell "$script" > "$GOLDEN_DIR/$name.txt" || true
}

AM_P_GOLDEN="$(shell_quote "$GOLDEN_ROOT")"

# listDirectory (ADBClient.listDirectory) — find -mindepth 1 -maxdepth 1 + stat.
capture "listing" \
  "AM_P=$AM_P_GOLDEN; command -v toybox >/dev/null 2>&1 || { echo __AM_NO_TOYBOX__; exit 0; }; AM_R=\$(toybox readlink -f \"\$AM_P\" 2>/dev/null); [ -n \"\$AM_R\" ] && AM_P=\"\$AM_R\"; if [ ! -d \"\$AM_P\" ]; then echo __AM_NOT_A_DIR__; exit 0; fi; toybox find \"\$AM_P\" -mindepth 1 -maxdepth 1 -exec toybox stat -c '%F|%s|%Y|%n' {} + 2>/dev/null; exit 0"

# recursiveFiles (ADBClient.recursiveFiles) — find -type f + stat.
capture "recursive_files" \
  "AM_P=$AM_P_GOLDEN; if [ ! -e \"\$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; toybox find \"\$AM_P\" -type f -exec toybox stat -c '%s|%n' {} + 2>/dev/null; exit 0"

# recursiveDirs (ADBClient.recursiveDirs) — find -type d + stat.
capture "recursive_dirs" \
  "AM_P=$AM_P_GOLDEN; if [ ! -e \"\$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; toybox find \"\$AM_P\" -type d -exec toybox stat -c '%Y|%n' {} + 2>/dev/null; exit 0"

# statMTimes (ADBClient.statMTimes) — find (файли І теки, БЕЗ -type) + stat.
capture "stat_mtimes" \
  "AM_P=$AM_P_GOLDEN; if [ ! -e \"\$AM_P\" ]; then echo __AM_MISSING__; exit 0; fi; toybox find \"\$AM_P\" -exec toybox stat -c '%Y|%n' {} + 2>/dev/null; exit 0"

# storageInfo (ADBClient.storageInfo) — stat -f.
capture "storage_info" \
  "AM_P=$AM_P_GOLDEN; command -v toybox >/dev/null 2>&1 || { echo __AM_NO_TOYBOX__; exit 0; }; toybox stat -f -c '%a|%b|%S' \"\$AM_P\" 2>/dev/null || echo __AM_STAT_FAILED__; exit 0"

# push (ADBClient.push) — не shell-скрипт, окремий формат виводу самого `adb push`.
echo "==> golden: push"
"$ADB_PATH" -s "$AM_DEVICE_SERIAL" push "$LOCAL_FIXTURES/Фото 1.jpg" "$GOLDEN_ROOT/push-приймач.jpg" \
  > "$GOLDEN_DIR/push.txt" 2>&1 || true

echo "==> Готово. Golden-транскрипти — у $GOLDEN_DIR/*.txt (тестова тека на телефоні прибирається через trap)."
