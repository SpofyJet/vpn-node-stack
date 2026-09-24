#!/bin/bash
# shieldnode — тест: секция health в status (v1.1.3, 2026-09-23).
# «Живая» таблица эмулируется: фейковый nft отдаёт РЕАЛЬНЫЙ ruleset генератора
# (shield_nft_build_ruleset) — list table/chain/set/counters; элементы сетов и
# значения счётчиков — из фикстур. Против него внедряются неисправности:
# дрейф конфиг<->таблица, drop до accept, пустые/устаревшие/алертные блоклисты,
# внешний порт xray вне protected_*, EXTRA вне сета, SSH-порт без правил,
# emergency, отсутствующая таблица, неактивные таймер/служба. Отдельно: таблица
# гейтинга health == гейтинг генератора на всех флагах и дефолтах.
# Сценарии с /run и /etc/node-profile.d — в `unshare -m` (root); без root — skip.
set -euo pipefail
if [ "$(id -u)" -eq 0 ] && [ "${SHIELD_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    SHIELD_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
[ "${SHIELD_TEST_IN_NS:-0}" = "1" ] || { echo "SKIP: нужен root + unshare -m (эмуляция /run, /etc/node-profile.d)"; exit 77; }
for d in /run /etc/node-profile.d; do mkdir -p "$d"; mount -t tmpfs t "$d"; done

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-health
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state" "$OUT/elems" "$OUT/bl"
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_EXCLUDE="$OUT/none" SHIELD_UFW_DIR="$OUT/no-ufw"
export SHIELD_BLOCKLIST_STATE="$OUT/bl" LIVE="$OUT/live.nft" ELEMS="$OUT/elems" CNTS="$OUT/counters"
: > "$SHIELD_LOG"; : > "$CNTS"; unset SSH_CONNECTION

cat > "$OUT/bin/nft" <<'EOF'
#!/bin/bash
# фейковый nft: «ядро» = $LIVE (вывод генератора), элементы — $ELEMS/<set>
a=("$@"); [ "${a[0]}" = "-n" ] && a=("${a[@]:1}")
[ -f "$LIVE" ] || exit 1
block() { awk -v k="$1" -v n="$2" '$1 == k && $2 == n {f = 1} f {print} f && /^    }/ {exit}' "$LIVE"; }
case "${a[*]}" in
  "list table inet shieldnode") exit 0 ;;
  "list chains inet shieldnode") grep -E "^    chain " "$LIVE" ;;
  "list chain inet shieldnode "*)
      b="$(block chain "${a[4]}")"; [ -n "$b" ] || exit 1; printf 'table inet shieldnode {\n%s\n}\n' "$b" ;;
  "list set inet shieldnode "*)
      b="$(block set "${a[4]}")"; [ -n "$b" ] || exit 1
      if [ -s "$ELEMS/${a[4]}" ]; then b="$(printf '%s\n' "$b" | sed '/elements = /d; $d')"; printf 'table inet shieldnode {\n%s\n\t\telements = { %s }\n    }\n}\n' "$b" "$(paste -sd, "$ELEMS/${a[4]}" | sed 's/,/,\n\t\t\t     /g')"
      else printf 'table inet shieldnode {\n%s\n}\n' "$b"; fi ;;
  "list counters") echo "table inet shieldnode {"; while read -r n p; do printf '\tcounter %s {\n\t\tpackets %s bytes %s\n\t}\n' "$n" "$p" "$((p * 60))"; done < "$CNTS"; echo "}" ;;
  *) exit 0 ;;
esac
EOF
cat > "$OUT/bin/ss" <<'EOF'
#!/bin/bash
case "$*" in
  "-tlnp") printf '%s\n' 'State Recv-Q Send-Q Local Peer Process' \
     'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
     'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=7,fd=7))' \
     'LISTEN 0 4096 127.0.0.1:10085 0.0.0.0:* users:(("xray",pid=7,fd=8))' ;;
  "-ulnp") [ -n "${SS_UDP:-}" ] && printf '%s\n' 'State Recv-Q Send-Q Local Peer Process' "UNCONN 0 0 0.0.0.0:${SS_UDP} 0.0.0.0:* users:((\"xray\",pid=7,fd=9))" ;;
  "-tulnp") printf '%s\n' 'Netid State Recv-Q Send-Q Local Peer Process' 'tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=7,fd=7))' ;;
