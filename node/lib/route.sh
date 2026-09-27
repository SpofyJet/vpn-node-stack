#!/bin/bash
# node — lib/route.sh: начальное окно TCP (initcwnd/initrwnd) на IPv4-маршрутах по умолчанию (v1.2.2).
# 2026-09-27: VLESS без mux открывает к ноде отдельное TCP на каждое соединение приложения, и каждое
# начинается с окна ядра 10 сегментов (~14 КБ, RFC 6928): ответ 64 КБ – 1 МБ приходит клиенту за
# лишние круги «туда-обратно». На мобильном RTT 60–150 мс это заметная часть загрузки страницы.
# initcwnd — сколько нода отправит сразу (к клиенту и к сайту), initrwnd — сколько разрешит прислать
# себе сразу (ответы сайтов). BBR + fq разносит начальное окно по времени (pacing), без пачки в линк.
# Где живёт настройка: атрибут маршрута (ip route ... initcwnd N). Он не переживает reboot и
# DHCP-продление, поэтому: 1) сразу — ip route change; 2) boot — node-rt-tweaks (After=network-online);
# 3) DHCP — drop-in networkd [DHCPv4] InitialCongestionWindow= (networkd сам ставит его на свой маршрут).
# Только IPv4 и только table main: IPv6 на ноде выключен, policy-таблицы не наши.
set -euo pipefail

NODE_ROUTE_DROPIN="91-vpn-node-initcwnd.conf"

# node_route_initcwnd_value — TCP_INITCWND из конфига: 0 = выключено (окно ядра), иначе 10..128.
node_route_initcwnd_value() {
    local v; v="$(node_conf_get TCP_INITCWND 32)"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || { [ "$v" -ne 0 ] && { [ "$v" -lt 10 ] || [ "$v" -gt 128 ]; }; }; then
        warn "route" "TCP_INITCWND='$v' вне 0 или 10..128 — беру 32"
        v=32
    fi
    echo "$v"
}

# _node_route_base <строка ip -o route> — спецификация маршрута для `ip route change` без наших
# атрибутов и без флагов состояния, которые ip печатает, но не принимает на вход.
_node_route_base() {
    sed -E 's/ (initcwnd|initrwnd) [0-9]+//g; s/ (linkdown|dead|offload|trap|rt_offload|rt_trap|rt_offload_failed|pervasive)( |$)/\2/g; s/[[:space:]]+$//' <<<"$1"
}

# node_route_initcwnd_set <N> — выставить (N>0) или снять (N=0) initcwnd/initrwnd на всех IPv4
# default-маршрутах table main. Возвращает число изменённых маршрутов в stdout.
# Дубликаты: DHCP-продление в networkd без нашего drop-in ДОБАВЛЯЕТ свой маршрут рядом с нашим
# (лаба: «default … initcwnd 32» + «default …» с тем же ключом). Ядро берёт первый — наш (проверено:
# cwnd:32 у нового соединения). `ip route change` на значение без окна при таком дубликате ядро
# отвергает («File exists» — идентичный уже есть) — снимаем удалением НАШЕГО варианта: дубликат
# остаётся маршрутом по умолчанию.
node_route_initcwnd_set() {
    local n="$1" r base changed=0 seen=" "
    local routes; routes="$(ip -4 -o route show table main default 2>/dev/null | sed -E 's/[[:space:]]+$//')"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$r" in *nexthop*)
            warn "route" "multipath-маршрут по умолчанию — initcwnd не ставлю: $r"; continue ;; esac
        base="$(_node_route_base "$r")"
        # shellcheck disable=SC2086  # base — слова спецификации маршрута, split намеренный
        if [ "$n" -gt 0 ]; then
            case "$seen" in *" [$base] "*) continue ;; esac   # дубликат того же маршрута — один change
            seen="${seen}[${base}] "
            ip -4 route change $base initcwnd "$n" initrwnd "$n" 2>/dev/null && changed=$((changed + 1)) \
                || warn "route" "ip route change не принял маршрут (оставлен как есть): $base"
        else
            [ "$base" = "$r" ] && continue
            if ip -4 route change $base 2>/dev/null; then changed=$((changed + 1))
            elif grep -qxF -- "$base" <<<"$routes"; then
                # shellcheck disable=SC2046  # атрибуты окна — отдельные слова
                ip -4 route del $base $(grep -oE '(initcwnd|initrwnd) [0-9]+' <<<"$r") 2>/dev/null \
                    && changed=$((changed + 1)) || warn "route" "не удалось снять initcwnd с маршрута: $r"
            else
                warn "route" "не удалось снять initcwnd с маршрута: $r"
            fi
        fi
    done <<<"$routes"
    echo "$changed"
}

