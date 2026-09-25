#!/bin/bash
# shieldnode — detect.sh: снапшот окружения (read-only). Никаких изменений системы.
set -euo pipefail

SHIELD_PROTECTED_STATE="$SHIELD_STATE_DIR/protected-ports.txt"
# 2026-09-24 (v1.1.6): процессы VPN-ядра, чьи слушающие порты защищаются автоматически.
# rw-core — имя Xray в образе remnawave/node; sing-box/hysteria — отдельные Hysteria2-серверы.
SHIELD_VPN_PROC_RE='xray|rw-core|remnanode|sing-box|hysteria|v2ray'

# shield_detect_ufw_sources <tcp|udp> <порт> — 2026-09-25 (v1.2.0): IPv4-источники правил UFW
# «allow from X to any port P» (оператор явно ограничил порт) — для ограничения API ноды панелью.
shield_detect_ufw_sources() {
    local proto="$1" port="$2" d="${SHIELD_UFW_DIR:-/etc/ufw}"
    grep -qsE '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes' "$d/ufw.conf" || return 0
    awk -v pr="$proto" -v pt="$port" '
        $1 == "-A" && $2 == "ufw-user-input" {
            p = ""; dp = ""; src = ""; tgt = ""
            for (i = 3; i <= NF; i++) {
                if ($i == "-p") p = $(i + 1); else if ($i == "--dport") dp = $(i + 1)
                else if ($i == "-s") src = $(i + 1); else if ($i == "-j") tgt = $(i + 1)
            }
            if (p == pr && dp == pt && src != "" && src !~ /^0\.0\.0\.0\/0$/ && (tgt == "ACCEPT" || tgt ~ /^ufw-user-limit/)) print src
        }' "$d/user.rules" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'
    return 0
}

# shield_ss_public_ports — stdin: вывод ss -lnp; $1 = ERE по строке (процесс). Порты сокетов,
# слушающих НЕ только loopback (2026-09-24, v1.1.6: API Xray 127.0.0.1:10085 снаружи
# недоступен — защищать нечего). Колонки как в _ss_local_ports (первое поле адрес:порт).
shield_ss_public_ports() {
    awk -v re="$1" '$0 ~ re { for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) {
        a = $i; n = split(a, x, ":"); p = x[n]; sub(/:[0-9]+$/, "", a)
        if (a !~ /^(127\.|\[::1\]$|::1$)/ && a !~ /%lo$/) print p; break } }'
}

# shield_detect_vpn_listen <tcp|udp> — внешние порты, слушаемые VPN-ядром (v1.1.6)
# 2026-09-25 (v1.2.0): для UDP это НЕ инбаунды — у Xray каждый UDP-поток клиента (DNS, QUIC)
# открывает несвязанный wildcard-сокет на эфемерном порту, в `ss` неотличимый от инбаунда
# (DIAGNOSIS P0-1). Источник правды — shield_detect_inbounds; эта функция — только сырьё.
shield_detect_vpn_listen() {
    local f=-tlnp; [ "$1" = udp ] && f=-ulnp
    command -v ss >/dev/null 2>&1 || return 0
    { ss "$f" 2>/dev/null || true; } | shield_ss_public_ports "$SHIELD_VPN_PROC_RE" | sort -un | tr '\n' ' ' | sed 's/ $//'
}

