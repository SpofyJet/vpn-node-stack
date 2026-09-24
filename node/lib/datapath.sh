#!/bin/bash
# node — lib/datapath.sh: datapath-pack 2 (порт ШАГ 7.12A/B старой ветки, v5.x).
# Обоснования — из боевого лога старого скрипта:
#   netdev_budget=600 (usecs пропорционально: 4000; v1.1.7 — было 8000): дефолтный
#     NAPI budget=300 пакетов/2ms — softirq не успевает выгребать RX-ring при 20k+ сессий;
#   tcp_max_tw_buckets=524288: TIME_WAIT-потолок (дефолт 16-32k) — узкое
#     место массовых коротких VPN-сессий;
#   tcp_mem по RAM (~25%): pressure-пороги TCP-стека (на больших RAM дефолт
#     консервативен, pressure режет буферы раньше времени); floor от старого
#     фикса: минимальные значения не ниже, чем дефолт ядра;
#   rmem_default/wmem_default: НЕ трогаем (v1.1.7; только явные NET_RMEM/WMEM_DEFAULT);
#   vm.dirty_*_bytes=64M/256M (все тиры): дефолт ratio 20%/10% RAM на
#     16-32GB ноде = 3-6GB dirty pages → writeback-всплески, стопорящие
#     fsync (crowdsec sqlite, journald); bytes-лимиты не зависят от роста
#     RAM и в ядре перекрывают ratio (старый стек v5.12.0);
#   vm.swappiness/min_free_kbytes tier-aware; fs.file-max (только повышение) +
#     inotify headroom (docker-хост: 128 instances по умолчанию исчерпываются);
#   v1.1.7 убраны: watermark_boost_factor/page-cluster/vfs_cache_pressure,
#     overcommit_memory=1, max_map_count (дефолт Ubuntu), tcp_plb_enabled (нужен
#     PLB-capable CC вроде DCTCP, для IPv4 — no-op по ip-sysctl.rst);
#   busy_poll/busy_read=50µs — opt-in (ENABLE_BUSY_POLL=1): -10-30µs latency,
#     цена — CPU spin на пустой ноде, включение осознанное;
#   fq tune (live + boot-unit): limit=100000 buckets=32768 — дефолтные buckets=1024
#     дают хеш-коллизии при >1000 потоков (head-of-line между потоками в одном bucket
#     под BBR pacing). flow_limit — дефолт ядра 100 (v1.1.7, было 1000): TCP держит в
#     qdisc лишь TSQ-порцию (tcp_limit_output_bytes), а UDP без EDT (Hysteria2/quic-go)
#     ограничен только flow_limit — 1000 пакетов = до ~120мс очереди на поток при
#     100 Мбит/с и 10x доля общего limit у одного «жадного» потока.
# НЕ переносим (собственные revert-фиксы старой ветки): tcp_notsent_lowat
# (удалён v5.0.5 — фризы relay-стека), tcp_adv_win_scale=-2 (вернули дефолт 1
# в v5.2.0 — tcp_collapse ~59/сек на проде).
set -euo pipefail