esac; exit 0
EOF
cat > "$OUT/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in *is-active*timer*) [ "${FAKE_TIMER:-1}" = 1 ] ;; *is-enabled*shieldnode.service*) [ "${FAKE_SVC:-1}" = 1 ] ;; *) exit 0 ;; esac
EOF
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"
for f in detect.sh limits.sh lib/nft.sh ssh.sh status.sh; do source "$SHIELD_DIR/$f"; done

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
cfg()  { printf '%b' "$1" > "$OUT/cfg.conf"; SHIELD_CONFIG="$OUT/cfg.conf" shield_load_config; }
gen()  { cfg "$1"; ( shield_limits_resolve >/dev/null 2>&1; SH_F_IPV6=1; shield_nft_build_ruleset ) > "$LIVE"; }
H()    { shield_health > "$OUT/h.txt" 2>&1; }
has()  { grep -qF -- "$1" "$OUT/h.txt"; }
sumf() { grep -oE "health: FAIL=[0-9]+ WARN=[0-9]+" "$OUT/h.txt"; }
# 2026-09-24 (v1.1.6): crowdsec включён по умолчанию — здоровая нода имеет и его сет
fill() { local s; for s in scanner_blocklist_v4 threat_blocklist_v4 custom_blocklist_v4 spamhaus_blocklist_v4 cins_blocklist_v4 crowdsec_blocklist_v4; do printf '1.2.3.0/24\n5.6.7.8/32\n' > "$ELEMS/$s"; done
         for n in scanner threat custom spamhaus cins crowdsec; do : > "$OUT/bl/last-good-$n.txt"; done; }
healthy() { printf '[shieldnode]\nversion=test\nupdated=2026-09-23T10:00:00Z\n' > /etc/node-profile.d/stack.conf; fill; printf 'c_drops_scanner_v4 42\nc_drops_invalid 3\n' > "$CNTS"; }

# ---------- 1. здоровая нода ----------
gen ''; healthy; H
t "здоровая нода: FAIL=0 WARN=0"                         '[ "$(sumf)" = "health: FAIL=0 WARN=0" ]'
t "порядок: established/lo/whitelist до первого drop"    'has "[PASS] established/related accept — до первого drop" && has "[PASS] loopback accept" && has "[PASS] whitelist accept"'
t "SSH 22 (SSH_PORT пуст -> авто-детект) под защитой"    'has "[PASS] SSH 22: rate/conn-limit активны (авто-детект)"'
t "внешний xray 443/tcp под защитой, loopback 10085 игнорируется" 'has "все внешние порты xray/remnanode под защитой (tcp: 443;" && ! has "10085"'
t "блоклисты: записи + пояснение про MIN до схлопывания" 'has "[PASS] scanner: 2 записей" && has "MIN проверяет updater"'
t "tor выключен и отсутствует — PASS; crowdsec (дефолт ВКЛ, v1.1.6) — есть записи" 'has "[PASS] tor: выключен и отсутствует" && has "[PASS] crowdsec: 2 записей"'
t "последний apply, дропы 45, abuse-сеты, журнал"       'has "последний apply: 2026-09-23T10:00:00Z" && has "дропов с последнего apply: 45 пакетов" && has "abuse-сеты сейчас: ssh=0"'
t "таймер + boot-служба PASS"                            'has "[PASS] shieldnode-blocklist.timer активен" && has "[PASS] shieldnode.service enabled"'

# ---------- 2. порядок нарушен: drop до established ----------
sed -i '0,/ct state established,related accept/{/ct state established,related accept/d}' "$LIVE"
sed -i '/chain prerouting {/,/policy accept;/{/policy accept;/a\        ip saddr 9.9.9.9 drop\n        ct state established,related accept
}' "$LIVE"; H
t "drop ДО established -> FAIL"                          'has "[FAIL] established/related accept отсутствует или ПОСЛЕ drop"'

# ---------- 3. дрейф конфиг <-> таблица ----------
gen 'ENABLE_THREAT_LIST=0\n'; cfg ''; healthy; H
t "threat включён в конфиге, в таблице нет -> FAIL"      'has "[FAIL] threat: включён, но set/drop-правила нет"'
gen 'BLOCK_TOR=1\n'; cfg ''; healthy; H
t "tor выключен в конфиге, в таблице остался -> WARN half-present" 'has "[WARN] tor: выключен" && has "half-present"'
gen ''; cfg 'ENABLE_ABUSE_LIMITING=1\n'; healthy
sed -i '/@protected_udp/d' "$LIVE"; H
t "abuse-лимит udp пропал из таблицы -> FAIL"            'has "[FAIL] ENABLE_ABUSE_LIMITING=1, но правил по @protected_tcp/@protected_udp нет"'

# ---------- 4. блоклисты: пусто / устарел / алерт / никогда ----------
gen ''; healthy; : > "$ELEMS/scanner_blocklist_v4"; touch -d '3 days ago' "$OUT/bl/last-good-threat.txt"
date -u +%FT%TZ > "$OUT/bl/.alert-spamhaus"; rm -f "$OUT/bl/last-good-cins.txt"; H
t "scanner пуст -> WARN «set ПУСТ» (возраст last-good без артефактов «0ч назад0»)" 'has "[WARN] scanner: set ПУСТ" && has "(последний успех: 0ч назад)"'
t "threat обновлён 72ч назад (> 2x360мин) -> WARN"       'has "[WARN] threat: последнее успешное обновление 72ч назад"'
t "spamhaus алерт -> WARN"                               'has "[WARN] spamhaus: фид падает подряд"'
t "cins без last-good -> WARN «успешных обновлений не было»" 'has "[WARN] cins: успешных обновлений ещё не было"'
t "custom не проверяется на свежесть (hash-guard, неизменный контент — норма)" '! grep -q "custom: последнее успешное" "$OUT/h.txt"'

