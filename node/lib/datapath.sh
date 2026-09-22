#!/bin/bash
# node — lib/datapath.sh: datapath-pack 2 (порт ШАГ 7.12A/B старой ветки, v5.x).
# Обоснования — из боевого лога старого скрипта:
#   netdev_budget=600/usecs=8000: дефолтный NAPI budget=300 пакетов/2ms —
#     softirq не успевает выгребать RX-ring при 20k+ сессий;
#   tcp_max_tw_buckets=524288: TIME_WAIT-потолок (дефолт 16-32k) — узкое
#     место массовых коротких VPN-сессий;
#   tcp_mem по RAM (~25%): pressure-пороги TCP-стека (на больших RAM дефолт
#     консервативен, pressure режет буферы раньше времени); floor от старого
#     фикса: минимальные значения не ниже, чем дефолт ядра;
#   rmem_default/wmem_default tier-aware: high-watermark autotuning'а для
#     сокетов без SO_RCVBUF (Xray/QUIC); анти-RcvbufErrors (v5.1.0);
#   vm.dirty_*_bytes=64M/256M (все тиры): дефолт ratio 20%/10% RAM на
#     16-32GB ноде = 3-6GB dirty pages → writeback-всплески, стопорящие
#     fsync (crowdsec sqlite, journald); bytes-лимиты не зависят от роста
#     RAM и в ядре перекрывают ratio (старый стек v5.12.0);
#   vm.swappiness/min_free_kbytes/vfs_cache_pressure tier-aware (прод-значения
#     старого стека), watermark_boost_factor=0 (меньше latency-спайков
#     reclaim), page-cluster=0 (swap readahead off — диски VPS не шпиндлы);
#   fs.file-max=2M + inotify headroom (v6.0.0: systemd/dockerd/crowdsec);
#   vm.overcommit_memory=1 на T1/T2 (<=4GB): anti-OOM;
#   tcp_plb_enabled=1 (probed, kernel >=6.3): protective load balancing
#     внутри loss recovery — сглаживает повторные RTO;
#   busy_poll/busy_read=50µs — opt-in (ENABLE_BUSY_POLL=1): -10-30µs latency,
#     цена — CPU spin на пустой ноде, включение осознанное;
#   fq tune (live + boot-unit): limit=100000 flow_limit=1000 buckets=32768 —
#     дефолтные buckets=1024 дают хеш-коллизии при >1000 потоков (head-of-line
#     между потоками в одном bucket под BBR pacing).
# НЕ переносим (собственные revert-фиксы старой ветки): tcp_notsent_lowat
# (удалён v5.0.5 — фризы relay-стека), tcp_adv_win_scale=-2 (вернули дефолт 1
# в v5.2.0 — tcp_collapse ~59/сек на проде).
set -euo pipefail

