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
    # 2026-09-24 (v1.1.6): содержимое не изменилось — не переписываем и НЕ бэкапим.
    # Раньше каждый apply/rt-reapply делал .pre-node-* с идентичной копией: при
    # BACKUP_KEEP=5 пять повторных apply вытесняли все значимые старые версии.
    local _new
    mkdir -p -- "$(dirname "$dst")" 2>/dev/null || true
    _new="$(mktemp "$(dirname "$dst")/.node-new.XXXXXX")" || die "mktemp failed for $dst"
    cat > "$_new"
    if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$_new" "$dst"; then
        rm -f "$_new"
        node_manifest_record "$dst"
        log info "persist" "$dst (без изменений)"
        return 0
    fi
    # 2026-09-24 (v1.1.5): logrotate (и apt) читают ВСЕ файлы своих .d-каталогов — бэкап рядом с
    # СВОИМ (created) файлом logrotate принимал за второй конфиг: «duplicate log entry»,
    # rc=1. Исходное состояние такого файла — «отсутствует» (реестр происхождения;
    # rollback его удаляет), рядом-бэкапы не нужны — не кладём и убираем прежние.
    # Чужие (существовавшие до нас) файлы бэкапятся как раньше.
    case "$dst" in
        /etc/logrotate.d/*|/etc/apt/apt.conf.d/*)
            if awk -F'\t' -v p="$dst" '$1==p && $2=="created"{f=1} END{exit !f}' "$NODE_STATE_DIR/file-origins.tsv" 2>/dev/null; then
                rm -f -- "$dst".pre-node-* 2>/dev/null || true
            else
                backup "$dst"
            fi ;;
        *) backup "$dst" ;;
    esac
    atomic_write "$dst" < "$_new"
    rm -f "$_new"
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
