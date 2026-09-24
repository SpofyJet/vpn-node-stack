#!/bin/bash
# node — тест: NIC «сильный» режим (lib/nic.sh), v1.1.7.
# tso/gso off и txqueuelen 10000 убраны (вредно на сервере / не действует при fq);
# твики прежних версий из runtime-tweaks.tsv возвращаются к исходным и снимаются с учёта
# (node_rt_drop), прочие записи реестра (rings) не трогаются. ethtool/ip — заглушки.
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log" NODE_RT_TWEAKS="$OUT/state/runtime-tweaks.tsv"
mkdir -p "$OUT/state" "$OUT/bin"; : > "$NODE_LOG"
LOG_LEVEL=error
cat > "$OUT/bin/ethtool" <<EOS
#!/bin/sh
echo "ethtool \$*" >> "$OUT/calls"
case "\$1" in
    -k) printf 'tcp-segmentation-offload: on\ngeneric-segmentation-offload: on\nlarge-receive-offload: off\n' ;;
    -g) printf 'Pre-set maximums:\nRX:\t1024\nTX:\t1024\nCurrent hardware settings:\nRX:\t1024\nTX:\t1024\n' ;;
    -c) printf 'adaptive-rx: on\nadaptive-tx: on\n' ;;
esac; exit 0
EOS
printf '#!/bin/sh\necho "ip $*" >> "%s/calls"\nexit 0\n' "$OUT" > "$OUT/bin/ip"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/lib/nic.sh"
node_default_iface() { echo eth0; }

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
conf() { printf '%b' "$1" > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1; : > "$OUT/calls"; }

# реестр прежней версии: tso/gso off + txqueuelen 10000 + ring (ring должен остаться)
printf 'eth0\toffload\ttcp-segmentation-offload\ton\neth0\toffload\tgeneric-segmentation-offload\ton\neth0\ttxqueuelen\t10000\t1000\neth0\tring_rx\t4096\t256\n' > "$NODE_RT_TWEAKS"
conf ''
node_nic_opt_apply >/dev/null 2>&1
t "миграция: tso возвращён в on"         "grep -qx 'ethtool -K eth0 tcp-segmentation-offload on' '$OUT/calls'"
t "миграция: gso возвращён в on"         "grep -qx 'ethtool -K eth0 generic-segmentation-offload on' '$OUT/calls'"
t "миграция: txqueuelen возвращён 1000"  "grep -qx 'ip link set dev eth0 txqueuelen 1000' '$OUT/calls'"
t "миграция: в реестре остался только ring_rx" "[ \"\$(cut -f2 '$NODE_RT_TWEAKS' | tr '\n' ' ')\" = 'ring_rx ' ]"
t "миграция: rings не откатывались"      "! grep -q 'ethtool -G' '$OUT/calls'"
: > "$OUT/calls"; node_nic_opt_apply >/dev/null 2>&1
t "повторный запуск: идемпотентно (нечего возвращать)" "! grep -qE 'ethtool -K|txqueuelen' '$OUT/calls'"

conf 'ENABLE_NIC_OFFLOAD_OPT=1\n'
node_nic_opt_apply >/dev/null 2>&1
t "OPT=1: tso/gso НЕ выключаются"        "! grep -qE 'segmentation-offload off' '$OUT/calls'"
t "OPT=1: txqueuelen НЕ меняется"        "! grep -q txqueuelen '$OUT/calls'"
t "OPT=1: реестр без offload/txqueuelen" "! grep -qE 'offload|txqueuelen' '$NODE_RT_TWEAKS'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: nic-opt (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
