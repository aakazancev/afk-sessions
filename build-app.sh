#!/bin/bash
# Собирает AFKSessions.app. Бандл нужен обязательно: без него не работают
# уведомления (UNUserNotificationCenter требует bundle identifier)
# и автозапуск через SMAppService.
set -euo pipefail

case "${1:-}" in
  ""|--release) ;;
  *) echo "usage: ./build-app.sh [--release]"; exit 1 ;;
esac

# CLT не могут скомпилировать манифест SwiftPM — собираем тулчейном Xcode
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NAME="AFKSessions"
DISPLAY_NAME="AFK Sessions"
BUNDLE_ID="${BUNDLE_ID:-dev.local.afksessions}"
# Единственный источник версии: попадает в Info.plist, приложение читает её оттуда
VERSION="0.7"
APP="build/$NAME.app"

echo "→ Сборка бинарников (release, universal: arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
PRODUCTS=".build/apple/Products/Release"

echo "→ Сборка бандла $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PRODUCTS/SessionsApp" "$APP/Contents/MacOS/$NAME"
cp "$PRODUCTS/sessions-cli" "$APP/Contents/Resources/sessions-cli"
chmod +x "$APP/Contents/Resources/sessions-cli"
# Иконка: AppIcon.icon (Icon Composer) → Assets.car для macOS 26+
# (уведомления берут иконку только оттуда) + легаси AppIcon.icns для старых.
# Пути только абсолютные: actool резолвит относительные не от cwd.
echo "→ Сборка иконки из AppIcon.icon"
ROOT="$(pwd -P)"
ACTOOL_LOG="$(xcrun actool "$ROOT/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/build/actool-partial.plist")" || { echo "$ACTOOL_LOG"; exit 1; }
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "$ACTOOL_LOG"; echo "actool не создал Assets.car"; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Только строка меню, без иконки в Dock -->
  <key>LSUIElement</key><true/>
  <!-- Для AppleScript-перехода в iTerm2 и Terminal -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Переключение в окно терминала, где запущена сессия.</string>
</dict>
</plist>
PLIST

echo "→ Подпись (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo
echo "Готово: $APP"
echo "Запуск:  open $APP"
echo
echo "Дальше — Настройки → Подключение → Установить."

# --release: zip для GitHub Releases (ditto сохраняет права и подпись)
if [ "${1:-}" = "--release" ]; then
  mkdir -p dist
  ZIP="dist/$NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo
  echo "Релиз: $ZIP"
  shasum -a 256 "$ZIP"
fi
