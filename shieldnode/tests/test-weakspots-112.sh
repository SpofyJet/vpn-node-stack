#!/bin/bash
# shieldnode — тест: слабые места v1.1.2 (2026-09-23).
#   default-iface по ключевому слову dev; ss-детект портов SSH/xray без номеров
#   колонок (в т.ч. раскладка без State); уникальный tmp у абуз-журнала
#   (параллельные писатели) и guard-снапшота; updater: однопроходный v4-парсер
#   (mawk: не опираться на longest-match у цепочек «[0-9]?»; усечённый октет
#   отбрасывается) и быстрый collapse — байт-в-байт = ipaddress.collapse_addresses.
# Updater-часть требует root: `unshare -m`, tmpfs поверх реальных путей.
set -euo pipefail
if [ "$(id -u)" -eq 0 ] && [ "${SHIELD_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    SHIELD_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
IN_NS="${SHIELD_TEST_IN_NS:-0}"
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-ws112
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
if [ "$IN_NS" = "1" ]; then
    for d in /usr/local/sbin /etc/systemd/system /etc/shieldnode /etc/tmpfiles.d /var/lib/shieldnode /var/log /run; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
fi
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/shieldnode.log" SHIELD_CONFIG="$OUT/none.conf" SHIELD_EXCLUDE="$OUT/none" DRY_RUN=0
: > "$SHIELD_LOG"

cat > "$OUT/bin/ip" <<'EOF'
#!/bin/bash
case "${LAYOUT:-std}" in
  std)  echo "default via 10.0.0.1 dev eth0 proto dhcp metric 100" ;;
  nhid) echo "default nhid 12 via 10.0.0.1 dev ens3 proto static" ;;
  nogw) echo "default dev venet0 scope link" ;;
esac
EOF
cat > "$OUT/bin/ss" <<'EOF'
#!/bin/bash
# SS_NOSTATE=1 — гипотетическая раскладка без колонки State (иной набор флагов/версия)
emit() { if [ "${SS_NOSTATE:-0}" = 1 ]; then sed -E 's/^(tcp|udp)( +)(LISTEN|UNCONN) +/\1\2/; s/^(LISTEN|UNCONN) +//'; else cat; fi; }
case "$*" in
  "-tlnp")  printf '%s\n' 'State Recv-Q Send-Q Local Peer Process' 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' 'LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1,fd=4))' | emit ;;
  "-tulnp") printf '%s\n' 'Netid State Recv-Q Send-Q Local Peer Process' 'udp UNCONN 0 0 0.0.0.0:8443 0.0.0.0:* users:(("xray",pid=7,fd=9))' 'tcp LISTEN 0 4096 [::]:443 [::]:* users:(("xray",pid=7,fd=7))' | emit ;;
  "-ulnp")  printf '%s\n' 'State Recv-Q Send-Q Local Peer Process' 'UNCONN 0 0 0.0.0.0:8443 0.0.0.0:* users:(("xray",pid=7,fd=9))' | emit ;;
esac
EOF
for c in systemctl logger; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
for f in detect.sh limits.sh persist.sh lib/crowdsec.sh lib/blocklist.sh; do source "$SHIELD_DIR/$f"; done

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ---------- ip ----------
t "default iface: std -> eth0"          '[ "$(LAYOUT=std shield_default_iface)" = eth0 ]'
t "default iface: nhid -> ens3 (старый \$5 давал 10.0.0.1)" '[ "$(LAYOUT=nhid shield_default_iface)" = ens3 ]'
t "default iface: без шлюза -> venet0 (старый \$5 давал link)" '[ "$(LAYOUT=nogw shield_default_iface)" = venet0 ]'
t "не осталось \$5-скрейпа ip route" '! grep -rnE "route show to default[^|]*\| *awk .\{print \\\$[0-9]" "$SHIELD_DIR" --include=*.sh'

