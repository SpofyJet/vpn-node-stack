#!/bin/bash
# shieldnode — тест: поведение политик в изолированном network namespace (хост не тронут).
# Требует root + ip + nft + python3(для listener). Без них — SKIP (код 77).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
command -v ip  >/dev/null 2>&1 || { echo "SKIP: нет ip"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: нет python3 (нужен listener)"; exit 77; }

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=shieldtest$$
cleanup() { ip netns del "$NS" 2>/dev/null || true; rm -f /tmp/shieldtest-ruleset.nft; }
trap cleanup EXIT

ip netns add "$NS"
ip -n "$NS" link set lo up
ip link add "veth-${NS}a" type veth peer name "veth-${NS}b" || { echo "SKIP: нет прав на veth"; exit 77; }
ip link set "veth-${NS}b" netns "$NS"
ip addr add 10.77.0.1/24 dev "veth-${NS}a"
ip -n "$NS" addr add 10.77.0.2/24 dev "veth-${NS}b"
ip link set "veth-${NS}a" up
ip -n "$NS" link set "veth-${NS}b" up

# ruleset с заниженным TCP_NEW_RATE=20/min для триггера за разумное время
export SHIELD_VERSION=1.0.0
export SH_F_SSH_PORTS="22"
export SH_F_PROTECTED_TCP="80"
export SH_F_PROTECTED_UDP=""
export SH_F_ADMIN_V4="" SH_F_ADMIN_V6=""
export SH_F_EXCL_V4="" SH_F_EXCL_V6=""
export SH_F_IPV6=0 SH_F_EXTENSIONS=""
export SH_F_WAN_IFACE="" SH_F_ENABLE_ANTISPOOF=0
export SH_F_ENABLE_SSH_PROTECTION=0 SH_F_ENABLE_INVALID_DROP=1 SH_F_ENABLE_LOOPBACK=1
export SH_F_ENABLE_ESTABLISHED=1 SH_F_ENABLE_ABUSE_LIMITING=1
export SH_R_SSH_CONN_MAX=8 SH_R_SSH_NEW_RATE=10 SH_R_SSH_NEW_BURST=20
export SH_R_TCP_NEW_RATE=20 SH_R_TCP_NEW_BURST=40 SH_R_TCP_SYN_RATE=500 SH_R_TCP_SYN_BURST=1000
export SH_R_TCP_CONN_MAX=15000 SH_R_TCP_GLOBAL_CEIL=0
export SH_R_UDP_RATE=20000 SH_R_UDP_BURST=40000 SH_R_UDP_GLOBAL_CEIL=0
export SH_R_SSH_ABUSERS_TIMEOUT=3600 SH_R_SSH_ABUSERS_SIZE=65536
export SH_R_TCP_ABUSERS_TIMEOUT=900 SH_R_TCP_ABUSERS_SIZE=131072
export SH_R_UDP_ABUSERS_TIMEOUT=900 SH_R_UDP_ABUSERS_SIZE=65536
export SH_R_TEMP_BLOCKLIST_TIMEOUT=3600 SH_R_TEMP_BLOCKLIST_SIZE=32768

bash -c "source '$SHIELD_DIR/lib/nft.sh'; shield_nft_build_ruleset" > /tmp/shieldtest-ruleset.nft

# применяем ВНУТРИ namespace (затронут только netns)
ip netns exec "$NS" nft -f /tmp/shieldtest-ruleset.nft || { echo "FAIL: ruleset не применился в netns"; exit 1; }

# re-apply того же ruleset ПОВЕРХ живой таблицы: тройка table/delete/table
# в начале файла делает замену атомарной (meter — named dynset, иначе EBUSY)
ip netns exec "$NS" nft -f /tmp/shieldtest-ruleset.nft || { echo "FAIL: повторный apply ruleset не прошёл (meter EBUSY?)"; exit 1; }

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# TCP-листенер (protected port 80) внутри ns
ip netns exec "$NS" python3 -m http.server 80 --bind 10.77.0.2 >/dev/null 2>&1 &
LISTENER=$!
sleep 0.7

t "нормальный TCP-connect (хост->ns:80) проходит" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80"'

# флуд 60 новыx коннектов с одного src (лимит 20/мин, burst 40) -> tcp_abusers
for i in $(seq 1 60); do
    (timeout 2 bash -c "exec 3<>/dev/tcp/10.77.0.2/80") 2>/dev/null || true
done

t "абьюзер 10.77.0.1 попал в tcp_abusers" bash -c "ip netns exec $NS nft list set inet shieldnode tcp_abusers | grep -q 'elements = { 10.77.0.1'"
t "после бана connect с того же src НЕ проходит" bash -c '! timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80" 2>/dev/null'

# temporary_blocklist: ручной бан + снятие
ip netns exec "$NS" nft add element inet shieldnode temporary_blocklist "{ 10.77.0.1 }"
t "temporary_blocklist банит (дроп)" bash -c '! timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80" 2>/dev/null'
ip netns exec "$NS" nft delete element inet shieldnode temporary_blocklist "{ 10.77.0.1 }"
t "снятие бана возвращает connect" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80"' || t "снятие бана возвращает connect (после сброса conntrack)" bash -c "ip netns exec $NS conntrack -F 2>/dev/null; timeout 3 bash -c 'exec 3<>/dev/tcp/10.77.0.2/80'"

kill "$LISTENER" 2>/dev/null || true
wait "$LISTENER" 2>/dev/null || true

echo
if [ "$fails" -eq 0 ]; then echo "PASS: policies (netns)"; else echo "FAILED: $fails проверок"; exit 1; fi
