#!/bin/bash
# shieldnode — тест: регрессии аудита 2026-09-23.
#   ss-парсинг: admin IP (колонки без State при `state established`) и UDP-порты
#   (`-ulnp`: $5 = Peer); валидация адреса перед nft; scrub; rollback — не
#   трогает config.conf, удаляет СВОИ файлы после повторного apply, runtime
#   security-sysctl -> исходные; stack.conf через mktemp в каталоге назначения;
#   blocklist-юниты: ReadWritePaths с '-', tmpfiles, state-каталог; creds без
#   исполнения кода при source; guard -> main.sh +x.
#   (креды в argv curl -u — исправлено 2026-09-24 v1.1.4, см. test-crowdsec-argv.sh)
# Под root тест уходит в `unshare -mn`: tmpfs поверх реальных путей (/etc/*,
# /usr/local/sbin, /var/lib/shieldnode, /var/log, /run) — хост не затрагивается.
set -euo pipefail

if [ "$(id -u)" -eq 0 ] && [ "${SHIELD_TEST_IN_NS:-0}" != "1" ] && unshare -mn true 2>/dev/null; then
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
IN_NS="${SHIELD_TEST_IN_NS:-0}"
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-0923
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
if [ "$IN_NS" = "1" ]; then
    for d in /etc/sysctl.d /etc/nftables.d /etc/systemd/system /etc/shieldnode /etc/tmpfiles.d /etc/logrotate.d \
             /etc/node-profile.d /usr/local/sbin /var/lib/shieldnode /var/log /run; do
        mkdir -p "$d"; mount -t tmpfs t "$d"
    done
fi
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/shieldnode.log"
export SHIELD_CONFIG="$OUT/config.conf" SHIELD_EXCLUDE="$OUT/none" DRY_RUN=0
: > "$SHIELD_LOG"; unset SSH_CONNECTION

cat > "$OUT/bin/ss" <<'EOF'
#!/bin/bash
# раскладка колонок iproute2: одиночный state-фильтр прячет State, -l (2 состояния) показывает
case "$*" in
  "-tnp state established")
    echo 'Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
    echo '0      0      127.0.0.1:22       127.0.0.1:40000   users:(("sshd",pid=9,fd=4))'
    echo '0      0      10.0.0.5:22        203.0.113.7:51234 users:(("sshd",pid=1234,fd=4))' ;;
  "-ulnp")
    echo 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
    echo 'UNCONN 0      0      0.0.0.0:8443       0.0.0.0:*         users:(("xray",pid=77,fd=9))'
    echo 'UNCONN 0      0      [::]:8443          [::]:*            users:(("xray",pid=77,fd=10))' ;;
  "-tlnp")
    echo 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
    echo 'LISTEN 0      128    0.0.0.0:22         0.0.0.0:*         users:(("sshd",pid=1,fd=3))' ;;
  "-tulnp")
    echo 'Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
    echo 'tcp   LISTEN 0      4096   0.0.0.0:443        0.0.0.0:*         users:(("xray",pid=77,fd=7))' ;;
esac
EOF
for c in systemctl logger udevadm; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
printf '#!/bin/sh\n[ "$1" = list ] && exit 1\nexit 0\n' > "$OUT/bin/nft"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
for f in detect.sh limits.sh lib/nft.sh persist.sh rollback.sh firewall.sh lib/crowdsec.sh lib/blocklist.sh; do source "$SHIELD_DIR/$f"; done

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ---------- ss / валидация ----------
t "admin IP: peer из 2-го поля адрес:порт, loopback пропущен" '[ "$(shield_detect_admin_ip)" = 203.0.113.7 ]'
t "admin IP: SSH_CONNECTION приоритетнее"      '[ "$(SSH_CONNECTION="198.51.100.4 5555 10.0.0.5 22" shield_detect_admin_ip)" = 198.51.100.4 ]'
t "admin IP: мусор в SSH_CONNECTION не проходит в nft" '[ -z "$(SSH_CONNECTION="1.2.3.4}; flush 1 2 3" shield_detect_admin_ip 2>/dev/null)" ]'
t "valid_ip: v4/v6 да, 999.1.1.1/process-строка нет" 'shield_valid_ip 203.0.113.7 && shield_valid_ip 2001:db8::1 && ! shield_valid_ip 999.1.1.1 && ! shield_valid_ip "users:((\"sshd\",pid=1))"'
shield_limits_resolve >/dev/null 2>&1
t "UDP: protected_udp = локальный порт 8443 (не 0.0.0.0:*)" '[ "$SH_F_PROTECTED_UDP" = 8443 ]'
t "whitelist_v4 содержит admin"                 '[ "$SH_F_ADMIN_V4" = 203.0.113.7 ]'
SH_F_IPV6=1 shield_nft_build_ruleset > "$OUT/rs.nft"
t "ruleset: в сетах только адреса/порты"       '! awk "/elements = \\{/{sub(/.*elements = \\{ */,\"\"); sub(/ *\\}.*/,\"\"); n=split(\$0,a,/, */); for(i=1;i<=n;i++) if (a[i] !~ /^([0-9.]+(\\/[0-9]+)?|[0-9a-fA-F:]+(\\/[0-9]+)?|[0-9]+)\$/) {print a[i]; bad=1}} END{exit !bad}" "$OUT/rs.nft"'

# ---------- scrub ----------
S="$(printf '%s' 'password=hunter2secret token=AAAA1111 {"password": "jsonpw99"} 3f2b9c1e-7d4a-4e21-9b3c-0a1b2c3d4e5f' | scrub)"
t "scrub: без 4-символьного префикса и все секреты" '! grep -qE "hunt|AAAA|jsonpw99|3f2b9c1e" <<<"$S"'

