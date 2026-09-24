#!/bin/bash
# node — uninstall.sh: полное удаление (rollback + манифест + конфиг оставляем? нет).
set -euo pipefail

node_uninstall() {
    log info "uninstall" "rolling back all changes"
    source "$NODE_DIR/rollback.sh"
    node_rollback ""
    rm -f "$NODE_STATE_DIR/owner-keys.txt" "$NODE_STATE_DIR/applied-files.txt" \
          "$NODE_STATE_DIR/.xray-meta.before" "$NODE_STATE_DIR/.xray-meta.after"
    # конфиг оператора не удаляем без явного желания
    if [ -f /etc/node/node.conf ]; then
        log info "uninstall" "конфиг /etc/node/node.conf оставлен (удали вручную при необходимости)"
    fi
    ok "uninstall" "node removed"
}
