#!/bin/bash
# shieldnode — persist.sh: единая точка записи (backup + atomic + manifest),
# persist nft-файла, службы, security-sysctl. Никаких net.netfilter.* (ТЗ §15).
set -euo pipefail

SHIELD_MANIFEST="$SHIELD_STATE_DIR/applied-files.txt"
SHIELD_NFT_PERSIST=/etc/nftables.d/shieldnode.conf
SHIELD_SYSCTL_SECURITY=/etc/sysctl.d/99-z5-shieldnode-security.conf

shield_manifest_record() {
    local dst="$1"
    mkdir -p "$SHIELD_STATE_DIR"
    touch "$SHIELD_MANIFEST"
    grep -qxF -- "$dst" "$SHIELD_MANIFEST" || echo "$dst" >> "$SHIELD_MANIFEST"
}

# shield_persist_stream <dst> [mode] — stdin → backup → atomic write → manifest
shield_persist_stream() {
    local dst="$1" mode="${2:-0644}"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would write $dst"
        cat > /dev/null
        return 0
    fi
    backup "$dst"
    atomic_write "$dst" "$mode"
    shield_manifest_record "$dst"
    ok "persist" "$dst"
}

# shield_persist_nft <runtime-ruleset-file> — копия применённого ruleset для boot.
shield_persist_nft() {
    local src="$1"
    shield_persist_stream "$SHIELD_NFT_PERSIST" 0640 < "$src"
}

# shield_persist_service — oneshot-служба загрузки правил при boot (ТЗ §26).
shield_persist_service() {
    shield_persist_stream /etc/systemd/system/shieldnode.service 0644 <<'EOF'
[Unit]
Description=shieldnode firewall rules (nftables)
Documentation=file:/etc/shieldnode/config.conf
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
# destroy перед apply: иначе повторный старт службы упадёт на "File exists"
ExecStart=/bin/sh -c 'nft destroy table inet shieldnode 2>/dev/null || true; nft -c -f /etc/nftables.d/shieldnode.conf && nft -f /etc/nftables.d/shieldnode.conf'
ExecReload=/bin/sh -c 'nft destroy table inet shieldnode 2>/dev/null || true; nft -c -f /etc/nftables.d/shieldnode.conf && nft -f /etc/nftables.d/shieldnode.conf'
# Принципиально: никаких restart ssh/docker/xray — только загрузка правил.

[Install]
WantedBy=multi-user.target
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload
        systemctl enable shieldnode.service >/dev/null 2>&1 || log warn "persist" "systemctl enable shieldnode.service не удался"
    fi
}

# shield_guard_link — symlink /usr/local/sbin/guard → install.sh: «пульт» одной командой,
# как в старой ветке. Удаляется в rollback/uninstall вместе с остальными файлами.
shield_guard_link() {
    local link="${SHIELD_GUARD_LINK:-/usr/local/sbin/guard}"
    local target="$SHIELD_DIR/install.sh"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would symlink $link -> $target"
        return 0
    fi
    mkdir -p "$(dirname "$link")" 2>/dev/null || true
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        return 0
    fi
    ln -sfn "$target" "$link" 2>/dev/null \
        && { shield_manifest_record "$link"; ok "persist" "$link -> install.sh (команда: guard)"; } \
        || log warn "persist" "symlink $link не создан"
}

# shield_logrotate_persist — ротация лога (без неё shieldnode.log растёт бесконечно)
shield_logrotate_persist() {
    {
        echo "# shieldnode — ротация лога (managed by shieldnode)"
        echo "${SHIELD_LOG} {"
        echo "    size 10M"
        echo "    rotate 4"
        echo "    compress"
        echo "    missingok"
        echo "    notifempty"
        echo "    copytruncate"
        echo "}"
    } | shield_persist_stream /etc/logrotate.d/shieldnode
}

