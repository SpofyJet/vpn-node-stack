#!/bin/bash
# shieldnode — тест: emergency-режим на настоящем nft: IPv4 — только SSH/whitelist, IPv6 — ничего (v1.2.0).
# 2026-09-23 (v1.1.4): emergency-ruleset резал только `ip protocol tcp|udp` —
# по IPv6 любой TCP/UDP-порт оставался открыт; admin v6 резолвился, но в
# ruleset не попадал (whitelist_v6 отсутствовал).
# Под root тест уходит в `unshare -mn`: сервер = свой netns, клиент = ip netns
# внутри него; tmpfs поверх /run (ip netns) — хост и живой firewall не тронуты.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
command -v ip >/dev/null 2>&1 || { echo "SKIP: нет ip"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: нет python3 (нужен listener)"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
mkdir -p /run; mount -t tmpfs t /run

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-emerg6
rm -rf "$OUT"; mkdir -p "$OUT"
C=snc$$
ip netns add "$C" || { echo "SKIP: ip netns недоступен"; exit 77; }
LISTENER=""
cleanup() { [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; ip netns del "$C" 2>/dev/null || true; }
trap cleanup EXIT
ip link add sva$$ type veth peer name svb$$ || { echo "SKIP: нет veth"; exit 77; }
ip link set svb$$ netns "$C"
ip link set lo up; ip -n "$C" link set lo up
ip addr add 10.78.0.1/24 dev sva$$; ip addr add fd78::1/64 dev sva$$ nodad
ip -n "$C" addr add 10.78.0.2/24 dev svb$$; ip -n "$C" addr add fd78::2/64 dev svb$$ nodad
ip -n "$C" addr add fd78::a/64 dev svb$$ nodad   # «админский» v6-адрес клиента
ip link set sva$$ up; ip -n "$C" link set svb$$ up

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# emergency-ruleset: SSH 22, admin v4 нет, admin v6 = fd78::a
( source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/emergency.sh"
  SH_F_ADMIN_V4="" SH_F_ADMIN_V6="fd78::a" SH_F_SSH_PORTS="22" shield_emergency_ruleset ) > "$OUT/emerg.nft"
t "emergency: nft -c принимает ruleset" "nft -c -f $OUT/emerg.nft"
t "emergency: ruleset загружен" "nft -f $OUT/emerg.nft"

# listeners: tcp 22 (SSH-порт), tcp 8443 и udp 5353 (прочие) — v4 и v6 раздельно
python3 - > /dev/null 2>&1 <<'PY' &
import socket, threading, time
def mk(fam, typ, port):
    s = socket.socket(fam, typ); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if fam == socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind(("::" if fam == socket.AF_INET6 else "0.0.0.0", port)); return s
def tcp(s):
    s.listen()
    while True:
        c, _ = s.accept(); c.close()
def udp(s):
    while True:
        d, p = s.recvfrom(100); s.sendto(b"pong", p)
for fam in (socket.AF_INET, socket.AF_INET6):
    for port in (22, 8443):
        threading.Thread(target=tcp, args=(mk(fam, socket.SOCK_STREAM, port),), daemon=True).start()
    threading.Thread(target=udp, args=(mk(fam, socket.SOCK_DGRAM, 5353),), daemon=True).start()
time.sleep(60)
PY
LISTENER=$!
sleep 1
cat > "$OUT/probe.py" <<'PY'
import socket, sys
dst, proto, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
src = sys.argv[4] if len(sys.argv) > 4 else None
fam = socket.AF_INET6 if ":" in dst else socket.AF_INET
s = socket.socket(fam, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
s.settimeout(1.5)
if src: s.bind((src, 0))
try:
    if proto == "tcp": s.connect((dst, port))
    else: s.sendto(b"ping", (dst, port)); s.recvfrom(10)
except Exception:
    sys.exit(1)
PY
P="ip netns exec $C python3 $OUT/probe.py"
t "v4: tcp 22 (SSH) открыт"              "$P 10.78.0.1 tcp 22"
t "v4: tcp 8443 закрыт"                  "! $P 10.78.0.1 tcp 8443"
t "v4: udp 5353 закрыт"                  "! $P 10.78.0.1 udp 5353"
# 2026-09-25 (v1.2.0): IPv6 на ноде выключен ОБЯЗАТЕЛЬНО — в аварийном режиме IPv6 не проходит
# вовсе (fail-safe), включая SSH и адрес из whitelist_v6 (прежде тест требовал «паритет v4/v6»)
t "v6: tcp 22 (SSH) — закрыт (IPv6 fail-safe)"      "! $P fd78::1 tcp 22 fd78::2"
t "v6: tcp 8443 закрыт"                            "! $P fd78::1 tcp 8443 fd78::2"
t "v6: udp 5353 закрыт"                            "! $P fd78::1 udp 5353 fd78::2"
t "v6: даже адрес из whitelist_v6 не проходит"      "! $P fd78::1 tcp 8443 fd78::a"
t "v6: ICMPv6 echo не проходит"                     "! ip netns exec $C ping -6 -c1 -W2 fd78::1"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: emergency-v6 (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
