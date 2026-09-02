#!/bin/bash
# Раскатка собранной версии на все машины.
# Mac Studio получает сборку через deploy.sh, ноутбуки — копией бандла по ssh.
set -euo pipefail
cd "$(dirname "$0")/.."
HOSTS="${HOSTS:-igor-mac olga-mac}"

echo "==> сборка и установка на Mac Studio"
bash scripts/deploy.sh | grep -E "BUILD|error:" | head -3

echo "==> упаковка бандла"
ssh macstudio 'cd ~/Projects/Mantel && rm -f /tmp/Mantel.tgz && tar czf /tmp/Mantel.tgz -C build/Build/Products/Release Mantel.app'
scp -q macstudio:/tmp/Mantel.tgz /tmp/Mantel.tgz
echo "    $(du -h /tmp/Mantel.tgz | cut -f1)"

for H in $HOSTS; do
    echo "==> $H"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" true 2>/dev/null; then
        echo "    недоступен, пропускаю"; continue
    fi
    scp -q /tmp/Mantel.tgz "$H:/tmp/"
    ssh "$H" 'set -e
        pkill -f "/Applications/Mantel.app" 2>/dev/null || true
        sleep 1
        rm -rf /Applications/Mantel.app
        tar xzf /tmp/Mantel.tgz -C /Applications
        xattr -dr com.apple.quarantine /Applications/Mantel.app 2>/dev/null || true
        rm -f /tmp/Mantel.tgz
        defaults write by.maru.Mantel launchAtLogin -bool true
        open -a /Applications/Mantel.app
        sleep 4
        pgrep -f "/Applications/Mantel.app" >/dev/null && echo "    запущено, версия $(defaults read /Applications/Mantel.app/Contents/Info.plist CFBundleShortVersionString)" || echo "    НЕ ЗАПУСТИЛОСЬ"'
done
echo "==> готово"
