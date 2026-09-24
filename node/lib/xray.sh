#!/bin/bash
# node — lib/xray.sh: верификация НЕИЗМЕННОСТИ Xray (ТЗ §30).
# Метаданные до/после (имена, размеры, sha256, mtime). Содержимое конфигов
# (UUID, inbounds, routing, TLS/REALITY, Hysteria2) НЕ читается и НЕ логируется.
set -euo pipefail

NODE_XRAY_META_BEFORE="$NODE_STATE_DIR/.xray-meta.before"
NODE_XRAY_META_AFTER="$NODE_STATE_DIR/.xray-meta.after"

# Найти директорию(и) конфигурации Xray через cmdline процесса (read-only)
node_xray_config_dirs() {
    local pid arg dirs=()
    for pid in $(pgrep -x xray 2>/dev/null || pgrep -f '/xray ' 2>/dev/null || true); do
        while IFS= read -r arg; do
            case "$arg" in
                -config|--config|-c)
                    read -r arg
                    dirs+=("$(dirname "$arg")")
                    ;;
                -config=*|--config=*) dirs+=("$(dirname "${arg#*=}")") ;;
            esac
        done < <(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null)
    done
    # стандартные пути, если процесс не найден (только существующие)
    for d in /etc/xray /usr/local/etc/xray /opt/xray; do
        [ -d "$d" ] && dirs+=("$d")
    done
    printf '%s\n' "${dirs[@]:-}" | sort -u | sed '/^$/d'
}

node_xray_snapshot_meta() {
    local out="$1"
    : > "$out"
    local d f
    while read -r d; do
        [ -d "$d" ] || continue
        echo "# dir: $d" >> "$out"
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$f" "$(stat -c '%s' "$f" 2>/dev/null || echo '?')" \
                "$(stat -c '%Y' "$f" 2>/dev/null || echo '?')" \
                "$(sha256sum "$f" 2>/dev/null | awk '{print $1}')" >> "$out"
        done < <(find "$d" -maxdepth 2 -type f 2>/dev/null | sort)
    done < <(node_xray_config_dirs)
    chmod 0600 "$out"
}

node_xray_verify_unchanged() {
    node_xray_snapshot_meta "$NODE_XRAY_META_AFTER"
    if [ -f "$NODE_XRAY_META_BEFORE" ] && ! cmp -s "$NODE_XRAY_META_BEFORE" "$NODE_XRAY_META_AFTER"; then
        diff "$NODE_XRAY_META_BEFORE" "$NODE_XRAY_META_AFTER" | head -20 | while read -r l; do
            warn "xray" "метаданные изменились: $(printf '%s' "$l" | scrub)"
        done
        warn "xray" "ВНЕШНЕЕ изменение конфигурации Xray зафиксировано (node не модифицировал). Проверь вручную."
        return 1
    fi
    ok "xray" "метаданные конфигурации Xray неизменны"
    return 0
}

# node_xray_sockets_summary — сколько сокетов держит процесс xray/remnanode (read-only).
# Используется в status: факт «сервис жив и слушает» без чтения его конфигурации (ТЗ §30).
node_xray_sockets_summary() {
    command -v ss >/dev/null 2>&1 || { echo "ss missing"; return 0; }
    local t u
    t="$(ss -tlnp 2>/dev/null | awk '/xray|remnanode/{n++} END{print n+0}')"
    u="$(ss -ulnp 2>/dev/null | awk '/xray|remnanode/{n++} END{print n+0}')"
    echo "tcp:$t udp:$u"
}