node_datapath_plan() {
    [ "$(node_conf_get ENABLE_DATAPATH 1)" = "1" ] || { log info "datapath" "ENABLE_DATAPATH=0 — пропуск"; return 0; }
    local f="$NODE_SYSCTL_DATAPATH"

    node_sysctl_add "$f" net.core.netdev_budget "$(node_conf_get NETDEV_BUDGET 600)"
    node_sysctl_add "$f" net.core.netdev_budget_usecs "$(node_conf_get NETDEV_BUDGET_USECS 8000)"
    node_sysctl_add "$f" net.ipv4.tcp_max_tw_buckets "$(node_conf_get TCP_MAX_TW_BUCKETS 524288)"

    # tcp_mem: потолок ≈ TCP_MEM_PCT% RAM (страницы), pressure 75%/87.5% от него
    local kb pages memp pct
    kb="$(awk '/MemTotal/{print $2}' "${NODE_PROC_MEMINFO:-/proc/meminfo}" 2>/dev/null || echo 1048576)"
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=1048576
    pages=$(( kb / 4 ))
    pct="$(node_conf_get TCP_MEM_PCT 25)"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=25
    [ "$pct" -gt 0 ] && [ "$pct" -le 80 ] || pct=25
    memp=$(( pages * pct / 100 ))
    node_sysctl_add "$f" net.ipv4.tcp_mem "$((memp*3/4)) $((memp*7/8)) $memp"

    # rmem_default/wmem_default: watermark autotuning'а для сокетов без SO_RCVBUF
    local tier rd wd
    tier="$(node_ram_tier)"
    case "$tier" in
        1) rd=262144;  wd=262144 ;;
        2) rd=2097152; wd=2097152 ;;
        *) rd=8388608; wd=8388608 ;;
    esac
    rd="$(node_conf_get NET_RMEM_DEFAULT "$rd")"
    wd="$(node_conf_get NET_WMEM_DEFAULT "$wd")"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.core.rmem_default "$rd"
    node_sysctl_add "$NODE_SYSCTL_BASE" net.core.wmem_default "$wd"

    # --- vm/fs-блок (порт прод-значений старого стека, v5.12.0/v6.0.0) ---
    # dirty_* в BYTES, не в ratio: проценты от RAM на больших нодах — это
    # гигабайты dirty-буферов и редкие, но огромные writeback-всплески.
    # bytes-лимиты (фоновый flush с 64MB, hard-stall на 256MB) не зависят
    # от объёма RAM; в ядре запись dirty_bytes обнуляет dirty_ratio —
    # ratio-ключи из плана убраны (stale-cleanup снесёт старые файлы).
    # Runtime-запись — через node_sysctl_apply (sysctl -p), как весь план.
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.dirty_background_bytes 67108864   # 64MB
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.dirty_bytes 268435456             # 256MB
    # watermark_boost_factor=0 (старый ~3914): отключает watermark-boost →
    # меньше latency-спайков преждевременного reclaim при фрагментации.
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.watermark_boost_factor 0
    # page-cluster=0: swap readahead off — на VPS/VM диски не шпиндлы,
    # чтение страниц пачками только тратит I/O.
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.page-cluster 0
    # swappiness/min_free_kbytes/vfs_cache_pressure — tier-значения старого
    # стека (~3630/3661/3693/3723): T1 активнее свопится (RAM мало),
    # vfs_cache_pressure=150 только на T1 (dentry/inode cache поджать),
    # на T3/T4 НЕ пишем — ядерный дефолт 100 норм.
    local swap="" mfk="" vcp=""
    case "$tier" in
        1) swap=20; mfk=32768;  vcp=150 ;;
        2) swap=10; mfk=65536;  vcp=100 ;;
        3) swap=10; mfk=131072 ;;
        *) swap=10; mfk=262144 ;;
    esac
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.swappiness "$swap"
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.min_free_kbytes "$mfk"
    [ -z "$vcp" ] || node_sysctl_add "$NODE_SYSCTL_MEM" vm.vfs_cache_pressure "$vcp"
    if [ "$tier" -le 2 ]; then
        node_sysctl_add "$NODE_SYSCTL_MEM" vm.overcommit_memory "$(node_conf_get VM_OVERCOMMIT 1)"
    fi
    # max_map_count: Xray — Go-приложение с тысячами горутин/коннектов,
    # дефолтных 65530 map'ов нагруженной ноде мало (ломается не сразу,
    # а под пиковой нагрузкой — mmap: cannot allocate memory).
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.max_map_count "$(node_conf_get VM_MAX_MAP_COUNT 1048576)"
    # fs: потолок открытых файлов + inotify headroom (обоснование старого
    # v6.0.0): systemd/dockerd/crowdsec держат много watches — дефолтные
    # лимиты (128 instances / ~16k queued events) исчерпываются под
    # нагрузкой, inotify начинает отвечать ENOSPC на живой системе.
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.file-max 2097152
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.inotify.max_user_watches 524288
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.inotify.max_user_instances 8192
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.inotify.max_queued_events 65536

    # PLB (kernel >=6.3): сглаживание повторных RTO в loss recovery
    node_sysctl_add_probed "$f" net.ipv4.tcp_plb_enabled 1

    # busy_poll: low-latency polling (ценa — CPU spin на простое)
    if [ "$(node_conf_get ENABLE_BUSY_POLL 0)" = "1" ]; then
        node_sysctl_add "$f" net.core.busy_poll 50
        node_sysctl_add "$f" net.core.busy_read 50
        log info "datapath" "busy_poll=50µs включён (ENABLE_BUSY_POLL=1)"
    fi
}

