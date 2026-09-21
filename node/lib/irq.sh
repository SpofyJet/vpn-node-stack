#!/bin/bash
# node — lib/irq.sh: §13 RSS/RPS/XPS — диагностика обязательна, изменения opt-in.
# Без произвольного пиннинга. RFS не реализуется. irqbalance не трогаем.
set -euo pipefail

node_irq_diag() {
    local ifname queues cpus
    ifname="$(ip -o -4 route show to default | awk '{print $5; exit}')"
    [ -z "$ifname" ] && return 0
    queues="$(ls -d "/sys/class/net/$ifname/queues/rx-"* 2>/dev/null | wc -l)"
    cpus="$(node_cpu_count)"
    log info "irq" "iface=$ifname hw_queues=$queues cpus=$cpus rps_maps=$(cat /sys/class/net/$ifname/queues/rx-*/rps_cpus 2>/dev/null | tr '\n' ' ')"
    if [ "$(node_conf_get ENABLE_RSS_BALANCE 0)" = "1" ] && systemctl is-active --quiet irqbalance 2>/dev/null; then
        warn "irq" "irqbalance активен и конфликтует с ENABLE_RSS_BALANCE=1 — реши конфликт сам (node не отключает чужие сервисы)"
    fi
}

node_irq_apply() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    local ifname queues cpus
    ifname="$(ip -o -4 route show to default | awk '{print $5; exit}')"
    [ -z "$ifname" ] && return 0
    queues="$(ls -d "/sys/class/net/$ifname/queues/rx-"* 2>/dev/null | wc -l)"
    cpus="$(node_cpu_count)"

    if [ "$(node_conf_get ENABLE_RSS_BALANCE 0)" = "1" ]; then
        if [ "$queues" -gt 1 ] && command -v ethtool >/dev/null 2>&1; then
            local q wt=() i
            for ((i=0; i<queues; i++)); do wt+=("$((cpus / queues))"); done
            if ethtool -X "$ifname" weight "${wt[@]}" >/dev/null 2>&1; then
                ok "irq" "RSS indirection равномерно: ${wt[*]}"
            else
                warn "irq" "ethtool -X не поддерживается драйвером $ifname"
            fi
        fi
    fi

    if [ "$(node_conf_get ENABLE_RPS 0)" = "1" ]; then
        if [ "$queues" -lt "$cpus" ]; then
            local mask q i qn orig
            # rps_cpus = все CPU кроме обслуживающих очереди 0..queues-1
            mask=0
            for ((i=queues; i<cpus; i++)); do mask=$((mask | 1 << i)); done
            for q in /sys/class/net/"$ifname"/queues/rx-*; do
                qn="$(basename "$q")"
                orig="$(cat "$q/rps_cpus" 2>/dev/null || echo 0)"
                if printf '%x' "$mask" > "$q/rps_cpus" 2>/dev/null; then
                    node_rt_record "$ifname" rps "$qn" "$orig"
                fi
            done
            ok "irq" "RPS applied mask=$(printf '%x' "$mask") (persist после reboot не делаем; rollback — из реестра)"
        else
            warn "irq" "RPS: queues($queues) >= cpus($cpus) — по правилам §13 RPS не применяется"
        fi
    fi

    if [ "$(node_conf_get ENABLE_XPS 0)" = "1" ]; then
        local q mask=0 i qn orig
        for ((i=0; i<queues && i<cpus; i++)); do mask=$((mask | 1 << i)); done
        for q in /sys/class/net/"$ifname"/queues/tx-*; do
            qn="$(basename "$q")"
            orig="$(cat "$q/xps_cpus" 2>/dev/null || echo 0)"
            if printf '%x' "$mask" > "$q/xps_cpus" 2>/dev/null; then
                node_rt_record "$ifname" xps "$qn" "$orig"
            fi
        done
        ok "irq" "XPS applied mask=$(printf '%x' "$mask") (rollback — из реестра)"
    fi
}

# node_irq_affinity_apply — «сильный» режим (opt-in, ENABLE_IRQ_AFFINITY=1):
# равномерный spread IRQ очередей NIC по всем CPU (round-robin). Без isolcpus.
# Конфликт с irqbalance — предупреждаем, чужой сервис не трогаем.
node_irq_affinity_apply() {
    [ "$(node_conf_get ENABLE_IRQ_AFFINITY 0)" = "1" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "irq: NIC IRQ spread round-robin по CPU"; return 0; }
    local ifname cpus
    ifname="$(ip -o -4 route show to default | awk '{print $5; exit}')"
    [ -z "$ifname" ] && return 0
    cpus="$(node_cpu_count)"
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        warn "irq" "irqbalance активен — конфликтует с ручным affinity; отключи его сам, либо выключи ENABLE_IRQ_AFFINITY"
    fi
    local irqs=() irq i=0 cpu orig
    mapfile -t irqs < <(awk -v dev="$ifname" '$NF ~ dev {gsub(":","",$1); print $1}' /proc/interrupts 2>/dev/null | sort -n | awk 'NF')
    [ "${#irqs[@]}" -gt 0 ] || { log warn "irq" "IRQ для $ifname в /proc/interrupts не найдены — пропуск"; return 0; }
    for irq in "${irqs[@]}"; do
        [ -w "/proc/irq/$irq/smp_affinity_list" ] || continue
        cpu=$((i % cpus))
        orig="$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || echo 0)"
        if echo "$cpu" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
            node_rt_record "$ifname" irq "$irq" "$orig"
        fi
        i=$((i+1))
    done
    ok "irq" "IRQ spread: ${#irqs[@]} IRQ очередей по $cpus CPU round-robin (persist reboot — нет; rollback восстановит)"
}
