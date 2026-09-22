#!/bin/bash
# shieldnode — lib/common.sh: logging (scrub, §5), lock, backup, atomic write.
set -euo pipefail

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'; C_NC=$'\033[0m'

scrub() {
    # Маскирование секретов перед записью в лог (ТЗ §5): токены/пароли/UUID.
    sed -E 's/(token|password|passwd|secret|uuid|bearer)([=: ][^ ]{0,4})[^ ]*/\1\2****/I'
}

log() {
    # log <level> <module> <msg...>
    local level="$1" module="$2"; shift 2
    local msg; msg="$(printf '%s' "$*" | scrub)"
    local line; line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $module: $msg"
    local lvl_prio cur_prio
    lvl_prio=3; case "$level" in debug) lvl_prio=4 ;; info) lvl_prio=3 ;; warn) lvl_prio=2 ;; error) lvl_prio=1 ;; esac
    cur_prio=3; case "$(shield_conf_get LOG_LEVEL info 2>/dev/null || echo info)" in debug) cur_prio=4 ;; info) cur_prio=3 ;; warn) cur_prio=2 ;; error) cur_prio=1 ;; esac
    [ "$lvl_prio" -le "$cur_prio" ] || return 0
    if [ -w "$SHIELD_LOG" ]; then printf '%s\n' "$line" >> "$SHIELD_LOG"; fi
    case "$level" in
        error) printf '%s%s%s\n' "$C_RED" "$line" "$C_NC" >&2 ;;
        warn)  printf '%s%s%s\n' "$C_YEL" "$line" "$C_NC" >&2 ;;
        *)     printf '%s\n' "$line" ;;
    esac
}

die()  { log error "fatal" "$*"; exit 1; }
warn() { log warn  "$@"; }
ok()   { log info  "$@"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo bash install.sh"
}

acquire_lock() {
    mkdir -p "$(dirname "$SHIELD_LOCK")" 2>/dev/null || true
    exec 9>"$SHIELD_LOCK"
    flock -n 9 || die "another shieldnode instance holds the lock ($SHIELD_LOCK)"
}

# backup <path> — сохранить существующий файл перед перезаписью; keep=BACKUP_KEEP
backup() {
    local path="$1" keep ts bdir
    [ -e "$path" ] || return 0
    keep="$(shield_conf_get BACKUP_KEEP 5)"
    ts="$(date '+%Y%m%d-%H%M%S')"
    cp -a "$path" "${path}.pre-shieldnode-${ts}" || die "backup failed: $path"
    bdir="$(dirname "$path")"
    ls -1t "$bdir"/"$(basename "$path")".pre-shieldnode-* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
    log debug "backup" "$path -> ${path}.pre-shieldnode-${ts}"
}

# atomic_write <dst> [mode] — stdin → tmp в той же ФС → mv. mode по умолчанию 0644.
atomic_write() {
    local dst="$1" mode="${2:-0644}" tmp
    # mktemp требует существующий каталог: на fresh-ноде /etc/shieldnode ещё
    # нет при первой записи config.conf (баг 2026-09-22: fatal mktemp failed)
    mkdir -p -- "$(dirname "$dst")" 2>/dev/null \
        || die "не удалось создать каталог $(dirname "$dst") для $dst"
    tmp="$(mktemp "$(dirname "$dst")/.shieldnode-write.XXXXXX")" || die "mktemp failed for $dst"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$dst"
    log debug "persist" "wrote $dst (mode $mode)"
}

# foreign_owner_keys — ключи sysctl, принадлежащие node (реестр владения ТЗ §15/§21).
# shieldnode НИКОГДА не пишет net.netfilter.* — там только node.
foreign_owner_keys() {
    [ -f /var/lib/node/owner-keys.txt ] && cat /var/lib/node/owner-keys.txt || true
}

# validate_key_ownership <key> — 0 если ключ наш/свободен; 1 если владелец — node.
# Жёсткий стоп для net.netfilter.* (К-1: двойное владение conntrack).
validate_key_ownership() {
    local key="$1"
    case "$key" in
        net.netfilter.*|net.ipv4.netfilter.*) return 1 ;;
    esac
    grep -qxF "$key" <(foreign_owner_keys) && return 1
    return 0
}