# shield_xray_lsi_json — `api lsi` работающего Xray (JSON в stdout; пусто при недоступности).
# API remnanode — gRPC на абстрактном unix-сокете @xtls-api-<rnd> в сетевом namespace хоста
# (host network): находим сокет и процесс-владелец; в контейнере — docker exec того же бинаря,
# на хосте — сам бинарь. Вывод содержит пользователей инбаундов: парсится в памяти, в лог и
# файлы НЕ пишется. SHIELD_XRAY_LSI_FILE — фикстура для тестов.
shield_xray_lsi_json() {
    if [ -n "${SHIELD_XRAY_LSI_FILE:-}" ]; then cat "$SHIELD_XRAY_LSI_FILE" 2>/dev/null; return 0; fi
    command -v ss >/dev/null 2>&1 || return 0
    local line sock pid exe cid
    line="$( { ss -xlpH 2>/dev/null || true; } | grep -m1 -E '@xtls-api-[A-Za-z0-9_-]+' || true)"
    [ -n "$line" ] || return 0
    sock="$(grep -oE '@xtls-api-[A-Za-z0-9_-]+' <<<"$line" | head -1)"
    pid="$(grep -oE 'pid=[0-9]+' <<<"$line" | head -1 | cut -d= -f2)"
    [ -n "$sock" ] && [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"; exe="${exe% (deleted)}"
    [ -n "$exe" ] || return 0
    cid="$(grep -oE 'docker-[0-9a-f]{64}\.scope|/docker/[0-9a-f]{64}' "/proc/$pid/cgroup" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1 || true)"
    if [ -n "$cid" ] && command -v docker >/dev/null 2>&1; then
        timeout 15 docker exec "$cid" "$exe" api lsi --server="unix:$sock" -timeout 5 2>/dev/null || true
    elif [ -x "$exe" ]; then
        timeout 15 "$exe" api lsi --server="unix:$sock" -timeout 5 2>/dev/null || true
    fi
}

# shield_inbounds_from_lsi — stdin: JSON `api lsi`; stdout: строки «tcp|udp <порт|a-b>».
# Транспорт: список network прокси (shadowsocks/dokodemo) > протокол потока (kcp/quic/hysteria
# -> UDP) > тип прокси (hysteria/wireguard/tun -> UDP) > TCP. Loopback/unix-слушатели — мимо.
shield_inbounds_from_lsi() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def ports(pl):
    out = []
    if pl is None: return out
    if isinstance(pl, (int, float)): return [str(int(pl))]
    if isinstance(pl, str):
        for part in pl.replace(" ", "").split(","):
            if part: out.append(part)
        return out
    if isinstance(pl, list):
        for x in pl: out += ports(x)
        return out
    if isinstance(pl, dict):
        lo = pl.get("from", pl.get("From")); hi = pl.get("to", pl.get("To"))
        if lo is not None:
            return [str(int(lo))] if hi in (None, lo) else ["%d-%d" % (int(lo), int(hi))]
        for k in ("range", "Range", "ports", "portList"):
            if k in pl: return ports(pl[k])
    return out
UDP_STREAM = {"kcp", "mkcp", "quic", "hysteria", "hysteria2"}
for ib in (d or {}).get("inbounds") or []:
    rs = ib.get("receiverSettings") or {}; ps = ib.get("proxySettings") or {}
    listen = str(rs.get("listen") or "")
    if listen.startswith(("@", "/", "127.", "::1", "localhost")) or listen == "::1": continue
    pl = ports(rs.get("portList", rs.get("port")))
    if not pl: continue
    ptype = str(ps.get("_TypedMessage_") or ps.get("@type") or "").lower()
    nets = ps.get("network") or ps.get("networks") or []
    if isinstance(nets, str): nets = [n for n in nets.replace(" ", "").split(",") if n]
    nets = {str(n).lower() for n in nets}
    stream = str(((rs.get("streamSettings") or {}).get("protocolName")) or "").lower()
    if nets & {"tcp", "udp"}: tr = sorted(nets & {"tcp", "udp"})
    elif stream in UDP_STREAM: tr = ["udp"]
    elif any(k in ptype for k in ("hysteria", "wireguard", "tun")): tr = ["udp"]
    else: tr = ["tcp"]
    for t in tr:
        for p in pl: print(t, p)
' 2>/dev/null
}

# shield_detect_node_api_port — порт API remnanode (панель -> нода). Процесс rw-node; иначе
# NODE_PORT/APP_PORT контейнера remnanode или /opt/remnanode/.env (нода ещё не запущена).
shield_detect_node_api_port() {
    local p=""
    command -v ss >/dev/null 2>&1 && p="$( { ss -tlnpH 2>/dev/null || true; } | shield_ss_public_ports 'rw-node' | sort -un | head -1)"
    if [ -z "$p" ] && command -v docker >/dev/null 2>&1; then
        p="$(timeout 10 docker inspect remnanode --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | sed -nE 's/^(NODE_PORT|APP_PORT)=([0-9]+).*/\2/p' | head -1 || true)"
    fi
    if [ -z "$p" ]; then
        local f
        for f in "${SHIELD_REMNANODE_DIR:-/opt/remnanode}/.env" /opt/remnawave/node/.env; do
            [ -r "$f" ] || continue
            p="$(sed -nE 's/^[[:space:]]*(NODE_PORT|APP_PORT)[[:space:]]*=[[:space:]]*"?([0-9]+).*/\2/p' "$f" | head -1)"
            [ -n "$p" ] && break
        done
    fi
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && echo "$p"
    return 0
}

