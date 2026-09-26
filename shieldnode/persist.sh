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

# shield_origin_record <dst> — состояние файла ДО первой записи shieldnode.
# Баг 2026-09-23 (подтверждён: apply x2 -> rollback): при повторном apply
# backup() сохраняет СОБСТВЕННУЮ прошлую версию, и rollback «восстанавливал»
# её (nft-persist, 99-z5 security sysctl, юниты переживали откат/ребут).
# Реестр: <path>\tcreated | <path>\t<копия>; путь в манифесте без записи =
# установка до v1.1.1 (legacy-логика rollback).
shield_origin_record() {
    local dst="$1" reg="$SHIELD_STATE_DIR/file-origins.tsv" copy
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    mkdir -p "$SHIELD_STATE_DIR"
    if [ -f "$reg" ] && awk -F'\t' -v p="$dst" '$1==p{f=1} END{exit !f}' "$reg"; then return 0; fi
    if [ -f "$SHIELD_MANIFEST" ] && grep -qxF -- "$dst" "$SHIELD_MANIFEST"; then return 0; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        mkdir -p "$SHIELD_STATE_DIR/origins"; chmod 0700 "$SHIELD_STATE_DIR/origins"
        copy="$SHIELD_STATE_DIR/origins/$(printf '%s' "$dst" | sha256sum | cut -c1-16)"
        cp -a -- "$dst" "$copy" || die "origin copy failed: $dst"
        printf '%s\t%s\n' "$dst" "$copy" >> "$reg"
    else
        printf '%s\tcreated\n' "$dst" >> "$reg"
    fi
}

