#!/bin/bash
# Збирає release-бінарник і пакує його в dist/Android Mover.app
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release --product AndroidMover

BIN=".build/release/AndroidMover"
APP="dist/Android Mover.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/AndroidMover"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3.7: SwiftPM-ресурси AndroidMover-таргету (Resources/Localizable.xcstrings — String Catalog)
# пакуються SPM у ОКРЕМИЙ .bundle поруч із бінарником у .build/, НЕ всередину нього — без
# цього кроку Bundle.module (генерований SPM-акцесор) не знаходить бандл поруч із
# виконуваним файлом усередині .app і крешить при першому зверненні до ресурсу.
RESOURCE_BUNDLE=".build/release/AndroidMover_AndroidMover.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
  echo "!! Ресурсний бандл $RESOURCE_BUNDLE не знайдено — Bundle.module крешитиме" >&2
  exit 1
fi

# Версія — з git-тега (0.4): CFBundleShortVersionString з останнього тега (без "v"),
# CFBundleVersion — монотонний лічильник комітів. Правимо ЛИШЕ скопійований plist у dist/,
# scripts/Info.plist лишається джерелом-шаблоном з дефолтом "0.1.0"/"1".
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
if [ -z "$VERSION" ]; then
  VERSION="0.0.0"
fi
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Ad-hoc підпис (обов'язково для arm64).
codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> Готово: $APP (версія $VERSION, build $BUILD)"

# 3.7: smoke-тест — без ресурсного бандла вище (Bundle.module) додаток крешив би одразу при
# першому зверненні до String Catalog (SettingsView/OnboardingView тощо), тож "живий ще
# через ~3с після старту" — дешева, але реальна перевірка саме на цей регрес.
echo "==> Smoke test"
"$APP/Contents/MacOS/AndroidMover" &
SMOKE_PID=$!
sleep 3.5
if kill -0 "$SMOKE_PID" 2>/dev/null; then
  echo "==> Smoke OK (pid $SMOKE_PID живий через 3.5с)"
else
  echo "!! Smoke FAILED — процес завершився передчасно (можливо, Bundle.module-креш)" >&2
  exit 1
fi

# 6: після kill додатка (SIGTERM) — дочірній adb-процес (DeviceStore track-devices) НЕ мав
# лишитись сиротою. AppDelegate.applicationDidFinishLaunching (Sources/AndroidMover/
# AppDelegate.swift) ловить SIGTERM через DispatchSource і кличе ProcessRunner.
# terminateAllChildren() (ChildProcessRegistry, Core) ДО того, як сам процес помре — без
# цього посаджений `adb track-devices` репарентився б до launchd і жив би далі сам по собі
# (підтверджено емпірично до фіксу: `ps aux` після смоук-тесту показував живий процес).
# v0.10.4: перевіряємо ЛИШЕ дітей ВЛАСНОГО smoke-процесу (pgrep -P), а не будь-який
# `adb track-devices` у системі — інакше smoke бачив «сироту» в РОБОЧОМУ екземплярі додатка
# власника, що працював поруч, і ще й убивав його pkill-ом за іменем.
SMOKE_CHILDREN="$(pgrep -P "$SMOKE_PID" 2>/dev/null || true)"
kill "$SMOKE_PID" 2>/dev/null || true
sleep 1
# Дитині дається до 4 с: SIGTERM → (3 с) → SIGKILL-ескалація в ChildProcess.terminateWithEscalation,
# тож одразу після kill adb ще може доживати — це не сирота, а ескалація в дорозі.
alive_children() {
  local pid
  for pid in $SMOKE_CHILDREN; do
    kill -0 "$pid" 2>/dev/null && echo "$pid"
  done
}
for _ in 1 2 3 4; do
  [ -z "$(alive_children)" ] && break
  sleep 1
done
ORPHANS="$(alive_children || true)"
if [ -n "$ORPHANS" ]; then
  echo "!! Smoke FAILED — дочірні процеси додатка лишились живими після kill: $ORPHANS" >&2
  for pid in $ORPHANS; do kill -9 "$pid" 2>/dev/null || true; done
  exit 1
fi
echo "==> Smoke OK — жодного сирітського 'adb track-devices' після kill"
