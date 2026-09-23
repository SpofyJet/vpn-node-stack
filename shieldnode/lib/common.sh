#!/bin/bash
# shieldnode — lib/common.sh: logging (scrub, §5), lock, backup, atomic write.
set -euo pipefail

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'; C_NC=$'\033[0m'

scrub() {
    # Маскирование секретов перед записью в лог (ТЗ §5): токены/пароли/UUID.
    # 2026-09-23: порт фикса node — значение маскируется ЦЕЛИКОМ (раньше в лог
    # уходили 4 символа префикса секрета), флаг g (все секреты строки, не только
    # первый), JSON/YAML-разделители, «голые» UUID.
    local q="'"
    sed -E -e "s/(token|password|passwd|secret|uuid|bearer)([\"$q]?[=: ]+[\"$q]?)[^ \"$q,;}]+/\1\2****/Ig" \
           -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/****-uuid/Ig'
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
    # валидация: BACKUP_KEEP=abc -> $((keep+1))=1 -> снесло бы ВСЕ бэкапы
    case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
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

# nft_counters — вывод "<name> <packets> <bytes>" по всем counter'ам таблицы.
# ВАЖНО: скоупедная форма `nft list counters inet <table>` — СИНТАКСИЧЕСКАЯ
# ОШИБКА на nft < 1.0.8 (Debian 12: nft 1.0.6): "Error: syntax error,
# unexpected string" (проверено на живом ядре 2026-09-22 — из-за этого guard
# показывал пустые счётчики на работающем firewall). Единственная рабочая
# форма — глобальная `nft list counters` (все таблицы), фильтруем по секции
# "table inet shieldnode" (awk'ом — nft не даёт фильтра по таблице).
# Реальный вывод многострочный (НЕ однострочники с запятой):
#   table inet shieldnode {
#       counter c_drops_x {
#           packets 123 bytes 456
#       }
#   }
nft_counters() {
    nft list counters 2>/dev/null | awk '
        /^table inet shieldnode[[:space:]]*\{/ { in_table = 1; next }
        /^table / { in_table = 0; next }
        in_table && /^[[:space:]]*counter [a-zA-Z0-9_]+[[:space:]]*\{/ { name = $2; next }
        in_table && /^[[:space:]]*packets [0-9]+ bytes [0-9]+/ {
            if (name != "") { print name, $2, $4; name = "" }
        }' || true
}

# nft_set_elem_count <set> — число элементов сета. nft переносит длинные
# списки elements = { ... } на несколько строк — считаем awk'ом с накоплением
# между "elements = {" и "}". Отсутствующий сет -> 0 (rc 0).
nft_set_elem_count() {
    nft -n list set inet shieldnode "$1" 2>/dev/null | awk '
        /elements = \{/ {
            ine = 1
            rest = $0; sub(/.*elements = \{[[:space:]]*/, "", rest)
            if (rest ~ /\}/) { sub(/[[:space:]]*\}.*/, "", rest); ine = 0 }
            n = split(rest, a, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i])
                if (a[i] != "") cnt++
            }
            next
        }
        ine {
            rest = $0
            if (rest ~ /\}/) { sub(/[[:space:]]*\}.*/, "", rest); ine = 0 }
            n = split(rest, a, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i])
                if (a[i] != "") cnt++
            }
        }
        END { print cnt + 0 }' || true
}

# --- разбор вывода ip/ss БЕЗ номеров колонок (v1.1.2, 2026-09-23) ---
# ip route: значение берём по КЛЮЧЕВОМУ слову грамматики iproute2 (dev/via), а
# не $5/$3 — номер колонки сдвигается: «default nhid N via ...» (nexthop-объекты),
# «default dev venet0 scope link» (без шлюза: OpenVZ/wg/ppp), multipath
# («default proto static ... nexthop via X dev Y»). ip -j не используем: в node нет
# JSON-парсера (python3/jq — не зависимости node), в shieldnode python3 опционален.
# ss: JSON-вывода у ss в upstream iproute2 НЕТ (ss(8)); Local = первое поле вида
# адрес:порт — независимо от наличия колонок Netid/State (зависят от фильтров).
# awk читает вход ДО КОНЦА (без exit) — продюсер не получает SIGPIPE под pipefail.
# Тела _route_kw/_ss_local_ports ИДЕНТИЧНЫ в node и shieldnode (test-shared-helpers).
_route_kw() { # stdin: `ip -o route`; $1 = dev|via — значение из первого маршрута, где оно есть
    awk -v kw="$1" '!done { for (i = 1; i < NF; i++) if ($i == kw) { print $(i + 1); done = 1; break } }'
}
_ss_local_ports() { # stdin: вывод ss; $1 = ERE по строке (процесс) — порт Local каждой строки
    awk -v re="$1" '$0 ~ re { for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) { n = split($i, a, ":"); print a[n]; break } }'
}
shield_default_iface() { ip -o -4 route show to default 2>/dev/null | _route_kw dev; }

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
