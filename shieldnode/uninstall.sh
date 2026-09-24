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
    rm -f /etc/systemd/system/shieldnode.service /etc/systemd/system/shieldnode-cleanup.service /etc/systemd/system/shieldnode-cleanup.timer \
          /etc/systemd/system/shieldnode-blocklist.service /etc/systemd/system/shieldnode-blocklist.timer \
          /etc/systemd/system/shieldnode-blocklist-custom.service /etc/systemd/system/shieldnode-blocklist-custom.path

    log info "uninstall" "сохранены пользовательские конфиги: /etc/shieldnode/ (config.conf, exclude.conf, extensions.d/)"
    ok "uninstall" "shieldnode удалён"
}
