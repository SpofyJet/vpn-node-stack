#!/bin/bash
# shieldnode — ssh.sh: anti-lockout (ТЗ §20). Приоритет «нет блокировки SSH»
# выше всего, кроме доступности сети: админ-сессия в whitelist ДО блокирующих
# правил, self-test через loopback-connect, runtime-whitelist сразу после apply.
set -euo pipefail

# shield_ssh_whitelist_admin_runtime — немедленно добавить admin IP в whitelist-set.
shield_ssh_whitelist_admin_runtime() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    if [ -n "$SH_F_ADMIN_V4" ]; then
        nft add element inet shieldnode whitelist_v4 "{ $SH_F_ADMIN_V4 }" 2>/dev/null \
            && log info "ssh" "admin $SH_F_ADMIN_V4 добавлен в whitelist_v4 (runtime)" || true
    fi
    if [ -n "${SH_F_ADMIN_V6:-}" ]; then
        nft add element inet shieldnode whitelist_v6 "{ $SH_F_ADMIN_V6 }" 2>/dev/null \
            && log info "ssh" "admin $SH_F_ADMIN_V6 добавлен в whitelist_v6 (runtime)" || true
    fi
}

# shield_ssh_self_test — sshd жив на loopback по каждому SSH-порту.
# bash /dev/tcp: TCP-handshake достаточно (sshd отвечает banner даже pre-auth).
shield_ssh_self_test() {
    local port fails=0
    for port in $SH_F_SSH_PORTS; do
        if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            log debug "ssh" "self-test: 127.0.0.1:$port reachable"
        else
            log error "ssh" "self-test: sshd НЕДОСТУПЕН на 127.0.0.1:$port"
            fails=$((fails+1))
        fi
    done
    return "$fails"
}

# shield_ssh_ports_summary — для status/логов.
shield_ssh_ports_summary() {
    echo "${SH_F_SSH_PORTS:-$(shield_detect_ssh_ports)}"
}