# --- softnet-обратная связь (v1.1.3, 2026-09-23) ---
# /proc/net/softnet_stat (по строке на CPU, hex): 1 = processed, 2 = dropped
# (переполнение backlog: netdev_max_backlog), 3 = time_squeeze (NAPI-цикл
# упёрся в netdev_budget/_usecs при оставшейся работе) — см. Documentation/
# admin-guide/sysctl/net.rst. Счётчики — с boot, читаем ОДИН раз за прогон.
node_softnet_read() {
    [ -n "${_NODE_SN_READ:-}" ] && return 0
    local t
    t="$(awk '{p += strtonum_hex($1); d += strtonum_hex($2); s += strtonum_hex($3)}
        function strtonum_hex(h,   i, v, c) { v = 0; h = tolower(h)
            for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)); if (!c) return v; v = v * 16 + c - 1 }
            return v }
        END {printf "%d %d %d\n", p, d, s}' "${NODE_PROC_ROOT:-/proc}/net/softnet_stat" 2>/dev/null || echo "0 0 0")"
    read -r _NODE_SN_PROC _NODE_SN_DROP _NODE_SN_SQZ <<<"$t"
    _NODE_SN_READ=1
}
# node_conf_user_set — в config.sh (v1.1.7: нужен и irq.sh в rt-reapply)
# node_softnet_value <ключ-конфига> <значение-плана> <drop|squeeze> — шаг вверх (x2)
# ТОЛЬКО при доказанном насыщении и AUTO_SOFTNET_TUNE=1; иначе значение плана как есть.
node_softnet_value() {
    local key="$1" v="$2" kind="$3"
    [ "$(node_conf_get AUTO_SOFTNET_TUNE 1)" = "1" ] || { echo "$v"; return 0; }
    node_conf_user_set "$key" && { echo "$v"; return 0; }
    case "$kind" in
        drop)    [ "${_NODE_SN_DROP:-0}" -gt 0 ] && v=$((v * 2)) ;;
        # squeeze > 0.1% processed: единичные исторические squeeze не в счёт
        squeeze) [ $(( ${_NODE_SN_SQZ:-0} * 1000 )) -gt "${_NODE_SN_PROC:-0}" ] && [ "${_NODE_SN_SQZ:-0}" -gt 0 ] && v=$((v * 2)) ;;
    esac
    echo "$v"
}

# --- perf-снапшот и отчёт «что упирается» (v1.1.3, 2026-09-23) ---
# Только чтение /proc и /sys (корни переопределяемы NODE_PROC_ROOT/NODE_SYS_ROOT).
# apply сохраняет снапшот как baseline; status показывает дельты с момента apply —
# видно, помогли ли твики и где текущий предел (softirq/backlog, accept-очередь,
# UDP-буферы, потери пути, steal гипервизора, кольца NIC).
node_perf_snapshot() {
    local pr="${NODE_PROC_ROOT:-/proc}" sr="${NODE_SYS_ROOT:-/sys}" ifname k
    echo "ts=$(date +%s)"
    if declare -F node_softnet_read >/dev/null 2>&1; then
        unset _NODE_SN_READ; node_softnet_read   # свежее чтение, не кэш плана
        echo "softnet_processed=$_NODE_SN_PROC"; echo "softnet_dropped=$_NODE_SN_DROP"; echo "softnet_squeeze=$_NODE_SN_SQZ"
    fi
    # /proc/net/netstat и /proc/net/snmp: пары строк «Префикс: имена» / «Префикс: значения»
    awk '$1 == "TcpExt:" || $1 == "Tcp:" || $1 == "Udp:" {
            if (!(($1) in hdr)) { hdr[$1] = 1; for (i = 2; i <= NF; i++) name[$1, i] = $i; next }
            for (i = 2; i <= NF; i++) v[$1 name[$1, i]] = $i }
        END { n = split("TcpExt:ListenOverflows TcpExt:ListenDrops TcpExt:TCPBacklogDrop TcpExt:TCPRcvQDrop Tcp:RetransSegs Tcp:OutSegs Udp:RcvbufErrors Udp:SndbufErrors Udp:InErrors", want, " ")
              for (j = 1; j <= n; j++) { key = want[j]; sub(":", "", key); printf "%s=%d\n", key, v[want[j]] + 0 } }' \
        "$pr/net/netstat" "$pr/net/snmp" 2>/dev/null || true
    # /proc/stat: cpu user nice system idle iowait irq softirq steal
    awk '$1 == "cpu" { t = 0; for (i = 2; i <= 9; i++) t += $i; printf "cpu_total=%d\ncpu_softirq=%d\ncpu_steal=%d\n", t, $8, $9 }' "$pr/stat" 2>/dev/null || true
    ifname="$(node_default_iface 2>/dev/null || true)"
    if [ -n "$ifname" ]; then
        echo "nic=$ifname"
        for k in rx_packets rx_dropped rx_missed_errors tx_dropped; do
            echo "nic_$k=$(cat "$sr/class/net/$ifname/statistics/$k" 2>/dev/null || echo 0)"
        done
    fi
}

