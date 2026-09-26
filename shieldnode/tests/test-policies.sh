#!/bin/bash
# shieldnode — тест: поведение политик в изолированном network namespace (хост не тронут).
# Требует root + ip + nft + python3(для listener). Без них — SKIP (код 77).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
command -v ip  >/dev/null 2>&1 || { echo "SKIP: нет ip"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: нет python3 (нужен listener)"; exit 77; }
# 2026-09-24 (v1.1.4): «хостовая» сторона veth (и 10.77.0.1/24) создавалась в НАСТОЯЩЕМ
# netns хоста — на живой ноде это udev net-add (node rt-reapply) и чужой адрес на хосте.
# Теперь весь тест — в своём netns (`unshare -mn`, tmpfs над /run для ip netns).
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ] && unshare -mn true 2>/dev/null; then
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
if [ "${SHIELD_TEST_IN_NS:-0}" = "1" ]; then mount -t tmpfs t /run; ip link set lo up; fi

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=shieldtest$$
# 2026-09-23 (v1.1.4): имя veth ≤15 символов (IFNAMSIZ) — "veth-shieldtest<pid>b"
# не создавался никогда, и тест всегда уходил в ложный SKIP "нет прав на veth"
VA="sv$$a" VB="sv$$b"
NS2=shieldout$$ VC="so$$a" VD="so$$b"
cleanup() { ip netns del "$NS" 2>/dev/null || true; ip netns del "$NS2" 2>/dev/null || true; rm -f /tmp/shieldtest-ruleset.nft /tmp/shieldtest-ruleset2.nft; }
trap cleanup EXIT

ip netns add "$NS"
ip -n "$NS" link set lo up
ip link add "$VA" type veth peer name "$VB" || { echo "SKIP: нет прав на veth"; exit 77; }
ip link set "$VB" netns "$NS"
ip addr add 10.77.0.1/24 dev "$VA"
ip -n "$NS" addr add 10.77.0.2/24 dev "$VB"
ip link set "$VA" up
ip -n "$NS" link set "$VB" up

# ruleset с заниженным TCP_NEW_RATE=20/min для триггера за разумное время
export SHIELD_VERSION=1.0.0
export SH_F_SSH_PORTS="22"
export SH_F_PROTECTED_TCP="80"
export SH_F_PROTECTED_UDP="5353"
export SH_F_ADMIN_V4="" SH_F_ADMIN_V6=""
export SH_F_EXCL_V4="" SH_F_EXCL_V6=""
export SH_F_IPV6=0 SH_F_EXTENSIONS=""
export SH_F_WAN_IFACE="" SH_F_ENABLE_ANTISPOOF=0
export SH_F_ENABLE_SSH_PROTECTION=0 SH_F_ENABLE_INVALID_DROP=1 SH_F_ENABLE_LOOPBACK=1
export SH_F_ENABLE_ESTABLISHED=1 SH_F_ENABLE_ABUSE_LIMITING=1
export SH_R_SSH_CONN_MAX=8 SH_R_SSH_NEW_RATE=10 SH_R_SSH_NEW_BURST=20
export SH_R_TCP_NEW_RATE=20 SH_R_TCP_NEW_BURST=40 SH_R_TCP_SYN_RATE=500 SH_R_TCP_SYN_BURST=1000
# фаза 1: дефолт v1.2.2 — бан за флуд выключен (TCP_SYN_BAN_RATE=0), мягкие лимиты НЕ банят
export SH_R_TCP_SYN_BAN_RATE=0 SH_R_TCP_SYN_BAN_BURST=20000
export SH_R_TCP_CONN_MAX=15000 SH_R_TCP_GLOBAL_CEIL=0
export SH_R_UDP_RATE=50 SH_R_UDP_BURST=50 SH_R_UDP_GLOBAL_CEIL=0
export SH_R_SSH_ABUSERS_TIMEOUT=3600 SH_R_SSH_ABUSERS_SIZE=65536
export SH_R_TCP_ABUSERS_TIMEOUT=900 SH_R_TCP_ABUSERS_SIZE=131072
export SH_R_UDP_ABUSERS_TIMEOUT=900 SH_R_UDP_ABUSERS_SIZE=65536
export SH_R_TEMP_BLOCKLIST_TIMEOUT=3600 SH_R_TEMP_BLOCKLIST_SIZE=32768
# 2026-09-23 (v1.1.4): переменные, которые рендерер требует с v1.1.x (иначе unbound)
export SH_F_ENABLE_BLOCKLISTS=0
export SH_R_SCANNER_BLOCKLIST_SIZE=262144 SH_R_THREAT_BLOCKLIST_SIZE=131072 SH_R_TOR_BLOCKLIST_SIZE=16384
export SH_R_CUSTOM_BLOCKLIST_SIZE=65536 SH_R_SPAMHAUS_BLOCKLIST_SIZE=8192 SH_R_CINS_BLOCKLIST_SIZE=65536
export SH_R_CROWDSEC_BLOCKLIST_SIZE=262144

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