# shield_detect_inbounds — 2026-09-25 (v1.2.0): реальные инбаунды VPN-ядра (DIAGNOSIS P0-1).
# Глобалы: SH_IB_SOURCE api|heuristic|none, SH_IB_TCP, SH_IB_UDP, SH_IB_API_PORT.
#  api       — конфиг работающего Xray (`api lsi`) — источник правды;
#  heuristic — API нет: TCP-слушатели ядра как есть; UDP-сокет — только wildcard, стабилен в
#              двух замерах (SHIELD_DETECT_STABLE_DELAY, 3 с) И (есть TCP-слушатель ядра на том
#              же порту ИЛИ порт вне ip_local_port_range ИЛИ в ip_local_reserved_ports);
#  none      — ядро не слушает ничего (не запущено) — вызывающий берёт keep-last-good.
shield_detect_inbounds() {
    [ "${SH_IB_DONE:-0}" = 1 ] && return 0
    SH_IB_SOURCE=none SH_IB_TCP="" SH_IB_UDP="" SH_IB_API_PORT=""
    SH_IB_API_PORT="$(shield_detect_node_api_port)"
    local lsi rows
    lsi="$(shield_xray_lsi_json)"
    rows="$(printf '%s' "$lsi" | shield_inbounds_from_lsi)"
    if [ -n "$rows" ]; then
        SH_IB_SOURCE=api
        SH_IB_TCP="$(awk '$1 == "tcp" {print $2}' <<<"$rows" | sort -u | sort -n | tr '\n' ' ' | sed 's/ $//')"
        SH_IB_UDP="$(awk '$1 == "udp" {print $2}' <<<"$rows" | sort -u | sort -n | tr '\n' ' ' | sed 's/ $//')"
    else
        local t u1 u2 p lo hi resv keep=""
        t="$(shield_detect_vpn_listen tcp)"
        u1="$(shield_detect_vpn_listen udp)"
        if [ -n "$u1" ]; then
            sleep "${SHIELD_DETECT_STABLE_DELAY:-3}"
            u2="$(shield_detect_vpn_listen udp)"
            read -r lo hi < <(cat "${SHIELD_PROC_SYS:-/proc/sys}/net/ipv4/ip_local_port_range" 2>/dev/null || echo "32768 60999")
            resv=" $(tr ',' ' ' < "${SHIELD_PROC_SYS:-/proc/sys}/net/ipv4/ip_local_reserved_ports" 2>/dev/null || true) "
            for p in $u1; do
                case " $u2 " in *" $p "*) ;; *) continue ;; esac            # не стабилен — эфемерный
                if case " $t " in *" $p "*) true ;; *) false ;; esac \
                   || [ "$p" -lt "${lo:-32768}" ] || [ "$p" -gt "${hi:-60999}" ] \
                   || _shield_port_in_list "$p" "$resv"; then
                    keep="$keep $p"
                fi
            done
        fi
        if [ -n "$t$keep" ]; then SH_IB_SOURCE=heuristic; SH_IB_TCP="$t"; SH_IB_UDP="${keep# }"; fi
    fi
    SH_IB_DONE=1
    export SH_IB_SOURCE SH_IB_TCP SH_IB_UDP SH_IB_API_PORT SH_IB_DONE
}
# _shield_port_in_list <порт> "<список портов/диапазонов a-b через пробел>"
_shield_port_in_list() {
    local x
    for x in $2; do
        case "$x" in
            *-*) [ "$1" -ge "${x%-*}" ] && [ "$1" -le "${x#*-}" ] && return 0 ;;
            *)   [ "$1" = "$x" ] && return 0 ;;
        esac
    done
    return 1
}