node_perf_report() {   # <baseline-file>: дельты «сейчас − apply» и подсказки по пределам
    local base="$1" cur
    [ -f "$base" ] || { echo "perf: baseline нет (появится после следующего apply)"; return 0; }
    # 2026-09-24 (v1.1.6): baseline 0600 root — без root awk падал (rc 2 роняло status
    # «без root») и mktemp-файл ниже оставался в /tmp
    [ -r "$base" ] || { echo "perf: baseline недоступен без root ($base) — sudo для дельт"; return 0; }
    cur="$(mktemp)"; node_perf_snapshot > "$cur"
    awk -F= 'NR == FNR { b[$1] = $2; next } { c[$1] = $2 }
        function d(k) { return c[k] - b[k] }
        END {
            dt = d("ts"); if (dt <= 0) dt = 1
            if (d("softnet_processed") < 0 || d("cpu_total") < 0) { print "perf: счётчики меньше baseline — был reboot; повтори apply для нового baseline"; exit }
            ret = (d("TcpOutSegs") > 0) ? 100 * d("TcpRetransSegs") / d("TcpOutSegs") : 0
            sq  = (d("softnet_processed") > 0) ? 100 * d("softnet_squeeze") / d("softnet_processed") : 0
            st  = (d("cpu_total") > 0) ? 100 * d("cpu_steal") / d("cpu_total") : 0
            si  = (d("cpu_total") > 0) ? 100 * d("cpu_softirq") / d("cpu_total") : 0
            printf "perf since apply (%ds): pps_in=%d/s softnet drop=+%d squeeze=%.3f%% | listen_ovf=+%d | tcp_retrans=%.2f%% | udp_rcvbuf_err=+%d | cpu steal=%.1f%% softirq=%.1f%% | nic rx_drop=+%d missed=+%d\n", \
                dt, d("nic_rx_packets") / dt, d("softnet_dropped"), sq, d("TcpExtListenOverflows"), ret, d("UdpRcvbufErrors"), st, si, d("nic_rx_dropped"), d("nic_rx_missed_errors")
            n = 0
            if (d("softnet_dropped") > 0)        { n++; print "  LIMIT: softnet backlog overflow — netdev_max_backlog (AUTO_SOFTNET_TUNE при следующем apply) / ENABLE_RPS" }
            if (sq > 0.1)                        { n++; print "  LIMIT: NAPI budget исчерпывается (time_squeeze) — netdev_budget (AUTO_SOFTNET_TUNE) / больше очередей (RSS)" }
            if (d("TcpExtListenOverflows") > 0 || d("TcpExtListenDrops") > 0) { n++; print "  LIMIT: accept-очередь переполняется — somaxconn/tcp_max_syn_backlog или backlog inbound xray" }
            if (d("UdpRcvbufErrors") > 0)        { n++; print "  LIMIT: UDP receive buffer — rmem_default/udp_mem (QUIC/Hysteria2)" }
            if (ret > 2)                         { n++; printf "  NOTE: ретрансмиты %.2f%% — потери/перегрузка ПУТИ (BBR, MTU), не узкое место хоста\n", ret }
            if (st > 5)                          { n++; printf "  NOTE: CPU steal %.1f%% — конкуренция на гипервизоре; тюнинг хоста не поможет\n", st }
            if (d("nic_rx_missed_errors") > 0 || d("nic_rx_dropped") > 0) { n++; print "  LIMIT: NIC дропает на приёме — NIC_RING_RX / ENABLE_NIC_OFFLOAD_OPT (кольца до max)" }
            if (n == 0) print "  нет сигналов узкого места на стороне хоста с момента apply"
        }' "$base" "$cur"
    rm -f "$cur"
}

