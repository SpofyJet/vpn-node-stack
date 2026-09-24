#!/bin/bash
# node — тест: оптимизации v1.1.3 (2026-09-23).
#   кольца: один `ethtool -G dev rx N tx M` (раньше два -G -> отказ целиком),
#   early-out без сброса очередей, один `ethtool -g` на функцию, разбор вывода
#   ethtool 5.x/6.x = старому awk; XPS по scaling.rst (каждый CPU — в одну
#   tx-очередь); softnet-обратная связь (x2 только при доказанном насыщении,
#   явный ключ оператора и AUTO_SOFTNET_TUNE=0 уважаются); perf-снапшот/отчёт.
# XPS-часть пишет в фейковый /sys/class/net — нужен root + `unshare -m`.
set -euo pipefail
if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
IN_NS="${NODE_TEST_IN_NS:-0}"
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-opt113
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log" NODE_RT_TWEAKS="$OUT/state/rt.tsv" DRY_RUN=0
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$NODE_STATE_DIR" "$OUT/proc/net"; : > "$NODE_LOG"; : > "$NODE_RT_TWEAKS"
printf '#!/bin/sh\necho "default via 10.0.0.1 dev eth0 proto static"\n' > "$OUT/bin/ip"
cat > "$OUT/bin/ethtool" <<'EOF'
#!/bin/bash
echo "$*" >> "$ETHLOG"
case "$1" in
  -g) cat "$RINGFIX" ;;
  -G) [ "$*" = "${ETH_ACCEPT:-}" ] || { echo "ethtool: bad command line argument(s)" >&2; exit 1; } ;;
  -k) echo "large-receive-offload: off [fixed]" ;;
esac; exit 0
EOF
printf '#!/bin/sh\necho "${FAKE_NPROC:-4}"\n' > "$OUT/bin/nproc"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH" ETHLOG="$OUT/eth.log"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
for f in sysctl datapath network nic irq; do source "$NODE_DIR/lib/$f.sh"; done
source "$NODE_DIR/detect.sh"

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
cfg() { printf '%b' "$1" > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1; export NODE_CONFIG="$OUT/node.conf"; }

# ---------- разбор ethtool -g: новый хелпер == старому awk (форматы 5.x / 6.x / virtio) ----------
cat > "$OUT/ring5" <<'EOF'
Ring parameters for eth0:
Pre-set maximums:
RX:		4096
RX Mini:	0
RX Jumbo:	0
TX:		4096
Current hardware settings:
RX:		512
RX Mini:	0
RX Jumbo:	0
TX:		512
EOF
cat > "$OUT/ring6" <<'EOF'
Ring parameters for eth0:
Pre-set maximums:
RX:			8192
RX Mini:		n/a
RX Jumbo:		n/a
TX:			8192
TX push buff len:	n/a
Current hardware settings:
RX:			1024
RX Mini:		n/a
RX Jumbo:		n/a
TX:			1024
RX Buf Len:		n/a
CQE Size:		n/a
TX Push:		off
TCP data split:		n/a
EOF
for fx in ring5 ring6; do
    g="$(cat "$OUT/$fx")"
    for sec in "Pre-set maximums" "Current hardware settings"; do for d in RX TX; do
        old="$(awk "/$sec/{f=1} f&&/$d:/{print \$2; exit}" "$OUT/$fx")"
        t "ring $fx [$sec/$d]: новый разбор = старому ($old)" "[ \"\$(_node_ring \"\$g\" \"$sec\" $d)\" = '$old' ]"
    done; done
done

# ---------- кольца: синтаксис, early-out, один -g ----------
export RINGFIX="$OUT/ring5"
cfg 'NIC_RING_RX=4096\nNIC_RING_TX=4096\n'; : > "$ETHLOG"; ETH_ACCEPT="-G eth0 rx 4096 tx 4096" node_nic_apply_rings >/dev/null 2>&1
t "rings RX+TX: ОДИН вызов «-G eth0 rx 4096 tx 4096»" 'grep -qx -- "-G eth0 rx 4096 tx 4096" "$ETHLOG" && [ "$(grep -c -- "^-G" "$ETHLOG")" = 1 ]'
t "rings: в вызове ровно один «-G» (старое «-G dev rx .. -G dev tx ..» отвергалось)" '[ "$(grep -- "^-G" "$ETHLOG" | grep -o -- "-G" | wc -l)" = 1 ]'
t "rings: orig записан в реестр для rollback" 'grep -qP "^eth0\tring_rx\t4096\t512$" "$NODE_RT_TWEAKS"'
t "rings: ethtool -g вызван один раз" '[ "$(grep -c -- "^-g" "$ETHLOG")" = 1 ]'
cfg 'NIC_RING_RX=512\nNIC_RING_TX=512\n'; : > "$ETHLOG"; node_nic_apply_rings >/dev/null 2>&1
t "rings уже = цель: ethtool -G НЕ вызывается (нет сброса очередей)" '! grep -q -- "^-G" "$ETHLOG"'
cfg 'NIC_RING_RX=512\n'; : > "$ETHLOG"; node_nic_apply_rings >/dev/null 2>&1
t "rings только RX и он = цель: без -G" '! grep -q -- "^-G" "$ETHLOG"'
cfg ''; : > "$ETHLOG"; node_nic_apply_rings >/dev/null 2>&1
t "rings не заданы: ethtool не вызывается вовсе (как раньше)" '[ ! -s "$ETHLOG" ]'
: > "$ETHLOG"; node_nic_diag >/dev/null 2>&1
t "nic_diag: ethtool -g один раз (было 4)" '[ "$(grep -c -- "^-g" "$ETHLOG")" = 1 ]'
cfg 'ENABLE_NIC_OFFLOAD_OPT=1\n'; : > "$ETHLOG"; ETH_ACCEPT="-G eth0 rx 4096 tx 4096" node_nic_opt_apply >/dev/null 2>&1 || true
t "nic_opt: ethtool -g один раз (было 4), rings -> max одним -G" '[ "$(grep -c -- "^-g" "$ETHLOG")" = 1 ] && grep -qx -- "-G eth0 rx 4096 tx 4096" "$ETHLOG"'