# node_route_networkd_dropin <N> — drop-in [DHCPv4] для .network с DHCP IPv4 (N=0 — убрать наши drop-in).
# networkd не перезапускаем (сеть живой ноды не дёргаем): вступит при следующем DHCP-событии/reboot,
# до того держит runtime-атрибут, выставленный выше.
node_route_networkd_dropin() {
    local n="$1" f name dd src cnt=0
    local dir="${NODE_IPV6_NETWORKD_DIR:-/etc/systemd/network}"
    local srcs="${NODE_IPV6_NETWORKD_SRC:-/run/systemd/network /etc/systemd/network /usr/lib/systemd/network}"
    if [ "$n" -eq 0 ]; then
        rm -f "$dir"/*.network.d/"$NODE_ROUTE_DROPIN" 2>/dev/null || true
        return 0
    fi
    for f in $(for src in $srcs; do ls -1 "$src"/*.network 2>/dev/null; done); do
        [ -f "$f" ] || continue
        name="${f##*/}"
        case "$name" in 80-*|89-*|99-default*) continue ;; esac
        grep -qiE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|ipv4|1)[[:space:]]*$' "$f" || continue
        dd="$dir/$name.d"
        mkdir -p "$dd"
        printf '# vpn-node-stack: начальное окно TCP на DHCP-маршрутах (TCP_INITCWND, managed by node)\n[DHCPv4]\nInitialCongestionWindow=%s\nInitialAdvertisedReceiveWindow=%s\n' \
            "$n" "$n" | node_persist "$dd/$NODE_ROUTE_DROPIN"
        chmod 0644 "$dd/$NODE_ROUTE_DROPIN" 2>/dev/null || true
        cnt=$((cnt + 1))
    done
    [ "$cnt" -gt 0 ] && log info "route" "networkd: drop-in [DHCPv4] InitialCongestionWindow=$n для $cnt .network"
    return 0
}

# node_route_initcwnd_apply [runtime] — шаг apply; `runtime` — из rt-reapply (node-rt-tweaks при boot):
# только атрибут маршрута. Unit работает под ProtectSystem=strict (/etc только для чтения) — запись
# drop-in там роняла unit (лаба, первая перезагрузка 1.4.4: «mktemp … Read-only file system»);
# drop-in — забота apply, при boot networkd уже прочитал его сам.
node_route_initcwnd_apply() {
    local n c mode="${1:-}"
    n="$(node_route_initcwnd_value)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "route: would set initcwnd/initrwnd=$n на IPv4 default-маршрутах (0 = окно ядра)"
        return 0
    fi
    if [ "$n" -eq 0 ]; then
        c="$(node_route_initcwnd_set 0)"
        [ "$mode" = runtime ] || node_route_networkd_dropin 0
        [ "$c" -gt 0 ] && log info "route" "initcwnd/initrwnd сняты с $c маршрутов (TCP_INITCWND=0)"
        return 0
    fi
    c="$(node_route_initcwnd_set "$n")"
    [ "$mode" = runtime ] && { log info "route" "rt-reapply: initcwnd/initrwnd=$n на $c маршрутах"; return 0; }
    node_rt_record "-" route "default" "none"
    node_route_networkd_dropin "$n"
    if [ "$c" -gt 0 ]; then ok "route" "initcwnd/initrwnd=$n на $c маршрутах по умолчанию"
    else warn "route" "маршрутов по умолчанию IPv4 не найдено — initcwnd не выставлен"; fi
}

# node_route_initcwnd_rollback — rollback/uninstall: снять атрибуты и drop-in.
node_route_initcwnd_rollback() {
    node_route_initcwnd_set 0 >/dev/null
    node_route_networkd_dropin 0
}
