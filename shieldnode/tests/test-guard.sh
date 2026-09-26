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
    # 2026-09-25 (v1.1.7): guard проверяет админа через `nft get element` (учитывает CIDR)
    "get element inet shieldnode whitelist_v4 { "*)
        grep -q 'admin-wl' "$FAKE_NFT_DB/flags" 2>/dev/null; exit $? ;;
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
printf 'loopback scanner admin-wl' > "$OUT/nftdb/flags"
export SSH_CONNECTION="203.0.113.10 40000 10.0.0.1 22" SHIELD_UNIT_DIR="$OUT/units"
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
# FAKE_TIMER=0 — таймер блок-листов остановлен
case "\$*" in
    "is-enabled --quiet shieldnode.service") exit 0 ;;
    "is-active --quiet shieldnode-blocklist.timer") [ "\${FAKE_TIMER:-1}" = 1 ] ;;
    "list-timers --all --no-legend shieldnode-blocklist.timer") echo "Fri 2030-01-01 07:26:06 UTC 5h 56min - - shieldnode-blocklist.timer shieldnode-blocklist.service"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$OUT/bin/systemctl"
export PATH="$OUT/bin:$PATH"

source "$SHIELD_DIR/detect.sh"
source "$SHIELD_DIR/guard.sh"
# v1.2.0 (E5): раздел «проблемы» берётся из health/verify — подменяем их фикстурой
# (сами health/verify покрыты test-health / test-ports-sync)
HEALTH_FIX="$OUT/health.txt"; VERIFY_FIX="$OUT/verify.txt"
printf '  [PASS] table inet shieldnode присутствует\n  health: FAIL=0 WARN=0 PASS=1\n' > "$HEALTH_FIX"
printf '  ✔ prerouting: 40 правил\n' > "$VERIFY_FIX"
_g_health() { cat "$HEALTH_FIX"; }
_g_verify() { cat "$VERIFY_FIX"; }

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# --- firewall ABSENT: дашборд не падает ---
rm -f "$OUT/nftdb/table"
# ---------- 1. таблицы нет ----------
rm -f "$OUT/nftdb/table"
shield_guard > "$OUT/guard-absent.txt" 2>&1 || true
t "absent: не падает, «не применён» по-русски" grep -q "○ не применён" "$OUT/guard-absent.txt"
t "absent: вместо счётчиков — пояснение" grep -q "счётчиков нет — фаервол не применён" "$OUT/guard-absent.txt"
t "absent: снапшот НЕ создан без таблицы" bash -c "! test -f '$SHIELD_GUARD_SNAPSHOT'"
: > "$OUT/nftdb/table"

# ---------- 2. рабочая нода ----------
shield_guard > "$OUT/guard1.txt" 2>&1
t "active: «● работает»" grep -q "● работает" "$OUT/guard1.txt"
t "атаки по смыслу: сканеры 42" grep -qE "Сканеры интернета +42" "$OUT/guard1.txt"
t "атаки по смыслу: SYN-флуд -> «Флуд соединениями» 123 456 (разряды)" grep -qE "Флуд соединениями TCP/SYN +123 456" "$OUT/guard1.txt"
t "атаки по смыслу: invalid -> «Мусорные и поддельные пакеты» 7" grep -qE "Мусорные и поддельные пакеты +7" "$OUT/guard1.txt"
t "итого = сумма групп (123 505)" grep -qE "Итого +123 505" "$OUT/guard1.txt"
t "нулевые второстепенные группы скрыты (Tor), ключевые видны (UDP-флуд 0)" bash -c "! grep -q 'Выходы Tor' '$OUT/guard1.txt' && grep -qE 'UDP-флуд +0' '$OUT/guard1.txt'"
t "без технических имён счётчиков (c_drops_*) в обычном виде" bash -c "! grep -q 'c_drops_' '$OUT/guard1.txt'"
t "баны: SSH 1 (ssh_abusers)" grep -q "SSH 1 · TCP 0 · UDP 0" "$OUT/guard1.txt"
t "блок-листы: «Сканеры 3»" grep -q "Сканеры 3" "$OUT/guard1.txt"
t "блок-листы: время следующего обновления" grep -q "следующее через" "$OUT/guard1.txt"
t "проблем нет + админ в белом списке" grep -q "Проблем не найдено · ваш IP 203.0.113.10 в белом списке" "$OUT/guard1.txt"
t "без терминала — только снимок, без меню" bash -c "! grep -q 'Действия' '$OUT/guard1.txt'"
t "снапшот создан" test -f "$SHIELD_GUARD_SNAPSHOT"
t "снапшот: первая строка unixts" bash -c "head -1 '$SHIELD_GUARD_SNAPSHOT' | grep -qE '^[0-9]+\$'"

