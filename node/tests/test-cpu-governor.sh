#!/bin/bash
# node — тест: cpufreq governor -> performance (lib/cpu.sh, v1.1.7) на sysfs-фикстуре.
# Меняется только при наличии cpufreq и доступном performance; исходное — в реестр rt;
# rollback возвращает; нет cpufreq (VM) — no-op; ENABLE_CPU_PERF_GOVERNOR=0 — не трогаем.
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log" NODE_RT_TWEAKS="$OUT/state/runtime-tweaks.tsv"
mkdir -p "$OUT/state"; : > "$NODE_LOG"
LOG_LEVEL=error
source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/lib/cpu.sh"

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
conf() { printf '%b' "$1" > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1; }
SR="$OUT/sys"; C=devices/system/cpu
fx() { rm -rf "$SR"; local i
    for i in 0 1; do mkdir -p "$SR/$C/cpu$i/cpufreq"; echo "$1" > "$SR/$C/cpu$i/cpufreq/scaling_governor"
        echo "$2" > "$SR/$C/cpu$i/cpufreq/scaling_available_governors"; done
    : > "$NODE_RT_TWEAKS"; }
gov() { cat "$SR/$C/cpu$1/cpufreq/scaling_governor"; }
export NODE_SYS_ROOT="$SR" DRY_RUN=0

conf ''; fx schedutil "conservative ondemand userspace powersave performance schedutil"; node_cpu_governor_apply
t "cpufreq есть: schedutil -> performance на всех CPU" '[ "$(gov 0)" = performance ] && [ "$(gov 1)" = performance ]'
t "исходное в реестре rt (sysfs, schedutil)" "grep -qP '^-\tsysfs\t$C/cpu1/cpufreq/scaling_governor\tschedutil$' '$NODE_RT_TWEAKS'"
: > "$OUT/before"; cp "$NODE_RT_TWEAKS" "$OUT/before"; node_cpu_governor_apply
t "повторно: идемпотентно (реестр не изменился)" "cmp -s '$OUT/before' '$NODE_RT_TWEAKS'"

fx powersave "performance powersave"; conf 'ENABLE_CPU_PERF_GOVERNOR=0\n'; node_cpu_governor_apply
t "ENABLE_CPU_PERF_GOVERNOR=0: не трогаем" '[ "$(gov 0)" = powersave ] && [ ! -s "$NODE_RT_TWEAKS" ]'
conf ''; fx userspace "userspace"; node_cpu_governor_apply
t "performance недоступен: не трогаем" '[ "$(gov 0)" = userspace ] && [ ! -s "$NODE_RT_TWEAKS" ]'
rm -rf "$SR"; mkdir -p "$SR/$C/cpu0"; : > "$NODE_RT_TWEAKS"; node_cpu_governor_apply
t "нет cpufreq (VM): no-op" '[ ! -s "$NODE_RT_TWEAKS" ]'
fx powersave "performance powersave"; DRY_RUN=1 node_cpu_governor_apply
t "dry-run: ничего не пишет" '[ "$(gov 0)" = powersave ] && [ ! -s "$NODE_RT_TWEAKS" ]'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: cpu-governor (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
