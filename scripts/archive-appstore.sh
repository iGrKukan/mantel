#!/bin/bash
# Сборка App Store-версии, подпись сертификатом распространения и отправка в App Store Connect.
# Запускается НА macstudio. Ничего не устанавливает в /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID="75ZP2J5D59"
ISSUER="69a6de8e-0e6d-47e3-e053-5b8c7c11a4d1"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ARCHIVE="$PWD/build/Mantel-MAS.xcarchive"
EXPORT_DIR="$PWD/build/export"
GUI="sudo -n launchctl asuser $(id -u) sudo -u $(whoami)"

command -v xcodegen >/dev/null && xcodegen generate || echo "xcodegen нет — беру готовый .xcodeproj"

cat > /tmp/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>U5BAN54DL2</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "==> архивирую"
rm -rf "$ARCHIVE"
$GUI xcodebuild -project Mantel.xcodeproj -scheme Mantel-MAS -configuration Release \
  -archivePath "$ARCHIVE" archive -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  | tail -5

echo "==> экспортирую и отправляю в App Store Connect"
rm -rf "$EXPORT_DIR"
$GUI xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist /tmp/ExportOptions.plist -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  | tail -10
echo "готово"