# ---------- softnet ----------
sn() { : > "$OUT/proc/net/softnet_stat"; local l; for l in "$@"; do echo "$l 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000" >> "$OUT/proc/net/softnet_stat"; done; unset _NODE_SN_READ; }
plan() { node_sysctl_plan_init; node_datapath_plan >/dev/null 2>&1; node_network_plan >/dev/null 2>&1; }
val() { awk -F'\t' -v k="$1" '$1 == k {print $2}' "$NODE_PLAN_FILE"; }
export NODE_PROC_ROOT="$OUT/proc" DRY_RUN=1
cfg ''
sn "000f4240 00000000 00000000" "000f4240 00000000 00000000"; plan
t "softnet чисто: budget 600 / backlog 8192 (как в 1.1.2)" '[ "$(val net.core.netdev_budget)" = 600 ] && [ "$(val net.core.netdev_max_backlog)" = 8192 ]'
t "softnet чисто: usecs 4000 (v1.1.7, было 8000)" '[ "$(val net.core.netdev_budget_usecs)" = 4000 ]'
sn "000f4240 00000000 000001f4"; plan     # 500 / 1_000_000 = 0.05%
t "squeeze 0.05% (ниже порога 0.1%): budget не меняется" '[ "$(val net.core.netdev_budget)" = 600 ]'
sn "000f4240 00000000 00002710"; plan     # 10000 / 1_000_000 = 1%
t "squeeze 1%: netdev_budget 600 -> 1200" '[ "$(val net.core.netdev_budget)" = 1200 ]'
t "squeeze 1%: usecs пропорционально 1200 -> 8000 (v1.1.7)" '[ "$(val net.core.netdev_budget_usecs)" = 8000 ]'
sn "000f4240 00000005 00000000" "000f4240 00000000 00000000"; plan
t "dropped > 0: netdev_max_backlog 8192 -> 16384" '[ "$(val net.core.netdev_max_backlog)" = 16384 ]'
sn "ffffffff 00000000 00000000"; node_softnet_read
t "hex-разбор без strtonum (mawk): ffffffff = 4294967295" '[ "$_NODE_SN_PROC" = 4294967295 ]'
cfg 'NETDEV_BUDGET=900\n'; sn "000f4240 00000000 00002710"; plan
t "явный NETDEV_BUDGET оператора не трогается даже при squeeze" '[ "$(val net.core.netdev_budget)" = 900 ]'
cfg 'NETDEV_BUDGET_USECS=2000\n'; sn "000f4240 00000000 00000000"; plan
t "явный NETDEV_BUDGET_USECS оператора соблюдается" '[ "$(val net.core.netdev_budget_usecs)" = 2000 ]'
cfg 'AUTO_SOFTNET_TUNE=0\n'; sn "000f4240 00000009 00002710"; plan
t "AUTO_SOFTNET_TUNE=0: прежние фиксированные значения" '[ "$(val net.core.netdev_budget)" = 600 ] && [ "$(val net.core.netdev_max_backlog)" = 8192 ]'
cfg ''

# ---------- perf-снапшот / отчёт ----------
mkdir -p "$OUT/sys/class/net/eth0/statistics"
fx() { # <processed> <dropped> <ovf> <retrans> <out> <rcvbuf> <steal> <total> <missed>
    printf '%08x %08x 00000000\n' "$1" "$2" > "$OUT/proc/net/softnet_stat"
    printf 'TcpExt: SyncookiesSent ListenOverflows ListenDrops TCPBacklogDrop TCPRcvQDrop\nTcpExt: 0 %d %d 0 0\n' "$3" "$3" > "$OUT/proc/net/netstat"
    printf 'Tcp: RtoAlgorithm RetransSegs OutSegs\nTcp: 1 %d %d\nUdp: InDatagrams InErrors RcvbufErrors SndbufErrors\nUdp: 10 0 %d 0\n' "$4" "$5" "$6" > "$OUT/proc/net/snmp"
    local rest=$(( $8 - $7 )); printf 'cpu  %d 0 0 0 0 0 0 %d 0 0\n' "$rest" "$7" > "$OUT/proc/stat"
    echo 1000 > "$OUT/sys/class/net/eth0/statistics/rx_packets"; echo 0 > "$OUT/sys/class/net/eth0/statistics/rx_dropped"
    echo "$9" > "$OUT/sys/class/net/eth0/statistics/rx_missed_errors"; echo 0 > "$OUT/sys/class/net/eth0/statistics/tx_dropped"; }
