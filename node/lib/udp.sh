#!/bin/bash
# node — lib/udp.sh: §10 UDP-буферы (tier-aware), только буферы — ничего больше.
set -euo pipefail

node_udp_plan() {
    local tier rmem wmem udp_mem
    tier="$(node_ram_tier)"
    case "$tier" in
        1) udp_mem="393216 524288 786432" ;;
        2) udp_mem="786432 1048576 1572864" ;;
        3) udp_mem="1572864 2097152 3145728" ;;
        4) udp_mem="3145728 4194304 6291456" ;;
        *) udp_mem="786432 1048576 1572864" ;;  # неизвестный tier — безопасный средний
    esac
    # UDP шарит rmem/wmem_max с TCP (net.core.*) — здесь только udp_mem + min
    udp_mem="$(node_conf_get UDP_MEM "$udp_mem")"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.udp_mem "$udp_mem"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.udp_rmem_min 8192
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.udp_wmem_min 8192
}
