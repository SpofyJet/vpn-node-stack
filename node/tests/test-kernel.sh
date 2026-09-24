#!/bin/bash
# node — тест: lib/kernel.sh (BBR-гейтинг, CPU-уровень, план perf-sysctl).
# Запуск: bash tests/test-kernel.sh (root не обязателен)
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-test-kernel/state
export NODE_DIAG_DIR=/tmp/node-test-kernel/diag
export NODE_PROFILE_DIR=/tmp/node-test-kernel/profile.d
export NODE_LOG=/tmp/node-test-kernel/node.log
export DRY_RUN=1

rm -rf /tmp/node-test-kernel
mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR"

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
node_load_config
source "$NODE_DIR/lib/sysctl.sh"
source "$NODE_DIR/lib/tcp.sh"
source "$NODE_DIR/lib/kernel.sh"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# --- node_bbr_plan: без BBR в ядре — не пишем ключи (dry-run окружение может не иметь bbr) ---
node_sysctl_plan_init
node_bbr_plan
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
    t "BBR доступен -> план содержит congestion_control=bbr" grep -q $'net.ipv4.tcp_congestion_control\tbbr' "$NODE_PLAN_FILE"
else
    t "BBR недоступен -> ключи НЕ планируются (не ломаем систему)" bash -c "! grep -q 'congestion_control' '$NODE_PLAN_FILE'"
fi

# --- perf-tier выключен по умолчанию ---
node_sysctl_plan_init
node_tcp_perf_plan
t "perf-sysctl выключен по умолчанию: план пуст" bash -c "test ! -s '$NODE_PLAN_FILE'"

# --- perf-tier включён: все ключи в плане ---
node_sysctl_plan_init
sed -i 's/^ENABLE_PERFORMANCE_SYSCTL=0$/ENABLE_PERFORMANCE_SYSCTL=1/' "$CONFIG_CACHE"   # user-override
node_tcp_perf_plan
for k in tcp_tw_reuse tcp_fin_timeout tcp_retries2 tcp_keepalive_time tcp_fastopen tcp_no_metrics_save tcp_synack_retries; do
    t "perf: $k запланирован" grep -q "net.ipv4.$k" "$NODE_PLAN_FILE"
done
for k in tcp_sack tcp_dsack tcp_mtu_probing tcp_slow_start_after_idle; do   # v1.1.7: no-op/перенесены в базу
    t "perf: $k больше не в perf-tier" bash -c "! grep -q 'net.ipv4.$k	' '$NODE_PLAN_FILE'"
done
sed -i 's/^ENABLE_PERFORMANCE_SYSCTL=1$/ENABLE_PERFORMANCE_SYSCTL=0/' "$CONFIG_CACHE"

# --- perf-tier чужие ключи не трогает ---
t "perf: conntrack-ключи не появились" bash -c "! grep -q 'net.netfilter' '$NODE_PLAN_FILE'"

# --- CPU-уровень: валидация формата v1/v2/v3 ---
xt_cpu_xlevel() { case "$(node_cpu_xlevel)" in v1|v2|v3) return 0 ;; *) return 1 ;; esac; }
t "cpu_xlevel возвращает vN" xt_cpu_xlevel

# --- XanMod-гейтинг: не поддерживаемая платформа -> not supported ---
xt_xanmod_gate() {
    if [ "$(uname -m)" = x86_64 ] && grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null; then
        node_xanmod_supported
    else
        ! node_xanmod_supported
    fi
}
t "xanmod_supported требует Debian/Ubuntu x86_64" xt_xanmod_gate

# --- XanMod-ветка: имя пакета по branch (функции живут в текущем шелле — без bash -c) ---
xt_pkg_bad() { ! node_xanmod_pkg edge v2; }
t "xanmod pkg: lts -> linux-xanmod-lts-x64v3"   test "$(node_xanmod_pkg lts v3)" = "linux-xanmod-lts-x64v3"
t "xanmod pkg: main -> linux-xanmod-x64v2"      test "$(node_xanmod_pkg main v2)" = "linux-xanmod-x64v2"
t "xanmod pkg: дефолт lts (defaults.conf)"      grep -q '^XANMOD_BRANCH=lts$' "$NODE_DIR/node.defaults.conf"
t "xanmod pkg: мусорная ветка отвергается"      xt_pkg_bad

# --- BBR-active флаг ---
t "bbr_active без bbr = no" bash -c '! node_bbr_active'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: kernel (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
