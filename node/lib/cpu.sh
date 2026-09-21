#!/bin/bash
# node — lib/cpu.sh: §14 — ничего не применяется. Только проверка запрещённых
# параметров (idle=poll, mitigations=off, isolcpus, nohz_full, rcu_nocbs, C-states).
set -euo pipefail

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
