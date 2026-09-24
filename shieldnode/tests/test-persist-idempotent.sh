#!/bin/bash
# shieldnode — тест: persist не перезаписывает и не бэкапит файл с тем же содержимым.
# 2026-09-24 (v1.1.5): каждый apply переписывал все свои файлы с .pre-shieldnode-*:
# при BACKUP_KEEP=5 пять повторных apply вытесняли значимые версии одинаковыми копиями.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/state" "$OUT/etc"
export SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_CONFIG="$OUT/c" DRY_RUN=0
: > "$OUT/c"; : > "$OUT/log"
source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1 || true
source "$SHIELD_DIR/persist.sh"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
F="$OUT/etc/shieldnode.conf"
echo "x" | shield_persist_stream "$F" 0640 >/dev/null 2>&1
m1="$(stat -c %Y.%i "$F")"; sleep 1
echo "x" | shield_persist_stream "$F" 0640 >/dev/null 2>&1
t "то же содержимое: файл не переписан" "[ \"\$(stat -c %Y.%i $F)\" = '$m1' ]"
t "то же содержимое: .pre-shieldnode-* не создан" "! ls $F.pre-shieldnode-* >/dev/null 2>&1"
chmod 0666 "$F"; echo "x" | shield_persist_stream "$F" 0640 >/dev/null 2>&1
t "то же содержимое, другой режим: режим восстановлен (0640)" "[ \$(stat -c %a $F) = 640 ]"
echo "y" | shield_persist_stream "$F" 0640 >/dev/null 2>&1
t "другое содержимое: записано, backup прежней версии есть" "grep -qx y $F && grep -qx x \$(ls $F.pre-shieldnode-* | head -1)"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: persist-idempotent (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
