#!/bin/bash
# shieldnode — detect.sh: снапшот окружения (read-only). Никаких изменений системы.
set -euo pipefail

SHIELD_PROTECTED_STATE="$SHIELD_STATE_DIR/protected-ports.txt"

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
        xports="$(ss -tulnp 2>/dev/null | _ss_local_ports 'xray|remnanode' | sort -un | tr '\n' ' ' | sed 's/ $//')"
        [ -n "$xports" ] && ports="$ports $xports"
    fi
    ports="$(echo "$ports" | tr ' ' '\n' | awk 'NF' | sort -un | tr '\n' ' ' | sed 's/ $//')"
    if [ -z "$ports" ] && [ -s "$SHIELD_PROTECTED_STATE" ]; then
        ports="$(cat "$SHIELD_PROTECTED_STATE")"
        log warn "detect" "protected ports auto-detect empty — keep-last-good: $ports"
    fi
    [ -n "$ports" ] && echo "$ports" > "$SHIELD_PROTECTED_STATE"
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
