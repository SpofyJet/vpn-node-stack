#!/bin/bash
# node — config.sh: declarative config /etc/node/node.conf (пустое значение = auto).
set -euo pipefail

NODE_CONFIG="${NODE_CONFIG:-/etc/node/node.conf}"
NODE_DEFAULTS="$NODE_DIR/node.defaults.conf"

: "${CONFIG_CACHE:=""}" # path to merged key=value file

node_conf_get() {
    # $1=key $2=default. Empty value in config => default (auto semantics).
    # Inline-комментарии после значения отрезаем ("KEY=1 # why" -> "1").
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

node_load_config() {
    CONFIG_CACHE="$(mktemp)"
    # Порядок важен: awk в node_conf_get берёт ПЕРВОЕ совпадение.
    # Сначала user-конфиг (переопределения), затем defaults (заполнение пустот).
    if [ -f "$NODE_CONFIG" ]; then
        # tr -d '\r': конфиг, отредактированный на Windows (CRLF), иначе тихо игнорируется
        { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_CONFIG" 2>/dev/null || true; } | tr -d '\r' > "$CONFIG_CACHE"
    else
        : > "$CONFIG_CACHE"
    fi
    # shellcheck disable=SC2094
    { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DEFAULTS" 2>/dev/null || true; } | tr -d '\r' >> "$CONFIG_CACHE"
    chmod 0600 "$CONFIG_CACHE"
    export CONFIG_CACHE
    if [ "$(node_conf_get ENABLE_NODE 1)" != "1" ]; then
        log warn "config" "ENABLE_NODE != 1 — nothing to do"
        exit 0
    fi
}

# RAM tier: T1<=2GB T2<=4GB T3<=8GB T4>8GB (auto-выбор консервативных веток)
node_ram_tier() {
    local mb
    mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    if   [ "$mb" -le 2048 ]; then echo 1
    elif [ "$mb" -le 4096 ]; then echo 2
    elif [ "$mb" -le 8192 ]; then echo 3
    else echo 4; fi
}

node_cpu_count() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo
}