# node_fq_tune_apply — fq-параметры (BBR pacing queue): live + boot-unit.
# Трогаем только существующие fq-инстансы (root и дочерние под mq) —
# qdisc не меняем, только параметры.
node_fq_tune_apply() {
    [ "$(node_conf_get ENABLE_DATAPATH 1)" = "1" ] || return 0
    [ "$(node_conf_get ENABLE_FQ_TUNE 1)" = "1" ] || { log info "datapath" "ENABLE_FQ_TUNE=0 — пропуск"; return 0; }
    command -v tc >/dev/null 2>&1 || { log warn "datapath" "нет tc — fq tune пропущен"; return 0; }

    local limit fl buckets
    limit="$(node_conf_get FQ_LIMIT 100000)"
    fl="$(node_conf_get FQ_FLOW_LIMIT 1000)"
    buckets="$(node_conf_get FQ_BUCKETS 32768)"

    # скрипт применения: live сейчас + юнитом при boot (network-pre)
    local script=/usr/local/sbin/node-fq-tune.sh
    {
        echo '#!/bin/bash'
        echo '# node — fq tune (generated, managed by node; do not edit)'
        printf 'LIM=%s\nFL=%s\nBKT=%s\n' "$limit" "$fl" "$buckets"
        cat <<'TCEOF'
# root fq: "qdisc fq 0: dev eth0 root ..."; дочерние под mq: "... parent 1:1 ..."
tc qdisc show 2>/dev/null | awk '$1=="qdisc" && $2=="fq" {
    dev=""; parent=""; handle=$3
    for (i=1; i<=NF; i++) {
        if ($i=="dev") dev=$(i+1)
        if ($i=="parent") parent=$(i+1)
    }
    if (parent=="") print "root", dev, "-"
    else print "child", dev, parent, handle
}' | while read -r kind dev parent handle; do
    [ -n "$dev" ] || continue
    case "$kind" in
        root)  tc qdisc change dev "$dev" root fq limit "$LIM" flow_limit "$FL" buckets "$BKT" 2>/dev/null || true ;;
        child) tc qdisc change dev "$dev" parent "$parent" handle "$handle" fq limit "$LIM" flow_limit "$FL" buckets "$BKT" 2>/dev/null || true ;;
    esac
done
exit 0
TCEOF
    } | node_persist "$script"
    chmod 0755 "$script" 2>/dev/null || true

    {
        echo '[Unit]'
        echo 'Description=node fq tune (BBR pacing queue params)'
        echo 'After=network-pre.target'
        echo 'Wants=network-pre.target'
        echo 'Before=network.target'
        echo
        echo '[Service]'
        echo 'Type=oneshot'
        echo "ExecStart=$script"
        echo 'RemainAfterExit=yes'
        echo
        echo '[Install]'
        echo 'WantedBy=multi-user.target'
    } | node_persist /etc/systemd/system/node-fq-tune.service

    if [ "${DRY_RUN:-0}" != "1" ]; then
        "$script"
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable node-fq-tune.service >/dev/null 2>&1 || \
            log warn "datapath" "systemctl enable node-fq-tune.service не удался"
        ok "datapath" "fq tuned: limit=$limit flow_limit=$fl buckets=$buckets"
    else
        log info "dry-run" "would: apply fq tune (limit=$limit flow_limit=$fl buckets=$buckets) live + enable node-fq-tune.service"
    fi
}