node_datapath_plan() {
    [ "$(node_conf_get ENABLE_DATAPATH 1)" = "1" ] || { log info "datapath" "ENABLE_DATAPATH=0 — пропуск"; return 0; }
    local f="$NODE_SYSCTL_DATAPATH"

    node_softnet_read
    local nb; nb="$(node_softnet_value NETDEV_BUDGET "$(node_conf_get NETDEV_BUDGET 600)" squeeze)"
    [ "$nb" != "$(node_conf_get NETDEV_BUDGET 600)" ] && log info "datapath" "softnet: time_squeeze=${_NODE_SN_SQZ}/${_NODE_SN_PROC} (>0.1%) — netdev_budget -> $nb (AUTO_SOFTNET_TUNE)"
    node_sysctl_add "$f" net.core.netdev_budget "$nb"
    # 2026-09-24 (v1.1.7): usecs — пропорционально budget (дефолт ядра 2000µs на 300 пакетов):
    # 600 -> 4000, после авто-удвоения по time_squeeze 1200 -> 8000. Прежние безусловные 8000
    # при budget 600 давали softirq-циклы до 8мс (2 тика при HZ=250 у XanMod) — задержка
    # Xray/real-time UDP на этом ядре CPU без выигрыша (packet-budget исчерпывается раньше).
    local nbu; nbu="$(node_conf_get NETDEV_BUDGET_USECS "")"
    [[ "$nbu" =~ ^[0-9]+$ ]] || nbu=$(( nb > 0 ? 2000 * nb / 300 : 4000 ))
    node_sysctl_add "$f" net.core.netdev_budget_usecs "$nbu"
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

    # 2026-09-24 (v1.1.7): rmem_default/wmem_default — дефолтный буфер ВСЕХ не-TCP сокетов
    # (UDP, netlink, ...). Прежние 8 МБ (T3/T4) давали каждому UDP-сокету Xray-relay
    # очередь до ~5500 пакетов = до секунд задержки real-time трафика; QUIC (quic-go)
    # ставит свой буфер сам (нужен лишь rmem_max, см. tcp.sh). Дефолт ядра, если не задано явно.
    local tier; tier="$(node_ram_tier)"
    node_conf_user_set NET_RMEM_DEFAULT && node_sysctl_add "$NODE_SYSCTL_BASE" net.core.rmem_default "$(node_conf_get NET_RMEM_DEFAULT 212992)"
    node_conf_user_set NET_WMEM_DEFAULT && node_sysctl_add "$NODE_SYSCTL_BASE" net.core.wmem_default "$(node_conf_get NET_WMEM_DEFAULT 212992)"

    # --- vm/fs-блок (порт прод-значений старого стека, v5.12.0/v6.0.0) ---
    # dirty_* в BYTES, не в ratio: проценты от RAM на больших нодах — это
    # гигабайты dirty-буферов и редкие, но огромные writeback-всплески.
    # bytes-лимиты (фоновый flush с 64MB, hard-stall на 256MB) не зависят
    # от объёма RAM; в ядре запись dirty_bytes обнуляет dirty_ratio —
    # ratio-ключи из плана убраны (stale-cleanup снесёт старые файлы).
    # Runtime-запись — через node_sysctl_apply (sysctl -p), как весь план.
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.dirty_background_bytes 67108864   # 64MB
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.dirty_bytes 268435456             # 256MB
    # 2026-09-24 (v1.1.7): убраны без доказанной пользы для VPN-нагрузки —
    # watermark_boost_factor=0, page-cluster=0 (важен лишь при swap/zram), vfs_cache_pressure
    # (T1/T2), overcommit_memory=1 (снимал страховку ENOMEM; Go/Xray работает с эвристикой
    # по умолчанию), max_map_count=1048576 (в Ubuntu 24.04 это уже дефолт, 10-map-count.conf).
    # Значения прежних версий вернёт node_sysctl_restore_dropped. VM_OVERCOMMIT /
    # VM_MAX_MAP_COUNT — только если заданы явно.
    # swappiness/min_free_kbytes — tier-значения: min_free_kbytes — резерв для атомарных
    # (softirq) аллокаций skb на высоком pps.
    local swap="" mfk=""
    case "$tier" in
        1) swap=20; mfk=32768 ;;
        2) swap=10; mfk=65536 ;;
        3) swap=10; mfk=131072 ;;
        *) swap=10; mfk=262144 ;;
    esac
    node_sysctl_add "$NODE_SYSCTL_MEM" vm.swappiness "$swap"
    # 2026-09-24 (v1.1.7): min_free_kbytes — только ПОВЫШАЕМ. Ядро само считает резерв
    # (sqrt(lowmem*16), а с THP — set_recommended_min_free_kbytes khugepaged): живая 2GB-нода
    # имела 45056, tier T1 32768 его ПОНИЖАЛ — меньше запаса для GFP_ATOMIC skb в softirq,
    # обратное задуманному. Базовое значение ниже tier — поднимаем, иначе ключ не пишем.
    local mfb; mfb="$(node_sysctl_baseline vm.min_free_kbytes)"
    mfk="$(node_conf_get VM_MIN_FREE_KBYTES "$mfk")"
    if node_conf_user_set VM_MIN_FREE_KBYTES || ! [[ "$mfb" =~ ^[0-9]+$ ]] || [ "$mfk" -gt "$mfb" ]; then
        node_sysctl_add "$NODE_SYSCTL_MEM" vm.min_free_kbytes "$mfk"
    fi
    node_conf_user_set VM_OVERCOMMIT && node_sysctl_add "$NODE_SYSCTL_MEM" vm.overcommit_memory "$(node_conf_get VM_OVERCOMMIT 0)"
    node_conf_user_set VM_MAX_MAP_COUNT && node_sysctl_add "$NODE_SYSCTL_MEM" vm.max_map_count "$(node_conf_get VM_MAX_MAP_COUNT 1048576)"
    # fs: inotify headroom — RemnaNode в docker: systemd/dockerd/контейнеры держат много
    # inotify-инстансов, дефолтные 128 instances исчерпываются («too many open files»).
    # 2026-09-24 (v1.1.6): fs.file-max — только ПОВЫШАЕМ. С ядер 5.x дефолт ~2^63
    # (живая нода: 9223372036854775807) — безусловные 2097152 ПОНИЖАЛИ системный
    # лимит дескрипторов прокси-ноды. Нужен лишь на старых ядрах с малым дефолтом.
    local fm; fm="$(node_sysctl_baseline fs.file-max)"
    if [[ "$fm" =~ ^[0-9]{1,18}$ ]] && [ "$fm" -lt 2097152 ]; then
        node_sysctl_add "$NODE_SYSCTL_MEM" fs.file-max 2097152
    fi
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.inotify.max_user_watches 524288
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.inotify.max_user_instances 8192
    node_sysctl_add "$NODE_SYSCTL_MEM" fs.inotify.max_queued_events 65536

    # 2026-09-24 (v1.1.7): tcp_plb_enabled убран — PLB работает лишь с congestion control,
    # поддерживающим его (DCTCP), и для IPv4 — no-op (Documentation/networking/ip-sysctl.rst);
    # с BBR на WAN эффекта нет.

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
    fl="$(node_conf_get FQ_FLOW_LIMIT 100)"
    buckets="$(node_conf_get FQ_BUCKETS 32768)"
    # 2026-09-23: значения попадают в генерируемый root-скрипт (LIM=...) —
    # только числа, иначе дефолт (мусор/инъекция из конфига не исполняется)
    [[ "$limit" =~ ^[0-9]+$ ]]   || { warn "datapath" "FQ_LIMIT='$limit' не число — 100000"; limit=100000; }
    [[ "$fl" =~ ^[0-9]+$ ]]      || { warn "datapath" "FQ_FLOW_LIMIT='$fl' не число — 100"; fl=100; }
    [[ "$buckets" =~ ^[0-9]+$ ]] || { warn "datapath" "FQ_BUCKETS='$buckets' не число — 32768"; buckets=32768; }

    # скрипт применения: live сейчас + юнитом при boot (network-pre)
    local script=/usr/local/sbin/node-fq-tune.sh
    {
        echo '#!/bin/bash'
        echo '# node — fq tune (generated, managed by node; do not edit)'
        printf 'LIM=%s\nFL=%s\nBKT=%s\n' "$limit" "$fl" "$buckets"
        cat <<'TCEOF'
# root fq: "qdisc fq 0: dev eth0 root ..."; дочерние под mq: "... parent 1:1 ..."
# 2026-09-24 (v1.1.5): change по дефолтному qdisc (handle 0:) ядро отвергает
# ("Qdisc not found ... NLM_F_CREATE") — тогда replace тем же fq с новыми
# параметрами (тип qdisc не меняется). rc!=0, если хоть один fq не обновлён.
rc=0
while read -r kind dev parent handle; do
    [ -n "$dev" ] || continue
    case "$kind" in
        root)  tc qdisc change dev "$dev" root fq limit "$LIM" flow_limit "$FL" buckets "$BKT" 2>/dev/null \
                 || tc qdisc replace dev "$dev" root fq limit "$LIM" flow_limit "$FL" buckets "$BKT" 2>/dev/null || rc=1 ;;
        child) tc qdisc change dev "$dev" parent "$parent" handle "$handle" fq limit "$LIM" flow_limit "$FL" buckets "$BKT" 2>/dev/null \
                 || tc qdisc replace dev "$dev" parent "$parent" fq limit "$LIM" flow_limit "$FL" buckets "$BKT" 2>/dev/null || rc=1 ;;
    esac
