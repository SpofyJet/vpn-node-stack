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

# shield_persist_remove <path...> — удалить СВОИ файлы (юниты и т.п.). 2026-10-08 (v1.2.5): единая
# точка, как shield_persist_stream: тесты подменяют обе и пишут/удаляют под $OUT. Раньше
# blocklist.sh делал `rm -f /etc/systemd/system/...` напрямую — test-blocklist.sh под root
# сносил живой crowdsec-таймер ноды.
shield_persist_remove() {
    local f
    for f in "$@"; do
        if [ "${DRY_RUN:-0}" = "1" ]; then log info "dry-run" "would remove $f"; continue; fi
        rm -f -- "$f"
    done
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
        # 2026-10-09 (v1.2.5): log_martians убран. UFW при старте применяет /etc/ufw/sysctl.conf
        # (log_martians=0) ПОСЛЕ systemd-sysctl — на живой ноде значение всё равно было 0; и это верно:
        # под spoofed-флудом каждый martian-пакет — строка в kern.log (rate-limit ядра общий на всё)
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
        # 2026-10-09 (v1.2.5): IPv6 выключен в ядре (ipv6.disable=1 — обязательный режим node) —
        # ключей net.ipv6.* нет вовсе; раньше каждый apply писал 4 warn «kernel отклонил»
        if [[ "$key" == net.ipv6.* ]] && [ ! -d "${SHIELD_PROC_SYS:-/proc/sys}/net/ipv6" ]; then
            log debug "sysctl" "skip $key — IPv6 выключен в ядре"
            continue
        fi
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
            # 2026-10-09: комментарий — отдельной строкой. sysctl.d(5) не знает хвостовых комментариев:
            # systemd-sysctl писал в ядро «0   # текст…» (журнал boot: Couldn't write '0  # не принимать…')
            printf '# %s\n%s\n' "$comment" "$kv"
        done
    } | shield_persist_stream "$SHIELD_SYSCTL_SECURITY" 0640
    # owner-keys для cross-check со стороны node (ТЗ §15/§21)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        for entry in "${accepted[@]}"; do echo "${entry%%|*}" | cut -d= -f1; done > "$SHIELD_STATE_DIR/owner-keys.txt"
    fi
}

# --- 2026-11-14 (v1.2.11): ранний фильтр на входе (spofy-guard; логика — earlyfilter.sh) ---
# Скрипт кладётся как есть, юниты — с теми же именами и тем же текстом, что при установке руками: на сервере,
# где фильтр уже включён, shield_persist_stream видит совпадение и ничего не переписывает.
SHIELD_EF_BIN="${SHIELD_EF_BIN:-/usr/local/sbin/spofy-guard}"
SHIELD_EF_UNITS="${SHIELD_UNIT_DIR:-/etc/systemd/system}"

# shield_manifest_forget <path...> — файл больше не наш: убрать из манифеста и реестра происхождения
# (иначе rollback «откатил» бы файл, который позже поставили руками).
shield_manifest_forget() {
    local f reg="$SHIELD_STATE_DIR/file-origins.tsv" tmp copy
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    for f in "$@"; do
        if [ -f "$SHIELD_MANIFEST" ] && grep -qxF -- "$f" "$SHIELD_MANIFEST"; then
            tmp="$(mktemp "$SHIELD_STATE_DIR/.manifest.XXXXXX")" || return 0
            grep -vxF -- "$f" "$SHIELD_MANIFEST" > "$tmp" || true
            mv "$tmp" "$SHIELD_MANIFEST"
        fi
        [ -f "$reg" ] || continue
        copy="$(awk -F'\t' -v p="$f" '$1==p{print $2; exit}' "$reg")"
        [ -n "$copy" ] || continue
        [ "$copy" = created ] || rm -f -- "$copy"
        tmp="$(mktemp "$SHIELD_STATE_DIR/.origins.XXXXXX")" || return 0
        awk -F'\t' -v p="$f" '$1!=p' "$reg" > "$tmp" || true
        mv "$tmp" "$reg"
    done
}

# shield_persist_earlyfilter — файл скрипта и юниты фильтра (без включения: порядок включения — earlyfilter.sh)
shield_persist_earlyfilter() {
    local src="${SHIELD_EF_SRC:-$SHIELD_DIR/spofy-guard}"   # переменная — для тестов
    [ -s "$src" ] || { log warn "persist" "нет $src — ранний фильтр не ставится (неполная копия стека?)"; return 1; }
    shield_persist_stream "$SHIELD_EF_BIN" 0755 < "$src"
    [ "$(shield_conf_get PERSIST_ENABLED 1)" = "1" ] || { log info "persist" "PERSIST_ENABLED=0 — юниты раннего фильтра пропущены (после перезагрузки сам не вернётся)"; return 0; }
    command -v systemctl >/dev/null 2>&1 || return 0
    shield_persist_stream "$SHIELD_EF_UNITS/spofy-guard.service" 0644 <<'EOF'
[Unit]
Description=Spofy guard: early filter at the node's network entry
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/spofy-guard ensure
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
EOF
    shield_persist_stream "$SHIELD_EF_UNITS/spofy-guard.timer" 0644 <<'EOF'
[Unit]
Description=Spofy guard: keep the table, add new listening ports, save memory to disk
[Timer]
OnBootSec=20s
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then systemctl daemon-reload 2>/dev/null || true; fi
}

