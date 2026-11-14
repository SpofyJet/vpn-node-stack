#!/bin/bash
# shieldnode — uninstall.sh: полный откат + удаление своих файлов (ТЗ §25).
# Сохраняются только пользовательские файлы конфигурации /etc/shieldnode/*.
set -euo pipefail

shield_uninstall() {
    shield_rollback ""

    # состояние (backups, журналы, снапшеты, owner-keys, manifest, protected-ports)
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would rm -rf $SHIELD_STATE_DIR"
    else
        rm -rf "$SHIELD_STATE_DIR"
        ok "uninstall" "state removed: $SHIELD_STATE_DIR"
    fi

    # runtime-таймер и служба (уже отключены в rollback; каталоги unit-файлов чистим)
    # 2026-11-14 (v1.2.11): под DRY_RUN юниты удалялись по-настоящему — теперь только «would remove».
    # Юниты из манифеста уже названы откатом выше; здесь — те, что остались бы после него (нет в манифесте)
    local u
    for u in shieldnode.service shieldnode-cleanup.service shieldnode-cleanup.timer \
             shieldnode-blocklist.service shieldnode-blocklist.timer \
             shieldnode-blocklist-custom.service shieldnode-blocklist-custom.path \
             shieldnode-blocklist-crowdsec.service shieldnode-blocklist-crowdsec.timer \
             shieldnode-ports.service shieldnode-blocklist-restore.service \
             shieldnode-blocklist-retry.service shieldnode-blocklist-retry.timer \
             shieldnode-earlyfilter.service shieldnode-earlyfilter.timer; do
        u="/etc/systemd/system/$u"
        if [ "${DRY_RUN:-0}" != "1" ]; then rm -f "$u"; continue; fi
        [ -e "$u" ] || [ -L "$u" ] || continue
        if [ -f "${SHIELD_MANIFEST:-}" ] && grep -qxF -- "$u" "$SHIELD_MANIFEST"; then continue; fi
        log info "dry-run" "would remove $u (нет в манифесте)"
    done

    log info "uninstall" "сохранены пользовательские конфиги: /etc/shieldnode/ (config.conf, exclude.conf, extensions.d/)"
    # 2026-09-24 (v1.1.6): crowdsec (agent-режим) — отдельный пакет со своей БД; не удаляем молча
    command -v cscli >/dev/null 2>&1 && log info "uninstall" "crowdsec (демон/пакет) оставлен: удалить — apt purge crowdsec"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "uninstall: ничего не изменено — выше перечислено, что сделал бы настоящий uninstall"
        return 0
    fi
    ok "uninstall" "shieldnode удалён"
}
