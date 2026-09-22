#!/bin/bash
# node — тест: vm/fs-блок (lib/datapath.sh), keepalive (lib/tcp.sh),
# nf_conntrack_helper (lib/conntrack.sh) против meminfo-фикстур тиров T1/T4.
# Запуск: bash tests/test-vmfs.sh
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-vmfs-test/state
export NODE_DIAG_DIR=/tmp/node-vmfs-test/diag
export NODE_PROFILE_DIR=/tmp/node-vmfs-test/profile.d
export NODE_LOG=/tmp/node-vmfs-test/node.log
export DRY_RUN=1
LOG_LEVEL=info

rm -rf /tmp/node-vmfs-test
mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR"

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/lib/sysctl.sh"
source "$NODE_DIR/lib/datapath.sh"
source "$NODE_DIR/lib/tcp.sh"
source "$NODE_DIR/lib/conntrack.sh"

# минимальный CONFIG_CACHE из defaults (как в test-datapath.sh)
CONFIG_CACHE="$(mktemp)"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf" > "$CONFIG_CACHE"
export CONFIG_CACHE
# keepalive живёт в «сильном» TCP-тире — включаем
sed -i 's/^ENABLE_PERFORMANCE_SYSCTL=.*/ENABLE_PERFORMANCE_SYSCTL=1/' "$CONFIG_CACHE"

# meminfo-фикстуры тиров (node_memtotal_mb/node_ram_tier читают NODE_PROC_MEMINFO)
MEMINFO_T1=/tmp/node-vmfs-test/meminfo-t1   # 1GB  -> tier 1
MEMINFO_T4=/tmp/node-vmfs-test/meminfo-t4   # 16GB -> tier 4
printf 'MemTotal:    1048576 kB\nMemFree:     262144 kB\n' > "$MEMINFO_T1"
printf 'MemTotal:    16777216 kB\nMemFree:    4194304 kB\n' > "$MEMINFO_T4"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

replan() {
    node_sysctl_plan_init
    node_datapath_plan
    node_tcp_plan
    node_tcp_perf_plan
    node_conntrack_plan
    PLAN="$NODE_PLAN_FILE"
}

# ============ TIER 1 (1GB) ============
export NODE_PROC_MEMINFO="$MEMINFO_T1"
replan

t "T1: swappiness=20"            bash -c "grep -q 'vm.swappiness	20' '$PLAN'"
t "T1: min_free_kbytes=32768"    bash -c "grep -q 'vm.min_free_kbytes	32768' '$PLAN'"
t "T1: vfs_cache_pressure=150"   bash -c "grep -q 'vm.vfs_cache_pressure	150' '$PLAN'"
t "T1: overcommit_memory=1"      bash -c "grep -q 'vm.overcommit_memory	1' '$PLAN'"

# ============ TIER 4 (16GB) ============
export NODE_PROC_MEMINFO="$MEMINFO_T4"
replan

t "T4: swappiness=10"                bash -c "grep -q 'vm.swappiness	10' '$PLAN'"
t "T4: min_free_kbytes=262144"       bash -c "grep -q 'vm.min_free_kbytes	262144' '$PLAN'"
t "T4: vfs_cache_pressure НЕ пишется" bash -c "! grep -q 'vm.vfs_cache_pressure' '$PLAN'"
t "T4: overcommit_memory НЕ пишется"  bash -c "! grep -q 'vm.overcommit_memory' '$PLAN'"

# ============ безусловные vm/fs (все тиры, здесь — T4) ============
t "vm: dirty_background_bytes=64MB" bash -c "grep -q 'vm.dirty_background_bytes	67108864' '$PLAN'"
t "vm: dirty_bytes=256MB"           bash -c "grep -q 'vm.dirty_bytes	268435456' '$PLAN'"
t "vm: dirty_ratio ОТСУТСТВУЮТ"     bash -c "! grep -qE 'vm.dirty_background_ratio|vm.dirty_ratio	' '$PLAN'"
t "vm: watermark_boost_factor=0"    bash -c "grep -q 'vm.watermark_boost_factor	0' '$PLAN'"
t "vm: page-cluster=0"              bash -c "grep -q 'vm.page-cluster	0' '$PLAN'"
t "vm: блок идёт в MEM-файл (84)"   bash -c "grep -q \"vm.dirty_bytes	268435456	$NODE_SYSCTL_MEM\" '$PLAN'"
t "fs: file-max=2097152"            bash -c "grep -q 'fs.file-max	2097152' '$PLAN'"
t "fs: inotify.max_user_watches=524288"   bash -c "grep -q 'fs.inotify.max_user_watches	524288' '$PLAN'"
t "fs: inotify.max_user_instances=8192"   bash -c "grep -q 'fs.inotify.max_user_instances	8192' '$PLAN'"
t "fs: inotify.max_queued_events=65536"   bash -c "grep -q 'fs.inotify.max_queued_events	65536' '$PLAN'"

# ============ keepalive (прод-значения старого стека: carrier-NAT < 600с) ============
t "tcp: keepalive_time=300"   bash -c "grep -q 'net.ipv4.tcp_keepalive_time	300' '$PLAN'"
t "tcp: keepalive_intvl=15"   bash -c "grep -q 'net.ipv4.tcp_keepalive_intvl	15' '$PLAN'"
t "tcp: keepalive_probes=5"   bash -c "grep -q 'net.ipv4.tcp_keepalive_probes	5' '$PLAN'"
t "tcp: старых 600/30 в плане НЕТ" bash -c "! grep -qE 'tcp_keepalive_time	600|tcp_keepalive_intvl	30' '$PLAN'"

# ============ conntrack helper off ============
t "conntrack: nf_conntrack_helper=0" bash -c "grep -q 'net.netfilter.nf_conntrack_helper	0' '$PLAN'"
t "conntrack: helper идёт в CONNTRACK-файл" bash -c "grep -q \"net.netfilter.nf_conntrack_helper	0	$NODE_SYSCTL_CONNTRACK\" '$PLAN'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: vmfs (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
