#!/bin/bash
# shieldnode — тест: повторный apply не снимает активные баны и журналирует их ДО замены.
# 2026-09-24 (v1.1.5): apply пересоздаёт таблицу (table/delete/table) — все
# динамические сеты (ssh/tcp/udp_abusers, temporary_blocklist, в т.ч. ручные баны
# оператора) обнулялись на КАЖДОМ apply и emergency off; журнал abuse писался ПОСЛЕ
# замены — уже пустых сетов. Найдено на живой ноде (бан 133.18.122.63 пропал).
# Под root: `unshare -mn` + tmpfs поверх всех путей, куда пишет apply; sysctl net.*
# — в своём netns; listener на 127.0.0.1:22 для SSH self-test.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: нет python3 (нужен listener)"; exit 77; }
command -v flock >/dev/null 2>&1 || { echo "SKIP: нет flock"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /etc/sysctl.d /etc/nftables.d /etc/systemd/system /etc/shieldnode /etc/tmpfiles.d /etc/logrotate.d \
         /etc/node-profile.d /usr/local/sbin /var/lib/shieldnode /var/log /run; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done
ip link set lo up

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-bans
rm -rf "$OUT"; mkdir -p "$OUT/bin"
export SHIELD_LOCK=/run/shieldnode/shieldnode.lock
unset SSH_CONNECTION
printf 'SSH_PORT=22\n' > /etc/shieldnode/config.conf

# systemctl: протокол + состояние основного lock'а в момент старта updater'а
cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$OUT/systemctl.log"
if [ "\$1" = start ] && [[ " \$* " == *" shieldnode-blocklist.service "* ]]; then
    if flock -n "$SHIELD_LOCK" true; then echo FREE >> "$OUT/lockstate"; else echo BUSY >> "$OUT/lockstate"; fi
fi
exit 0
EOF
for c in logger udevadm; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",22)); s.listen(64); time.sleep(120)' &
LISTENER=$!
trap 'kill $LISTENER 2>/dev/null || true' EXIT
sleep 0.5

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

bash "$SHIELD_DIR/main.sh" apply > "$OUT/apply1.out" 2>&1 || true
t "apply #1: таблица загружена" "nft list set inet shieldnode ssh_abusers"
nft add element inet shieldnode ssh_abusers '{ 198.51.100.7 timeout 50m }'
nft add element inet shieldnode temporary_blocklist '{ 203.0.113.9 timeout 2h }'
rc=0; bash "$SHIELD_DIR/main.sh" apply > "$OUT/apply2.out" 2>&1 || rc=$?
t "apply #2: rc=0" "[ $rc = 0 ]"
t "бан ssh_abusers пережил apply" "nft list set inet shieldnode ssh_abusers | grep -q '198.51.100.7'"
t "ручной бан temporary_blocklist пережил apply" "nft list set inet shieldnode temporary_blocklist | grep -q '203.0.113.9'"
t "перенесён ОСТАТОК срока (expires <= 50m, не новый полный timeout 1h)" \
  "nft list set inet shieldnode ssh_abusers | grep -o '198.51.100.7 timeout [0-9hms]*' | grep -qE 'timeout (4[0-9]|50)m'"
t "журнал abuse записан ДО замены таблицы (содержит баны)" \
  "grep -qx 198.51.100.7 /var/lib/shieldnode/abuse.journal && grep -qx 203.0.113.9 /var/lib/shieldnode/abuse.journal"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: apply-bans (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
