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
    # Порядок важен: сначала кавычки — если значение в кавычках, " #" внутри
    # НЕ комментарий (PASSWORD="ab #cd" не должен портиться). Обрезка
    # inline-комментария — только для некавыченных значений.
    case "$val" in
        \"*)  val="${val#\"}"; val="${val%%\"*}" ;;
        "'"*) val="${val#\'}"; val="${val%%\'*}" ;;
        *)    val="${val%%[[:space:]]#*}"
              val="${val%"${val##*[![:space:]]}"}" ;;
    esac
    if [ -z "$val" ]; then echo "$def"; else echo "$val"; fi
}

shield_load_config() {
    CONFIG_CACHE="$(mktemp)"
    # mktemp-файл не должен оставаться после выхода (root-сессии, /tmp)
    trap 'rm -f "$CONFIG_CACHE" 2>/dev/null || true' EXIT
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

# 2026-11-14 (v1.2.11): ENABLE_EARLY_FILTER — ранний фильтр на входе (earlyfilter.sh). Только 0 или 1.
# Любое другое значение — опечатка: по ней нельзя ни снять работающий фильтр, ни поставить его, поэтому
# ответ «invalid» — стек фильтр не трогает и пишет предупреждение (apply, status).
shield_conf_early_filter() {   # -> 1 | 0 | invalid
    local v; v="$(shield_conf_get ENABLE_EARLY_FILTER 1)"
    case "$v" in 0|1) echo "$v" ;; *) echo invalid ;; esac
}
# EARLY_FILTER_MODE — что стек делает с режимом раннего фильтра: auto — после наблюдения сам включает отброс,
# если под него не попадают свои пакеты; observe — держит в наблюдении (серверы с пробросом портов в
# контейнеры и т.п.). Другое значение — опечатка: «invalid», режим стек не меняет.
shield_conf_early_filter_mode() {   # -> auto | observe | invalid
    local v; v="$(shield_conf_get EARLY_FILTER_MODE auto)"
    case "$v" in auto|observe) echo "$v" ;; *) echo invalid ;; esac
}

shield_cpu_count() {
    # grep -c возвращает rc=1 при 0 совпадений — под set -e это fatal без || true
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || true
}