done < <(tc qdisc show 2>/dev/null | awk '$1=="qdisc" && $2=="fq" {
    dev=""; parent=""; handle=$3
    for (i=1; i<=NF; i++) {
        if ($i=="dev") dev=$(i+1)
        if ($i=="parent") parent=$(i+1)
    }
    if (parent=="") print "root", dev, "-"
    else print "child", dev, parent, handle
}')
exit "$rc"
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
        # 2026-09-24 (v1.1.5): исходные параметры каждого fq — в rt-реестр (rollback
        # вернёт их через replace); повторный apply исходное не перезаписывает
        local fdev fwhere flim ffl fbkt
        while IFS=$'\t' read -r fdev fwhere flim ffl fbkt; do
            [ -n "$fdev" ] && [ -n "$flim" ] && [ -n "$ffl" ] && [ -n "$fbkt" ] || continue
            node_rt_record "$fdev" fq "$fwhere" "limit $flim flow_limit $ffl buckets $fbkt"
        done < <(tc qdisc show 2>/dev/null | awk '$1=="qdisc" && $2=="fq" {
            dev=""; where="root"; l=""; f=""; b=""
            for (i=1; i<=NF; i++) {
                if ($i=="dev") dev=$(i+1)
                if ($i=="parent") where="parent " $(i+1)
                if ($i=="limit") l=$(i+1)
                if ($i=="flow_limit") f=$(i+1)
                if ($i=="buckets") b=$(i+1)
            }
            sub(/p$/, "", l); sub(/p$/, "", f)
            printf "%s\t%s\t%s\t%s\t%s\n", dev, where, l, f, b
        }')
        local frc=0
        "$script" || frc=$?
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable node-fq-tune.service >/dev/null 2>&1 || \
            log warn "datapath" "systemctl enable node-fq-tune.service не удался"
        # 2026-09-24 (v1.1.5): «fq tuned» — только если tc реально принял параметры
        if [ "$frc" = 0 ]; then
            ok "datapath" "fq tuned: limit=$limit flow_limit=$fl buckets=$buckets"
        else
            warn "datapath" "fq tune не применён: tc отклонил параметры fq (проверь: tc qdisc show)"
        fi
    else
        log info "dry-run" "would: apply fq tune (limit=$limit flow_limit=$fl buckets=$buckets) live + enable node-fq-tune.service"
    fi
}
