#!/bin/bash
# shieldnode — тест: ICMP echo-лимит — per-source (backlog #4), на настоящем nft.
# 2026-09-24 (v1.1.4): правило `icmp type echo-request limit rate over 10/second`
# было ГЛОБАЛЬНЫМ (комментарий обещал per-src): пока один источник флудил новыми
# ICMP-потоками, легитимный ping (~3/с) другого источника терял ~30% (замер 14/20).
# Под root: `unshare -mn` (сервер) + два клиентских netns через veth; tmpfs над /run.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
for c in nft ip ping python3; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP: нет $c"; exit 77; }; done
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /run /etc/shieldnode /var/log /var/lib/shieldnode; do mkdir -p "$d"; mount -t tmpfs t "$d"; done

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-icmp
rm -rf "$OUT"; mkdir -p "$OUT"
C1=sic1$$ C2=sic2$$
cleanup() { ip netns del "$C1" 2>/dev/null || true; ip netns del "$C2" 2>/dev/null || true; }
trap cleanup EXIT
ip netns add "$C1"; ip netns add "$C2"
ip link set lo up
ip link add sia$$ type veth peer name sib$$ netns "$C1" || { echo "SKIP: нет veth"; exit 77; }
ip link add sic$$ type veth peer name sid$$ netns "$C2"
ip addr add 10.79.1.1/24 dev sia$$; ip addr add 10.79.2.1/24 dev sic$$
ip -n "$C1" addr add 10.79.1.2/24 dev sib$$; ip -n "$C2" addr add 10.79.2.2/24 dev sid$$
ip link set sia$$ up; ip link set sic$$ up
ip -n "$C1" link set lo up; ip -n "$C1" link set sib$$ up
ip -n "$C2" link set lo up; ip -n "$C2" link set sid$$ up

# настоящий ruleset из генератора (dry-run, SSH 22) — в netns сервера
export SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_LOCK=/run/shieldnode/l SHIELD_CONFIG="$OUT/config.conf" SHIELD_EXCLUDE="$OUT/none"
printf 'SSH_PORT=22\n' > "$SHIELD_CONFIG"; unset SSH_CONNECTION
bash "$SHIELD_DIR/main.sh" --dry-run apply 2>/dev/null \
  | awk '/^table inet shieldnode$/{on=1} on && !/^20[0-9][0-9]-[0-9-]+T[0-9:]+Z \[/' > "$OUT/rs.nft"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

t "ruleset загружен" "nft -f $OUT/rs.nft"
ip netns exec "$C1" ping -c1 -W2 10.79.1.1 >/dev/null 2>&1 && ip netns exec "$C2" ping -c1 -W2 10.79.2.1 >/dev/null 2>&1 \
    || { echo "SKIP: топология не поднялась"; exit 77; }

# C1: ~300 новых ICMP-потоков/с (разные id) 7с; C2: 20 одиночных ping (~3/с)
cat > "$OUT/flood.py" <<'PY'
import socket, struct, sys, time
def cs(b):
    t = sum(struct.unpack('!%dH' % (len(b) // 2), b)); t = (t >> 16) + (t & 0xffff); t += t >> 16; return ~t & 0xffff
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
end = time.time() + float(sys.argv[2]); i = 0
while time.time() < end:
    i += 1; h = struct.pack('!BBHHH', 8, 0, 0, i & 0xffff, 1) + b'x' * 8
    s.sendto(struct.pack('!BBHHH', 8, 0, cs(h), i & 0xffff, 1) + b'x' * 8, (sys.argv[1], 0)); time.sleep(1 / 300)
PY
ip netns exec "$C1" python3 "$OUT/flood.py" 10.79.1.1 7 &
FL=$!
sleep 1
ok=0
for _ in $(seq 1 20); do ip netns exec "$C2" ping -c1 -W1 10.79.2.1 >/dev/null 2>&1 && ok=$((ok+1)); sleep 0.25; done
wait "$FL" || true
echo "  (C2: $ok/20 ответов во время флуда C1)"
t "флуд C1 режется (c_drops_icmp > 0)" "[ \$(nft list counter inet shieldnode c_drops_icmp | awk '/packets/{print \$2}') -gt 0 ]"
t "легитимный ping C2 (~3/с) не страдает от флуда C1 (20/20 — лимит per-source)" "[ $ok = 20 ]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: icmp-scope (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
