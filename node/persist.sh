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

# Fallback-делегат: в боевом apply-пути node_persist определяет apply.sh
# (тот же делегат). Здесь — для контекстов, где apply.sh не засурсен
# (тесты, rt-reapply до source apply.sh и т.п.): иначе «command not found».
if ! declare -F node_persist >/dev/null 2>&1; then
    node_persist() {
        node_persist_stream "$1"
    }
fi
