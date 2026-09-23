#!/bin/bash
# node — lib/irq.sh: §13 RSS/RPS/XPS — диагностика обязательна, изменения opt-in.
# Без произвольного пиннинга. RFS не реализуется. irqbalance не трогаем.
set -euo pipefail

# node_cpumask_hex <mask> — cpumask для rps_cpus/xps_cpus в формате ядра.
# 2026-09-23: bitmap_parse принимает группы ПО 8 hex-цифр через запятую; группа
# длиннее 32 бит = EOVERFLOW (проверено на ядре: '000000001' отвергнут). Маска
# одним словом на нодах >32 CPU молча не записывалась, а лог писал «applied».
# До 32 CPU вывод побайтно прежний.
node_cpumask_hex() {
    local m="$1" hi lo
    hi=$(( (m >> 32) & 0xffffffff )); lo=$(( m & 0xffffffff ))
    if [ "$hi" -eq 0 ]; then printf '%x' "$lo"; else printf '%x,%08x' "$hi" "$lo"; fi
}

node_irq_diag() {
    local ifname queues cpus
    ifname="$(node_default_iface)"
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
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    # 2026-09-23 (v1.1.3): без rx-* каталогов ls -> rc 2, под pipefail присваивание
    # падало и set -e обрывал ВЕСЬ irq_apply (RSS/RPS/XPS) — считаем 0 очередей
    queues="$( { ls -d "/sys/class/net/$ifname/queues/rx-"* 2>/dev/null || true; } | wc -l)"
    cpus="$(node_cpu_count)"

    if [ "$(node_conf_get ENABLE_RSS_BALANCE 0)" = "1" ]; then
        if [ "$queues" -gt 1 ] && command -v ethtool >/dev/null 2>&1; then
            local q wt=() i
            # 2026-09-23 (v1.1.2): при queues > cpus cpus/queues = 0 -> все веса 0, ethtool
            # отвергал таблицу. Равные веса = равномерно при любом w>0 -> минимум 1.
            local w=$((cpus / queues)); [ "$w" -ge 1 ] || w=1
            for ((i=0; i<queues; i++)); do wt+=("$w"); done
            if ethtool -X "$ifname" weight "${wt[@]}" >/dev/null 2>&1; then
                node_rt_record "$ifname" rss "indir" "default"   # 2026-09-23: rollback -> ethtool -X default
                ok "irq" "RSS indirection равномерно: ${wt[*]}"
            else
                warn "irq" "ethtool -X не поддерживается драйвером $ifname"
            fi
        fi
    fi

    if [ "$(node_conf_get ENABLE_RPS 0)" = "1" ]; then
        if [ "$queues" -lt "$cpus" ]; then
            local mask q i qn orig eff
            # rps_cpus = все CPU кроме обслуживающих очереди 0..queues-1.
            # CAP=64: одно hex-слово rps_cpus покрывает только CPU 0..63
            # (на >64 ядрах нужен multi-word формат — node его не генерирует,
            # это территория irqbalance/NUMA-пиннинга; лучше честный cap с
            # предупреждением, чем молчаливо неверный битмап).
            eff=$cpus; [ "$eff" -gt 64 ] && eff=64
            [ "$cpus" -gt 64 ] && warn "irq" "CPUs=$cpus > 64 — rps_cpus/xps_cpus ограничены первыми 64 ядрами (multi-word cpumask node не генерирует; используй irqbalance)"
            mask=0
            for ((i=queues; i<eff; i++)); do mask=$((mask | 1 << i)); done
            for q in /sys/class/net/"$ifname"/queues/rx-*; do
                qn="$(basename "$q")"
                orig="$(cat "$q/rps_cpus" 2>/dev/null || echo 0)"
                if node_cpumask_hex "$mask" > "$q/rps_cpus" 2>/dev/null; then
                    node_rt_record "$ifname" rps "$qn" "$orig"
                fi
            done
            ok "irq" "RPS applied mask=$(node_cpumask_hex "$mask") (persist после reboot не делаем; rollback — из реестра)"
        else
            warn "irq" "RPS: queues($queues) >= cpus($cpus) — по правилам §13 RPS не применяется"
        fi
    fi

    if [ "$(node_conf_get ENABLE_XPS 0)" = "1" ]; then
        # 2026-09-23 (v1.1.3): раньше КАЖДОЙ tx-очереди писалась одна и та же маска
        # CPU 0..rxq-1: по Documentation/networking/scaling.rst xps_cpus очереди — это
        # CPU, которым разрешено слать в неё; при одинаковых масках каждый CPU
        # отображён на ВСЕ очереди (локальности нет), а CPU вне маски — ни на одну
        # (fallback на хеш). Теперь как рекомендует scaling.rst: каждый CPU — ровно
        # в одну очередь: tx-i <- {CPU c : c mod txq == i}; при txq > cpus — tx-i <- CPU
        # (i mod cpus). Размер — по числу TX-очередей (было: по RX).
        local q i qn orig eff txq c mask
        eff=$cpus; [ "$eff" -gt 64 ] && eff=64
        txq="$( { ls -d "/sys/class/net/$ifname/queues/tx-"* 2>/dev/null || true; } | wc -l)"
        [ "$txq" -ge 1 ] || txq=1
        for q in /sys/class/net/"$ifname"/queues/tx-*; do
            [ -e "$q" ] || continue
            qn="$(basename "$q")"; i="${qn#tx-}"
            [[ "$i" =~ ^[0-9]+$ ]] || continue
            mask=0
            if [ "$eff" -ge "$txq" ]; then
                for ((c=i; c<eff; c+=txq)); do mask=$((mask | 1 << c)); done
            else
                mask=$((1 << (i % eff)))
            fi
            orig="$(cat "$q/xps_cpus" 2>/dev/null || echo 0)"
            if node_cpumask_hex "$mask" > "$q/xps_cpus" 2>/dev/null; then
                node_rt_record "$ifname" xps "$qn" "$orig"
            fi
        done
        ok "irq" "XPS: tx-i <- CPU {c : c mod $txq == i} (txq=$txq cpus=$eff; rollback — из реестра)"
    fi
}