# shield_persist_stream <dst> [mode] — stdin → backup → atomic write → manifest
shield_persist_stream() {
    local dst="$1" mode="${2:-0644}"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would write $dst"
        cat > /dev/null
        return 0
    fi
    shield_origin_record "$dst"
    # 2026-09-24 (v1.1.5): содержимое не изменилось — не переписываем и НЕ бэкапим.
    # Раньше каждый apply/rt-reapply делал .pre-shieldnode-* с идентичной копией: при
    # BACKUP_KEEP=5 пять повторных apply вытесняли все значимые старые версии.
    local _new
    mkdir -p -- "$(dirname "$dst")" 2>/dev/null || true
    _new="$(mktemp "$(dirname "$dst")/.shieldnode-new.XXXXXX")" || die "mktemp failed for $dst"
    cat > "$_new"
    if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$_new" "$dst"; then
        rm -f "$_new"
        chmod "$mode" "$dst" 2>/dev/null || true
        shield_manifest_record "$dst"
        log info "persist" "$dst (без изменений)"
        return 0
    fi
    # 2026-09-24 (v1.1.4): logrotate (и apt) читают ВСЕ файлы своих .d-каталогов — бэкап рядом с
    # СВОИМ (created) файлом logrotate принимал за второй конфиг: «duplicate log entry»,
    # rc=1. Исходное состояние такого файла — «отсутствует» (реестр происхождения;
    # rollback его удаляет), рядом-бэкапы не нужны — не кладём и убираем прежние.
    # Чужие (существовавшие до нас) файлы бэкапятся как раньше.
    case "$dst" in
        /etc/logrotate.d/*|/etc/apt/apt.conf.d/*)
            if awk -F'\t' -v p="$dst" '$1==p && $2=="created"{f=1} END{exit !f}' "$SHIELD_STATE_DIR/file-origins.tsv" 2>/dev/null; then
                rm -f -- "$dst".pre-shieldnode-* 2>/dev/null || true
            else
                backup "$dst"
            fi ;;
        *) backup "$dst" ;;
    esac
    atomic_write "$dst" "$mode" < "$_new"
    rm -f "$_new"
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
# 2026-09-25 (v1.2.0): правила — ДО настройки сети (было After=network-pre: интерфейс поднимался
# ~5 с раньше таблицы, DIAGNOSIS P0-2) и ПОСЛЕ nftables.service (его /etc/nftables.conf делает
# `flush ruleset` — запущенный позже, он стёр бы таблицу). До docker — remnanode стартует уже
# под защитой.
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service nftables.service
Before=network-pre.target docker.service shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
# delete (не destroy: destroy есть только в nft>=1.0.8, Debian 12 = 1.0.6) перед
# apply: иначе повторный старт службы упадёт на "File exists"
ExecStart=/bin/sh -c 'nft delete table inet shieldnode 2>/dev/null || true; nft -c -f /etc/nftables.d/shieldnode.conf && nft -f /etc/nftables.d/shieldnode.conf'
ExecReload=/bin/sh -c 'nft delete table inet shieldnode 2>/dev/null || true; nft -c -f /etc/nftables.d/shieldnode.conf && nft -f /etc/nftables.d/shieldnode.conf'
# Принципиально: никаких restart ssh/docker/xray — только загрузка правил.

[Install]
WantedBy=multi-user.target
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload
        # enable --now (а не только enable): иначе после install служба НЕ
        # стартует и применённые правила переживут только до ребута — до
        # вмешательства оператора firewall держался бы только в runtime.
        # start безопасен: правила уже применены (idempotent-triple в nft.sh
        # делает повторный apply атомарной заменой, не перерывом трафика).
        systemctl enable --now shieldnode.service >/dev/null 2>&1 \
            || log warn "persist" "systemctl enable --now shieldnode.service не удался"
    fi
    shield_persist_ports_service
}

# shield_persist_ports_service — 2026-09-25 (v1.2.0): ports-watch (DIAGNOSIS P0-2) — защищаемые
# порты следуют за реальностью (remnanode запущен/перенастроен панелью, UFW, config) без apply.
shield_persist_ports_service() {
    shield_persist_stream /etc/systemd/system/shieldnode-ports.service 0644 <<EOF
[Unit]
Description=shieldnode: защищаемые порты следуют за инбаундами Xray/UFW (ports-watch)
After=shieldnode.service docker.service
Wants=shieldnode.service

[Service]
Type=simple
ExecStart=/bin/bash $SHIELD_DIR/main.sh ports-watch
Restart=always
RestartSec=10
Nice=10
# принципиально: только чтение состояния и правка наборов nft — ssh/docker/xray не трогаем

[Install]
WantedBy=multi-user.target
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload
        systemctl enable shieldnode-ports.service >/dev/null 2>&1 || log warn "persist" "enable shieldnode-ports.service не удался"
        # restart: подхватить новый код после обновления (служба только читает и правит наборы)
        systemctl restart shieldnode-ports.service >/dev/null 2>&1 || log warn "persist" "restart shieldnode-ports.service не удался"
    fi
}

# shield_guard_link — symlink /usr/local/sbin/guard → main.sh: «пульт» одной
# командой, как в старой ветке. Цель — именно main.sh (не install.sh): после
# exec $0=main.sh, проверка basename=guard в main.sh не сработала бы и вместо
# дашборда запустился APPLY. Удаляется в rollback/uninstall вместе с остальными.
shield_guard_link() {
    local link="${SHIELD_GUARD_LINK:-/usr/local/sbin/guard}"
    local target="$SHIELD_DIR/main.sh"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would symlink $link -> $target"
        return 0
    fi
    mkdir -p "$(dirname "$link")" 2>/dev/null || true
    # 2026-09-23: symlink ведёт на main.sh — без exec-бита `guard` = Permission
    # denied (инцидент 2026-09-22 при доставке мимо vpn-node-setup: tar/git без +x)
    chmod +x "$target" 2>/dev/null || true
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        return 0
    fi
    shield_origin_record "$link"
    ln -sfn "$target" "$link" 2>/dev/null \
        && { shield_manifest_record "$link"; ok "persist" "$link -> main.sh (команда: guard)"; } \
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
        "net.ipv4.tcp_rfc1337=1|защита TIME_WAIT от RST-флуда (old fallback v5.0.4)"
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
        # 2026-09-23: исходное значение — в реестр ДО изменения (один раз на ключ;
        # ключ уже под shieldnode до v1.1.1 — не исходный, legacy-снапшот)
        local sreg="$SHIELD_STATE_DIR/sysctl-orig.tsv" cur
        mkdir -p "$SHIELD_STATE_DIR"; touch "$sreg"
        if ! awk -F'\t' -v k="$key" '$1==k{f=1} END{exit !f}' "$sreg" \
            && ! { [ -f "$SHIELD_STATE_DIR/owner-keys.txt" ] && grep -qxF -- "$key" "$SHIELD_STATE_DIR/owner-keys.txt"; } \
            && cur="$(sysctl -n "$key" 2>/dev/null)"; then
            printf '%s\t%s\n' "$key" "$cur" >> "$sreg"
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
# UDP_RATE=20000         # UDP-пакетов/с с одного IP (Hysteria2: ~9.3k pps на
# UDP_BURST=40000        #   100 Мбит/с; безопасный минимум после GRO-анализа —
#                        #   легитимный QUIC коалесцируется и считается заниженно,
#                        #   флуд с рандомных портов — по полному wire-pps)
# PROTECTED_TCP_EXTRA=   # доп. порты к авто-детекту
# PROTECTED_UDP_EXTRA=
# TRUSTED_IPS=           # доп. whitelist: "IP панели Remnawave, мониторинг" — через пробел
EOF
}
