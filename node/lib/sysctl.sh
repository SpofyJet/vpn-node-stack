#!/bin/bash
# node — lib/sysctl.sh: сбор ключей от модулей, валидация владения, запись, применение.
# Запрещено: sysctl --system. Применяем только свои файлы через sysctl -p.
set -euo pipefail

# Имена с суффиксом 99-zN выбраны не случайно: sysctl.d применяет файлы в
# лексикографическом порядке, а штатные дистрибутивные/облачные файлы
# (99-sysctl.conf на Debian, 99-cloudimg-*.conf на Ubuntu cloud images)
# иначе перекрывали бы наши значения. 'z' идёт после 's'/'c', поэтому наши
# файлы применяются последними и побеждают. Админ всё ещё может перекрыть
# нас своим файлом с суффиксом выше (например 99-z9-*.conf).
NODE_SYSCTL_BASE="/etc/sysctl.d/99-z0-node-base.conf"
NODE_SYSCTL_DATAPATH="/etc/sysctl.d/99-z1-node-datapath.conf"
NODE_SYSCTL_CONNTRACK="/etc/sysctl.d/99-z2-node-conntrack.conf"
NODE_SYSCTL_IPV6="/etc/sysctl.d/99-z3-node-ipv6.conf"
NODE_SYSCTL_MEM="/etc/sysctl.d/99-z4-node-vm.conf"
# Единый список наших sysctl-файлов (запись/применение/self-test итерируют его)
NODE_SYSCTL_FILES=("$NODE_SYSCTL_BASE" "$NODE_SYSCTL_DATAPATH" "$NODE_SYSCTL_CONNTRACK" "$NODE_SYSCTL_IPV6" "$NODE_SYSCTL_MEM")

# План: файлы со строками "key<TAB>value<TAB>file"
NODE_PLAN_FILE=""

node_sysctl_plan_init() {
    NODE_PLAN_FILE="$(mktemp)"
    : > "$NODE_PLAN_FILE"
}

# node_sysctl_add <file> <key> <value>
node_sysctl_add() {
    local file="$1" key="$2" value="$3"
    validate_key_ownership "$key" || { warn "sysctl" "skip foreign-owned key: $key"; return 0; }
    printf '%s\t%s\t%s\n' "$key" "$value" "$file" >> "$NODE_PLAN_FILE"
}

# node_sysctl_add_probed <file> <key> <value> — добавить только если ключ существует
# в текущем ядре (новые/удалённые sysctl между версиями ядер не роняют apply).
node_sysctl_add_probed() {
    local file="$1" key="$2" value="$3"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        sysctl -n "$key" >/dev/null 2>&1 || { log warn "sysctl" "ключ $2 отсутствует в ядре $(uname -r) — пропуск"; return 0; }
    fi
    node_sysctl_add "$file" "$key" "$value"
}

node_sysctl_write() {
    local file key value
    for file in "${NODE_SYSCTL_FILES[@]}"; do
        if [ -s "$NODE_PLAN_FILE" ] && grep -F "$file" "$NODE_PLAN_FILE" > /dev/null 2>&1; then
            {
                echo "# node — $(date -u '+%Y-%m-%d') — managed by node, do not edit"
                grep -F "$file" "$NODE_PLAN_FILE" | sort -u -t$'\t' -k1,1 | \
                    awk -F'\t' '{printf "%s = %s\n", $1, $2}'
            } | node_persist "$file"
        elif [ -f "$file" ]; then
            # оператор выключил фичу (в плане ключей файла нет), а наш старый
            # 99-z*-node-*.conf остался на диске — удаляем, иначе устаревшие
            # значения молча продолжают действовать. backup — перед удалением.
            if [ "${DRY_RUN:-0}" = "1" ]; then
                log info "dry-run" "would remove stale $file (нет в текущем плане)"
            else
                backup "$file"
                rm -f "$file"
                log info "sysctl" "удалён устаревший $file (ключей нет в плане; backup сохранён)"
            fi
        fi
    done
}

# ВАЖНО: node_persist здесь НЕ определяется. Делегат с записью в манифест
# живёт в apply.sh; fallback — в persist.sh. Локальное определение здесь
# (баг 2026-09: манифест всегда пуст) перекрывало делегат, т.к. этот файл
# source'ится внутри node_apply ПОСЛЕ apply.sh, — rollback/uninstall ломались.

node_sysctl_apply() {
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "sysctl -p (skipped)"; return 0; }
    local f
    for f in "${NODE_SYSCTL_FILES[@]}"; do
        [ -f "$f" ] || continue
        sysctl -p "$f" >/dev/null || die "sysctl -p failed: $f (система в частично применённом состоянии — выполни: bash install.sh rollback)"
        log info "sysctl" "applied $f"
    done
}

# Список наших ключей -> реестр владения
node_sysctl_owner_dump() {
    [ -f "$NODE_PLAN_FILE" ] && cut -f1 "$NODE_PLAN_FILE" | sort -u > "$NODE_STATE_DIR/owner-keys.txt" || true
    chmod 0644 "$NODE_STATE_DIR/owner-keys.txt" 2>/dev/null || true
}
