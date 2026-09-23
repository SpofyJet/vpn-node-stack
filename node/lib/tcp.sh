#!/bin/bash
# node — lib/tcp.sh: §9 TCP-профиль (tier-aware). Агрессивные параметры
# (tw_reuse/fin_timeout/retries2/keepalive/PMTU/TFO) — только в opt-in «сильном»
# tiers ниже (node_tcp_perf_plan, ENABLE_PERFORMANCE_SYSCTL=1).
set -euo pipefail

node_tcp_plan() {
    local tier somaxconn rmem wmem port_range
    tier="$(node_ram_tier)"
    case "$tier" in
        1) somaxconn=8192;  rmem=4194304;  wmem=4194304 ;;
        2) somaxconn=16384; rmem=8388608;  wmem=8388608 ;;
        3) somaxconn=32768; rmem=16777216; wmem=16777216 ;;
        4) somaxconn=65535; rmem=33554432; wmem=33554432 ;;
        *) somaxconn=16384; rmem=8388608;  wmem=8388608 ;;  # неизвестный tier — средний
    esac
    somaxconn="$(node_conf_get TCP_SOMAXCONN "$somaxconn")"
    rmem="$(node_conf_get NET_RMEM_MAX "$rmem")"
    wmem="$(node_conf_get NET_WMEM_MAX "$wmem")"
    port_range="$(node_conf_get TCP_PORT_RANGE "10240 65535")"

    node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn "$somaxconn"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.tcp_max_syn_backlog "$(node_conf_get TCP_SYN_BACKLOG "$somaxconn")"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.tcp_syncookies 1
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.tcp_moderate_rcvbuf 1
    node_sysctl_add "$NODE_SYSCTL_BASE" net.core.rmem_max "$rmem"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.core.wmem_max "$wmem"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.ip_local_port_range "$port_range"
    node_tcp_buf_plan "$rmem" "$wmem"
}

# node_tcp_buf_plan <rmem_max> <wmem_max> — opt-in (ENABLE_TCP_BUF_TUNE=1, v1.1.1).
# net.core.{r,w}mem_max ограничивают только явный SO_RCVBUF/SO_SNDBUF; окно
# АВТОТЮНИНГА TCP (Xray его не трогает) ограничено tcp_rmem[2]/tcp_wmem[2]
# (дефолт ядра 6MiB/4MiB) — tier-значения выше до TCP-сокетов не доходили.
# Потолок одного потока ≈ окно/RTT: wmem 4MiB @150мс ≈ 224 Мбит/с. Только
# ПОВЫШАЕМ (tier ниже текущего — ключ не трогаем); суммарная память ограничена
# tcp_mem (datapath). Откат — реестр sysctl-orig.tsv + удаление файла.
node_tcp_buf_plan() {
    [ "$(node_conf_get ENABLE_TCP_BUF_TUNE 0)" = "1" ] || return 0
    local rmax="$1" wmax="$2" cur_r cur_w
    [[ "$rmax" =~ ^[0-9]+$ && "$wmax" =~ ^[0-9]+$ ]] || { warn "tcp" "tcp_rmem/wmem: rmem/wmem_max не числа — пропуск"; return 0; }
    cur_r="$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')"; cur_r="${cur_r:-6291456}"
    cur_w="$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')"; cur_w="${cur_w:-4194304}"
    [ "$rmax" -gt "$cur_r" ] && node_sysctl_add_writable "$NODE_SYSCTL_DATAPATH" net.ipv4.tcp_rmem "4096 131072 $rmax"
    [ "$wmax" -gt "$cur_w" ] && node_sysctl_add_writable "$NODE_SYSCTL_DATAPATH" net.ipv4.tcp_wmem "4096 16384 $wmax"
    log info "tcp" "tcp_rmem/wmem tune (ENABLE_TCP_BUF_TUNE=1): max r=$rmax w=$wmax (было $cur_r/$cur_w)"
    return 0
}

# node_tcp_perf_plan — «сильный» TCP-стек (opt-in, ENABLE_PERFORMANCE_SYSCTL=1).
# Ключи, которых нет в текущем ядре — пропускаются (probed), apply не падает.
node_tcp_perf_plan() {
    [ "$(node_conf_get ENABLE_PERFORMANCE_SYSCTL 0)" = "1" ] || return 0
    local f="$NODE_SYSCTL_DATAPATH"
    node_sysctl_add      "$f" net.ipv4.tcp_tw_reuse 1        # reuse TIME_WAIT (исходящие) — риск CGNAT-клиентов осознан
    node_sysctl_add      "$f" net.ipv4.tcp_fin_timeout 15    # 60 дефолт — медленно закрываемся
    node_sysctl_add      "$f" net.ipv4.tcp_retries2 8        # 15 дефолт медленно; «2» из гуру-скриптов ломает — 8 разумно
    # keepalive 300/15/5 — прод-значения старого стека (~3497-3500, мобильные
    # клиенты): carrier-NAT мобильных операторов умирает раньше 600с, поэтому
    # keepalive обязан успеть до смерти NAT-записи.
    node_sysctl_add      "$f" net.ipv4.tcp_keepalive_time 300
    node_sysctl_add      "$f" net.ipv4.tcp_keepalive_intvl 15
    node_sysctl_add      "$f" net.ipv4.tcp_keepalive_probes 5
    node_sysctl_add      "$f" net.ipv4.tcp_mtu_probing 1     # PMTU blackhole обход (особенно с GRO на туннелях)
    node_sysctl_add      "$f" net.ipv4.tcp_fastopen 3        # TFO client+server
    node_sysctl_add      "$f" net.ipv4.tcp_slow_start_after_idle 0  # long-lived VPN-потоки не сбрасывают cwnd
    node_sysctl_add      "$f" net.ipv4.tcp_no_metrics_save 1 # не кэшировать cwnd по маршрутам — стабильность при флапах клиентов
    node_sysctl_add      "$f" net.ipv4.tcp_synack_retries 3  # 5 дефолт: half-open живут дольше и жрут conntrack при SYN-флуде
    node_sysctl_add_probed "$f" net.ipv4.tcp_sack 1
    node_sysctl_add_probed "$f" net.ipv4.tcp_dsack 1
    node_sysctl_add_probed "$f" net.ipv4.ipfrag_high_thresh 8388608  # дефолт ядра 4MB — поднимаем (фрагментированный UDP: DNS/туннели)
    log info "tcp" "performance TCP-tier включён (ENABLE_PERFORMANCE_SYSCTL=1)"
}
