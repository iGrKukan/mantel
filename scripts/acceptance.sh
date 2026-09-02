#!/bin/bash
# Приёмка ShelfTop. Запускать НА Mac Studio.
set -uo pipefail
LIB="$HOME/Library/Application Support/ShelfTop"
CAP="$LIB/Captures"
DESK="$HOME/Desktop"
SHOTS="$HOME/Screenshots"
GUI="sudo -n launchctl asuser $(id -u) sudo -u $(whoami)"
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }

echo "=== 0. приложение запущено ==="
pgrep -f '/Applications/ShelfTop.app' >/dev/null && ok "процесс ShelfTop жив" || no "процесс не найден"

echo "=== 1. скриншот с Рабочего стола уезжает в полку ==="
before=$(ls "$CAP" 2>/dev/null | wc -l | tr -d ' ')
$GUI screencapture -x "$DESK/Снимок экрана 2099-01-01 в 00.00.01.png" 2>/dev/null \
  || cp /System/Library/CoreServices/DefaultDesktop.heic "$DESK/Снимок экрана 2099-01-01 в 00.00.01.png" 2>/dev/null
sleep 4
if [ ! -e "$DESK/Снимок экрана 2099-01-01 в 00.00.01.png" ]; then ok "файл ушёл с Рабочего стола"; else no "файл остался на Рабочем столе"; fi
after=$(ls "$CAP" 2>/dev/null | wc -l | tr -d ' ')
[ "$after" -gt "$before" ] && ok "элемент появился в библиотеке ($before -> $after)" || no "в библиотеке не прибавилось"

echo "=== 3. обычный файл НЕ трогается ==="
echo "рабочий документ" > "$DESK/ShelfTop-обычный-файл.txt"
cp /System/Library/CoreServices/DefaultDesktop.heic "$DESK/отпуск.heic" 2>/dev/null
sleep 4
[ -e "$DESK/ShelfTop-обычный-файл.txt" ] && ok "txt на месте" || no "txt унесён!"
[ -e "$DESK/отпуск.heic" ] && ok "картинка не-захват на месте" || no "картинка унесена!"
rm -f "$DESK/ShelfTop-обычный-файл.txt" "$DESK/отпуск.heic"

echo "=== 7. индекс на диске ==="
[ -s "$LIB/index.json" ] && ok "index.json есть ($(wc -c < "$LIB/index.json") байт)" || no "index.json пуст/нет"
echo "  элементов в индексе: $(grep -c '"id"' "$LIB/index.json" 2>/dev/null)"
echo "  миниатюр: $(ls "$LIB/Thumbnails" 2>/dev/null | wc -l | tr -d ' ')"

echo "=== 8. CPU в простое ==="
sleep 5
cpu=$(ps -A -o %cpu,comm | grep -i 'ShelfTop' | grep -v grep | awk '{s+=$1} END {print s+0}')
rss=$(ps -A -o rss,comm | grep -i 'ShelfTop' | grep -v grep | awk '{s+=$1} END {printf "%.0f", s/1024}')
echo "  CPU=${cpu}%  RSS=${rss} МБ"
awk -v c="$cpu" 'BEGIN{exit !(c<3)}' && ok "CPU в простое < 3%" || no "CPU высокий: $cpu%"

echo "=== окно полки ==="
$GUI osascript -e 'tell application "System Events" to get name of every window of (first process whose bundle identifier is "by.maru.ShelfTop")' 2>&1 | head -2

echo
echo "ИТОГО: пройдено $pass, провалено $fail"
