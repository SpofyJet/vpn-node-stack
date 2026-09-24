#!/bin/bash
# shieldnode — тест: abuse-журнал содержит адреса, а не сырой вывод nft (настоящий nft).
# 2026-09-24 (v1.1.5): nft печатает `\t\telements = { A timeout 1h expires 40m, B ... }`
# с отступом; парсер срезал `^elements = {` только с 1-й колонки — на живой ноде
# журнал писал «elements = { 133.18.122.63 timeout 1h expires 40m29s912ms».
# Проверка test-weakspots-112 проходила лишь потому, что живые сеты были пусты.
# Под root: `unshare -mn` (свой netns с таблицей inet shieldnode).
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_CONFIG="$OUT/c"
mkdir -p "$SHIELD_STATE_DIR"; : > "$OUT/c"; : > "$OUT/log"
nft -f - <<'NFT'
table inet shieldnode {
    set ssh_abusers { type ipv4_addr; size 65536; flags dynamic,timeout; timeout 1h; }
    set tcp_abusers_v6 { type ipv6_addr; size 65536; flags dynamic,timeout; timeout 15m; }
    set temporary_blocklist { type ipv4_addr; size 32768; flags dynamic,timeout; timeout 1h; }
}
NFT
nft add element inet shieldnode ssh_abusers '{ 133.18.122.63, 198.51.100.7, 203.0.113.9 }'
nft add element inet shieldnode tcp_abusers_v6 '{ 2001:db8::5, fd00::17 }'
source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1 || true
source "$SHIELD_DIR/limits.sh"
shield_abuse_journal_append
J="$SHIELD_STATE_DIR/abuse.journal"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
t "журнал: только ###/## заголовки и адреса (без elements/timeout/expires/скобок)" \
  "! grep -vE '^(### |## |[0-9a-f:.]+(/[0-9]+)?\$)' $J"
t "журнал: ssh_abusers — все 3 адреса" "grep -qx 133.18.122.63 $J && grep -qx 198.51.100.7 $J && grep -qx 203.0.113.9 $J"
t "журнал: v6 (в т.ч. на букву: fd00::17)" "grep -qx 2001:db8::5 $J && grep -qx fd00::17 $J"
t "журнал: пустые сеты не пишутся" "! grep -qx '## temporary_blocklist' $J"
# большой сет: явный предел 100 адресов, честный итог в заголовке
nft add set inet shieldnode udp_abusers '{ type ipv4_addr; size 65536; flags dynamic,timeout; timeout 15m; }'
awk 'BEGIN{printf "add element inet shieldnode udp_abusers { "; for(i=0;i<250;i++) printf "%s198.18.0.%d", (i?", ":""), i+1; print " }"}' | nft -f -
: > "$J"; shield_abuse_journal_append
t "журнал: большой сет — заголовок с итогом и ровно 100 адресов" \
  "grep -qx '## udp_abusers (первые 100 из 250)' $J && [ \$(awk '/^## udp_abusers/{f=1; next} /^#/{f=0} f' $J | wc -l) = 100 ]"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: abuse-journal (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