# ---------- guard link: main.sh получает +x ----------
mkdir -p "$OUT/sd"; cp -a "$SHIELD_DIR/." "$OUT/sd/"; chmod 0644 "$OUT/sd/main.sh"
( SHIELD_DIR="$OUT/sd" SHIELD_GUARD_LINK="$OUT/guard"; shield_guard_link ) >/dev/null 2>&1
t "guard: symlink -> main.sh и main.sh исполняемый" '[ -L "$OUT/guard" ] && [ -x "$OUT/sd/main.sh" ]'

if [ "$IN_NS" != "1" ]; then
    echo "skip - rollback/units/creds/curl (нужен root + unshare -mn)"
else
# ---------- rollback после повторного apply ----------
SHIELD_CONFIG=/etc/shieldnode/config.conf
sysctl -w net.ipv4.tcp_rfc1337=0 >/dev/null
apply_sim() { echo "RULESET $1" | shield_persist_stream "$SHIELD_NFT_PERSIST" 0640; shield_persist_security_sysctl; shield_config_ensure; }
apply_sim v1 >/dev/null 2>&1
printf 'SSH_PORT=2222\nTRUSTED_IPS=198.51.100.9\n' >> "$SHIELD_CONFIG"
sleep 1; apply_sim v2 >/dev/null 2>&1
t "apply применил tcp_rfc1337=1"                '[ "$(sysctl -n net.ipv4.tcp_rfc1337)" = 1 ]'
shield_rollback "" >/dev/null 2>&1
t "rollback: config.conf оператора СОХРАНЁН"    'grep -qx SSH_PORT=2222 "$SHIELD_CONFIG"'
t "rollback: свой nft-persist удалён (не восстановлен из своего бэкапа)" '[ ! -e "$SHIELD_NFT_PERSIST" ]'
t "rollback: 99-z5 security sysctl удалён"      '[ ! -e "$SHIELD_SYSCTL_SECURITY" ]'
t "rollback: runtime tcp_rfc1337 -> исходный 0" '[ "$(sysctl -n net.ipv4.tcp_rfc1337)" = 0 ]'

# ---------- stack.conf: mktemp в каталоге назначения ----------
REAL_MKTEMP="$(command -v mktemp)"
cat > "$OUT/bin/mktemp" <<EOF
#!/bin/sh
echo "\$*" >> "$OUT/mktemp.calls"; exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$OUT/bin/mktemp"; : > "$OUT/mktemp.calls"
shield_contract_write >/dev/null 2>&1; shield_rollback "" >/dev/null 2>&1
t "stack.conf: все mktemp — в /etc/node-profile.d (атомарный mv)" '[ "$(grep -c "^/etc/node-profile.d/.stack.conf" "$OUT/mktemp.calls")" = 2 ]'
rm -f "$OUT/bin/mktemp"

# ---------- blocklist units + creds + curl argv ----------
printf 'ENABLE_CROWDSEC_LIST=1\nCROWDSEC_MODE=feed\nCROWDSEC_INTEGRATION_ID=abc123\nCROWDSEC_USER=bl-user\nCROWDSEC_PASSWORD='"'"'p$(touch %s/pwned)"x\\y'"'"'\n' "$OUT" > "$SHIELD_CONFIG"
shield_load_config; shield_limits_resolve >/dev/null 2>&1
shield_blocklist_install >/dev/null 2>&1
for u in shieldnode-blocklist shieldnode-blocklist-custom; do
    t "$u: все ReadWritePaths с префиксом '-'" "grep -q '^ReadWritePaths=' /etc/systemd/system/$u.service && ! grep '^ReadWritePaths=' /etc/systemd/system/$u.service | sed 's/^ReadWritePaths=//' | tr ' ' '\n' | awk 'NF' | grep -qv '^-'"
    t "$u: ReadWritePaths непустой" "grep -q '^ReadWritePaths=-/var/lib/shieldnode/blocklists -/run/shieldnode -/var/log/shieldnode.log$' /etc/systemd/system/$u.service"
done
t "tmpfiles: /run/shieldnode, blocklists/, лог" 'grep -qx "d /run/shieldnode 0755 root root -" /etc/tmpfiles.d/shieldnode.conf && grep -qx "d /var/lib/shieldnode/blocklists 0750 root root -" /etc/tmpfiles.d/shieldnode.conf && grep -qx "f /var/log/shieldnode.log 0640 root root -" /etc/tmpfiles.d/shieldnode.conf'
t "state-каталог blocklists/ создан сразу"      '[ -d /var/lib/shieldnode/blocklists ]'
t "creds: 0600"                                 '[ "$(stat -c %a /etc/shieldnode/crowdsec.creds)" = 600 ]'
( . /etc/shieldnode/crowdsec.creds; [ "$CROWDSEC_PASSWORD" = 'p$(touch '"$OUT"'/pwned)"x\y' ] ) && r=0 || r=1
t "creds: пароль с \$( \" \\ сохранён буквально при source" '[ $r = 0 ]'
t "creds: код из пароля НЕ исполнен"             '[ ! -e "$OUT/pwned" ]'
t "creds: безопасное значение — прежний формат \"...\"" 'grep -qx "CROWDSEC_USER=\"bl-user\"" /etc/shieldnode/crowdsec.creds'

# ---------- лог-файл создаётся main.sh ----------
rm -f /var/log/shieldnode.log
env -u SHIELD_LOG -u SHIELD_STATE_DIR -u SHIELD_CONFIG bash "$SHIELD_DIR/main.sh" status >/dev/null 2>&1 || true
t "main.sh: создаёт /var/log/shieldnode.log (0640)" '[ -s /var/log/shieldnode.log ] && [ "$(stat -c %a /var/log/shieldnode.log)" = 640 ]'
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: hardening-0923 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
