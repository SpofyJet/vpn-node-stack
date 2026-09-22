#!/bin/bash
# node — lib/udp.sh: §10 UDP-буферы (tier-aware), только буферы — ничего больше.
set -euo pipefail

node_udp_plan() {
    local tier rmem wmem udp_mem
    tier="$(node_ram_tier)"
    # udp_mem — в СТРАНИЦАХ по 4KB, не в KB! Значения портированы из старого
    # продакшен-стека (vpn-node-setup.sh, v5.1.0 tier-aware; раньше здесь были
    # числа в KB — потолок получался завышен в ~8.8 раза):
    #   T1 ≈ 175/233/349 MB, T2 ≈ 349/466/699 MB, T3 ≈ 1.4/1.9/2.8 GB, T4 ≈ 2.8/3.8/5.7 GB
    case "$tier" in
        1) udp_mem="44693 59590 89385" ;;      # ~350 MB ceiling
        2) udp_mem="89385 119181 178770" ;;    # ~700 MB ceiling
        3) udp_mem="371994 495994 743988" ;;   # ~3 GB ceiling
        4) udp_mem="743988 991988 1487976" ;;  # ~6 GB ceiling
        *) udp_mem="89385 119181 178770" ;;    # неизвестный tier — безопасный средний (T2)
    esac
    # UDP шарит rmem/wmem_max с TCP (net.core.*) — здесь только udp_mem + min
    udp_mem="$(node_conf_get UDP_MEM "$udp_mem")"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.udp_mem "$udp_mem"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.udp_rmem_min 8192
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.udp_wmem_min 8192
}
