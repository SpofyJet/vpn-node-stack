#!/bin/bash
# node — lib/conntrack.sh: §15 — ЕДИНСТВЕННЫЙ владелец conntrack.
set -euo pipefail

node_conntrack_plan() {
    local tier max hashsize loose
    tier="$(node_ram_tier)"
    case "$tier" in
        1) max=131072 ;;
        2) max=262144 ;;
        3) max=524288 ;;
        4) max=1048576 ;;
        *) max=262144 ;;  # неизвестный tier — безопасный средний
    esac
    max="$(node_conf_get CONNTRACK_MAX "$max")"
    [[ "$max" =~ ^[0-9]+$ ]] || { warn "conntrack" "CONNTRACK_MAX='$max' не число — fallback 262144"; max=262144; }
    hashsize=$((max / 4))
    loose="$(node_conf_get CONNTRACK_TCP_LOOSE 1)"

    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_max "$max"
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_timeout_established 14400
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_timeout_close_wait 30
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_timeout_fin_wait 30
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_timeout_last_ack 30
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_udp_timeout 180
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_udp_timeout_stream 600
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_generic_timeout 300
    node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_loose "$loose"
    # стабильность под нагрузкой: conntrack НЕ дропает легитимные ретрансмиты,
    # попавшие «мимо окна» (типично для VPN-потоков с MTU-проблемами)
    if [ "$(node_conf_get ENABLE_CONNTRACK_LIBERAL 1)" = "1" ]; then
        node_sysctl_add "$NODE_SYSCTL_CONNTRACK" net.netfilter.nf_conntrack_tcp_be_liberal 1
    fi

    export NODE_CONNTRACK_MAX="$max" NODE_CONNTRACK_HASHSIZE="$hashsize"
}

# node_conntrack_ensure_module — на чистом сервере nf_conntrack может быть
# НЕ загружен (ни одного ct-правила в системе): без модуля sysctl -p на
# 82-node-conntrack.conf умрёт и утащит за собой весь apply. Загружаем заранее.
node_conntrack_ensure_module() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    [ -f /proc/sys/net/netfilter/nf_conntrack_max ] && return 0
    if command -v modprobe >/dev/null 2>&1 && modprobe nf_conntrack 2>/dev/null; then
        log info "conntrack" "модуль nf_conntrack загружен"
    else
        log warn "conntrack" "modprobe nf_conntrack недоступен (контейнер?) — значения применятся после reboot"
    fi
}

node_conntrack_persist() {
    local modprobe_f="/etc/modprobe.d/node-conntrack.conf"
    local modules_f="/etc/modules-load.d/node-conntrack.conf"
    {
        echo "# node — conntrack hashsize (max/4), managed by node"
        echo "options nf_conntrack hashsize=${NODE_CONNTRACK_HASHSIZE}"
    } | node_persist "$modprobe_f"
    {
        echo "# node — force-load nf_conntrack (needed for nf_conntrack_max at boot)"
        echo "nf_conntrack"
    } | node_persist "$modules_f"
}

node_conntrack_apply() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    node_conntrack_ensure_module
    # runtime hashsize (текущее значение сохранено в снапшоте детекта для rollback)
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo "$NODE_CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize || \
            warn "conntrack" "runtime hashsize write failed (применится после reboot)"
    fi
}
