#!/bin/bash
# node — lib/nic.sh: §12 диагностика NIC обязательна; изменения rings — только
# явным значением в конфиге. Offloads (GRO/GSO/TSO/LRO) по умолчанию НЕ трогаем;
# меняет их только opt-in «сильный» режим node_nic_opt_apply (ENABLE_NIC_OFFLOAD_OPT=1).
set -euo pipefail

# _node_ring <вывод ethtool -g> <секция> <RX|TX> — значение из секции «Pre-set
# maximums»/«Current hardware settings». 2026-09-23 (v1.1.3): вывод ethtool -g
# берём ОДИН раз на функцию (было до 4 одинаковых вызовов подряд) и разбираем
# здесь; awk читает вход до конца (без exit).
_node_ring() { printf '%s\n' "$1" | awk -v s="$2" -v d="$3:" 'index($0, s) {f = 1} f && !done && $1 == d {print $2; done = 1}'; }

node_nic_diag() {
    local ifname
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    local driver speed mtu
    driver="$(basename "$(readlink -f "/sys/class/net/$ifname/device/driver" 2>/dev/null || echo none)")"
    speed="$(cat "/sys/class/net/$ifname/speed" 2>/dev/null || echo '?')"
    mtu="$(cat "/sys/class/net/$ifname/mtu" 2>/dev/null || echo '?')"
    log info "nic" "iface=$ifname driver=$driver speed=${speed}Mb mtu=$mtu"
    if command -v ethtool >/dev/null 2>&1; then
        local rx_max tx_max rx_cur tx_cur g
        g="$(ethtool -g "$ifname" 2>/dev/null || true)"
        rx_max="$(_node_ring "$g" "Pre-set maximums" RX)";          tx_max="$(_node_ring "$g" "Pre-set maximums" TX)"
        rx_cur="$(_node_ring "$g" "Current hardware settings" RX)"; tx_cur="$(_node_ring "$g" "Current hardware settings" TX)"
        [ -n "$rx_max" ] && log info "nic" "rings rx=$rx_cur/$rx_max tx=$tx_cur/$tx_max (изменения — только через NIC_RING_RX/TX в конфиге)"
        ethtool -k "$ifname" 2>/dev/null | grep -E 'generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|large-receive-offload' | sed 's/^/  /' | while read -r l; do log debug "nic" "$l"; done || true
        ethtool -S "$ifname" 2>/dev/null | awk '/(drop|err|miss)/ && $2+0>0 {print}' | head -5 | while read -r l; do log warn "nic" "counter: $l"; done || true
        # ^ 2026-09-23: || true — диагностика не должна валить шаг: без ethtool-статистики
        #   (wg/tun/venet: «no stats available», rc!=0) pipefail помечал apply как упавший
    else
        warn "nic" "ethtool не установлен — диагностика rings/offloads пропущена"
    fi
}

node_nic_apply_rings() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    local ifname rx tx
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    rx="$(node_conf_get NIC_RING_RX "")"; tx="$(node_conf_get NIC_RING_TX "")"
    [ -z "$rx" ] && [ -z "$tx" ] && return 0
    command -v ethtool >/dev/null 2>&1 || { warn "nic" "ethtool нет — rings не применены"; return 0; }
    # 2026-09-23 (v1.1.3): (1) ОДНА команда `ethtool -G dev rx N tx M` — синтаксис
    # ethtool(8) допускает один -G с одним devname; прежнее «-G dev rx N -G dev tx M»
    # при заданных RX и TX сразу отвергалось целиком (кольца не применялись вовсе,
    # а лог писал «не принят драйвером»). (2) early-out: кольца уже в целевом
    # размере — ethtool -G не вызываем: на многих драйверах (ixgbe/i40e/igb/mlx5,
    # virtio_net resize) смена колец пересоздаёт очереди — блип линка, потери,
    # сброс RSS/XPS — и так на КАЖДОМ apply и rt-reapply (boot/hotplug).
    local args=("-G" "$ifname")
    [ -n "$rx" ] && args+=("rx" "$rx")
    [ -n "$tx" ] && args+=("tx" "$tx")
    # исходные значения — ДО изменения (rollback иначе бы восстанавливал новые)
    local rx_orig tx_orig g
    g="$(ethtool -g "$ifname" 2>/dev/null || true)"
    rx_orig="$(_node_ring "$g" "Current hardware settings" RX)"
    tx_orig="$(_node_ring "$g" "Current hardware settings" TX)"
    if { [ -z "$rx" ] || [ "$rx" = "$rx_orig" ]; } && { [ -z "$tx" ] || [ "$tx" = "$tx_orig" ]; }; then
        log info "nic" "rings уже rx=${rx_orig:-?} tx=${tx_orig:-?} = цель — ethtool -G не вызывается (без сброса очередей)"
        return 0
    fi
    if ethtool "${args[@]}" >/dev/null 2>&1; then
        ok "nic" "rings применены: ${args[*]}"
        [ -n "$rx" ] && [ -n "$rx_orig" ] && node_rt_record "$ifname" ring_rx "$rx" "$rx_orig"
        [ -n "$tx" ] && [ -n "$tx_orig" ] && node_rt_record "$ifname" ring_tx "$tx" "$tx_orig"
        warn "nic" "persist rings после reboot не делаем (минимальное вмешательство) — зафиксируй сам при необходимости"
    else
        warn "nic" "ethtool -G не принят драйвером (virtio/fixed?) — оставлено как есть"
    fi
}

