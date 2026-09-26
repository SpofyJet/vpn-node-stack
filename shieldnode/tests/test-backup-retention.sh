#!/bin/bash
# shieldnode — тест: дампы ruleset'а ротируются и не читаются посторонними (v1.1.6).
# Раньше каждый apply писал ~1МБ-дамп в /var/lib/shieldnode/backups без ротации (живая
# нода: 21 файл / 13МБ), файлы 0644 — внутри whitelist (IP админа и панели).
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_CONFIG="$OUT/c"; : > "$OUT/log"
source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
run() { printf '%b' "$1" > "$OUT/c"; shield_load_config >/dev/null 2>&1
    ( source "$SHIELD_DIR/firewall.sh"; shield_backup_dir_prep; shield_backup_prune ) || echo "FAIL - prep/prune недоступны"; }
B="$OUT/state/backups"
# пустой/отсутствующий каталог (чистый старт) под set -e: prune не должен ронять apply
# отдельный процесс bash: в `( ... ) || rc=$?` errexit внутри subshell отключён и сбой не виден
printf '' > "$OUT/c"
rc=0; bash -c 'set -euo pipefail; source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1
    source "$SHIELD_DIR/firewall.sh"; shield_backup_dir_prep; shield_backup_prune; echo reached' > "$OUT/clean.out" 2>&1 || rc=$?
grep -q reached "$OUT/clean.out" || rc=99
t "чистый старт (дампов нет) под set -e/pipefail: rc 0" "[ $rc = 0 ]"
mkdir -p "$B"; chmod 755 "$B"
for i in 01 02 03 04 05 06 07 08; do echo x > "$B/202609$i-000000.nft"; touch -d "2026-09-$i" "$B/202609$i-000000.nft"; done
for i in 01 02 03 04 05 06 07; do echo e > "$B/emergency-202609$i-000000.nft"; touch -d "2026-09-$i" "$B/emergency-202609$i-000000.nft"; done
chmod 644 "$B"/*.nft
run 'BACKUP_KEEP=3\n'
t "обычные дампы: осталось 3 самых новых (06-08)" "[ \"\$(ls $B | grep -v emergency | tr '\n' ' ')\" = '20260906-000000.nft 20260907-000000.nft 20260908-000000.nft ' ]"
t "emergency-дампы ротируются отдельно: 3 новых" "[ \"\$(ls $B | grep -c emergency)\" = 3 ] && [ -e $B/emergency-20260907-000000.nft ]"
t "каталог 0700, файлы 0600" "[ \"\$(stat -c %a $B)\" = 700 ] && [ -z \"\$(find $B -type f ! -perm 600)\" ]"
run 'BACKUP_KEEP=abc\n'
t "BACKUP_KEEP мусор -> 5 (ничего лишнего не удалено)" "[ \"\$(ls $B | wc -l)\" = 6 ]"
t "apply пишет дамп через umask 077 и ротацию" "grep -q 'umask 077; shield_table_dump' '$SHIELD_DIR/firewall.sh' && grep -q 'shield_backup_prune' '$SHIELD_DIR/firewall.sh' && grep -q 'shield_backup_prune' '$SHIELD_DIR/emergency.sh'"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: backup-retention (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
