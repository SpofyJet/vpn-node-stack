#!/bin/bash
# shieldnode — config.sh: декларативный конфиг /etc/shieldnode/config.conf (ТЗ §28).
# Пустое значение = авто. Порядок мержа: user-конфиг ПЕРВЫМ (awk берёт первое совпадение).
set -euo pipefail

SHIELD_CONFIG="${SHIELD_CONFIG:-/etc/shieldnode/config.conf}"
SHIELD_DEFAULTS="$SHIELD_DIR/shieldnode.defaults.conf"
SHIELD_EXCLUDE="${SHIELD_EXCLUDE:-/etc/shieldnode/exclude.conf}"

: "${CONFIG_CACHE:=""}"

shield_conf_get() {
    # $1=key $2=default. Пустое значение => default (авто-семантика ТЗ §28).
    local key="$1" def="$2" val=""
    if [ -n "${CONFIG_CACHE:-}" ] && [ -f "$CONFIG_CACHE" ]; then
        val="$(awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$CONFIG_CACHE")"
    fi
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    val="${val%%[[:space:]]#*}"
    val="${val%"${val##*[![:space:]]}"}"
    if [ -z "$val" ]; then echo "$def"; else echo "$val"; fi
}

shield_load_config() {
    CONFIG_CACHE="$(mktemp)"
    if [ -f "$SHIELD_CONFIG" ]; then
        # tr -d '\r': конфиг, отредактированный на Windows (CRLF), иначе тихо игнорируется
        { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SHIELD_CONFIG" 2>/dev/null || true; } | tr -d '\r' > "$CONFIG_CACHE"
    else
        : > "$CONFIG_CACHE"
    fi
    # shellcheck disable=SC2094
    { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SHIELD_DEFAULTS" 2>/dev/null || true; } | tr -d '\r' >> "$CONFIG_CACHE"
    chmod 0600 "$CONFIG_CACHE"
    export CONFIG_CACHE
    if [ "$(shield_conf_get ENABLE_SHIELDNODE 1)" != "1" ]; then
        log warn "config" "ENABLE_SHIELDNODE != 1 — nothing to do"
        exit 0
    fi
}

shield_cpu_count() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo
}
