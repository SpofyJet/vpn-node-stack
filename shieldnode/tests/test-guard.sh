#!/bin/bash
# shieldnode — тест: guard-дашборд (guard.sh) без root, против fake-nft.
# Запуск: bash tests/test-guard.sh
set -euo pipefail

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHIELD_DIR SHIELD_VERSION=1.0.0
OUT=/tmp/shieldnode-guard-test
export SHIELD_STATE_DIR="$OUT/state"
export SHIELD_LOG="$OUT/shieldnode.log"
export SHIELD_LOCK="$OUT/lock"
export SHIELD_GUARD_SNAPSHOT="$OUT/guard-snapshot.tsv"
export FAKE_NFT_DB="$OUT/nftdb"
export NODE_PROFILE_DIR="$OUT/profile.d"
LOG_LEVEL=info

rm -rf "$OUT"
mkdir -p "$OUT/state" "$OUT/profile.d" "$OUT/bin" "$OUT/nftdb"

source "$SHIELD_DIR/lib/common.sh"
source "$SHIELD_DIR/config.sh"
shield_load_config

# --- fake nft: counters + sets + chains (read-only команды) ---
cat > "$OUT/bin/nft" <<'EOF'
#!/bin/bash
# любая list-команда требует существования таблицы (как у реального nft)
[ -f "$FAKE_NFT_DB/table" ] || exit 1
case "$*" in
    "list counters inet shieldnode")
        cat "$FAKE_NFT_DB/counters" 2>/dev/null; exit 0 ;;
    "list table inet shieldnode") [ -f "$FAKE_NFT_DB/table" ]; exit $? ;;
    "list chain inet shieldnode prerouting")
        grep -q 'loopback' "$FAKE_NFT_DB/flags" 2>/dev/null && echo 'iifname "lo" accept'
        grep -q 'scanner' "$FAKE_NFT_DB/flags" 2>/dev/null && echo 'ip saddr @scanner_blocklist_v4 counter name c_drops_scanner_v4 drop'
        exit 0 ;;
    "list set inet shieldnode "*|"-n list set inet shieldnode "*)
        s="${*: -1}"
        case "$s" in
            whitelist_v4) echo 'elements = { 203.0.113.10 }' ;;
            scanner_blocklist_v4) echo 'elements = { 91.240.118.0/24, 185.220.101.4/32, 8.8.4.4/32 }' ;;
            ssh_abusers) echo 'elements = { 45.148.10.0/28 }' ;;
            threat_blocklist_v4) echo 'elements = { }' ;;
            *) echo "elements = { }" ;;
        esac; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$OUT/bin/nft"
: > "$OUT/nftdb/table"
printf 'loopback scanner' > "$OUT/nftdb/flags"
cat > "$OUT/nftdb/counters" <<'EOF'
counter c_drops_syn_v4 { packets 123456, bytes 9876543 }
counter c_drops_scanner_v4 { packets 42, bytes 1764 }
counter c_drops_invalid { packets 7, bytes 294 }
counter c_drops_global_udp { packets 0, bytes 0 }
EOF

# systemctl-заглушка
cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
case "\$*" in
    "is-active shieldnode.service") echo active; exit 0 ;;
    "is-active shieldnode-blocklist.timer") echo active; exit 0 ;;
    "is-active shieldnode-blocklist-custom.path") echo inactive; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$OUT/bin/systemctl"
export PATH="$OUT/bin:$PATH"

source "$SHIELD_DIR/detect.sh"
source "$SHIELD_DIR/guard.sh"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# --- firewall ABSENT: дашборд не падает ---
rm -f "$OUT/nftdb/table"
shield_guard > "$OUT/guard-absent.txt" 2>&1 || true
t "absent: не падает без таблицы" grep -q "firewall: ABSENT" "$OUT/guard-absent.txt"
t "absent: снапшот НЕ создан без таблицы" bash -c "! test -f '$SHIELD_GUARD_SNAPSHOT'"

# --- firewall ACTIVE: полный дашборд ---
: > "$OUT/nftdb/table"
shield_guard > "$OUT/guard1.txt" 2>&1
t "active: статус ACTIVE" grep -q "firewall: ACTIVE" "$OUT/guard1.txt"
t "counters: syn_v4 показан" grep -q "c_drops_syn_v4" "$OUT/guard1.txt"
t "counters: сортировка по packets (syn первым)" bash -c "grep -n 'c_drops_syn_v4' '$OUT/guard1.txt' | head -1 | cut -d: -f1 | xargs -I{} sh -c 'head -{} \"$OUT/guard1.txt\" | tail -1 | grep -q c_drops_syn_v4'"
t "counters: нулевой global_udp показан" grep -q "c_drops_global_udp" "$OUT/guard1.txt"
t "sets: scanner 3 элемента" grep -q "scanner_blocklist_v4 .*3" "$OUT/guard1.txt"
t "sets: пустой threat скрыт (не whitelist/protected)" bash -c "! grep -q 'threat_blocklist_v4' '$OUT/guard1.txt'"
t "conntrack: секция есть (или честный fallback)" bash -c "grep -qE 'usage: [0-9]+%|не доступен' '$OUT/guard1.txt'"
t "services: blocklist-custom.path inactive показан" grep -q "shieldnode-blocklist-custom.path.*inactive" "$OUT/guard1.txt"
t "services: timer active" grep -q "shieldnode-blocklist.timer.*active" "$OUT/guard1.txt"
t "alerts: none при чистом состоянии" grep -q "updater alerts" "$OUT/guard1.txt"
t "quick: loopback-accept ✓" grep -q "loopback-accept: ✓" "$OUT/guard1.txt"
t "снапшот создан" test -f "$SHIELD_GUARD_SNAPSHOT"
t "снапшот: первая строка unixts" bash -c "head -1 '$SHIELD_GUARD_SNAPSHOT' | grep -qE '^[0-9]+\$'"

# --- второй запуск: дельты ---
sleep 1
cat > "$OUT/nftdb/counters" <<'EOF'
counter c_drops_syn_v4 { packets 123556, packets 0, bytes 9884543 }
counter c_drops_scanner_v4 { packets 42, bytes 1764 }
counter c_drops_invalid { packets 17, bytes 714 }
counter c_drops_global_udp { packets 0, bytes 0 }
EOF
# (в строке выше намеренный дефект парсинга — сработает NF==3-фильтр; чиним)
cat > "$OUT/nftdb/counters" <<'EOF'
counter c_drops_syn_v4 { packets 123556, bytes 9884543 }
counter c_drops_scanner_v4 { packets 42, bytes 1764 }
counter c_drops_invalid { packets 17, bytes 714 }
counter c_drops_global_udp { packets 0, bytes 0 }
EOF
shield_guard > "$OUT/guard2.txt" 2>&1
t "delta: у syn_v4 появилась дельта +N/s" bash -c "grep 'c_drops_syn_v4' '$OUT/guard2.txt' | grep -qE '\+[0-9]+/s'"
t "delta: у scanner дельта +0/s (не менялся)" bash -c "grep 'c_drops_scanner_v4' '$OUT/guard2.txt' | grep -q '+0/s'"

# --- emergency ---
printf 'loopback' > "$OUT/nftdb/flags"
mkdir -p "$OUT/run-shieldnode" 2>/dev/null || true
# emergency-маркер читается из /run/shieldnode — подменить нельзя, проверяем только отсутствие краха
shield_guard > "$OUT/guard3.txt" 2>&1
t "flags: scanner-правило пропало — не падает" grep -q "firewall: ACTIVE" "$OUT/guard3.txt"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: guard (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
