#!/bin/bash
# Архивирует цель Mantel-MAS (App Store, песочница) на Mac Studio.
# В отличие от install.sh — НИЧЕГО не ставит в /Applications, только собирает
# .xcarchive для отправки в App Store Connect (Xcode Organizer / altool).
set -euo pipefail

cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
elif [ -d "Mantel.xcodeproj" ]; then
    echo "xcodegen не найден, использую готовый Mantel.xcodeproj"
else
    echo "Ошибка: xcodegen не найден и Mantel.xcodeproj отсутствует" >&2
    exit 1
fi

ARCHIVE="./build/Mantel-MAS.xcarchive"
UID_GUI=$(id -u)

# Как и в build.sh: по ssh keychain (сертификат распространения) недоступен напрямую —
# заворачиваем xcodebuild в GUI-сессию через launchctl asuser.
sudo -n launchctl asuser "$UID_GUI" sudo -u "$(whoami)" \
    xcodebuild -project Mantel.xcodeproj -scheme Mantel-MAS -configuration Release \
    -archivePath "$ARCHIVE" archive -allowProvisioningUpdates

echo "Архив: $ARCHIVE"
