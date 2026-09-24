#!/bin/bash
# shieldnode — тест: после apply updater стартует, когда основной lock УЖЕ свободен.
# 2026-09-24 (v1.1.4): apply (держит lock) звал `systemctl start --no-block
# shieldnode-blocklist.service`; updater берёт основной lock неблокирующе и
# пропускал тик — после каждого apply/emergency off блоклисты оставались пустыми
# до следующего тика таймера (360 мин). Найдено на живой ноде.
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
OUT=/tmp/shieldnode-test-kick
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

: > "$OUT/lockstate"
rc=0; bash "$SHIELD_DIR/main.sh" apply > "$OUT/apply.out" 2>&1 || rc=$?
t "apply: rc=0 в изолированном netns" "[ $rc = 0 ]"
t "apply: таблица загружена" "nft list table inet shieldnode"
t "apply: updater запущен ровно один раз" "[ \$(wc -l < $OUT/lockstate) = 1 ]"
t "apply: в момент запуска updater'а основной lock СВОБОДЕН (тик не пропускается)" "[ \"\$(cat $OUT/lockstate)\" = FREE ]"

# 2026-09-24 (v1.1.4): updater держит основной lock весь свой прогон; apply/emergency
# брали lock неблокирующе и умирали «another shieldnode instance holds the lock» —
# на живой ноде повторный apply сразу после apply (updater от kick'а ещё шёл) = rc 1,
# а `emergency on` во время любого тика обновления был бы отвергнут.
( exec 7>"$SHIELD_LOCK"; flock -n 7 || exit 1; sleep 4 ) &
HOLDER=$!
sleep 0.5
rc=0; bash "$SHIELD_DIR/main.sh" apply > "$OUT/apply2.out" 2>&1 || rc=$?
wait "$HOLDER" || true
t "lock занят updater'ом: apply дожидается и проходит (rc=0)" "[ $rc = 0 ]"
( exec 7>"$SHIELD_LOCK"; flock -n 7 || exit 1; sleep 3 ) &
HOLDER=$!
sleep 0.5
rc=0; bash "$SHIELD_DIR/main.sh" emergency on > "$OUT/em.out" 2>&1 || rc=$?
wait "$HOLDER" || true
t "lock занят updater'ом: emergency on дожидается и включается" "[ $rc = 0 ] && nft list chain inet shieldnode prerouting | grep -q 'ip protocol tcp drop'"
bash "$SHIELD_DIR/main.sh" emergency off > /dev/null 2>&1 || true

echo
if [ "$fails" -eq 0 ]; then echo "PASS: apply-kick (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