# shield_persist_earlyfilter_enable — включить юниты фильтра. Звать ТОЛЬКО когда таблица уже стоит или
# её возвращает сам скрипт: таймер сразу зовёт `spofy-guard ensure`.
shield_persist_earlyfilter_enable() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -e "$SHIELD_EF_UNITS/spofy-guard.timer" ] || return 0
    systemctl enable spofy-guard.service >/dev/null 2>&1 || log warn "persist" "systemctl enable spofy-guard.service не удался"
    # enable --now без restart: у таймера OnBootSec — впервые запущенный, он срабатывает сразу, а уже
    # работающий (фильтр включён раньше) не трогаем
    systemctl enable --now spofy-guard.timer >/dev/null 2>&1 || log warn "persist" "systemctl enable --now spofy-guard.timer не удался"
}

# shield_persist_earlyfilter_remove — выключить и убрать юниты фильтра и файл скрипта
shield_persist_earlyfilter_remove() {
    local u
    if [ "${DRY_RUN:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        for u in spofy-guard.timer spofy-guard.service; do
            if [ -e "$SHIELD_EF_UNITS/$u" ]; then systemctl disable --now "$u" >/dev/null 2>&1 || true; fi
        done
    fi
    shield_persist_remove "$SHIELD_EF_UNITS/spofy-guard.service" "$SHIELD_EF_UNITS/spofy-guard.timer" "$SHIELD_EF_BIN"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        rm -f -- "$SHIELD_EF_BIN".pre-shieldnode-* "$SHIELD_EF_UNITS"/spofy-guard.service.pre-shieldnode-* \
                 "$SHIELD_EF_UNITS"/spofy-guard.timer.pre-shieldnode-* 2>/dev/null || true
        shield_manifest_forget "$SHIELD_EF_UNITS/spofy-guard.service" "$SHIELD_EF_UNITS/spofy-guard.timer" "$SHIELD_EF_BIN"
        if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload 2>/dev/null || true; fi
    fi
}

# shield_persist_earlyfilter_timer — свой таймер стека: раз в минуту проверяет наблюдение и включает отброс
# (earlyfilter.sh: tick). Живёт, только пока отброс не включён.
shield_persist_earlyfilter_timer() {
    [ "$(shield_conf_get PERSIST_ENABLED 1)" = "1" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    shield_persist_stream "$SHIELD_EF_UNITS/shieldnode-earlyfilter.service" 0644 <<EOF
[Unit]
Description=shieldnode: ранний фильтр — после наблюдения включить отброс (early-filter tick)
After=spofy-guard.service

[Service]
Type=oneshot
ExecStart=/bin/bash $SHIELD_DIR/main.sh early-filter tick
Nice=10
EOF
    shield_persist_stream "$SHIELD_EF_UNITS/shieldnode-earlyfilter.timer" 0644 <<'EOF'
[Unit]
Description=shieldnode: ранний фильтр — проверка наблюдения, пока отброс не включён

[Timer]
OnBootSec=2min
OnActiveSec=40s
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload 2>/dev/null || true
        # enable + restart: см. lib/blocklist.sh «активируем»
        { systemctl enable shieldnode-earlyfilter.timer >/dev/null 2>&1 && systemctl restart shieldnode-earlyfilter.timer >/dev/null 2>&1; } || \
            log warn "persist" "systemctl enable shieldnode-earlyfilter.timer не удался — отброс включит следующий apply"
    fi
}
shield_persist_earlyfilter_timer_remove() {
    [ -e "$SHIELD_EF_UNITS/shieldnode-earlyfilter.timer" ] || [ -e "$SHIELD_EF_UNITS/shieldnode-earlyfilter.service" ] || return 0
    if [ "${DRY_RUN:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1 && [ -e "$SHIELD_EF_UNITS/shieldnode-earlyfilter.timer" ]; then
        systemctl disable --now shieldnode-earlyfilter.timer >/dev/null 2>&1 || true
    fi
    shield_persist_remove "$SHIELD_EF_UNITS/shieldnode-earlyfilter.service" "$SHIELD_EF_UNITS/shieldnode-earlyfilter.timer"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        shield_manifest_forget "$SHIELD_EF_UNITS/shieldnode-earlyfilter.service" "$SHIELD_EF_UNITS/shieldnode-earlyfilter.timer"
        if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload 2>/dev/null || true; fi
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
# TCP_NEW_RATE=40000     # новых коннектов/мин с одного IP: лишние отбрасываются, IP не банится
# TCP_SYN_RATE=2000      # SYN/с с одного IP: лишние отбрасываются, IP не банится
# TCP_SYN_BAN_RATE=0     # >0 — банить IP за SYN-флуд выше этого (SYN/с); 0 = никогда не банить
# TCP_CONN_MAX=15000     # conntrack-лимит с одного IP (CGNAT-лояльно)
# UDP_RATE=20000         # UDP-пакетов/с с одного IP, лишние отбрасываются без бана (Hysteria2: ~9.3k pps на
# UDP_BURST=40000        #   100 Мбит/с; безопасный минимум после GRO-анализа —
#                        #   легитимный QUIC коалесцируется и считается заниженно,
#                        #   флуд с рандомных портов — по полному wire-pps)
# PROTECTED_TCP_EXTRA=   # доп. порты к авто-детекту
# PROTECTED_UDP_EXTRA=
# TRUSTED_IPS=           # доп. whitelist: "IP панели Remnawave, мониторинг" — через пробел
# ENABLE_EARLY_FILTER=1  # ранний фильтр на входе (spofy-guard); 0 — стек его не ставит и свой снимает
# EARLY_FILTER_MODE=auto # observe — держать ранний фильтр в наблюдении (серверы с docker / пробросом портов)
EOF
}
