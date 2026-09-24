#!/bin/bash
# node — тест: MSS clamp (opt-in ENABLE_MSS_CLAMP) на настоящем nft, MSS смотрим tcpdump'ом.
# 2026-09-24 (v1.1.5): backlog #5. (1) «set поднимает меньший MSS» — НЕ подтверждено:
# ядро (nft_exthdr) MSS только понижает, 1200 остаётся 1200 и на старом коде —
# проверка оставлена как страж. (2) IPv6 клампился v4-значением (mtu-40 вместо
# mtu-60) — исправлено: v6 = v4 - 20.
# Под root: `unshare -mn` + клиентский netns через veth; tmpfs поверх /etc/nftables.d,
# /etc/systemd/system, /run; systemctl — заглушка.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
for c in nft ip tcpdump python3 unshare; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP: нет $c"; exit 77; }; done
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /etc/nftables.d /etc/systemd/system /run; do mkdir -p "$d"; mount -t tmpfs t "$d"; done

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-mss
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diag" NODE_PROFILE_DIR="$OUT/profile.d"
export NODE_LOG="$OUT/node.log" NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
: > "$NODE_LOG"; printf 'ENABLE_MSS_CLAMP=1\nMSS_CLAMP_MTU=1400\n' > "$NODE_CONFIG"
for c in systemctl logger; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

C=nmss$$
ip netns add "$C"; trap 'ip netns del "$C" 2>/dev/null || true' EXIT
ip link set lo up
ip link add nma$$ type veth peer name nmb$$ netns "$C" || { echo "SKIP: нет veth"; exit 77; }
ip addr add 10.80.0.1/24 dev nma$$; ip addr add fd80::1/64 dev nma$$ nodad
ip -n "$C" addr add 10.80.0.2/24 dev nmb$$; ip -n "$C" addr add fd80::2/64 dev nmb$$ nodad
ip link set nma$$ up; ip -n "$C" link set lo up; ip -n "$C" link set nmb$$ up
ip route add default via 10.80.0.2 dev nma$$   # default iface = nma (для node_default_iface)

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1 || true
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/network.sh"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

node_network_mss_clamp > "$OUT/apply.out" 2>&1 || true
CONF=/etc/nftables.d/node-mss-clamp.conf
t "conf сгенерирован и проходит nft -c" "nft -c -f $CONF"
nft -f "$CONF"

# SYN от «сервера» (этот ns) к клиенту; MSS в SYN смотрит tcpdump в клиентском ns
syn_mss() { # syn_mss <dst> <port> [TCP_MAXSEG]
    local dst="$1" port="$2" seg="${3:-0}"
    ip netns exec "$C" timeout 6 tcpdump -i nmb$$ -nn -c1 -v "tcp dst port $port" > "$OUT/td.$port" 2>/dev/null &
    local td=$!
    sleep 1.2
    python3 - "$dst" "$port" "$seg" <<'PY' >/dev/null 2>&1 || true
import socket, sys
dst, port, seg = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_INET6 if ":" in dst else socket.AF_INET, socket.SOCK_STREAM)
if seg: s.setsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG, seg)
s.settimeout(1)
try: s.connect((dst, port))
except Exception: pass
PY
    wait "$td" || true
    grep -o 'mss [0-9]*' "$OUT/td.$port" | head -1 | awk '{print $2}'
}
m1="$(syn_mss 10.80.0.2 9101)"
m2="$(syn_mss 10.80.0.2 9102 1200)"
m3="$(syn_mss fd80::2 9103)"
echo "  (v4 default -> $m1, v4 MSS 1200 -> $m2, v6 default -> $m3)"
t "v4: MSS 1460 понижен до 1400" "[ '$m1' = 1400 ]"
t "v4: меньший MSS 1200 НЕ поднят до 1400" "[ '$m2' = 1200 ]"
t "v6: MSS понижен до 1380 (v4 - 20: заголовок IPv6 на 20 байт больше)" "[ '$m3' = 1380 ]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: mss-clamp (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