# ---------- 3. дельты «+N с прошлого просмотра» ----------
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
t "дельта: SYN-флуд +100" grep -qE "Флуд соединениями TCP/SYN +123 556 +\+100" "$OUT/guard2.txt"
t "дельта: сканеры +0 (не менялись)" grep -qE "Сканеры интернета +42 +\+0" "$OUT/guard2.txt"
t "дельта: итого +110" grep -qE "Итого +123 615 +\+110" "$OUT/guard2.txt"

# ---------- 4. проблемы — ровно то, что нашёл health (прод E5: «проблем нет» при WARN=12) ----------
cat > "$HEALTH_FIX" <<'EOF'
  [PASS] table inet shieldnode присутствует
  [WARN] инбаунд 8443/tcp не в protected_tcp — нужен apply
  [WARN] shieldnode-blocklist.timer НЕ активен — блоклисты не обновляются
  [FAIL] SSH 22: защитных правил нет (порт сменился после apply?) — повтори apply
  [INFO] последний apply: 2026-09-25
  health: FAIL=1 WARN=2 PASS=1
EOF
shield_guard > "$OUT/guard3.txt" 2>&1
t "health WARN=2 FAIL=1 -> НЕТ «Проблем не найдено»" bash -c "! grep -q 'Проблем не найдено' '$OUT/guard3.txt'"
t "проблемы: оба WARN health показаны" bash -c "grep -q 'инбаунд 8443/tcp не в protected_tcp' '$OUT/guard3.txt' && grep -q 'blocklist.timer НЕ активен' '$OUT/guard3.txt'"
t "проблемы: FAIL помечен ✘" grep -q "✘ SSH 22: защитных правил нет" "$OUT/guard3.txt"
t "проблемы: INFO/PASS не выводятся как проблемы" bash -c "! grep -q 'последний apply' '$OUT/guard3.txt'"
printf '  [PASS] ok\n  health: FAIL=0 WARN=0 PASS=1\n' > "$HEALTH_FIX"
printf '  ✔ prerouting: 40 правил\n  ✘ нет IPv6 fail-safe в prerouting\n' > "$VERIFY_FIX"
shield_guard > "$OUT/guard4.txt" 2>&1
t "verify ✘ -> проблема (даже если health чист)" grep -q "✘ нет IPv6 fail-safe в prerouting" "$OUT/guard4.txt"
printf '' > "$HEALTH_FIX"; printf '' > "$VERIFY_FIX"
shield_guard > "$OUT/guard5.txt" 2>&1
t "health не выполнился -> не «Проблем не найдено», а просьба запустить проверку" bash -c "grep -q 'полная проверка не выполнилась' '$OUT/guard5.txt' && ! grep -q 'Проблем не найдено' '$OUT/guard5.txt'"
printf '  [PASS] ok\n  health: FAIL=0 WARN=0 PASS=1\n' > "$HEALTH_FIX"; printf '  ✔ ok\n' > "$VERIFY_FIX"

# ---------- 5. технический вид ----------
SHIELD_GUARD_MODE=raw shield_guard > "$OUT/guard-raw.txt" 2>&1
t "--raw: технические счётчики nft" grep -qE "c_drops_syn_v4 +123556" "$OUT/guard-raw.txt"

# ---------- 6. меню (в терминале) ----------
if command -v script >/dev/null 2>&1; then
    printf '1\n\n2\n1.2.3\n\n0\n' | SHIELD_GUARD_MODE=menu bash -c 'source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config; source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/guard.sh"; shield_guard' > "$OUT/guard-menu.txt" 2>&1 || true
    t "меню: пункты действий по-русски" bash -c "grep -q 'Кто сейчас в бане' '$OUT/guard-menu.txt' && grep -q 'Разбанить IP' '$OUT/guard-menu.txt' && grep -q 'Доверенные IP' '$OUT/guard-menu.txt'"
    t "меню: «кто в бане» показывает набор SSH" grep -q "45.148.10.0/28" "$OUT/guard-menu.txt"
    t "меню: мусорный IP при разбане отвергнут" bash -c "grep -q '«1.2.3» — не IP-адрес' '$OUT/guard-menu.txt' || grep -q 'Нужен root' '$OUT/guard-menu.txt'"
fi
echo
if [ "$fails" -eq 0 ]; then echo "PASS: guard (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
