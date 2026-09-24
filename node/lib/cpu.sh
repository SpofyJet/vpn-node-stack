#!/bin/bash
# node — lib/cpu.sh: §14 — проверка запрещённых параметров (idle=poll, mitigations=off,
# isolcpus, nohz_full, rcu_nocbs, C-states) и cpufreq-governor (v1.1.7). C-states НЕ трогаем.
set -euo pipefail

# node_cpu_governor_apply — 2026-09-24 (v1.1.7): scaling_governor -> performance, если cpufreq
# есть и governor доступен (bare-metal/часть dedicated). Сетевой softirq — короткие всплески:
# schedutil/ondemand/powersave(HWP) поднимают частоту с задержкой в единицы-десятки мс, первые
# пакеты пачки обрабатываются на низкой частоте. На intel_pstate/amd-pstate-epp performance
# заодно ставит EPP=performance. C-states не трогаем (idle-энергия и турбо-запас соседних ядер).
# Нет cpufreq (VM, как большинство VPS) — no-op; XanMod по умолчанию уже performance — no-op.
# Исходное значение — в реестре rt (rollback), boot — rt-reapply.
node_cpu_governor_apply() {
    [ "$(node_conf_get ENABLE_CPU_PERF_GOVERNOR 1)" = "1" ] || return 0
    local sr="${NODE_SYS_ROOT:-/sys}" g cur rel n=0 skip=0
    for g in "$sr"/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -e "$g" ] || continue
        cur="$(cat "$g" 2>/dev/null || true)"
        [ "$cur" = performance ] && continue
        grep -qw performance "${g%/*}/scaling_available_governors" 2>/dev/null || { skip=$((skip + 1)); continue; }
        [ "${DRY_RUN:-0}" = "1" ] && { n=$((n + 1)); continue; }
        rel="${g#"$sr"/}"
        if printf 'performance' > "$g" 2>/dev/null; then
            node_rt_record "-" sysfs "$rel" "$cur"
            n=$((n + 1))
        fi
    done
    if [ "$n" -gt 0 ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then log info "dry-run" "cpu: would set cpufreq governor performance на $n CPU"
        else ok "cpu" "cpufreq governor -> performance на $n CPU (rollback — из реестра)"; fi
    fi
    [ "$skip" -gt 0 ] && log info "cpu" "cpufreq: governor performance недоступен на $skip CPU — пропуск"
    return 0
}

node_cpu_check() {
    local bad=0 p
    for p in idle=poll mitigations=off isolcpus nohz_full rcu_nocbs intel_idle.max_cstate=0 processor.max_cstate; do
        if grep -qw -- "$p" /proc/cmdline 2>/dev/null; then
            warn "cpu" "ЗАПРЕЩЁННЫЙ параметр в /proc/cmdline: $p (ТЗ §14)"
            bad=1
        fi
        if grep -qE "^[[:space:]]*GRUB_CMDLINE_LINUX.*${p//./\\.}" /etc/default/grub 2>/dev/null; then
            warn "cpu" "ЗАПРЕЩЁННЫЙ параметр в /etc/default/grub: $p (ТЗ §14)"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ] && ok "cpu" "запрещённых CPU-параметров не обнаружено"
    return 0
}