# ---------- ss ----------
for ns in 0 1; do
    t "ssh-порты (SS_NOSTATE=$ns) = 22 2222" "[ \"\$(SS_NOSTATE=$ns shield_detect_ssh_ports 2>/dev/null | tr -s ' ' | sed 's/ \$//')\" = '22 2222' ] || [ \"\$(SS_NOSTATE=$ns bash -c 'source $SHIELD_DIR/lib/common.sh; ss -tlnp | _ss_local_ports sshd | sort -u | tr \"\\n\" \" \"' | sed 's/ \$//')\" = '22 2222' ]"
    t "xray-порты (SS_NOSTATE=$ns) содержат 443 и 8443" "SS_NOSTATE=$ns ss -tulnp | _ss_local_ports 'xray|remnanode' | sort -un | tr '\n' ' ' | grep -qx '443 8443 '"
done
t "detect.sh/limits.sh: без \$4/\$5 у ss" '! grep -nE "ss -[a-z]+ [^|]*\| *awk .[^{]*\{print \\\$[0-9]" "$SHIELD_DIR/detect.sh" "$SHIELD_DIR/limits.sh"'

# ---------- гонки tmp ----------
: > "$SHIELD_ABUSE_JOURNAL"; for i in $(seq 1 200); do echo "1700000000 ssh 203.0.113.$((i % 250))" >> "$SHIELD_ABUSE_JOURNAL"; done
( for i in $(seq 1 20); do shield_abuse_journal_append >/dev/null 2>&1 & done; wait ) || true
t "journal: 20 параллельных писателей — нет осиротевших tmp" '[ -z "$(ls "$SHIELD_ABUSE_JOURNAL".* 2>/dev/null)" ]'
t "journal: файл цел (все строки валидного формата)" '[ -s "$SHIELD_ABUSE_JOURNAL" ] && ! grep -vqE "^(### |## |[0-9])" "$SHIELD_ABUSE_JOURNAL"'
# большой сет (> буфера пайпа): раньше `nft list set | grep -q` под pipefail -> SIGPIPE ->
# сет молча пропускался. Мок печатает элементы по строке, как nft (~300 КБ на сет).
mkdir -p "$OUT/big"; cat > "$OUT/big/nft" <<'EOF'
#!/bin/bash
echo "table inet shieldnode {"; echo "  set $5 {"; echo "    elements = { 198.18.0.1,"
for i in $(seq 1 20000); do echo "             198.18.$((i/250)).$((i%250)),"; done; echo "             1.1.1.1 }"; echo "  }"; echo "}"
EOF
chmod +x "$OUT/big/nft"; : > "$SHIELD_ABUSE_JOURNAL"
PATH="$OUT/big:$PATH" shield_abuse_journal_append >/dev/null 2>&1 || true
t "journal: все 8 КРУПНЫХ сетов попали в журнал (нет SIGPIPE-потерь)" '[ "$(grep -c "^## " "$SHIELD_ABUSE_JOURNAL")" = 8 ]'
t "journal/crowdsec: нет «list | grep -q» на больших выводах" '! grep -nE "nft list set[^|]*\| *grep -q|cscli decisions list[^|]*\| *grep -q" "$SHIELD_DIR/limits.sh" "$SHIELD_DIR/lib/crowdsec.sh" | grep -vqE "^[0-9]+:[[:space:]]*#|:[0-9]+:[[:space:]]*#"'
t "guard/journal: нет фиксированного «.tmp»" '! grep -nE "(SNAPSHOT|JOURNAL)\.tmp" "$SHIELD_DIR/guard.sh" "$SHIELD_DIR/limits.sh"'

