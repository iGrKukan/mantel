#!/bin/bash
# Локальный скрипт: залить исходники на Mac Studio, собрать, подписать, установить.
set -euo pipefail
cd "$(dirname "$0")/.."
REMOTE=${REMOTE:-macstudio}
DEST=${DEST:-'~/Projects/Mantel'}

echo "==> генерирую .xcodeproj локально"
xcodegen generate

echo "==> rsync -> $REMOTE:$DEST"
ssh "$REMOTE" "mkdir -p $DEST"
rsync -az --delete \
  --exclude build/ --exclude .git/ --exclude DerivedData/ \
  ./ "$REMOTE:$DEST/"

echo "==> сборка и установка на $REMOTE"
ssh "$REMOTE" "cd $DEST && bash scripts/install.sh"
