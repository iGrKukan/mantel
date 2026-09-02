#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

# Гасим запущенное приложение перед заменой.
pkill -f '/Applications/Mantel.app' || true
sleep 1

APP_SRC="./build/Build/Products/Release/Mantel.app"
if [ ! -d "$APP_SRC" ]; then
    echo "Ошибка: сборка не найдена по пути $APP_SRC" >&2
    exit 1
fi

# До сюда доходим только если build.sh отработал (set -e) — сборка удалась.
rm -rf /Applications/Mantel.app
cp -R "$APP_SRC" /Applications/Mantel.app
xattr -dr com.apple.quarantine /Applications/Mantel.app || true

open -a /Applications/Mantel.app

VERSION=$(defaults read /Applications/Mantel.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "?")
echo "Версия: $VERSION"
codesign -dv /Applications/Mantel.app 2>&1 || true
