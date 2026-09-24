#!/bin/bash
# shieldnode — detect.sh: снапшот окружения (read-only). Никаких изменений системы.
set -euo pipefail

SHIELD_PROTECTED_STATE="$SHIELD_STATE_DIR/protected-ports.txt"
# 2026-09-24 (v1.1.6): процессы VPN-ядра, чьи слушающие порты защищаются автоматически.
# rw-core — имя Xray в образе remnawave/node; sing-box/hysteria — отдельные Hysteria2-серверы.
SHIELD_VPN_PROC_RE='xray|rw-core|remnanode|sing-box|hysteria|v2ray'

# shield_ss_public_ports — stdin: вывод ss -lnp; $1 = ERE по строке (процесс). Порты сокетов,
# слушающих НЕ только loopback (2026-09-24, v1.1.6: API Xray 127.0.0.1:10085 снаружи
# недоступен — защищать нечего). Колонки как в _ss_local_ports (первое поле адрес:порт).
shield_ss_public_ports() {
    awk -v re="$1" '$0 ~ re { for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) {
        a = $i; n = split(a, x, ":"); p = x[n]; sub(/:[0-9]+$/, "", a)
        if (a !~ /^(127\.|\[::1\]$|::1$)/ && a !~ /%lo$/) print p; break } }'
}

# shield_detect_vpn_listen <tcp|udp> — внешние порты, слушаемые VPN-ядром (v1.1.6)
shield_detect_vpn_listen() {
    local f=-tlnp; [ "$1" = udp ] && f=-ulnp
    command -v ss >/dev/null 2>&1 || return 0
    { ss "$f" 2>/dev/null || true; } | shield_ss_public_ports "$SHIELD_VPN_PROC_RE" | sort -un | tr '\n' ' ' | sed 's/ $//'
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
    if [ -d /proc ]; then
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue
            if tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "sshd"; then
                local a port
                a="$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null)"
                port="$(printf '%s\n' "$a" | awk '/^-p$/{getline; print} /^-p[0-9]+/{print substr($0,3)}')"
                [ -n "$port" ] && ports="$ports $port"
            fi
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
    # в nft попадает только синтаксически валидный адрес
    if shield_valid_ip "$a"; then echo "$a"; else log warn "detect" "admin IP '$a' не похож на адрес — в whitelist НЕ добавлен"; fi
}

# --- защищаемые порты: ssh-порты + VIP-порты Xray (по слушающим процессам) ---
# keep-last-good: при пустой авто-детекции берём сохранённый прошлый список.
shield_detect_protected_ports() {
    local ports
    ports="$(shield_detect_ssh_ports)"
    if command -v ss >/dev/null 2>&1; then
        local xports
        xports="$(shield_detect_vpn_listen tcp)"
        [ -n "$xports" ] && ports="$ports $xports"
    fi
    # 2026-09-24 (v1.1.5): keep-last-good по ЧАСТИ xray — SSH-порты в списке есть всегда,
    # и прежняя проверка «весь список пуст» не срабатывала: apply во время рестарта
    # xray/remnanode молча выводил VPN-порты из protected_tcp до следующего apply
    if [ -z "${xports:-}" ] && [ -s "$SHIELD_PROTECTED_STATE" ]; then
        ports="$ports $(cat "$SHIELD_PROTECTED_STATE")"
        log warn "detect" "xray/remnanode не слушает TCP — keep-last-good: $(cat "$SHIELD_PROTECTED_STATE")"
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
