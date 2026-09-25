#!/bin/bash
# shieldnode — firewall.sh: сборка, атомарное применение (ТЗ §26), self-test,
# auto-rollback при потере SSH-доступа, контракт владения (ТЗ §15).
set -euo pipefail

SHIELD_BACKUP_DIR="$SHIELD_STATE_DIR/backups"

# 2026-09-24 (v1.1.6): дампы ruleset'а (~1МБ с блок-листами) писались на КАЖДЫЙ apply без
# ротации (живая нода: 21 файл, 13МБ) и были world-readable 0644 — внутри whitelist (IP
# админа, TRUSTED_IPS = IP панели). Теперь каталог 0700, файлы 0600, хранится BACKUP_KEEP
# последних (отдельно для обычных и emergency-дампов; только что записанный — самый новый).
shield_backup_dir_prep() {
    mkdir -p "$SHIELD_BACKUP_DIR"
    chmod 0700 "$SHIELD_BACKUP_DIR" 2>/dev/null || true
    chmod 0600 "$SHIELD_BACKUP_DIR"/*.nft 2>/dev/null || true
}
shield_backup_prune() {
    local keep; keep="$(shield_conf_get BACKUP_KEEP 5)"
    case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
    [ "$keep" -ge 1 ] || keep=1
    # `|| true`: пустой каталог -> ls rc 2, под pipefail+errexit это молча убивало apply
    # shellcheck disable=SC2012
    ls -1t "$SHIELD_BACKUP_DIR"/[0-9]*.nft 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f || true
    # shellcheck disable=SC2012
    ls -1t "$SHIELD_BACKUP_DIR"/emergency-*.nft 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f || true
    return 0
}

# shield_nft_available — жёсткое требование nftables (ТЗ §4: без iptables-fallback).
shield_nft_available() {
    command -v nft >/dev/null 2>&1 || die "nft не найден. Требуется nftables (apt install nftables / yum install nftables)."
}

# shield_table_dump <dst> — дамп текущей таблицы (для auto-rollback), 0 даже если нет.
shield_table_dump() {
    local dst="$1"
    if nft list table inet shieldnode > "$dst" 2>/dev/null; then
        return 0
    fi
    : > "$dst"
    return 1
}

# shield_contract_write — [shieldnode] в /etc/node-profile.d/stack.conf (schema v2, ТЗ §15).
# Путь — ЛИТЕРАЛ: переменная NODE_PROFILE_DIR живёт только в процессе node,
# в shieldnode её нет (unbound-баг 2026-09-22 в rollback/contract).
shield_contract_write() {
    local conf="/etc/node-profile.d/stack.conf"
    mkdir -p "/etc/node-profile.d" 2>/dev/null || true
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "contract: append [shieldnode] to $conf"
        return 0
    fi
    # 2026-09-23: mktemp в каталоге назначения (как в node) — mv из /tmp не атомарен
    local tmp; tmp="$(mktemp "/etc/node-profile.d/.stack.conf.XXXXXX")"
    if [ -f "$conf" ]; then
        awk '/^\[shieldnode\]/{skip=1; next} /^\[/{skip=0} !skip' "$conf" > "$tmp" || true
    fi
    {
        echo "[shieldnode]"
        echo "version=$SHIELD_VERSION"
        echo "table=inet/shieldnode"
        echo "conntrack_owner=no (node)"
        # 2026-09-25 (v1.2.0): реальные порты для node (ip_local_reserved_ports) — DIAGNOSIS P0-1
        echo "ssh_ports=${SH_F_SSH_PORTS:-}"
        echo "inbound_tcp=${SH_IB_TCP:-}"
        echo "inbound_udp=${SH_IB_UDP:-}"
        echo "node_api_port=${SH_IB_API_PORT:-}"
        echo "updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >> "$tmp"
    chmod 0644 "$tmp"; mv "$tmp" "$conf"
    ok "contract" "$conf [shieldnode] written"
}

# shield_self_test — проверки после apply (ТЗ §27/§31). 0 = ок, 1 = провал.
shield_self_test() {
    local fails=0
    # 1. таблица и цепочки существуют
    nft list table inet shieldnode >/dev/null 2>&1 || { log error "selftest" "таблица inet shieldnode отсутствует"; fails=$((fails+1)); }
    for c in prerouting; do
        nft list chain inet shieldnode "$c" >/dev/null 2>&1 || { log error "selftest" "цепочка $c отсутствует"; fails=$((fails+1)); }
    done
    # 2. наборы существуют
    local s
    for s in whitelist_v4 protected_tcp ssh_abusers tcp_abusers udp_abusers temporary_blocklist ssh_connlimit tcp_connlimit; do
        nft list set inet shieldnode "$s" >/dev/null 2>&1 || { log error "selftest" "набор $s отсутствует"; fails=$((fails+1)); }
    done
    # 3. SSH локально жив (anti-lockout, ТЗ §20): tcp-connect на loopback по каждому SSH-порту
    shield_ssh_self_test || fails=$((fails+1))
    # 4. cross-ownership (ТЗ §15): в нашем реестре нет net.netfilter.*
    if grep -qsE '^net\.(ipv4|ipv6)\.netfilter\.' "$SHIELD_STATE_DIR/owner-keys.txt"; then
        log error "selftest" "наш owner-keys содержит net.netfilter.* — нарушение §15"; fails=$((fails+1))
    fi
    # 5. снапшот detect существует
    [ -n "${SHIELD_LAST_SNAPSHOT:-}" ] && [ -f "${SHIELD_LAST_SNAPSHOT:-}" ] || { log error "selftest" "снапшот detect не найден"; fails=$((fails+1)); }
    return "$fails"
}

# 2026-09-24 (v1.1.5): перенос активных банов через apply. Замена таблицы
# (table/delete/table) обнуляла динамические сеты — каждый apply/emergency off
# снимал все баны abusers и ручные temporary_blocklist (живая нода: бан
# 133.18.122.63 пропал). Дамп: адрес + ОСТАТОК срока (expires) -> батч на сет.
SHIELD_CARRY_SETS="ssh_abusers ssh_abusers_v6 tcp_abusers tcp_abusers_v6 udp_abusers udp_abusers_v6 temporary_blocklist temporary_blocklist_v6"
shield_bans_carry_dump() { # <dir> — файл <dir>/<set>.nft на каждый непустой сет
    local dir="$1" s out
    mkdir -p "$dir"
    for s in $SHIELD_CARRY_SETS; do
        out="$(nft list set inet shieldnode "$s" 2>/dev/null)" || continue
        [[ "$out" == *elements* ]] || continue
        printf '%s\n' "$out" | awk -v s="$s" '
            /elements = \{/ { f = 1; sub(/.*elements = \{/, "") }
            f { e = $0; if (e ~ /\}/) { sub(/\}.*/, "", e); f = 0 }
                n = split(e, a, ",")
                for (i = 1; i <= n; i++) {
                    m = split(a[i], w, " "); if (w[1] !~ /^[0-9a-fA-F:.\/]+$/) continue
                    t = ""; for (j = 2; j < m; j++) if (w[j] == "expires" && w[j + 1] ~ /^[0-9dhms]+$/) t = w[j + 1]
                    printf "add element inet shieldnode %s { %s%s }\n", s, w[1], (t != "" ? " timeout " t : "")
                } }' > "$dir/$s.nft"
        [ -s "$dir/$s.nft" ] || rm -f "$dir/$s.nft"
    done
}
shield_bans_carry_restore() { # <dir> — best-effort: отказ по сету -> warn, apply не падает
    local dir="$1" f s n=0 bad=0
    for f in "$dir"/*.nft; do
        [ -e "$f" ] || continue
        s="$(basename "$f" .nft)"
        nft list set inet shieldnode "$s" >/dev/null 2>&1 || { bad=$((bad + 1)); continue; }   # сет выключен в новом ruleset
        if nft -f "$f" 2>/dev/null; then n=$((n + $(wc -l < "$f"))); else bad=$((bad + 1)); fi
    done
    [ "$n" -gt 0 ] && log info "apply" "активные баны перенесены через apply: $n (с остатком срока)"
    [ "$bad" -gt 0 ] && log warn "apply" "баны $bad сет(ов) не перенесены (сет выключен в новом ruleset или отказ nft)"
    rm -rf "$dir"
}

# shield_apply — полный цикл apply (режим по умолчанию, ТЗ §4/§26).
shield_apply() {
    shield_nft_available

    # §7: снапшот окружения до изменений
    shield_detect

    # §28: резолв числовых лимитов и наборов
    shield_limits_resolve

    # §28: шаблон конфига (если отсутствует)
    shield_config_ensure

    # --- сборка ruleset во временный файл ---
    local tmp
    tmp="$(mktemp /run/shieldnode-apply.XXXXXX.nft)"
    shield_nft_build_ruleset > "$tmp"

    if [ "$DRY_RUN" = "1" ]; then
        log info "dry-run" "ruleset ($(wc -l < "$tmp") строк):"
        cat "$tmp"
        log info "dry-run" "persist: $SHIELD_NFT_PERSIST, shieldnode.service, $SHIELD_SYSCTL_SECURITY, cleanup-timer"
        rm -f "$tmp"
        return 0
    fi

    # --- атомарная проверка ДО разрушения текущего состояния (ТЗ §26) ---
    if ! nft -c -f "$tmp" 2>"$tmp.err"; then
        # stderr nft — в консоль и лог, иначе диагностика теряется ("см. выше" — пусто)
        sed 's/^/  nft: /' "$tmp.err" >&2 || true
        log error "firewall" "nft -c rejected ruleset: $(tr '\n' ';' < "$tmp.err" | cut -c1-400)"
        rm -f "$tmp" "$tmp.err"
        die "nft -c: сгенерированный ruleset не проходит проверку (причина выше)"
    fi
    rm -f "$tmp.err"

    # --- backup текущей таблицы для auto-rollback ---
    shield_backup_dir_prep
    local ts bdump
    ts="$(date '+%Y%m%d-%H%M%S')"
    bdump="$SHIELD_BACKUP_DIR/${ts}.nft"
    ( umask 077; shield_table_dump "$bdump" ) || log info "apply" "таблицы inet shieldnode ещё не было — чистый старт"
    shield_backup_prune
    # 2026-09-24 (v1.1.5): журнал abuse и дамп банов — ДО замены таблицы (после неё
    # динамические сеты пусты; раньше журнал писался уже по пустым сетам)
    local carry="$tmp.carry"
    if [ -s "$bdump" ]; then
        declare -F shield_abuse_journal_append >/dev/null && { shield_abuse_journal_append || true; }
        shield_bans_carry_dump "$carry" || true
    fi

    # --- применение: внешний destroy УБРАН — ruleset начинается с тройки
    # table/delete/table, замена атомарна одной транзакцией nft -f (ТЗ §26).
    # Это закрывает и meter EBUSY на re-apply, и fail-open окно destroy→create.
    if ! nft -f "$tmp" 2>"$tmp.err"; then
        # stderr nft — в консоль и лог, иначе диагностика теряется (как у nft -c выше)
        sed 's/^/  nft: /' "$tmp.err" >&2 || true
        # ядро отвергло ruleset (parse-check не ловит kernel-side): восстанавливаем backup
        log error "apply" "nft -f отклонён ядром: $(tr '\n' ';' < "$tmp.err" | cut -c1-400) — откат к предыдущему ruleset"
        if [ -s "$bdump" ]; then
            # delete перед restore: поверх ЖИВОЙ таблицы restore падает (meter EBUSY)
            nft delete table inet shieldnode 2>/dev/null || true
            nft -f "$bdump" || shield_emergency on "apply rejected and backup restore failed"
            rm -rf "$tmp" "$tmp.err" "$carry"
            die "nft -f failed: ядро отклонило ruleset; восстановлен предыдущий ruleset"
        fi
        rm -rf "$tmp" "$tmp.err" "$carry"
        die "nft -f failed: ядро отклонило ruleset; предыдущей таблицы не было — firewall не активен (fail-open)"
    fi
    rm -f "$tmp.err"
    [ -d "$carry" ] && shield_bans_carry_restore "$carry"
    shield_ssh_whitelist_admin_runtime

    # --- self-test; при провале — auto-rollback (ТЗ §20/§27) ---
    if ! shield_self_test; then
        log error "apply" "SELF-TEST ПРОВАЛЕН — откат к предыдущему ruleset"
        # delete перед restore: поверх ЖИВОЙ новой таблицы restore из bdump падает (meter EBUSY)
        nft delete table inet shieldnode 2>/dev/null || true
        if [ -s "$bdump" ]; then
            nft -f "$bdump" || shield_emergency on "self-test failed and backup restore failed"
        fi
        rm -f "$tmp"
        die "self-test failed — состояние откачено (backup: $bdump)"
    fi

    # --- persist (ТЗ §26) ---
    shield_persist_nft "$tmp"
    shield_persist_service
    shield_persist_security_sysctl
    shield_logrotate_persist
    shield_cleanup_timer_install
    # crowdsec agent-режим (БЕЗ аккаунта): демон + анонимная CAPI-регистрация.
    # До blocklist_install — updater сразу читает cscli decisions.
    if [ "${SH_F_ENABLE_CROWDSEC_LIST:-0}" = "1" ] && [ "$(shield_crowdsec_resolve_mode)" = "agent" ]; then
        shield_crowdsec_agent_ensure || true
    fi
    # таблица пересоздана с пустыми наборами — метки «уже применено» больше не правда (P1-3)
    rm -f "${SHIELD_BLOCKLIST_STATE:-/var/lib/shieldnode/blocklists}"/.applied-*.sha256 2>/dev/null || true
    shield_blocklist_install
    shield_guard_link
    rm -f "$tmp"

    # --- контракт владения (ТЗ §15) ---
    shield_contract_write

    ok "apply" "shieldnode применён: ssh=[$SH_F_SSH_PORTS] protected_tcp=[$SH_F_PROTECTED_TCP] protected_udp=[$SH_F_PROTECTED_UDP] admin4=[$SH_F_ADMIN_V4] admin6=[$SH_F_ADMIN_V6]"
    log info "apply" "backup ruleset: $bdump ; снапшот: $SHIELD_LAST_SNAPSHOT"
}