# node_irq_affinity_apply — «сильный» режим (opt-in, ENABLE_IRQ_AFFINITY=1):
# равномерный spread IRQ очередей NIC по всем CPU (round-robin). Без isolcpus.
# Конфликт с irqbalance — предупреждаем, чужой сервис не трогаем.
# node_nic_irq_candidates — IRQ-номера сетевого устройства (stdout, по одному).
# Три метода по убыванию надёжности:
#   1) /sys/class/net/<if>/device/msi_irqs — MSI/MSI-X векторы устройства
#      (virtio, mlx4/5, ixgbe на современных ядрах) — работает там, где
#      /proc/interrupts вообще не содержит имени интерфейса;
#   2) PCI-адрес устройства (basename readlink /sys/.../device) в /proc/interrupts
#      — метки вида «mlx5_comp0@pci:0000:00:05.0», «eth0-Tx-Rx» на legacy;
#   3) legacy: последнее поле /proc/interrupts содержит имя интерфейса.
# Корни переопределяемы через NODE_SYS_ROOT/NODE_PROC_ROOT (тесты).
node_nic_irq_candidates() {
    local ifname="$1"
    local sysroot="${NODE_SYS_ROOT:-/sys}" procroot="${NODE_PROC_ROOT:-/proc}"
    local devdir="$sysroot/class/net/$ifname/device" pci=""
    # 1) MSI-векторы устройства
    if [ -d "$devdir/msi_irqs" ]; then
        local msi_list
        msi_list="$(ls -1 "$devdir/msi_irqs" 2>/dev/null | grep -E '^[0-9]+$' | sort -n || true)"
        if [ -n "$msi_list" ]; then
            printf '%s\n' "$msi_list"
            return 0
        fi
    fi
    # 2) по PCI-адресу устройства
    pci="$(basename "$(readlink -f "$devdir" 2>/dev/null)" 2>/dev/null || true)"
    if [ -n "$pci" ] && [ -r "$procroot/interrupts" ] && grep -q -- "$pci" "$procroot/interrupts" 2>/dev/null; then
        awk -v pci="$pci" 'index($0, pci) > 0 { gsub(":", "", $1); print $1 }' "$procroot/interrupts" | sort -n
        return 0
    fi
    # 3) legacy: метка очереди содержит имя интерфейса
    [ -r "$procroot/interrupts" ] || return 0
    awk -v dev="$ifname" '$NF ~ dev { gsub(":", "", $1); print $1 }' "$procroot/interrupts" | sort -n
}

node_irq_affinity_apply() {
    [ "$(node_conf_get ENABLE_IRQ_AFFINITY 0)" = "1" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "irq: NIC IRQ spread round-robin по CPU"; return 0; }
    local ifname cpus
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    cpus="$(node_cpu_count)"
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        warn "irq" "irqbalance активен — конфликтует с ручным affinity; отключи его сам, либо выключи ENABLE_IRQ_AFFINITY"
    fi
    local irqs=() irq i=0 cpu orig
    mapfile -t irqs < <(node_nic_irq_candidates "$ifname" | awk 'NF' | sort -n | uniq)
    [ "${#irqs[@]}" -gt 0 ] || { log warn "irq" "IRQ для $ifname не найдены (ни msi_irqs, ни PCI, ни метки) — пропуск"; return 0; }
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