# ---------- defaults ----------
missing="$(grep -rhoE 'shield_conf_get[[:space:]]+"?[A-Z_][A-Z0-9_]*' --include=*.sh "$SHIELD_DIR" | grep -v tests | awk '{print $2}' | tr -d '"' | sort -u | while read -r k; do grep -qE "^(# )?$k=" "$SHIELD_DIR/shieldnode.defaults.conf" || echo "$k"; done)"
t "каждый ключ, читаемый кодом, есть в defaults${missing:+ (нет: $missing)}" '[ -z "$missing" ]'
t "контракт: значение оператора побеждает документированный ключ" \
  '( printf "PROTECTED_TCP_EXTRA=9443\n" > "$OUT/op.conf"; SHIELD_CONFIG="$OUT/op.conf" shield_load_config; [ "$(shield_conf_get PROTECTED_TCP_EXTRA "")" = 9443 ] )'
t "контракт: дописанное в кэш переопределение не перекрыто defaults" \
  '( SHIELD_CONFIG=/nonexistent shield_load_config; echo BLOCKLIST_CUSTOM_URLS=x >> "$CONFIG_CACHE"; [ "$(shield_conf_get BLOCKLIST_CUSTOM_URLS "")" = x ] )'

# ---------- updater: парсер + collapse (реальный сгенерированный скрипт) ----------
if [ "$IN_NS" != "1" ]; then
    echo "skip - updater parse/collapse (нужен root + unshare -m)"
else
    cat > "$OUT/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in "-a list chain inet shieldnode prerouting") printf '\tip saddr @threat_blocklist_v4 drop # handle 7\n' ;; esac; exit 0
EOF
    printf '#!/bin/sh\nexit 7\n' > "$OUT/bin/curl"; chmod +x "$OUT/bin/nft" "$OUT/bin/curl"
    printf 'BLOCKLIST_THREAT_URLS=\nMIN_ENTRIES_THREAT=1\n' > "$OUT/cfg.conf"; SHIELD_CONFIG="$OUT/cfg.conf" shield_load_config
    shield_limits_resolve >/dev/null 2>&1; shield_blocklist_install >/dev/null 2>&1
    mkdir -p /etc/shieldnode/lists
    printf '%s\n' '1.0.108.130' '1.2.3.1234' 'S24-45.9.8.0/24 ; SBL1' '  91.1.2.3  # c' '10.0.0.1' '45.9.8.128/25' '203.0.113.9' '8.8.0.0/8' > /etc/shieldnode/lists/threat.txt
    FORCE=1 bash /usr/local/sbin/shieldnode-blocklist threat >/dev/null 2>&1 || true
    LG=/var/lib/shieldnode/blocklists/last-good-threat.txt
    t "updater: 3-значный последний октет не усечён (mawk longest-match)" 'grep -qx "1.0.108.130/32" "$LG"'
    t "updater: «1.2.3.1234» отброшен (раньше -> 1.2.3.123)" '! grep -q "^1\.2\.3\." "$LG"'
    t "updater: spamhaus S24- нормализован, /25 внутри /24 схлопнут" 'grep -qx "45.9.8.0/24" "$LG" && ! grep -q "45.9.8.128" "$LG"'
    t "updater: bogon/test-net/слишком короткий префикс отброшены" '! grep -qE "^(10\.|203\.0\.113\.|8\.8\.)" "$LG"'
    t "updater: ведущие пробелы/комментарий" 'grep -qx "91.1.2.3/32" "$LG"'
    # collapse: побайтно = ipaddress.collapse_addresses на случайных перекрытиях
    python3 - "$OUT/fz" <<'PY'
import random, sys
random.seed(3); L = []
for i in range(20000):
    L.append("%d.%d.%d.%d/%d" % (random.choice([5, 45, 91]), random.randint(0, 7), random.randint(0, 255), random.randint(0, 255), random.choice([22, 24, 25, 27, 29, 31, 32, 32])))
L += ["01.2.3.4", "1.2.3.0/08", "garbage", "255.255.255.255", "0.0.0.0"]
open(sys.argv[1], "w").write("\n".join(L) + "\n")
PY
    ( source <(sed -n '/^collapse_cidrs()/,/^}/p' /usr/local/sbin/shieldnode-blocklist); collapse_cidrs "$OUT/fz" "$OUT/fz.new" )
    python3 - "$OUT/fz" "$OUT/fz.ref" <<'PY'
import sys, ipaddress
n = []
for l in open(sys.argv[1]):
    try: n.append(ipaddress.ip_network(l.strip(), strict=False))
    except ValueError: pass
open(sys.argv[2], "w").write("".join(str(x) + "\n" for x in ipaddress.collapse_addresses(n)))
PY
    t "collapse: байт-в-байт = ipaddress.collapse_addresses ($(wc -l < "$OUT/fz.ref") сетей)" 'cmp -s "$OUT/fz.new" "$OUT/fz.ref"'
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: weakspots-112 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
