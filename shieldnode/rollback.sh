#!/bin/bash
# shieldnode — rollback.sh: обратимость (ТЗ §25). Только свои файлы.
# Точечный runtime-откат sysctl из снапшота; sysctl --system ЗАПРЕЩЁН.
set -euo pipefail

SHIELD_MANIFEST="${SHIELD_MANIFEST:-$SHIELD_STATE_DIR/applied-files.txt}"

# shield_rollback [id] — id = backup-set timestamp (YYYYMMDD-HHMMSS), без id — последний.
shield_rollback() {
    local id="${1:-}" ts="" f b newest
    if [ -n "$id" ]; then
        ts="$id"
    else
        b="$(ls -1 /etc/nftables.d/*.pre-shieldnode-* /etc/sysctl.d/*.pre-shieldnode-* /etc/systemd/system/*.pre-shieldnode-* /etc/shieldnode/*.pre-shieldnode-* 2>/dev/null | sed -E 's/.*\.pre-shieldnode-([0-9]{8}-[0-9]{6})$/\1/' | sort -u | tail -1 || true)"
        ts="$b"
    fi

    log info "rollback" "target backup set: ${ts:-<none — удаление своих файлов>}"

    # 1. восстановление/удаление по манифесту
    if [ -f "$SHIELD_MANIFEST" ]; then
        while read -r f; do
            [ -e "$f" ] || continue
            if [ -n "$ts" ]; then
                newest="$(ls -1t "${f}".pre-shieldnode-* 2>/dev/null | head -1 || true)"
                if [ -n "$newest" ]; then
                    cp -a "$newest" "$f"
                    log info "rollback" "restored $f <- $newest"
                    continue
                fi
            fi
            rm -f "$f"
            log info "rollback" "removed own file $f"
        done < "$SHIELD_MANIFEST"
        : > "$SHIELD_MANIFEST"
    fi

    # 2. runtime-откат security-sysctl: baseline из последнего снапшота detect
    local snap keys_f="$SHIELD_STATE_DIR/owner-keys.txt"
    snap="$(ls -1t "$SHIELD_STATE_DIR"/diagnostics/*.txt 2>/dev/null | head -1 || true)"
    if [ -f "$keys_f" ] && [ -n "$snap" ]; then
        local k v
        while read -r k; do
            [ -z "$k" ] && continue
            # ключ ещё управляется оставшимся файлом shieldnode?
            if grep -qsE "^${k}[[:space:]]*=" /etc/sysctl.d/85-shieldnode-security.conf 2>/dev/null; then
                continue
            fi
            v="$(awk -v key="$k" 'found && /^## /{exit} /^## sysctl-managed-baseline/{found=1; next} found && $1==key {print $3; exit}' "$snap")"
            if [ -n "$v" ] && [ "$v" != "?" ]; then
                sysctl -w "$k=$v" >/dev/null 2>&1 && log info "rollback" "runtime restored $k=$v" || true
            fi
        done < "$keys_f"
    fi

    # 3. службы и firewall
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl disable --now shieldnode-cleanup.timer >/dev/null 2>&1 || true
        systemctl disable --now shieldnode-blocklist.timer shieldnode-blocklist.service \
                           shieldnode-blocklist-custom.path shieldnode-blocklist-custom.service >/dev/null 2>&1 || true
        systemctl disable shieldnode.service >/dev/null 2>&1 || true
        systemctl daemon-reload 2>/dev/null || true
        # откат = удаление нашего firewall (возврат к состоянию «shieldnode не было»)
        nft destroy table inet shieldnode 2>/dev/null || true
        rm -f /run/shieldnode/emergency
    else
        log info "dry-run" "would: disable timers/service, destroy table inet shieldnode, rm emergency marker"
    fi

    # 4. контракт: убрать [shieldnode] из stack.conf
    local conf="$NODE_PROFILE_DIR/stack.conf"
    if [ -f "$conf" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        local tmp; tmp="$(mktemp)"
        awk '/^\[shieldnode\]/{skip=1; next} /^\[/{skip=0} !skip' "$conf" > "$tmp" || true
        chmod 0644 "$tmp"; mv "$tmp" "$conf"
    fi

    ok "rollback" "rollback завершён (backup-set: ${ts:-none})"
}
