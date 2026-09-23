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

# --- node_origin_record <dst>: состояние файла ДО первой записи node ---
# Баг 2026-09-23 (подтверждён: apply x2 -> rollback): при ПОВТОРНОМ apply backup()
# сохраняет собственную прошлую версию файла node, и rollback без id по правилу
# «есть .pre-node-* => файл был до node» ВОССТАНАВЛИВАЛ её вместо удаления —
# 99-z*-node-*.conf и прочее переживали откат и применялись при следующем boot.
# Реестр фиксирует происхождение один раз на жизненный цикл манифеста:
#   <path>\tcreated  — файла не было: rollback удаляет;
#   <path>\t<копия>  — файл был: rollback возвращает ИМЕННО эту копию
#                      (не ротируется BACKUP_KEEP, в отличие от .pre-node-*).
# Путь уже в манифесте без записи в реестре = установка до v1.1.1:
# происхождение неизвестно — rollback идёт прежней (legacy) логикой.
node_origin_record() {
    local dst="$1" reg="$NODE_STATE_DIR/file-origins.tsv" man="$NODE_STATE_DIR/applied-files.txt" copy
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    mkdir -p "$NODE_STATE_DIR"
    if [ -f "$reg" ] && awk -F'\t' -v p="$dst" '$1==p{f=1} END{exit !f}' "$reg"; then return 0; fi
    if [ -f "$man" ] && grep -qxF -- "$dst" "$man"; then return 0; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        mkdir -p "$NODE_STATE_DIR/origins"; chmod 0700 "$NODE_STATE_DIR/origins"
        copy="$NODE_STATE_DIR/origins/$(printf '%s' "$dst" | sha256sum | cut -c1-16)"
        cp -a -- "$dst" "$copy" || die "origin copy failed: $dst"
        printf '%s\t%s\n' "$dst" "$copy" >> "$reg"
    else
        printf '%s\tcreated\n' "$dst" >> "$reg"
    fi
}

node_persist_stream() {
    local dst="$1"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would write $dst"
        cat > /dev/null
        return 0
    fi
    node_origin_record "$dst"
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