# 2026-09-27 (v1.2.1): ТРАНЗИТ через ноду (исходящие Docker-контейнеров в bridge, гости LXD/KVM) —
# не «клиент ноды»: адрес назначения не её. Раньше prerouting резал и его: на лабе хост с shieldnode
# забанил свою VM за 400 исходящих соединений на :443. Схема: «контейнер» (этот netns, 10.77.0.1)
# -> нода ($NS, форвардинг) -> «интернет» ($NS2, 10.88.0.2:80, порт 80 — защищаемый у ноды).
ip netns add "$NS2"; ip -n "$NS2" link set lo up
ip -n "$NS" link add "$VC" type veth peer name "$VD"
ip -n "$NS" link set "$VD" netns "$NS2"
ip -n "$NS" addr add 10.88.0.1/24 dev "$VC"; ip -n "$NS" link set "$VC" up
ip -n "$NS2" addr add 10.88.0.2/24 dev "$VD"; ip -n "$NS2" link set "$VD" up
ip -n "$NS2" route add default via 10.88.0.1
ip netns exec "$NS" sysctl -qw net.ipv4.ip_forward=1
ip route add 10.88.0.0/24 via 10.77.0.2
ip netns exec "$NS2" python3 -m http.server 80 --bind 10.88.0.2 >/dev/null 2>&1 &
OUTSRV=$!
sleep 0.7
ok_tr=0
for i in $(seq 1 60); do
    timeout 2 bash -c "exec 3<>/dev/tcp/10.88.0.2/80" 2>/dev/null && ok_tr=$((ok_tr+1))
done
t "транзит: 60 исходящих соединений через ноду прошли все (было бы отброшено сверх 40)" test "$ok_tr" = 60
t "транзит: мягкий лимит не тронут (c_drops_newconn_limit_v4 = 0)" bash -c "[ \"\$(ip netns exec $NS nft list counter inet shieldnode c_drops_newconn_limit_v4 | awk '/packets/ {print \$2}')\" = 0 ]"
kill "$OUTSRV" 2>/dev/null || true; wait "$OUTSRV" 2>/dev/null || true

# 2026-09-26 (v1.2.1): всплеск 60 новых коннектов с одного src (мягкий лимит 20/мин, burst 40):
# лишние отбрасываются, но IP НЕ банится (так выглядит активный клиент VPN / CGNAT)
for i in $(seq 1 60); do
    (timeout 2 bash -c "exec 3<>/dev/tcp/10.77.0.2/80") 2>/dev/null || true
done
t "мягкий лимит: лишние новые соединения отброшены (c_drops_newconn_limit_v4 > 0)" bash -c "[ \"\$(ip netns exec $NS nft list counter inet shieldnode c_drops_newconn_limit_v4 | awk '/packets/ {print \$2}')\" -gt 0 ]"
t "мягкий лимит: src НЕ попал в tcp_abusers" bash -c "! ip netns exec $NS nft list set inet shieldnode tcp_abusers | grep -q 'elements = {'"
sleep 3.5   # 20/мин = 1 соединение за 3 с: без бана клиент снова подключается
t "мягкий лимит: через 3 с connect снова проходит" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80"'
# 2026-09-27 (v1.2.2): UDP сверх лимита (50/с burst 50) — лишнее отбрасывается, IP НЕ банится
ip netns exec "$NS" python3 -c '
import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("10.77.0.2", 5353))
while True:
    d, a = s.recvfrom(64)
    if d == b"probe": open("/tmp/shieldtest-udp-ok", "w").write("ok")