# shield_port_valid <port|a-b> — 0 если порт 1-65535 или диапазон a-b (a<=b)
shield_port_valid() {
    local a b
    case "$1" in
        *-*) a="${1%-*}"; b="${1#*-}" ;;
        *)   a="$1"; b="$1" ;;
    esac
    [[ "$a" =~ ^[0-9]{1,5}$ && "$b" =~ ^[0-9]{1,5}$ ]] || return 1
    [ "$((10#$a))" -ge 1 ] && [ "$((10#$b))" -le 65535 ] && [ "$((10#$a))" -le "$((10#$b))" ]
}

# shield_detect_ufw_ports <tcp|udp> — 2026-09-24 (v1.1.6): порты, открытые оператором в UFW
# (allow/limit на вход). Раньше защищались только порты, которые В МОМЕНТ apply слушал
# xray/remnanode: при лежащем/ещё не поднятом контейнере и для порта API ноды (2222, его
# слушает процесс node, а не xray) protected_tcp сводился к SSH. Читаем правила из
# /etc/ufw/user{,6}.rules (формат iptables-save, без вызова ufw); только при ENABLED=yes.
# Диапазоны a:b -> a-b (сеты protected_* — interval). Правила без порта (allow from IP) — нет.
shield_detect_ufw_ports() {
    local proto="$1" d="${SHIELD_UFW_DIR:-/etc/ufw}"
    [ "$(shield_conf_get PROTECTED_FROM_UFW 1)" = "1" ] || return 0
    grep -qsE '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes' "$d/ufw.conf" || return 0
    cat "$d/user.rules" "$d/user6.rules" 2>/dev/null \
      | awk -v pr="$proto" '
          $1 == "-A" && ($2 == "ufw-user-input" || $2 == "ufw6-user-input") {
              p = ""; ports = ""; tgt = ""
              for (i = 3; i <= NF; i++) {
                  if ($i == "-p") p = $(i + 1)
                  else if ($i == "--dport" || $i == "--dports") ports = $(i + 1)
                  else if ($i == "-j") tgt = $(i + 1)
              }
              if (p != pr || ports == "") next
              if (tgt != "ACCEPT" && tgt !~ /^ufw6?-user-limit/) next
              n = split(ports, a, ",")
              for (j = 1; j <= n; j++) { gsub(":", "-", a[j]); print a[j] }
          }' \
      | while read -r p; do shield_port_valid "$p" && echo "$p"; done \
      | sort -u | sort -n | tr '\n' ' ' | sed 's/ $//'
    return 0
}

