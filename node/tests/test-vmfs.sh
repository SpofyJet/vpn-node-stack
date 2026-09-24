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
# базовое (до node) min_free_kbytes — фикстура реестра, чтобы план не зависел от хоста
printf 'vm.min_free_kbytes\t11264\n' > "$NODE_STATE_DIR/sysctl-orig.tsv"

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
# 2026-09-24 (v1.1.7): ревизия тюнинга — vfs_cache_pressure/overcommit на T1 убраны
# 2026-09-24 (v1.1.7): min_free_kbytes только повышается — ядро (THP) уже держит 45056 > tier
printf 'vm.min_free_kbytes\t45056\n' > "$NODE_STATE_DIR/sysctl-orig.tsv"; replan
t "T1, база ядра 45056 > tier: min_free_kbytes НЕ пишется (не понижаем)" bash -c "! grep -q 'vm.min_free_kbytes' '$PLAN'"
cp "$CONFIG_CACHE" "$CONFIG_CACHE.orig"; printf 'VM_MIN_FREE_KBYTES=24576\n' > /tmp/node-vmfs-test/node.conf
cat /tmp/node-vmfs-test/node.conf "$CONFIG_CACHE.orig" > "$CONFIG_CACHE"; NODE_CONFIG=/tmp/node-vmfs-test/node.conf replan
t "явный VM_MIN_FREE_KBYTES оператора соблюдается (даже ниже базы)" bash -c "grep -q 'vm.min_free_kbytes	24576' '$PLAN'"
mv "$CONFIG_CACHE.orig" "$CONFIG_CACHE"; printf 'vm.min_free_kbytes\t11264\n' > "$NODE_STATE_DIR/sysctl-orig.tsv"; replan
t "T1: vfs_cache_pressure не пишется" bash -c "! grep -q 'vm.vfs_cache_pressure' '$PLAN'"
t "T1: overcommit_memory не пишется"  bash -c "! grep -q 'vm.overcommit_memory' '$PLAN'"

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
# 2026-09-24 (v1.1.7): ревизия тюнинга — watermark_boost_factor/page-cluster/max_map_count убраны
t "vm: watermark_boost_factor/page-cluster/max_map_count не пишутся" bash -c "! grep -qE 'vm.watermark_boost_factor|vm.page-cluster|vm.max_map_count' '$PLAN'"
t "vm: блок идёт в MEM-файл (84)"   bash -c "grep -q \"vm.dirty_bytes	268435456	$NODE_SYSCTL_MEM\" '$PLAN'"
# 2026-09-24 (v1.1.6): было «fs: file-max=2097152» безусловно — закрепляло ПОНИЖЕНИЕ
# (дефолт ядер 5.x+ ~2^63). Теперь только повышение: проверяем обе ветки на фикстуре.
# 2026-09-24 (v1.1.7): убранные из дефолта ключи по-прежнему задаются ЯВНО в node.conf
knob_plan() {
    ( T=/tmp/node-vmfs-test/knob; mkdir -p "$T"
      printf 'VM_OVERCOMMIT=2\nNET_RMEM_DEFAULT=1048576\n' > "$T/node.conf"
      export NODE_CONFIG="$T/node.conf" CONFIG_CACHE="$T/cache"
      { cat "$T/node.conf"; grep -E '^[A-Za-z_]+=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"
      NODE_PLAN_FILE=""; node_sysctl_plan_init
      NODE_PROC_MEMINFO="$MEMINFO_T4" node_datapath_plan >/dev/null 2>&1
      cat "$NODE_PLAN_FILE"; rm -f "$NODE_PLAN_FILE" )
}
KP="$(knob_plan)"
t "явные VM_OVERCOMMIT/NET_RMEM_DEFAULT в node.conf — применяются" \
  bash -c "grep -q 'vm.overcommit_memory	2' <<<'$KP' && grep -q 'net.core.rmem_default	1048576' <<<'$KP'"

fm_plan() { # fm_plan <базовое fs.file-max> -> строка fs.file-max из плана (или пусто)
    ( export NODE_PROC_ROOT=/tmp/node-vmfs-test/fmroot; mkdir -p "$NODE_PROC_ROOT/sys/fs"
      echo "$1" > "$NODE_PROC_ROOT/sys/fs/file-max"
      NODE_PLAN_FILE=""; node_sysctl_plan_init   # свой файл плана — основной $PLAN не трогаем
      NODE_PROC_MEMINFO="$MEMINFO_T4" node_datapath_plan >/dev/null 2>&1
      grep 'fs.file-max' "$NODE_PLAN_FILE" || true; rm -f "$NODE_PLAN_FILE" )
}
t "fs: file-max не понижается (базовое 9223372036854775807 -> ключа нет в плане)" \
  bash -c "[ -z '$(fm_plan 9223372036854775807)' ]"
t "fs: file-max повышается на старых ядрах (базовое 400000 -> 2097152)" \
  bash -c "[[ '$(fm_plan 400000)' == fs.file-max*2097152* ]]"
t "fs: inotify.max_user_watches=524288"   bash -c "grep -q 'fs.inotify.max_user_watches	524288' '$PLAN'"
t "fs: inotify.max_user_instances=8192"   bash -c "grep -q 'fs.inotify.max_user_instances	8192' '$PLAN'"
t "fs: inotify.max_queued_events=65536"   bash -c "grep -q 'fs.inotify.max_queued_events	65536' '$PLAN'"

# ============ keepalive (прод-значения старого стека: carrier-NAT < 600с) ============
t "tcp: keepalive_time=300"   bash -c "grep -q 'net.ipv4.tcp_keepalive_time	300' '$PLAN'"
t "tcp: keepalive_intvl=15"   bash -c "grep -q 'net.ipv4.tcp_keepalive_intvl	15' '$PLAN'"
t "tcp: keepalive_probes=5"   bash -c "grep -q 'net.ipv4.tcp_keepalive_probes	5' '$PLAN'"
t "tcp: старых 600/30 в плане НЕТ" bash -c "! grep -qE 'tcp_keepalive_time	600|tcp_keepalive_intvl	30' '$PLAN'"

# ============ conntrack helper off (best-effort runtime, НЕ в sysctl-файле:
# sysctl зависит от CONFIG_NF_CONNTRACK_HELPER ядра; в файле его нет даже после
# modprobe на части конфигов -> sysctl -p убивал apply. Баг на prod-ноде 2026-09-22) ============
t "conntrack: helper НЕ в плане (runtime best-effort)" bash -c "! grep -q 'nf_conntrack_helper' '$PLAN'"
t "conntrack: helper отключается runtime" grep -q 'nf_conntrack_helper' "$NODE_DIR/lib/conntrack.sh"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: vmfs (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
