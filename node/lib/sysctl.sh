#!/bin/bash
# node — lib/sysctl.sh: сбор ключей от модулей, валидация владения, запись, применение.
# Запрещено: sysctl --system. Применяем только свои файлы через sysctl -p.
set -euo pipefail

NODE_SYSCTL_BASE="/etc/sysctl.d/80-node-base.conf"
NODE_SYSCTL_DATAPATH="/etc/sysctl.d/81-node-datapath.conf"
NODE_SYSCTL_CONNTRACK="/etc/sysctl.d/82-node-conntrack.conf"
NODE_SYSCTL_IPV6="/etc/sysctl.d/83-node-ipv6.conf"
NODE_SYSCTL_MEM="/etc/sysctl.d/84-node-vm.conf"
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
        [ -s "$NODE_PLAN_FILE" ] || continue
        grep -F "$file" "$NODE_PLAN_FILE" > /dev/null 2>&1 || continue
        {
            echo "# node — $(date -u '+%Y-%m-%d') — managed by node, do not edit"
            grep -F "$file" "$NODE_PLAN_FILE" | sort -u -t$'\t' -k1,1 | \
                awk -F'\t' '{printf "%s = %s\n", $1, $2}'
        } | node_persist "$file"
    done
}

# node_persist <dst> — backup + atomic write из stdin (индirection для тестов)
node_persist() {
    local dst="$1"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "would write $dst"; cat > /dev/null; return 0
    fi
    backup "$dst"
    atomic_write "$dst"
}

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