# shield_persist_security_sysctl — ТЗ §22/§25: security-sysctl БЕЗ conntrack.
# Каждый ключ: probe через sysctl -w (runtime), в файл попадают только
# принятые ядром значения; чужие ключи (node) — skip.
shield_persist_security_sysctl() {
    local plan=(
        "net.ipv4.conf.all.rp_filter=1|martian/spoof защита: пакеты с невозможным обратным маршрутом drop"
        "net.ipv4.conf.default.rp_filter=1|то же для новых интерфейсов"
        "net.ipv4.icmp_echo_ignore_broadcasts=1|smurf-защита: не отвечать на broadcast ping"
        "net.ipv4.icmp_ignore_bogus_error_responses=1|не отвечать на некорректные ICMP errors"
        "net.ipv4.conf.all.log_martians=1|логировать martian-пакеты (видимость, ТЗ §27)"
        "net.ipv4.conf.default.log_martians=1|то же для новых интерфейсов"
        "net.ipv4.conf.all.accept_redirects=0|не принимать ICMP redirects (MITM-вектор)"
        "net.ipv4.conf.default.accept_redirects=0|то же для новых интерфейсов"
        "net.ipv4.conf.all.secure_redirects=0|и «secure» redirects тоже не принимать"
        "net.ipv4.conf.default.secure_redirects=0|то же для новых интерфейсов"
        "net.ipv4.conf.all.send_redirects=0|не слать redirects (нода не роутер для клиентов)"
        "net.ipv4.conf.default.send_redirects=0|то же для новых интерфейсов"
        "net.ipv4.conf.all.accept_source_route=0|source-routed пакеты запрещены"
        "net.ipv4.conf.default.accept_source_route=0|то же для новых интерфейсов"
        "net.ipv6.conf.all.accept_redirects=0|не принимать ICMPv6 redirects"
        "net.ipv6.conf.default.accept_redirects=0|то же для новых интерфейсов"
        "net.ipv6.conf.all.accept_source_route=0|source-routed пакеты запрещены"
        "net.ipv6.conf.default.accept_source_route=0|то же для новых интерфейсов"
    )
    local kv comment key val accepted=()
    for entry in "${plan[@]}"; do
        kv="${entry%%|*}"; comment="${entry#*|}"
        key="${kv%%=*}"; val="${kv#*=}"
        if ! validate_key_ownership "$key"; then
            log warn "sysctl" "skip $key — владелец node (реестр), не трогаем"
            continue
        fi
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log info "dry-run" "sysctl $key=$val  # $comment"
            accepted+=("$entry")
            continue
        fi
        if sysctl -w "$key=$val" >/dev/null 2>&1; then
            accepted+=("$entry")
            log debug "sysctl" "runtime ok: $key=$val"
        else
            log warn "sysctl" "kernel отклонил $key=$val — не персистим"
        fi
    done
    # генерация файла
    {
        echo "# shieldnode security sysctl (ТЗ §22/§25) — БЕЗ net.netfilter.* (владелец node, §15)"
        echo "# Сгенерировано shieldnode v$SHIELD_VERSION"
        for entry in "${accepted[@]}"; do
            kv="${entry%%|*}"; comment="${entry#*|}"
            printf '%-55s # %s\n' "$kv" "$comment"
        done
    } | shield_persist_stream "$SHIELD_SYSCTL_SECURITY" 0640
    # owner-keys для cross-check со стороны node (ТЗ §15/§21)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        for entry in "${accepted[@]}"; do echo "${entry%%|*}" | cut -d= -f1; done > "$SHIELD_STATE_DIR/owner-keys.txt"
    fi
}

# shield_config_ensure — создать шаблон /etc/shieldnode/config.conf (0640), если нет.
shield_config_ensure() {
    [ -f "$SHIELD_CONFIG" ] && return 0
    shield_persist_stream "$SHIELD_CONFIG" 0640 <<'EOF'
# shieldnode — декларативный конфиг (ТЗ §28). Пустое значение = авто.
# SSH_PORT=22            # не задано — авто-детект sshd
# ENABLE_SSH_PROTECTION=1
# ENABLE_INVALID_DROP=1
# ENABLE_LOOPBACK=1
# ENABLE_ESTABLISHED=1
# ENABLE_ABUSE_LIMITING=1
# SSH_CONN_MAX=8
# SSH_NEW_RATE=10        # новых SSH-коннектов/мин с одного IP, burst 20
# TCP_NEW_RATE=300       # новых коннектов/мин с одного IP на защищённые TCP-порты
# TCP_SYN_RATE=50        # SYN/с с одного IP
# TCP_CONN_MAX=15000     # conntrack-лимит с одного IP (CGNAT-лояльно)
# UDP_RATE=500           # UDP-пакетов/с с одного IP
# PROTECTED_TCP_EXTRA=   # доп. порты к авто-детекту
# PROTECTED_UDP_EXTRA=
# TRUSTED_IPS=           # доп. whitelist: "IP панели Remnawave, мониторинг" — через пробел
EOF
}
