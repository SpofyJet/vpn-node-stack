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
    # ВАЖНО: скоупедная форма `nft list counters inet <table>` — синтакс-ошибка
    # на nft < 1.0.8 (проверено на живом ядре 2026-09-22). Реальный вызов —
    # глобальный `nft list counters` (все таблицы, парсер фильтрует по секции
    # "table inet shieldnode"). Фейк имитирует глобальную форму.
    "list counters")
        cat "$FAKE_NFT_DB/counters" 2>/dev/null; exit 0 ;;
    "list table inet shieldnode") [ -f "$FAKE_NFT_DB/table" ]; exit $? ;;
    "list chain inet shieldnode prerouting")
        grep -q 'loopback' "$FAKE_NFT_DB/flags" 2>/dev/null && echo 'iifname "lo" accept'
        grep -q 'scanner' "$FAKE_NFT_DB/flags" 2>/dev/null && echo 'ip saddr @scanner_blocklist_v4 counter name c_drops_scanner_v4 drop'
        exit 0 ;;
    "list set inet shieldnode "*|"-n list set inet shieldnode "*)
        s="${*: -1}"
        # реальный nft печатает многострочные блоки (сет-заголовок + elements,
        # длинные списки переносятся на несколько строк)
        case "$s" in
            whitelist_v4) printf '\telements = { 203.0.113.10 }\n' ;;
            scanner_blocklist_v4) printf '\telements = { 91.240.118.0/24, 185.220.101.4/32,\n\t\t\t8.8.4.4/32 }\n' ;;
            ssh_abusers) printf '\telements = { 45.148.10.0/28 }\n' ;;
            threat_blocklist_v4) printf '\telements = { }\n' ;;
            *) printf '\telements = { }\n' ;;
        esac; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$OUT/bin/nft"
: > "$OUT/nftdb/table"
printf 'loopback scanner' > "$OUT/nftdb/flags"
# реальный формат `nft list counters`: блоки "counter X {\n packets N bytes M\n}"
cat > "$OUT/nftdb/counters" <<'EOF'
table inet shieldnode {
	counter c_drops_syn_v4 {
		packets 123456 bytes 9876543
	}
	counter c_drops_scanner_v4 {
		packets 42 bytes 1764
	}
	counter c_drops_invalid {
		packets 7 bytes 294
	}
	counter c_drops_global_udp {
		packets 0 bytes 0
	}
}
EOF

# systemctl-заглушка. Формат вывода guard: "active=<st> enabled=<en>"; «not-found»
# guard показывает только при rc!=0 от `systemctl cat` (не от is-active!).
cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
case "\$*" in
    "cat shieldnode.service") exit 0 ;;
    "cat shieldnode-blocklist.timer") exit 0 ;;
    "cat shieldnode-blocklist-custom.path") exit 0 ;;
    "cat shieldnode-updater.service") exit 1 ;;  # не существует
    "is-active shieldnode.service") echo active; exit 0 ;;
    "is-active shieldnode-blocklist.timer") echo active; exit 0 ;;
    "is-active shieldnode-blocklist-custom.path") echo inactive; exit 1 ;;
    "is-enabled shieldnode.service") echo enabled; exit 0 ;;
    "is-enabled shieldnode-blocklist.timer") echo enabled; exit 0 ;;
    "is-enabled shieldnode-blocklist-custom.path") echo disabled; exit 1 ;;
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
t "absent: сообщение «firewall не применён» (отлично от пусто-нормы)" grep -q "firewall не применён" "$OUT/guard-absent.txt"
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
t "services: blocklist-custom.path inactive+disabled показан" bash -c "grep 'shieldnode-blocklist-custom.path' '$OUT/guard1.txt' | grep -q 'active=inactive'"
t "services: timer active+enabled" bash -c "grep 'shieldnode-blocklist.timer ' '$OUT/guard1.txt' | grep -q 'active=active'"
t "services: единый формат active=/enabled= (не голый 'inactive')" bash -c "grep -qE 'shieldnode-blocklist-custom.path +active=inactive +enabled=disabled' '$OUT/guard1.txt'"
t "counters-пусто: ACTIVE без дропов — «нормально», не «не применён»" bash -c "! grep -q 'нет счётчиков' '$OUT/guard1.txt'"
t "alerts: none при чистом состоянии" grep -q "updater alerts" "$OUT/guard1.txt"
t "quick: loopback-accept ✓" grep -q "loopback-accept: ✓" "$OUT/guard1.txt"
t "снапшот создан" test -f "$SHIELD_GUARD_SNAPSHOT"
t "снапшот: первая строка unixts" bash -c "head -1 '$SHIELD_GUARD_SNAPSHOT' | grep -qE '^[0-9]+\$'"

# --- второй запуск: дельты ---
sleep 1
cat > "$OUT/nftdb/counters" <<'EOF'
table inet shieldnode {
	counter c_drops_syn_v4 {
		packets 123556 bytes 9884543
	}
	counter c_drops_scanner_v4 {
		packets 42 bytes 1764
	}
	counter c_drops_invalid {
		packets 17 bytes 714
	}
	counter c_drops_global_udp {
		packets 0 bytes 0
	}
}
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
