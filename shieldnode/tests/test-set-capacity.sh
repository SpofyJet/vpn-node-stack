#!/bin/bash
# shieldnode — тест: ёмкость interval-блоклистов = *_BLOCKLIST_SIZE ЗАПИСЕЙ (настоящий nft).
# 2026-09-24 (v1.1.4): interval-сет `size N` в ядре вмещает только N/2 несмежных
# интервалов (узлы начала+конца + служебный; замер на 6.8: N записей требуют size >= 2N+1).
# CUSTOM_BLOCKLIST_SIZE=1000 на деле давал 499. Теперь генератор объявляет size 2*N+1,
# а updater при превышении ёмкости пишет внятный warn и не трогает сет.
# Под root: `unshare -mn` + tmpfs поверх путей apply/updater; systemctl/logger — заглушки.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /etc/shieldnode /etc/systemd/system /etc/tmpfiles.d /usr/local/sbin /var/lib/shieldnode /var/log /run; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-cap
rm -rf "$OUT"; mkdir -p "$OUT/bin"
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG=/var/log/shieldnode.log
export SHIELD_LOCK=/run/shieldnode/shieldnode.lock SHIELD_CONFIG="$OUT/config.conf" SHIELD_EXCLUDE="$OUT/none"
: > /var/log/shieldnode.log; unset SSH_CONNECTION
printf 'CUSTOM_BLOCKLIST_SIZE=1000\n' > "$SHIELD_CONFIG"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/systemctl"; cp "$OUT/bin/systemctl" "$OUT/bin/logger"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

bash "$SHIELD_DIR/main.sh" --dry-run apply 2>/dev/null \
  | awk '/^table inet shieldnode$/{on=1} on && !/^20[0-9][0-9]-[0-9-]+T[0-9:]+Z \[/' > "$OUT/rs.nft"
t "ruleset загружен" "nft -f $OUT/rs.nft"
(
    source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
    source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"; source "$SHIELD_DIR/limits.sh"
    source "$SHIELD_DIR/lib/blocklist.sh"
    shield_limits_resolve
    shield_persist_stream() { mkdir -p "$(dirname "$1")"; cat > "$1"; chmod "${2:-0644}" "$1"; }
    shield_manifest_record() { :; }
    shield_blocklist_install
) >/dev/null 2>&1
UPD=/usr/local/sbin/shieldnode-blocklist
t "updater эмитирован" "test -x $UPD"
printf 'BL_URLS_custom=""\n' > /etc/shieldnode/blocklist.conf
# N несмежных /32 (через один адрес — auto-merge/collapse их не сольёт)
gen() { awk -v n="$1" 'BEGIN{for(i=0;i<n;i++) printf "45.%d.%d.%d\n", 60+int(i/(125*250)), int(i/125)%250, (i%125)*2+1}'; }
cnt() { nft list set inet shieldnode custom_blocklist_v4 | tr ',' '\n' | grep -c '45\.' || true; }
export -f cnt

gen 1000 > /etc/shieldnode/lists/custom.txt
rc=0; bash "$UPD" custom >/dev/null 2>&1 || rc=$?
t "SIZE=1000: 1000 несмежных записей загружены (раньше ёмкость была 499: size N -> (N-1)/2)" "[ $rc = 0 ] && [ \"\$(cnt)\" = 1000 ]"

gen 1001 > /etc/shieldnode/lists/custom.txt
rc=0; bash "$UPD" custom >/dev/null 2>&1 || rc=$?
t "SIZE=1000: 1001 запись — updater rc!=0, сет НЕ тронут (прежние 1000)" "[ $rc != 0 ] && [ \"\$(cnt)\" = 1000 ]"
t "SIZE=1000: внятный warn о превышении ёмкости (а не только ENOBUFS)" "grep -q 'custom: 1001 .*ёмкост' /var/log/shieldnode.log"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: set-capacity (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
