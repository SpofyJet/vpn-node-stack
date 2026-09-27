#!/bin/bash
# node — тест: начальное окно TCP (initcwnd/initrwnd) на маршрутах по умолчанию (v1.2.2, lib/route.sh).
# Реальное ядро: свой network namespace (`unshare -mn`), dummy-интерфейс и default-маршрут как у
# DHCP-ноды (proto dhcp src … metric 100). networkd-каталоги — временные.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
ip link set lo up
ip link add dm0 type dummy 2>/dev/null || { echo "SKIP: нет модуля dummy"; exit 77; }
ip link set dm0 up
ip addr add 10.99.0.2/24 dev dm0
ip route add default via 10.99.0.1 dev dm0 proto dhcp src 10.99.0.2 metric 100

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/state" "$OUT/run-net" "$OUT/etc-net"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" NODE_RT_TWEAKS="$OUT/state/runtime-tweaks.tsv"
export NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
export NODE_IPV6_NETWORKD_SRC="$OUT/run-net" NODE_IPV6_NETWORKD_DIR="$OUT/etc-net"
: > "$OUT/log"; : > "$NODE_CONFIG"
printf '[Match]\nName=dm0\n\n[Network]\nDHCP=ipv4\n' > "$OUT/run-net/10-netplan-dm0.network"
printf '[Match]\nName=eth9\n\n[Network]\nAddress=192.0.2.5/24\nGateway=192.0.2.1\n' > "$OUT/run-net/10-netplan-eth9.network"
printf '[Match]\nName=*\n\n[Network]\nDHCP=yes\n' > "$OUT/run-net/99-default.network"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
node_persist() { cat > "$1"; }
source "$NODE_DIR/lib/route.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
route() { ip -4 -o route show table main default; }

t "исходно: у маршрута нет initcwnd (окно ядра 10)" "! route | grep -q initcwnd"
node_route_initcwnd_apply >/dev/null 2>&1
t "apply (дефолт): initcwnd 32 initrwnd 32 на default" "route | grep -q 'initcwnd 32' && route | grep -q 'initrwnd 32'"
t "apply: остальное в маршруте не изменилось (via, proto dhcp, src, metric)" "route | grep -q 'default via 10.99.0.1 dev dm0 proto dhcp src 10.99.0.2 metric 100'"
t "apply: маршрут один (change, а не второй default)" "[ \$(route | wc -l) = 1 ]"
d="$OUT/etc-net/10-netplan-dm0.network.d/91-vpn-node-initcwnd.conf"
t "networkd: drop-in [DHCPv4] для DHCP-интерфейса" "grep -qx 'InitialCongestionWindow=32' '$d' && grep -qx 'InitialAdvertisedReceiveWindow=32' '$d' && grep -qx '\[DHCPv4\]' '$d'"
t "networkd: статический .network и шаблон 99-default не тронуты" "[ ! -e '$OUT/etc-net/10-netplan-eth9.network.d' ] && [ ! -e '$OUT/etc-net/99-default.network.d' ]"
t "реестр runtime-твиков: kind route записан один раз" "[ \$(grep -c \$'\\troute\\t' '$NODE_RT_TWEAKS') = 1 ]"
node_route_initcwnd_apply >/dev/null 2>&1
t "повторный apply идемпотентен (initcwnd 32 ровно один раз, запись в реестре одна)" "[ \$(route | grep -o 'initcwnd' | wc -l) = 1 ] && [ \$(grep -c \$'\\troute\\t' '$NODE_RT_TWEAKS') = 1 ]"

echo 'TCP_INITCWND=64' > "$NODE_CONFIG"; node_load_config >/dev/null 2>&1
node_route_initcwnd_apply >/dev/null 2>&1
t "TCP_INITCWND=64: значение меняется на месте" "route | grep -q 'initcwnd 64 initrwnd 64' && [ \$(route | wc -l) = 1 ] && grep -qx 'InitialCongestionWindow=64' '$d'"
echo 'TCP_INITCWND=5' > "$NODE_CONFIG"; node_load_config >/dev/null 2>&1
t "TCP_INITCWND=5 (вне 10..128): берётся 32" "[ \"\$(node_route_initcwnd_value 2>/dev/null)\" = 32 ]"
echo 'TCP_INITCWND=0' > "$NODE_CONFIG"; node_load_config >/dev/null 2>&1
node_route_initcwnd_apply >/dev/null 2>&1
t "TCP_INITCWND=0: атрибуты сняты, drop-in удалён" "! route | grep -q initcwnd && [ ! -e '$d' ]"

