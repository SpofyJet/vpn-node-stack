#!/bin/bash
# shieldnode — firewall.sh: сборка, атомарное применение (ТЗ §26), self-test,
# auto-rollback при потере SSH-доступа, контракт владения (ТЗ §15).
set -euo pipefail

SHIELD_BACKUP_DIR="$SHIELD_STATE_DIR/backups"

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
shield_contract_write() {
    local conf="$NODE_PROFILE_DIR/stack.conf"
    mkdir -p "$NODE_PROFILE_DIR" 2>/dev/null || true
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "contract: append [shieldnode] to $conf"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    if [ -f "$conf" ]; then
        awk '/^\[shieldnode\]/{skip=1; next} /^\[/{skip=0} !skip' "$conf" > "$tmp" || true
    fi
    {
        echo "[shieldnode]"
        echo "version=$SHIELD_VERSION"
        echo "table=inet/shieldnode"
        echo "conntrack_owner=no (node)"
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
    for s in whitelist_v4 protected_tcp ssh_abusers tcp_abusers udp_abusers temporary_blocklist; do
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
    mkdir -p "$SHIELD_BACKUP_DIR"
    local ts bdump
    ts="$(date '+%Y%m%d-%H%M%S')"
    bdump="$SHIELD_BACKUP_DIR/${ts}.nft"
    shield_table_dump "$bdump" || log info "apply" "таблицы inet shieldnode ещё не было — чистый старт"

    # --- применение: destroy + create, затем немедленная runtime-whitelist админа ---
    nft destroy table inet shieldnode 2>/dev/null || true
    if ! nft -f "$tmp" 2>/dev/null; then
        # ядро отвергло ruleset (parse-check не ловит kernel-side): восстанавливаем backup
        log error "apply" "nft -f отклонён ядром — откат к предыдущему ruleset"
        if [ -s "$bdump" ]; then
            nft -f "$bdump" || shield_emergency on "apply rejected and backup restore failed"
            rm -f "$tmp"
            die "nft -f failed: ядро отклонило ruleset; восстановлен предыдущий ruleset"
        fi
        rm -f "$tmp"
        die "nft -f failed: ядро отклонило ruleset; предыдущей таблицы не было — firewall не активен (fail-open)"
    fi
    shield_ssh_whitelist_admin_runtime

    # --- self-test; при провале — auto-rollback (ТЗ §20/§27) ---
    if ! shield_self_test; then
        log error "apply" "SELF-TEST ПРОВАЛЕН — откат к предыдущему ruleset"
        if [ -s "$bdump" ]; then
            nft -f "$bdump" || shield_emergency on "self-test failed and backup restore failed"
        else
            nft destroy table inet shieldnode 2>/dev/null || true
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
    shield_blocklist_install
    shield_guard_link
    rm -f "$tmp"

    # --- журнал abuse стартуем сразу ---
    shield_abuse_journal_append || true

    # --- контракт владения (ТЗ §15) ---
    shield_contract_write

    ok "apply" "shieldnode применён: ssh=[$SH_F_SSH_PORTS] protected_tcp=[$SH_F_PROTECTED_TCP] protected_udp=[$SH_F_PROTECTED_UDP] admin4=[$SH_F_ADMIN_V4] admin6=[$SH_F_ADMIN_V6]"
    log info "apply" "backup ruleset: $bdump ; снапшот: $SHIELD_LAST_SNAPSHOT"
}
