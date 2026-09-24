#!/bin/bash
# node — тест: значения node.conf не исполняются как код и не ломают apply (v1.1.8).
# bash вычисляет содержимое переменной в $(( )) / [[ -gt ]] как выражение: значение
# 'x[$(cmd)]' исполняло бы cmd от root. NETDEV_BUDGET шёл в $(( )) (usecs), MSS_CLAMP_MTU —
# в $(( )) и nft-правило, LIMIT_NOFILE — в systemd drop-in чужого юнита.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log" DRY_RUN=1
printf 'CONFIG_HZ=1000\n' > "$OUT/kconfig"; export NODE_KERNEL_CONFIG="$OUT/kconfig"   # HZ-зависимый usecs
mkdir -p "$OUT/state"; : > "$NODE_LOG"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; source "$NODE_DIR/lib/sysctl.sh"
source "$NODE_DIR/lib/datapath.sh"; source "$NODE_DIR/lib/limits.sh"; source "$NODE_DIR/lib/network.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
P="$OUT/pwn"
printf '%s\n' "NETDEV_BUDGET=x[\$(touch $P-nb)]" "MSS_CLAMP_MTU=y[\$(touch $P-mss)]" \
    'LIMIT_NOFILE=1048576 ExecStartPre=/bin/true' "VM_MIN_FREE_KBYTES=z[\$(touch $P-mf)]" 'ENABLE_MSS_CLAMP=1' > "$OUT/node.conf"
NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
node_sysctl_plan_init
( node_datapath_plan ) >/dev/null 2>&1 || true
t "NETDEV_BUDGET-инъекция не исполнена; budget/usecs = 600/4000" "[ ! -e $P-nb ] && grep -qP '^net.core.netdev_budget\t600\t' '$NODE_PLAN_FILE' && grep -qP '^net.core.netdev_budget_usecs\t4000\t' '$NODE_PLAN_FILE'"
t "VM_MIN_FREE_KBYTES-инъекция не исполнена" "[ ! -e $P-mf ]"
node_persist() { cat >> "$OUT/persisted"; }
node_default_iface() { echo lo; }
( node_network_mss_clamp ) >/dev/null 2>&1 || true
t "MSS_CLAMP_MTU-инъекция не исполнена; в nft — число (mtu-40)" "[ ! -e $P-mss ] && grep -qE 'maxseg size set [0-9]+$' '$OUT/persisted' && ! grep -q 'touch' '$OUT/persisted'"
( node_limits_plan; echo "$NODE_LIMIT_NOFILE" > "$OUT/nofile" ) >/dev/null 2>&1 || true
t "LIMIT_NOFILE с мусором -> 1048576 (в drop-in чужого юнита ничего лишнего)" "[ \"\$(cat $OUT/nofile)\" = 1048576 ]"
t "предупреждения в логе" "grep -q \"NETDEV_BUDGET='x\" '$NODE_LOG' && grep -q 'MSS_CLAMP_MTU=' '$NODE_LOG' && grep -q 'LIMIT_NOFILE=' '$NODE_LOG'"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: config-injection (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