# ---------- 5. порты: EXTRA, внешний UDP xray, интервалы ----------
gen ''; cfg 'PROTECTED_TCP_EXTRA=9443\nPROTECTED_UDP_EXTRA=5353\n'; healthy; SS_UDP=8443 H
t "EXTRA 9443/5353 отсутствуют в сетах -> FAIL"          'has "[FAIL] PROTECTED_TCP_EXTRA 9443 — НЕТ" && has "[FAIL] PROTECTED_UDP_EXTRA 5353 — НЕТ"'
t "xray слушает 8443/udp вне protected_udp -> WARN"      'has "[WARN] xray/remnanode слушает 8443/udp снаружи"'
printf '22\n443\n8000-9500\n' > "$ELEMS/protected_tcp"; printf '5000-6000\n8443\n' > "$ELEMS/protected_udp"; SS_UDP=8443 H
t "интервалы set: 9443 in 8000-9500, 5353 in 5000-6000 -> PASS" 'has "[PASS] PROTECTED_TCP_EXTRA 9443" && has "[PASS] PROTECTED_UDP_EXTRA 5353" && ! has "8443/udp снаружи"'
rm -f "$ELEMS/protected_tcp" "$ELEMS/protected_udp"

# ---------- 6. SSH: SSH_PORT задан, а в таблице правила для другого порта ----------
gen ''; cfg 'SSH_PORT=2222\n'; healthy; H
t "SSH_PORT=2222, правила только для 22 -> FAIL"         'has "[FAIL] SSH 2222: защитных правил нет"'

# ---------- 7. emergency / нет таблицы / таймер и служба ----------
gen ''; cfg ''; healthy; mkdir -p /run/shieldnode; date -u +%FT%TZ > /run/shieldnode/emergency; H
t "emergency: WARN и проверки политики пропущены (без ложных FAIL)" 'has "[WARN] EMERGENCY ON" && [ "$(sumf)" = "health: FAIL=0 WARN=1" ]'
rm -f /run/shieldnode/emergency; mv "$LIVE" "$LIVE.off"; H
t "таблицы нет (root) -> FAIL"                           'has "[FAIL] table inet shieldnode ОТСУТСТВУЕТ"'
mv "$LIVE.off" "$LIVE"; FAKE_TIMER=0 FAKE_SVC=0 H
t "таймер неактивен и служба не enabled -> 2 WARN"       'has "[WARN] shieldnode-blocklist.timer НЕ активен" && has "[WARN] shieldnode.service не enabled"'
printf '' > "$CNTS"; H
t "0 дропов — INFO «простаивает», не ошибка"             'has "[INFO] дропов с последнего apply: 0" && ! grep -q "FAIL.*дроп" "$OUT/h.txt"'

# ---------- 8. таблица гейтинга health == генератор ----------
while IFS=: read -r name flag def set; do
    for v in 0 1; do
        gen "ENABLE_BLOCKLISTS=1\n$flag=$v\n"
        got=0; grep -qE "^    set $set " "$LIVE" && grep -qE "saddr @$set .*drop" "$LIVE" && got=1
        t "гейтинг $name: $flag=$v -> генератор set+правило=$v" "[ $got = $v ]"
    done
    gen ''; got=0; grep -qE "^    set $set " "$LIVE" && got=1
    t "гейтинг $name: дефолт health ($def) == дефолт генератора" "[ $got = $def ]"
    gen "ENABLE_BLOCKLISTS=0\n$flag=1\n"; got=0; grep -qE "saddr @$set .*drop" "$LIVE" && got=1
    t "гейтинг $name: ENABLE_BLOCKLISTS=0 -> правила нет" "[ $got = 0 ]"
done <<<"$SHIELD_HEALTH_LISTS"

# ---------- 9. status: секция health вверху, код возврата прежний ----------
gen ''; cfg ''; healthy; rc=0; shield_status > "$OUT/st.txt" 2>&1 || rc=$?
t "status: rc 0 (прежний контракт)"                      '[ "$rc" = 0 ]'
t "status: health сразу после emergency"                 'e=$(grep -n "^--- emergency" "$OUT/st.txt" | cut -d: -f1); h=$(grep -n "^--- health" "$OUT/st.txt" | cut -d: -f1); [ -n "$h" ] && [ $((h - e)) -le 4 ]'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: health (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
