#!/bin/bash
# node — persist.sh: единая точка записи (backup + atomic). Используется через stdin.
set -euo pipefail

node_manifest_record() {
    local dst="$1" manifest="$NODE_STATE_DIR/applied-files.txt"
    mkdir -p "$NODE_STATE_DIR"
    touch "$manifest"
    # Дедупликация: путь записывается в манифест один раз
    if ! grep -qxF -- "$dst" "$manifest"; then
        echo "$dst" >> "$manifest"
    fi
}

node_persist_stream() {
    local dst="$1"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would write $dst"
        cat > /dev/null
        return 0
    fi
    backup "$dst"
    atomic_write "$dst"
    node_manifest_record "$dst"
    ok "persist" "$dst"
}