export NODE_SYS_ROOT="$OUT/sys"
fx 1000 0 0 0 1000 0 0 10000 0; node_perf_snapshot > "$OUT/base.txt"
t "снапшот: все ключевые счётчики" 'for k in softnet_dropped TcpExtListenOverflows TcpRetransSegs UdpRcvbufErrors cpu_steal nic_rx_missed_errors; do grep -q "^$k=" "$OUT/base.txt" || exit 1; done'
fx 2000 0 0 10 2000 0 0 20000 0; node_perf_report "$OUT/base.txt" > "$OUT/r1"
t "отчёт без нагрузки: «нет сигналов узкого места»" 'grep -q "нет сигналов" "$OUT/r1" && ! grep -q "LIMIT" "$OUT/r1"'
fx 5000 7 3 200 3000 4 900 20000 11; node_perf_report "$OUT/base.txt" > "$OUT/r2"
t "отчёт: softnet backlog overflow"        'grep -q "LIMIT: softnet backlog" "$OUT/r2"'
t "отчёт: accept-очередь"                  'grep -q "LIMIT: accept-очередь" "$OUT/r2"'
t "отчёт: UDP receive buffer"              'grep -q "LIMIT: UDP receive buffer" "$OUT/r2"'
t "отчёт: NIC rx missed -> кольца"         'grep -q "LIMIT: NIC дропает" "$OUT/r2"'
t "отчёт: ретрансмиты 10% (200/2000) — путь" 'grep -q "tcp_retrans=10.00%" "$OUT/r2" && grep -q "NOTE: ретрансмиты" "$OUT/r2"'
t "отчёт: steal 9% (900/10000) — гипервизор" 'grep -q "steal=9.0%" "$OUT/r2" && grep -q "NOTE: CPU steal" "$OUT/r2"'
fx 10 0 0 0 10 0 0 100 0; node_perf_report "$OUT/base.txt" > "$OUT/r3"
t "отчёт: счётчики меньше baseline -> «был reboot»" 'grep -q "был reboot" "$OUT/r3"'
t "отчёт без baseline — понятное сообщение" 'node_perf_report "$OUT/nope" | grep -q "baseline нет"'
unset NODE_PROC_ROOT NODE_SYS_ROOT; export DRY_RUN=0

# ---------- XPS по scaling.rst ----------
if [ "$IN_NS" != "1" ]; then
    echo "skip - XPS mapping (нужен root + unshare -m)"
else
    mount -t tmpfs t /sys/class/net
    xps_case() { # <cpus> <txq> <ожидаемые маски через пробел>
        rm -rf /sys/class/net/eth0; mkdir -p /sys/class/net/eth0/queues/rx-0; local i
        for ((i=0; i<$2; i++)); do mkdir -p "/sys/class/net/eth0/queues/tx-$i"; echo 0 > "/sys/class/net/eth0/queues/tx-$i/xps_cpus"; done
        : > "$NODE_RT_TWEAKS"; FAKE_NPROC=$1 node_irq_apply >/dev/null 2>&1
        local got=""; for ((i=0; i<$2; i++)); do got+="$(cat "/sys/class/net/eth0/queues/tx-$i/xps_cpus") "; done
        t "XPS cpus=$1 txq=$2: маски [${3}]" "[ '$got' = '$3 ' ]"
    }
    cfg 'ENABLE_XPS=1\n'
    xps_case 4 4 "1 2 4 8"
    xps_case 8 2 "55 aa"
    xps_case 2 4 "1 2 1 2"
    xps_case 6 4 "11 22 4 8"
    t "XPS: orig каждой очереди в реестре (rollback)" '[ "$(grep -cP "^eth0\txps\t" "$NODE_RT_TWEAKS")" = 4 ]'
    cfg ''; rm -rf /sys/class/net/eth0; mkdir -p /sys/class/net/eth0/queues/tx-0; echo 0 > /sys/class/net/eth0/queues/tx-0/xps_cpus
    FAKE_NPROC=4 node_irq_apply >/dev/null 2>&1
    t "ENABLE_XPS=0 (дефолт): xps_cpus не тронут" '[ "$(cat /sys/class/net/eth0/queues/tx-0/xps_cpus)" = 0 ]'
    # без rx-* каталогов irq_apply не должен обрываться (раньше rc 2 под pipefail)
    cfg 'ENABLE_XPS=1\n'; rc=0; FAKE_NPROC=4 node_irq_apply >/dev/null 2>&1 || rc=$?
    t "irq_apply без rx-* очередей: rc 0 и XPS применён" '[ "$rc" = 0 ] && [ "$(cat /sys/class/net/eth0/queues/tx-0/xps_cpus)" = f ]'
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: optimize-113 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