' >/dev/null 2>&1 &
UDPSRV=$!
sleep 0.5; rm -f /tmp/shieldtest-udp-ok
python3 -c '
import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for _ in range(500): s.sendto(b"x", ("10.77.0.2", 5353))'
t "UDP: лишнее сверх лимита отброшено (c_drops_udp_limit_v4 > 0)" bash -c "[ \"\$(ip netns exec $NS nft list counter inet shieldnode c_drops_udp_limit_v4 | awk '/packets/ {print \$2}')\" -gt 0 ]"
t "UDP: src НЕ попал в udp_abusers" bash -c "! ip netns exec $NS nft list set inet shieldnode udp_abusers | grep -q 'elements = {'"
sleep 1.5
python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"probe", ("10.77.0.2", 5353))'
sleep 0.5
t "UDP: через 1.5 с пакеты того же src снова доходят" test -f /tmp/shieldtest-udp-ok
kill "$UDPSRV" 2>/dev/null || true; wait "$UDPSRV" 2>/dev/null || true; rm -f /tmp/shieldtest-udp-ok

# фаза 2: опц. бан за SYN-флуд (TCP_SYN_BAN_RATE > 0) работает, если его включить
SH_R_TCP_SYN_BAN_RATE=5 SH_R_TCP_SYN_BAN_BURST=10 SH_R_TCP_NEW_RATE=100000 SH_R_TCP_NEW_BURST=100000 \
    bash -c "source '$SHIELD_DIR/lib/nft.sh'; shield_nft_build_ruleset" > /tmp/shieldtest-ruleset2.nft
ip netns exec "$NS" nft -f /tmp/shieldtest-ruleset2.nft || { echo "FAIL: ruleset фазы 2 не применился"; exit 1; }
for i in $(seq 1 60); do
    (timeout 2 bash -c "exec 3<>/dev/tcp/10.77.0.2/80") 2>/dev/null &
done
wait_conns() { local j; for j in $(jobs -p); do [ "$j" = "$LISTENER" ] || wait "$j" 2>/dev/null || true; done; }
wait_conns
t "SYN-флуд (> порога бана): src попал в tcp_abusers" bash -c "ip netns exec $NS nft list set inet shieldnode tcp_abusers | grep -q 'elements = { 10.77.0.1'"
t "SYN-флуд: c_drops_syn_v4 > 0" bash -c "[ \"\$(ip netns exec $NS nft list counter inet shieldnode c_drops_syn_v4 | awk '/packets/ {print \$2}')\" -gt 0 ]"
t "после бана connect с того же src НЕ проходит" bash -c '! timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80" 2>/dev/null'

# temporary_blocklist: ручной бан + снятие
# 2026-09-23 (v1.1.4): снимаем бан из шага выше — иначе src остаётся в tcp_abusers
# (15m) и проверка «снятие бана» не может пройти независимо от temporary_blocklist
ip netns exec "$NS" nft delete element inet shieldnode tcp_abusers "{ 10.77.0.1 }"
ip netns exec "$NS" nft add element inet shieldnode temporary_blocklist "{ 10.77.0.1 }"
t "temporary_blocklist банит (дроп)" bash -c '! timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80" 2>/dev/null'
ip netns exec "$NS" nft delete element inet shieldnode temporary_blocklist "{ 10.77.0.1 }"
t "снятие бана возвращает connect" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/10.77.0.2/80"' || t "снятие бана возвращает connect (после сброса conntrack)" bash -c "ip netns exec $NS conntrack -F 2>/dev/null; timeout 3 bash -c 'exec 3<>/dev/tcp/10.77.0.2/80'"

kill "$LISTENER" 2>/dev/null || true
wait "$LISTENER" 2>/dev/null || true

echo
if [ "$fails" -eq 0 ]; then echo "PASS: policies (netns)"; else echo "FAILED: $fails проверок"; exit 1; fi
