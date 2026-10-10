#!/bin/bash
# node — lib/udp.sh: §10 UDP-буферы (tier-aware), только буферы — ничего больше.
set -euo pipefail

node_udp_plan() {
    local tier udp_mem
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
    # 2026-09-24 (v1.1.7): udp_rmem_min/udp_wmem_min=8192 убраны — без доказанной пользы (дефолт 4096)
}

# node_udp_health — 2026-09-27 (v1.2.2): UDP для QUIC/Hysteria2 — ТОЛЬКО ЧТЕНИЕ, для status.
# Замер на лабе (Hysteria2 в rw-core/Xray 26.7, quic-go apernet): сокет сервера просит ровно 8 МиБ
# (в учёте ядра 16 МиБ) и получает их даже при rmem_max по умолчанию — у remnanode cap NET_ADMIN
# (SO_RCVBUFFORCE); rmem_max 8 МиБ node страхует контейнеры без NET_ADMIN, больше quic-go не просит.
# При 100% CPU очередь сокета — до 5% буфера, память UDP — 1 МБ; потерь 0. Поэтому здесь не «тюнинг»,
# а проверка фактов на ЭТОЙ ноде: буфер и потери UDP-сокетов Xray, RcvbufErrors, память UDP, NIC RX.
node_udp_health() {
    local mem pressure rcvbuf ring
    mem="$(awk '/^UDP:/ { for (i = 1; i < NF; i++) if ($i == "mem") print $(i + 1) }' /proc/net/sockstat 2>/dev/null || true)"
    pressure="$(awk '{print $2}' /proc/sys/net/ipv4/udp_mem 2>/dev/null || true)"
    local indg share
    rcvbuf="$(awk '/^Udp:/ { c++; if (c == 1) for (i = 2; i <= NF; i++) h[i] = $i; else for (i = 2; i <= NF; i++) if (h[i] == "RcvbufErrors") print $i }' /proc/net/snmp 2>/dev/null || true)"
    # 2026-10-10 (v1.2.6): доля потерь — голое «814983 с загрузки» без знаменателя выглядело аварией,
    # а на живой ноде это 0.03–0.07% UDP (исходящие потоки клиентов, QUIC сам перепосылает)
    indg="$(awk '/^Udp:/ { c++; if (c == 1) for (i = 2; i <= NF; i++) h[i] = $i; else for (i = 2; i <= NF; i++) if (h[i] == "InDatagrams") print $i }' /proc/net/snmp 2>/dev/null || true)"
    share="$(awk -v e="${rcvbuf:-0}" -v d="${indg:-0}" 'BEGIN { if (d + e > 0) printf "%.3f%%", 100 * e / (d + e); else print "?" }')"
    ring="$(command -v ethtool >/dev/null 2>&1 && ethtool -g "$(node_default_iface)" 2>/dev/null \
        | awk '/Pre-set maximums/ {s = "max"} /Current hardware settings/ {s = "cur"} $1 == "RX:" && s != "" && !seen[s]++ { v[s] = $2 } END { if (v["cur"] != "") print v["cur"] "/" v["max"] }' || true)"
    # ^ || true: ethtool -g не поддерживается частью виртуальных NIC — под set -e status обрывался (тест)
    printf 'UDP (QUIC/Hysteria2): память UDP %s стр. из порога давления %s (%s%%); RcvbufErrors с загрузки: %s (%s принятого UDP; < 0.5%% — норма); NIC RX-кольцо %s\n' \
        "${mem:-?}" "${pressure:-?}" "$(awk -v m="${mem:-0}" -v p="${pressure:-0}" 'BEGIN { printf (p > 0 ? "%.1f" : "?"), (p > 0 ? m * 100 / p : 0) }')" \
        "${rcvbuf:-?}" "$share" "${ring:-нет данных}"
    # UDP-сокеты прокси: пара строк ss — «UNCONN … local … users:((\"rw-core\",…))» + «skmem:(r…,rb…,…,d…)»
    # 2026-10-08 (v1.2.5): сводка вместо строки на сокет. На живой ноде у rw-core ~3000 UDP-сокетов —
    # это исходящие потоки клиентов (DNS/QUIC через freedom), status разрастался до 3000+ строк.
    # Поштучно — только «серверные» сокеты (порт ниже ip_local_port_range: эфемерным он не бывает)
    # и сокеты с потерями/заполненной очередью (не больше 10).
    local lport_lo
    lport_lo="$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true)"
    { ss -uamnp 2>/dev/null || true; } | awk -v lo="${lport_lo:-32768}" '
        function human(b) { return (b >= 1048576) ? sprintf("%d МиБ", b / 1048576) : sprintf("%d КиБ", b / 1024) }
        /^(UNCONN|ESTAB)/ { loc = $4; proc = ""; if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10); next }
        /skmem:\(/ && proc ~ /^(xray|rw-core|hysteria|sing-box|v2ray)/ {
            rb = 0; r = 0; d = 0
            # +0: substr даёт строку, без него "212992" >= 1048576 сравнивается как строки
            if (match($0, /rb[0-9]+/)) rb = substr($0, RSTART + 2, RLENGTH - 2) + 0
            if (match($0, /\(r[0-9]+/)) r = substr($0, RSTART + 2, RLENGTH - 2) + 0
            if (match($0, /d[0-9]+\)/)) d = substr($0, RSTART + 1, RLENGTH - 2) + 0
            port = loc; sub(/.*:/, "", port); port += 0
            n[proc]++; dr[proc] += d; q[proc] += r
            if (!(proc in bmin) || rb < bmin[proc]) bmin[proc] = rb
            if (rb > bmax[proc]) bmax[proc] = rb
            server = (port > 0 && port < lo)
            if (d > 0 || (rb > 0 && r * 2 >= rb) || server) {
                if (d > 0) {
                    # 2026-10-10 (v1.2.6): подсказка про quic-go/NET_ADMIN — только для СЕРВЕРНЫХ сокетов
                    # (инбаунд Hysteria2). Эфемерный сокет — исходящий UDP-поток клиента (QUIC/видео):
                    # всплеск сверх дефолтного буфера; поднимать rmem_default = задержка real-time трафика
                    if (!server)
                        hint = " — исходящий UDP-поток клиента (QUIC/видео): кратковременный всплеск, QUIC перепосылает сам; буфер не поднимаем (задержка звонков/игр)"
                    else
                        hint = (rb < 16777216) ? " — буфер меньше, чем просит quic-go (8 МиБ): rmem_max >= 8388608 или cap NET_ADMIN у контейнера" \
                                               : " — буфер полный по размеру: Xray не успевает читать (CPU/steal), не память"
                    line = sprintf("  ПОТЕРИ: сокет %s (%s): буфер %s, в очереди %d Б, потеряно %d пакетов%s", loc, proc, human(rb), r, d, hint)
                } else
                    line = sprintf("  сокет %s (%s%s): буфер %s, в очереди %d Б, потерь 0 — ok", loc, proc, server ? ", инбаунд" : "", human(rb), r)
                if (d > 0 || r * 2 >= rb) { if (nbad < 10) bad[++nbad] = line; else extra++ }
                else if (nsrv < 10) srv[++nsrv] = line
            }
            proc = ""
        }
        END {
            for (p in n)
                printf "  %s: UDP-сокетов %d (буфер %s…%s), в очередях %d Б, потерь на открытых сокетах %d%s\n", \
                    p, n[p], human(bmin[p]), human(bmax[p]), q[p], dr[p], (dr[p] > 0 ? " — см. ниже" : " — ok")
            for (i = 1; i <= nsrv; i++) print srv[i]
            for (i = 1; i <= nbad; i++) print bad[i]
            if (extra > 0) printf "  … и ещё %d сокетов с потерями/полной очередью\n", extra
        }'
    if [ -n "$mem" ] && [ -n "$pressure" ] && [ "$mem" -ge "$pressure" ] 2>/dev/null; then
        echo "  ВНИМАНИЕ: память UDP выше порога давления udp_mem — ядро урезает буферы всех UDP-сокетов"
    fi
    return 0
}