: > "$NODE_CONFIG"; node_load_config >/dev/null 2>&1
node_route_initcwnd_apply >/dev/null 2>&1
node_rt_rollback >/dev/null 2>&1
t "rollback (реестр runtime-твиков): атрибуты сняты, drop-in удалён, маршрут цел" "! route | grep -q initcwnd && [ ! -e '$d' ] && route | grep -q 'default via 10.99.0.1 dev dm0 proto dhcp src 10.99.0.2 metric 100'"

# 2026-09-27: дубликат после DHCP-продления (networkd без drop-in добавляет свой маршрут рядом с нашим)
node_route_initcwnd_apply >/dev/null 2>&1
ip route append default via 10.99.0.1 dev dm0 proto dhcp src 10.99.0.2 metric 100
t "подготовка: два маршрута по умолчанию — наш (initcwnd 32) первым, «голый» вторым" "[ \$(route | wc -l) = 2 ] && route | sed -n 1p | grep -q 'initcwnd 32' && ! route | sed -n 2p | grep -q initcwnd"
echo 'TCP_INITCWND=48' > "$NODE_CONFIG"; node_load_config >/dev/null 2>&1
node_route_initcwnd_apply >/dev/null 2>&1
t "при дубликате смена значения: первый (действующий) маршрут = 48, маршрутов по-прежнему 2" "route | sed -n 1p | grep -q 'initcwnd 48' && [ \$(route | wc -l) = 2 ]"
node_rt_rollback >/dev/null 2>&1
t "rollback при дубликате: окна нет нигде, маршрут по умолчанию остался (ровно один)" "! route | grep -q initcwnd && [ \$(route | wc -l) = 1 ] && route | grep -q 'default via 10.99.0.1 dev dm0'"
: > "$NODE_CONFIG"; node_load_config >/dev/null 2>&1

# 2026-09-27: rt-reapply при boot (node-rt-tweaks, ProtectSystem=strict — /etc только для чтения):
# только атрибут маршрута, без записи файлов; раньше unit падал на mktemp в /etc/systemd/network
node_route_initcwnd_apply >/dev/null 2>&1                       # apply: drop-in есть
ip route change default via 10.99.0.1 dev dm0 proto dhcp src 10.99.0.2 metric 100   # «после reboot»: атрибута нет
mount --bind "$OUT/etc-net" "$OUT/etc-net" && mount -o remount,bind,ro "$OUT/etc-net"
node_route_initcwnd_apply runtime > "$OUT/rt.out" 2>&1 || true
t "rt-reapply (runtime) на /etc только для чтения: ни одной попытки записи, initcwnd 32 выставлен" "! grep -qi 'read-only' '$OUT/rt.out' && route | grep -q 'initcwnd 32'"
( node_route_initcwnd_apply ) > "$OUT/full.out" 2>&1 || true
t "отрицательный контроль: полный apply на том же RO-каталоге пишет drop-in (Read-only file system)" "grep -qi 'read-only' '$OUT/full.out'"
umount "$OUT/etc-net"

# маршрут, который ip печатает с флагом состояния linkdown (не принимается на вход ip route change)
# veth включён, но без несущей (второй конец выключен) — ip печатает маршрут с флагом linkdown
ip link add v1 type veth peer name v1p; ip addr add 10.98.0.2/24 dev v1; ip link set v1 up
ip route add default via 10.98.0.1 dev v1 metric 200
t "подготовка: ip печатает маршрут с флагом linkdown" "ip -4 -o route show default dev v1 | grep -q linkdown"
node_route_initcwnd_apply >/dev/null 2>&1
t "маршрут с флагом linkdown (интерфейс down) тоже получает initcwnd" "ip -4 -o route show default dev v1 | grep -q 'initcwnd 32'"
t "оба маршрута по умолчанию получили initcwnd" "[ \$(route | grep -c 'initcwnd 32') = 2 ]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: initcwnd"; else echo "FAILED: $fails"; exit 1; fi
