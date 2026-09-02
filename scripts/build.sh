#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Проект генерируем через xcodegen, если он есть; если нет — используем
# готовый .xcodeproj, который приезжает вместе с исходниками.
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
elif [ -d "ShelfTop.xcodeproj" ]; then
    echo "xcodegen не найден, использую готовый ShelfTop.xcodeproj"
else
    echo "Ошибка: xcodegen не найден и ShelfTop.xcodeproj отсутствует" >&2
    exit 1
fi

# Сборка без подписи — подпишем отдельно настоящим сертификатом ниже,
# т.к. по ssh keychain недоступен напрямую.
xcodebuild -project ShelfTop.xcodeproj -scheme ShelfTop -configuration Release \
    -derivedDataPath ./build CODE_SIGNING_ALLOWED=NO build

APP="./build/Build/Products/Release/ShelfTop.app"
IDENTITY="Apple Development: Ihar Shkredau (ZVYKY9TF2X)"
UID_GUI=$(id -u)

# Подпись через GUI-сессию (по ssh keychain напрямую недоступен).
sudo -n launchctl asuser "$UID_GUI" sudo -u "$(whoami)" codesign --force --deep --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 || true

echo "Собрано: $APP"
