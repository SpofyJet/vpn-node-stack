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

    # 0. 2026-09-24 (v1.1.4): юниты останавливаем/отключаем ДО удаления их файлов (шаг 1):
    # на отсутствующем unit-файле `systemctl disable --now` падает целиком — таймеры
    # уходили в failed ("Unit to trigger vanished"), .path оставался active, а
    # симлинки в *.wants — висячими (живая нода)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl disable --now shieldnode-cleanup.timer >/dev/null 2>&1 || true
        systemctl disable --now shieldnode-blocklist.timer shieldnode-blocklist.service \
                           shieldnode-blocklist-custom.path shieldnode-blocklist-custom.service >/dev/null 2>&1 || true
        # --now: без него служба оставалась «active (exited)» not-found до reboot;
        # ExecStop у shieldnode.service нет — stop меняет только состояние юнита
        systemctl disable --now shieldnode.service >/dev/null 2>&1 || true
    fi

    # 1. восстановление/удаление по манифесту
    local reg="$SHIELD_STATE_DIR/file-origins.tsv" origin
    if [ -f "$SHIELD_MANIFEST" ]; then
        while read -r f; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            # 2026-09-23: операторские конфиги НЕ трогаем никогда. config.conf
            # создаётся шаблоном (попадал в манифест без бэкапа) и rollback его
            # УДАЛЯЛ вместе с SSH_PORT/TRUSTED_IPS — в т.ч. при авто-откате из
            # vpn-node-setup; следующий apply шёл на автодетекте (риск lockout).
            case "$f" in
                "${SHIELD_CONFIG:-/etc/shieldnode/config.conf}"|"${SHIELD_EXCLUDE:-/etc/shieldnode/exclude.conf}")
                    log info "rollback" "операторский $f оставлен"; continue ;;
            esac
            # 2026-09-23: откат без id — по реестру происхождения (persist.sh)
            origin=""
            [ -z "$id" ] && [ -f "$reg" ] && origin="$(awk -F'\t' -v p="$f" '$1==p{print $2; exit}' "$reg")"
            if [ "$origin" = "created" ]; then
                rm -f "$f"; log info "rollback" "removed own file $f (создан shieldnode)"; continue
            elif [ -n "$origin" ] && { [ -e "$origin" ] || [ -L "$origin" ]; }; then
                cp -a -- "$origin" "$f"; log info "rollback" "restored $f <- состояние до shieldnode"; continue
            fi
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
        rm -f "$reg" "$SHIELD_STATE_DIR"/origins/* 2>/dev/null || true
        rmdir "$SHIELD_STATE_DIR/origins" 2>/dev/null || true
    fi

    # 2. runtime-откат security-sysctl: baseline из последнего снапшота detect
    local snap keys_f="$SHIELD_STATE_DIR/owner-keys.txt" sreg="$SHIELD_STATE_DIR/sysctl-orig.tsv" restored=""
    # 2a. 2026-09-23: исходные значения из реестра (persist.sh) — приоритет над
    # снапшотом detect (после повторного apply тот хранит значения shieldnode)
    if [ -s "$sreg" ] && [ ! -f /etc/sysctl.d/99-z5-shieldnode-security.conf ]; then
        local rk rv
        while IFS=$'\t' read -r rk rv; do
            [ -n "$rk" ] || continue
            sysctl -w "$rk=$rv" >/dev/null 2>&1 && log info "rollback" "runtime restored $rk=$rv (до shieldnode)" || true
            restored+="$rk"$'\n'
        done < "$sreg"
        rm -f "$sreg"
    fi
    snap="$(ls -1t "$SHIELD_STATE_DIR"/diagnostics/*.txt 2>/dev/null | head -1 || true)"
    if [ -f "$keys_f" ] && [ -n "$snap" ]; then
        local k v
        while read -r k; do
            [ -z "$k" ] && continue
            grep -qxF -- "$k" <<<"$restored" && continue
            # ключ ещё управляется оставшимся файлом shieldnode?
            if grep -qsE "^${k}[[:space:]]*=" /etc/sysctl.d/99-z5-shieldnode-security.conf 2>/dev/null; then
                continue
            fi
            v="$(awk -v key="$k" 'found && /^## /{exit} /^## sysctl-managed-baseline/{found=1; next} found && $1==key {print $3; exit}' "$snap")"
            if [ -n "$v" ] && [ "$v" != "?" ]; then
                sysctl -w "$k=$v" >/dev/null 2>&1 && log info "rollback" "runtime restored $k=$v" || true
            fi
        done < "$keys_f"
    fi
    [ -f /etc/sysctl.d/99-z5-shieldnode-security.conf ] || { [ -f "$keys_f" ] && : > "$keys_f"; }

    # 3. службы и firewall
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload 2>/dev/null || true
        # откат = удаление нашего firewall (возврат к состоянию «shieldnode не было»)
        # delete, а не destroy: destroy появился только в nft 1.0.8 (Debian 12 = 1.0.6)
        nft delete table inet shieldnode 2>/dev/null || true
        rm -f /run/shieldnode/emergency
        # guard-symlink (в manifest, удалится и вместе с файлами; тут — явно)
        # symlink guard указывает на main.sh (вызов через него = read-only дашборд)
        [ -L /usr/local/sbin/guard ] && [ "$(readlink /usr/local/sbin/guard 2>/dev/null || true)" = "$SHIELD_DIR/main.sh" ] && rm -f /usr/local/sbin/guard || true
    else
        log info "dry-run" "would: disable timers/service, delete table inet shieldnode, rm emergency marker"
    fi

    # 4. контракт: убрать [shieldnode] из stack.conf
    # Путь — ЛИТЕРАЛ (/etc/node-profile.d — общий каталог контракта; NODE_PROFILE_DIR
    # существует только в процессе node и здесь даёт unbound variable)
    local conf="/etc/node-profile.d/stack.conf"
    if [ -f "$conf" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        # 2026-09-23: mktemp в каталоге назначения — mv из /tmp (часто tmpfs) не атомарен
        local tmp; tmp="$(mktemp "$(dirname "$conf")/.stack.conf.XXXXXX")"
        awk '/^\[shieldnode\]/{skip=1; next} /^\[/{skip=0} !skip' "$conf" > "$tmp" || true
        chmod 0644 "$tmp"; mv "$tmp" "$conf"
    fi

    ok "rollback" "rollback завершён (backup-set: ${ts:-none})"
}
