#!/bin/bash
# shieldnode — rollback.sh: обратимость (ТЗ §25). Только свои файлы.
# Точечный runtime-откат sysctl из снапшота; sysctl --system ЗАПРЕЩЁН.
# 2026-11-14 (v1.2.11): --dry-run прикрывал только шаги 0, 3 и 4 — шаг 1 по-настоящему удалял и возвращал
# файлы по манифесту и обнулял манифест с реестром происхождения, шаг 2 по-настоящему возвращал sysctl и
# стирал их реестр: `rollback --dry-run` и `uninstall --dry-run` выполняли откат наполовину. Теперь под
# DRY_RUN=1 ни один шаг ничего не меняет и каждый печатает, что сделал бы: «would remove …»,
# «would restore … <- …», «would sysctl -w k=v».
set -euo pipefail

SHIELD_MANIFEST="${SHIELD_MANIFEST:-$SHIELD_STATE_DIR/applied-files.txt}"

# shield_rollback [id] — id = backup-set timestamp (YYYYMMDD-HHMMSS), без id — последний.
shield_rollback() {
    local id="${1:-}" ts="" f b newest dry=0
    if [ "${DRY_RUN:-0}" = "1" ]; then dry=1; fi
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
        [ -e /etc/systemd/system/shieldnode-blocklist-restore.service ] && \
            { systemctl disable shieldnode-blocklist-restore.service >/dev/null 2>&1 || true; }
        # 2026-09-24 (v1.1.6): таймер crowdsec есть не всегда (только agent-режим) — отдельным
        # вызовом и только при наличии файла: несуществующий юнит в общем списке роняет disable целиком
        # 2026-09-25 (v1.2.0): ports-watch — до снятия таблицы (иначе успеет «досинхронизировать»)
        if [ -e /etc/systemd/system/shieldnode-ports.service ]; then
            systemctl disable --now shieldnode-ports.service >/dev/null 2>&1 || true
        fi
        # 2026-09-28 (v1.2.4): таймер повтора пустых наборов — тоже только при наличии файла
        if [ -e /etc/systemd/system/shieldnode-blocklist-retry.timer ]; then
            systemctl disable --now shieldnode-blocklist-retry.timer shieldnode-blocklist-retry.service >/dev/null 2>&1 || true
        fi
        if [ -e /etc/systemd/system/shieldnode-blocklist-crowdsec.timer ]; then
            systemctl disable --now shieldnode-blocklist-crowdsec.timer shieldnode-blocklist-crowdsec.service >/dev/null 2>&1 || true
        fi
        # 2026-11-09 (v1.2.9): чужой crowdsec-bouncer, отключённый при apply, включаем обратно
        if [ -s "$SHIELD_STATE_DIR/foreign-bouncer.removed" ]; then
            while read -r f; do
                [ -n "$f" ] && { systemctl enable --now "$f" >/dev/null 2>&1 || true; }
            done < "$SHIELD_STATE_DIR/foreign-bouncer.removed"
            rm -f "$SHIELD_STATE_DIR/foreign-bouncer.removed"
        fi
        # --now: без него служба оставалась «active (exited)» not-found до reboot;
        # ExecStop у shieldnode.service нет — stop меняет только состояние юнита
        systemctl disable --now shieldnode.service >/dev/null 2>&1 || true
    elif [ -s "$SHIELD_STATE_DIR/foreign-bouncer.removed" ]; then
        log info "dry-run" "would enable back foreign crowdsec bouncer: $(paste -sd' ' "$SHIELD_STATE_DIR/foreign-bouncer.removed")"
    fi

    # 1. восстановление/удаление по манифесту
    local reg="$SHIELD_STATE_DIR/file-origins.tsv" origin
    # secf — что окажется на месте файла security-sysctl после шага 1 (от этого зависит шаг 2). Под DRY_RUN
    # шаг 1 ничего не меняет, поэтому считаем: пусто — файла не стало бы, иначе — откуда он был бы возвращён
    local sec=/etc/sysctl.d/99-z5-shieldnode-security.conf secf
    secf="$sec"
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
                if [ "$dry" = 1 ]; then
                    log info "dry-run" "would remove $f (создан shieldnode)"; [ "$f" != "$sec" ] || secf=""; continue
                fi
                rm -f "$f"; log info "rollback" "removed own file $f (создан shieldnode)"; continue
            elif [ -n "$origin" ] && { [ -e "$origin" ] || [ -L "$origin" ]; }; then
                if [ "$dry" = 1 ]; then
                    log info "dry-run" "would restore $f <- $origin (состояние до shieldnode)"; [ "$f" != "$sec" ] || secf="$origin"; continue
                fi
                cp -a -- "$origin" "$f"; log info "rollback" "restored $f <- состояние до shieldnode"; continue
            fi
            if [ -n "$ts" ]; then
                newest="$(ls -1t "${f}".pre-shieldnode-* 2>/dev/null | head -1 || true)"
                if [ -n "$newest" ]; then
                    if [ "$dry" = 1 ]; then
                        log info "dry-run" "would restore $f <- $newest"; [ "$f" != "$sec" ] || secf="$newest"; continue
                    fi
                    cp -a "$newest" "$f"
                    log info "rollback" "restored $f <- $newest"
                    continue
                fi
            fi
            if [ "$dry" = 1 ]; then
                log info "dry-run" "would remove $f"; [ "$f" != "$sec" ] || secf=""; continue
            fi
            rm -f "$f"
            log info "rollback" "removed own file $f"
        done < "$SHIELD_MANIFEST"
        if [ "$dry" != 1 ]; then
            : > "$SHIELD_MANIFEST"
            rm -f "$reg" "$SHIELD_STATE_DIR"/origins/* 2>/dev/null || true
            rmdir "$SHIELD_STATE_DIR/origins" 2>/dev/null || true
        fi
    fi

    # 2. runtime-откат security-sysctl: baseline из последнего снапшота detect
    local snap keys_f="$SHIELD_STATE_DIR/owner-keys.txt" sreg="$SHIELD_STATE_DIR/sysctl-orig.tsv" restored=""
    # 2a. 2026-09-23: исходные значения из реестра (persist.sh) — приоритет над
    # снапшотом detect (после повторного apply тот хранит значения shieldnode)
    if [ -s "$sreg" ] && { [ -z "$secf" ] || [ ! -f "$secf" ]; }; then
        local rk rv
        while IFS=$'\t' read -r rk rv; do
            [ -n "$rk" ] || continue
            if [ "$dry" = 1 ]; then
                log info "dry-run" "would sysctl -w $rk=$rv (до shieldnode)"
            else
                sysctl -w "$rk=$rv" >/dev/null 2>&1 && log info "rollback" "runtime restored $rk=$rv (до shieldnode)" || true
            fi
            restored+="$rk"$'\n'
        done < "$sreg"
        if [ "$dry" != 1 ]; then rm -f "$sreg"; fi
    fi
    snap="$(ls -1t "$SHIELD_STATE_DIR"/diagnostics/*.txt 2>/dev/null | head -1 || true)"
    if [ -f "$keys_f" ] && [ -n "$snap" ]; then
        local k v
        while read -r k; do
            [ -z "$k" ] && continue
            grep -qxF -- "$k" <<<"$restored" && continue
            # ключ ещё управляется оставшимся файлом shieldnode?
            if [ -n "$secf" ] && grep -qsE "^${k}[[:space:]]*=" "$secf" 2>/dev/null; then
                continue
            fi
            v="$(awk -v key="$k" 'found && /^## /{exit} /^## sysctl-managed-baseline/{found=1; next} found && $1==key {print $3; exit}' "$snap")"
            if [ -n "$v" ] && [ "$v" != "?" ]; then
                if [ "$dry" = 1 ]; then
                    log info "dry-run" "would sysctl -w $k=$v"
                else
                    sysctl -w "$k=$v" >/dev/null 2>&1 && log info "rollback" "runtime restored $k=$v" || true
                fi
            fi
        done < "$keys_f"
    fi
    if [ "$dry" != 1 ] && [ ! -f "$sec" ] && [ -f "$keys_f" ]; then : > "$keys_f"; fi

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
    elif [ -f "$conf" ] && grep -q '^\[shieldnode\]' "$conf"; then
        log info "dry-run" "would remove section [shieldnode] from $conf"
    fi

    if [ "$dry" = 1 ]; then
        log info "dry-run" "rollback: ничего не изменено — выше перечислено, что сделал бы настоящий откат (backup-set: ${ts:-none})"
        return 0
    fi
    ok "rollback" "rollback завершён (backup-set: ${ts:-none})"
}