# node_nic_opt_apply — «сильный» режим NIC (opt-in, ENABLE_NIC_OFFLOAD_OPT=1):
# rings до максимума, tso/gso off, gro ВКЛ (на форвардинге UDP-флуда выключение
# GRO бьёт по CPU), txqueuelen 10000. Всё runtime — откат через runtime-tweaks.
node_nic_opt_apply() {
    [ "$(node_conf_get ENABLE_NIC_OFFLOAD_OPT 0)" = "1" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "nic: rings->max, tso/gso off, txqueuelen 10000"; return 0; }
    local ifname
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    command -v ethtool >/dev/null 2>&1 || { warn "nic" "ethtool нет — NIC-opt пропущен"; return 0; }

    local rx_max tx_max rx_cur tx_cur g
    g="$(ethtool -g "$ifname" 2>/dev/null || true)"   # 2026-09-23 (v1.1.3): один вызов вместо 4
    rx_max="$(_node_ring "$g" "Pre-set maximums" RX)";          tx_max="$(_node_ring "$g" "Pre-set maximums" TX)"
    rx_cur="$(_node_ring "$g" "Current hardware settings" RX)"; tx_cur="$(_node_ring "$g" "Current hardware settings" TX)"
    if [ -n "$rx_max" ] && { [ "$rx_cur" != "$rx_max" ] || [ "$tx_cur" != "$tx_max" ]; }; then
        if ethtool -G "$ifname" rx "$rx_max" tx "$tx_max" >/dev/null 2>&1; then
            ok "nic" "rings -> max (rx $rx_cur->$rx_max, tx $tx_cur->$tx_max)"
            node_rt_record "$ifname" ring_rx "$rx_max" "${rx_cur:-0}"
            node_rt_record "$ifname" ring_tx "$tx_max" "${tx_cur:-0}"
        else
            warn "nic" "rings->max отклонён драйвером $ifname"
        fi
    fi

    local feat orig
    for feat in tcp-segmentation-offload generic-segmentation-offload; do
        orig="$(ethtool -k "$ifname" 2>/dev/null | awk -v f="$feat:" '$1==f{print $2; exit}')"
        if [ "$orig" = "on" ]; then
            if ethtool -K "$ifname" "$feat" off >/dev/null 2>&1; then
                ok "nic" "$feat off (orig on — restore при rollback)"
                node_rt_record "$ifname" offload "$feat" "$orig"
            fi
        fi
    done
    # gro оставляем включённым; lro выключаем если включён
    orig="$(ethtool -k "$ifname" 2>/dev/null | awk '$1=="large-receive-offload:"{print $2; exit}')"
    if [ "$orig" = "on" ] && ethtool -K "$ifname" lro off >/dev/null 2>&1; then
        node_rt_record "$ifname" offload "large-receive-offload" "$orig"
        ok "nic" "lro off"
    fi

    # coalescing: адаптивное — меньше прерываний на пакет при высоких pps,
    # стабильнее латентность под нагрузкой (drivers: e1000e/igb/ixgbe/mlx... )
    local dir cav
    for dir in rx tx; do
        cav="$(ethtool -c "$ifname" 2>/dev/null | awk -v d="adaptive-$dir:" '$1==d{print $2; exit}')"
        if [ "$cav" = "off" ]; then
            if ethtool -C "$ifname" "adaptive-$dir" on >/dev/null 2>&1; then
                ok "nic" "adaptive coalescing $dir on (orig off)"
                node_rt_record "$ifname" coalesce "adaptive-$dir" off
            fi
        fi
    done

    local tql tql_orig
    tql_orig="$(cat "/sys/class/net/$ifname/tx_queue_len" 2>/dev/null || echo 1000)"
    tql="$(node_conf_get NIC_TXQUEUELEN 10000)"
    if [ "$tql_orig" != "$tql" ] && ip link set dev "$ifname" txqueuelen "$tql" >/dev/null 2>&1; then
        ok "nic" "txqueuelen $tql_orig -> $tql"
        node_rt_record "$ifname" txqueuelen "$tql" "$tql_orig"
    fi
}