# --- обнаружение SSH-портов sshd (ТЗ §19): -p из /proc/<pid>/cmdline + ss fallback ---
shield_detect_ssh_ports() {
    local ports=""
    # 1) из cmdline запущенных sshd
    # 2026-09-25 (v1.2.0): только процессы sshd (pgrep), а не tr|grep по КАЖДОМУ процессу в /proc —
    # ~900 мс на ноде со 150 процессами, а функция зовётся в каждом проходе ports-watch
    if [ -d /proc ]; then
        local pid a port
        for pid in $(pgrep -f sshd 2>/dev/null || true); do
            [ -r "/proc/$pid/cmdline" ] || continue
            a="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
            port="$(printf '%s\n' "$a" | awk '/^-p$/{getline; print} /^-p[0-9]+/{print substr($0,3)}')"
            [ -n "$port" ] && ports="$ports $port"
        done
    fi
    # 2) fallback: слушающие сокеты sshd (ss)
    if [ -z "$ports" ] && command -v ss >/dev/null 2>&1; then
        # 2026-09-23 (v1.1.2): порт по первому полю адрес:порт, не $4 (см. _ss_local_ports)
        ports="$(ss -tlnp 2>/dev/null | _ss_local_ports sshd | sort -u | tr '\n' ' ')"
    fi
    # 3) fallback: конфиг
    if [ -z "$ports" ] && [ -r /etc/ssh/sshd_config ]; then
        ports="$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config | sort -u | tr '\n' ' ')"
    fi
    # 4) last resort
    [ -z "$ports" ] && ports="22"
    # shellcheck disable=SC2086
    echo $ports | tr ' ' '\n' | awk 'NF' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

# shield_valid_ip <addr> — 0 если синтаксически IPv4/IPv6 (перед подстановкой в nft).
shield_valid_ip() {
    local a="$1" o
    if [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        for o in ${a//./ }; do [ "$((10#$o))" -le 255 ] || return 1; done
        return 0
    fi
    [[ "$a" == *:* && "$a" =~ ^[0-9A-Fa-f:.]+$ ]]
}

# shield_valid_cidr <addr[/mask]> — 2026-09-24 (v1.1.6): для whitelist (TRUSTED_IPS, exclude.conf).
# Раньше значения шли в текст ruleset без проверки: опечатка -> nft -c отвергал ВЕСЬ apply,
# а 0.0.0.0/0 (валиден для nft) выводил весь интернет из-под лимитов и блок-листов.
# Маска: IPv4 /8../32, IPv6 /16../128 — шире whitelist не бывает осмысленным.
shield_valid_cidr() {
    local a="${1%/*}" m=""
    [[ "$1" == */* ]] && m="${1#*/}"
    shield_valid_ip "$a" || return 1
    [ -z "$m" ] && return 0
    [[ "$m" =~ ^[0-9]{1,3}$ ]] || return 1
    case "$a" in
        *:*) [ "$((10#$m))" -ge 16 ] && [ "$((10#$m))" -le 128 ] ;;
        *)   [ "$((10#$m))" -ge 8 ]  && [ "$((10#$m))" -le 32 ] ;;
    esac
}

# --- админ IP текущей сессии (anti-lockout, ТЗ §20): только если реально SSH-сессия ---
shield_detect_admin_ip() {
    local a=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        a="${SSH_CONNECTION%% *}"
    elif command -v ss >/dev/null 2>&1; then
        # fallback: sshd-сессии. Баг 2026-09-23: с явным `state established` ss НЕ
        # печатает колонку State (Recv-Q Send-Q Local Peer Process) — $5 был полем
        # Process ('users:(("sshd",...'): под sudo/su (SSH_CONNECTION сброшен) admin
        # не whitelist'ился вовсе, а мусор с ':' уходил в whitelist_v6 и nft -c
        # отвергал весь ruleset. Берём 2-е поле вида адрес:порт (1-е — Local) —
        # не зависит от набора колонок/версии iproute2. IPv6 [a::b]:p — скобки срезаем.
        a="$(ss -tnp state established 2>/dev/null \
            | awk '/sshd/{n=0; for (i=1; i<=NF; i++) if ($i ~ /:[0-9]+$/ && ++n==2) { print $i; break }}' \
            | sed -E -e 's/^\[([^]]+)\]:[0-9]+$/\1/' -e t -e 's/:[0-9]+$//' \
            | grep -vE '^(127\.|::1$|0\.0\.0\.0$)' | head -1 || true)"
    fi
    [ -n "$a" ] || return 0
    # 2026-09-25 (v1.1.7): IPv4-mapped (::ffff:1.2.3.4) — sshd слушает dual-stack [::]:22, и под sudo
    # (SSH_CONNECTION сброшен) ss отдаёт IPv4 админа в такой форме. Он уходил в admin6, а при
    # выключенном IPv6 v6-правил нет — админ НЕ попадал в whitelist вовсе (живая нода, apply из меню)
    case "$a" in ::ffff:*.*.*.*|::FFFF:*.*.*.*) a="${a#::[fF][fF][fF][fF]:}" ;; esac
    # в nft попадает только синтаксически валидный адрес
    if shield_valid_ip "$a"; then echo "$a"; else log warn "detect" "admin IP '$a' не похож на адрес — в whitelist НЕ добавлен"; fi
}

# --- защищаемые порты: ssh-порты + VIP-порты Xray (по слушающим процессам) ---
# keep-last-good: при пустой авто-детекции берём сохранённый прошлый список.
shield_detect_protected_ports() {
    local ports xports
    ports="$(shield_detect_ssh_ports)"
    # 2026-09-25 (v1.2.0): инбаунды — из конфига работающего Xray (shield_detect_inbounds);
    # порт API ноды (rw-node) — всегда, даже если панель ещё не прислала конфиг
    shield_detect_inbounds
    xports="$SH_IB_TCP"
    [ -n "$xports" ] && ports="$ports $xports"
    [ -n "$SH_IB_API_PORT" ] && ports="$ports $SH_IB_API_PORT"
    # 2026-09-24 (v1.1.5): keep-last-good по ЧАСТИ xray — SSH-порты в списке есть всегда,
    # и прежняя проверка «весь список пуст» не срабатывала: apply во время рестарта
    # xray/remnanode молча выводил VPN-порты из protected_tcp до следующего apply
    if [ -z "${xports:-}" ] && [ -s "$SHIELD_PROTECTED_STATE" ]; then
        ports="$ports $(cat "$SHIELD_PROTECTED_STATE")"
        log warn "detect" "VPN-ядро не слушает TCP (не запущено/нет конфига от панели) — keep-last-good: $(cat "$SHIELD_PROTECTED_STATE")"
    fi
    ports="$(echo "$ports" | tr ' ' '\n' | awk 'NF' | sort -un | tr '\n' ' ' | sed 's/ $//')"
    [ -n "$ports" ] && echo "$ports" > "$SHIELD_PROTECTED_STATE"
    # UFW-порты — после keep-last-good (живой источник, в state не пишем: снятое в UFW
    # правило не должно «залипать» в защищаемых портах)
    ports="$(echo "$ports $(shield_detect_ufw_ports tcp)" | tr ' ' '\n' | awk 'NF' | sort -un | tr '\n' ' ' | sed 's/ $//')"
    echo "$ports"
}

shield_detect() {
    local ts snap
    ts="$(date '+%Y%m%d-%H%M%S')"
    snap="$SHIELD_STATE_DIR/diagnostics/${ts}.txt"
    mkdir -p "$SHIELD_STATE_DIR/diagnostics"

    local fw="nft"
    command -v nft >/dev/null 2>&1 || fw="MISSING:nft"
    if command -v iptables >/dev/null 2>&1; then fw="$fw iptables:$(iptables --version 2>/dev/null | head -1)"; fi
    if command -v ufw >/dev/null 2>&1; then fw="$fw ufw:$(ufw status 2>/dev/null | head -1)"; fi

    local ipv6="no"
    [ -r /proc/net/if_inet6 ] && ipv6="yes"

    {
        echo "# shieldnode detect — $ts"
        echo "## system"
        uname -a
        echo "cpus: $(shield_cpu_count)"
        echo "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"
        echo
        echo "## firewall"
        echo "stack: $fw"
        echo "nft_table_inet_shieldnode: $(nft list table inet shieldnode >/dev/null 2>&1 && echo present || echo absent)"
        echo
        echo "## ssh"
        echo "ports: $(shield_detect_ssh_ports)"
        echo "admin_ip: ${SSH_CONNECTION:-<none>}"
        echo
        echo "## network"
        echo "ipv6: $ipv6"
        echo "default_iface: $(command -v ip >/dev/null 2>&1 && shield_default_iface)"
        echo "protected_ports: $(shield_detect_protected_ports)"
        echo
        echo "## docker (read-only, never modified)"
        echo "docker: $(command -v docker >/dev/null 2>&1 && systemctl is-active docker 2>/dev/null || echo absent)"
        echo
        echo "## sysctl-managed-baseline (shieldnode owner keys at detect time)"
        local keys_f="$SHIELD_STATE_DIR/owner-keys.txt"
        if [ -f "$keys_f" ]; then
            local k
            while read -r k; do
                [ -z "$k" ] && continue
                printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo '?')"
            done < "$keys_f"
        else
            echo "(owner-keys.txt ещё нет — первый запуск)"
        fi
        echo
        echo "## exclude (ТЗ §30)"
        if [ -f "$SHIELD_EXCLUDE" ]; then sed 's/^/  /' "$SHIELD_EXCLUDE"; else echo "  (no exclude.conf)"; fi
        echo
        echo "## emergency"
        echo "marker: $([ -f /run/shieldnode/emergency ] && echo ON || echo off)"
    } > "$snap"
    chmod 0640 "$snap"

    # ротация keep=10
    ls -1t "$SHIELD_STATE_DIR"/diagnostics/*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f

    export SHIELD_LAST_SNAPSHOT="$snap"
    log info "detect" "snapshot: $snap"
    echo "snapshot: $snap"
}