# node_nic_lro_off — дефолтный дефенсивный LRO off (NIC_LRO_OFF=1): LRO конфликтует
# с ip_forward=1 (ixgbe/vmxnet3 firmware игнорируют kernel auto-disable). Orig ->
# runtime-реестр, rollback вернёт. Сильный режим выше делает то же — дедуп по orig.
node_nic_lro_off() {
    [ "$(node_conf_get NIC_LRO_OFF 1)" = "1" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "nic: lro off (defensive)"; return 0; }
    local ifname orig
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    command -v ethtool >/dev/null 2>&1 || { warn "nic" "ethtool нет — LRO off пропущен"; return 0; }
    orig="$(ethtool -k "$ifname" 2>/dev/null | awk '$1=="large-receive-offload:"{print $2; exit}')"
    if [ "$orig" = "on" ] && ethtool -K "$ifname" lro off >/dev/null 2>&1; then
        node_rt_record "$ifname" offload "large-receive-offload" "$orig"
        ok "nic" "lro off (defensive; orig on — restore при rollback)"
    fi
}

# node_nic_eee_off — opt-in (ENABLE_EEE_OFF=1, v1.1.1): Energy-Efficient Ethernet
# (802.3az) усыпляет PHY в паузах; выход из LPI = Tw ~4.5 мкс (10GBASE-T) …
# 16.5 мкс (1000BASE-T) на ПЕРВЫЙ пакет пачки — хвостовая латентность при
# рваной нагрузке. На пропускную способность под нагрузкой не влияет (линк не
# простаивает). Только bare-metal (virtio/ena EEE не поддерживают — no-op).
# Orig -> реестр, rollback вернёт eee on.
node_nic_eee_off() {
    [ "$(node_conf_get ENABLE_EEE_OFF 0)" = "1" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "nic: EEE off"; return 0; }
    local ifname st
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    command -v ethtool >/dev/null 2>&1 || { warn "nic" "ethtool нет — EEE пропущен"; return 0; }
    st="$(ethtool --show-eee "$ifname" 2>/dev/null | awk -F': *' '/^[[:space:]]*EEE status/{print $2; exit}' || true)"
    case "$st" in
        enabled*)
            if ethtool --set-eee "$ifname" eee off >/dev/null 2>&1; then
                node_rt_record "$ifname" eee "eee" "on"
                ok "nic" "EEE off (orig: $st — restore при rollback)"
            else
                warn "nic" "ethtool --set-eee отклонён драйвером $ifname"
            fi ;;
        *) log info "nic" "EEE: '${st:-не поддерживается}' — изменений нет" ;;
    esac
}

# node_nic_low_latency — classic NAPI: GRO flush timeout + napi defer -> 0/0.
# Opt-in (ENABLE_LOW_LATENCY_NIC=1, как в старой ветке): имеет смысл на малых
# нодах (50–200 юзеров), где defer-логика добавляет TX-jitter. Runtime-only,
# orig -> реестр, rollback вернёт.
node_nic_low_latency() {
    [ "$(node_conf_get ENABLE_LOW_LATENCY_NIC 0)" = "1" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "nic: GRO flush + napi defer -> 0/0 (classic NAPI)"; return 0; }
    local ifname p f orig
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    for p in gro_flush_timeout napi_defer_hard_irqs; do
        f="/sys/class/net/$ifname/$p"
        [ -w "$f" ] || continue
        orig="$(cat "$f" 2>/dev/null || echo 0)"
        if [ "$orig" != "0" ] && printf '0' > "$f" 2>/dev/null; then
            node_rt_record "$ifname" sysfs "class/net/$ifname/$p" "$orig"
            ok "nic" "$p: $orig -> 0 (classic NAPI)"
        fi
    done
}
