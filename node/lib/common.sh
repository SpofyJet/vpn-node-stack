#!/bin/bash
# node — lib/common.sh: logging (scrub), lock, backup, atomic write.
set -euo pipefail

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'; C_NC=$'\033[0m'

scrub() {
    # Маскирование секретов перед записью в лог (ТЗ §5).
    # Значение маскируется ЦЕЛИКОМ (раньше оставались 4 символа префикса —
    # достаточно для частичной идентификации секрета).
    # 2026-09-23: флаг g — маскируются ВСЕ секреты строки (раньше только первый:
    # "token=a password=b" оставлял b); разделители JSON/YAML ("password": "x");
    # «голые» UUID (ключи клиентов Xray) — даже без слова uuid рядом.
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
    cur_prio=3; case "$(node_conf_get LOG_LEVEL info 2>/dev/null || echo info)" in debug) cur_prio=4 ;; info) cur_prio=3 ;; warn) cur_prio=2 ;; error) cur_prio=1 ;; esac
    [ "$lvl_prio" -le "$cur_prio" ] || return 0
    if [ -w "$NODE_LOG" ]; then printf '%s\n' "$line" >> "$NODE_LOG"; fi
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
node_default_iface() { ip -o -4 route show to default 2>/dev/null | _route_kw dev; }
node_default_gw()    { ip -o -4 route show to default 2>/dev/null | _route_kw via; }

# --- node_step_run: исполнение шага apply с гарантированным errexit ---
# Баг 2026-09-22 (подтверждён эмпирически): форма `( cmd ) || { handler; }`
# заставляет bash ОТКЛЮЧИТЬ errexit ВНУТРИ subshell на всё его выполнение —
# шаги, писавшиеся под set -e (проверки, mktemp, пайплайны с pipefail),
# продолжали работу после внутренних ошибок, а rc шага получала ПОСЛЕДНЯЯ
# команда. Ложный «success» невозможно было отличить от настоящего.
# Решение: subshell — ГОЛЫМ оператором (вне || списка), снаружи временно
# set +e (вызывающий скрипт не умирает), внутри явный set -e (контракт шага
# восстановлен). Счётчики — в глобалах (init при source, set -u-safe).
NODE_STEP_RC="${NODE_STEP_RC:-0}"
NODE_STEP_FAILED="${NODE_STEP_FAILED:-}"
node_step_run() { # <имя> <команда...> — rc копим в NODE_STEP_RC/NODE_STEP_FAILED
    local name="$1"; shift
    local step_rc=0
    set +e
    ( set -e; "$@" )
    step_rc=$?
    set -e
    if [ "$step_rc" -ne 0 ]; then
        NODE_STEP_RC=$((NODE_STEP_RC+1)); NODE_STEP_FAILED+=" $name"
        log error "apply" "шаг '$name' завершился с ошибкой (rc=$step_rc) — продолжаем, итог в конце"
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$NODE_LOCK")" 2>/dev/null || true
    exec 9>"$NODE_LOCK"
    flock -n 9 || die "another node instance holds the lock ($NODE_LOCK)"
}

# backup <path> — сохранить существующий файл перед перезаписью; keep=N
backup() {
    local path="$1" keep ts bdir
    [ -e "$path" ] || return 0
    keep="$(node_conf_get BACKUP_KEEP 5)"
    # 2026-09-23: валидация (как в shieldnode): BACKUP_KEEP=abc под set -u давал
    # «abc: unbound variable» и die посреди записи файла
    case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
    ts="$(date '+%Y%m%d-%H%M%S')"
    cp -a "$path" "${path}.pre-node-${ts}" || die "backup failed: $path"
    bdir="$(dirname "$path")"
    ls -1t "$bdir"/"$(basename "$path")".pre-node-* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
    log debug "backup" "$path -> ${path}.pre-node-${ts}"
}

# atomic_write <dst> — прочитать stdin, записать tmp в той же ФС, mv
atomic_write() {
    local dst="$1" tmp
    # mktemp требует существующий каталог (аналогичный баг был в shieldnode)
    mkdir -p -- "$(dirname "$dst")" 2>/dev/null \
        || die "не удалось создать каталог $(dirname "$dst") для $dst"
    tmp="$(mktemp "$(dirname "$dst")/.node-write.XXXXXX")" || die "mktemp failed for $dst"
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$dst"
    log debug "persist" "wrote $dst"
}

# foreign_owner_keys — ключи sysctl, принадлежащие shieldnode (реестр владения)
foreign_owner_keys() {
    [ -f /var/lib/shieldnode/owner-keys.txt ] && cat /var/lib/shieldnode/owner-keys.txt || true
}

# validate_key_ownership <key> — вернуть 0 если ключ наш/свободен, 1 если чужой
validate_key_ownership() {
    local key="$1"
    grep -qxF "$key" <(foreign_owner_keys) && return 1
    return 0
}

# --- runtime-твики (ethtool/rings/offloads/txqueuelen/irq affinity): не переживают
# reboot, поэтому rollback восстанавливает их явно из реестра (ТЗ §16 reversibility).
NODE_RT_TWEAKS="$NODE_STATE_DIR/runtime-tweaks.tsv"

# node_rt_record <iface> <kind> <param> <orig> — kind: offload|ring_rx|ring_tx|txqueuelen|irq
node_rt_record() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    mkdir -p "$NODE_STATE_DIR"
    # re-apply: первый проход зафиксировал ИСХОДНОЕ значение — не перезаписываем
    # его текущим (уже подкрученным), иначе rollback вернёт не заводское состояние
    if [ -f "$NODE_RT_TWEAKS" ] && grep -qF "$(printf '%s\t%s\t%s\t' "$1" "$2" "$3")" "$NODE_RT_TWEAKS"; then
        log debug "rt" "tweak уже записан (re-apply), пропуск: $1/$2/$3"
        return 0
    fi
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$NODE_RT_TWEAKS"
    log debug "rt" "tweak recorded: $1/$2/$3 <- $4"
}

# node_rt_rollback — восстановить исходные значения runtime-твиков.
node_rt_rollback() {
    [ -f "$NODE_RT_TWEAKS" ] || return 0
    local iface kind param orig qf
    while IFS=$'\t' read -r iface kind param orig; do
        [ -n "$kind" ] || continue
        case "$kind" in
            offload)    command -v ethtool >/dev/null && ethtool -K "$iface" "$param" "$orig" >/dev/null 2>&1 \
                            && log info "rt" "offload $iface/$param restored=$orig" || true ;;
            ring_rx)    command -v ethtool >/dev/null && ethtool -G "$iface" rx "$orig" >/dev/null 2>&1 || true ;;
            ring_tx)    command -v ethtool >/dev/null && ethtool -G "$iface" tx "$orig" >/dev/null 2>&1 || true ;;
            coalesce)   command -v ethtool >/dev/null && ethtool -C "$iface" "$param" "$orig" >/dev/null 2>&1 \
                            && log info "rt" "coalesce $iface/$param restored=$orig" || true ;;
            eee)        command -v ethtool >/dev/null && ethtool --set-eee "$iface" eee "$orig" >/dev/null 2>&1 \
                            && log info "rt" "eee $iface restored=$orig" || true ;;
            rss)        # 2026-09-23: RSS indirection (ENABLE_RSS_BALANCE) раньше не откатывался вовсе
                        command -v ethtool >/dev/null && ethtool -X "$iface" default >/dev/null 2>&1 \
                            && log info "rt" "rss $iface indirection restored=default" || true ;;
            txqueuelen) ip link set dev "$iface" txqueuelen "$orig" >/dev/null 2>&1 && log info "rt" "txqueuelen $iface restored=$orig" || true ;;
            irq)        [ -w "/proc/irq/$param/smp_affinity_list" ] && echo "$orig" > "/proc/irq/$param/smp_affinity_list" 2>/dev/null \
                            && log info "rt" "irq $param affinity restored=$orig" || true ;;
            rps)        qf="/sys/class/net/$iface/queues/$param/rps_cpus"
                        [ -w "$qf" ] && printf '%s' "$orig" > "$qf" 2>/dev/null \
                            && log info "rt" "rps $iface/$param restored=$orig" || true ;;
            xps)        qf="/sys/class/net/$iface/queues/$param/xps_cpus"
                        [ -w "$qf" ] && printf '%s' "$orig" > "$qf" 2>/dev/null \
                            && log info "rt" "xps $iface/$param restored=$orig" || true ;;
            sysfs)      [ -w "/sys/$param" ] && printf '%s' "$orig" > "/sys/$param" 2>/dev/null \
                            && log info "rt" "sysfs /sys/$param restored=$orig" || true ;;
            mount)      findmnt -rn "$param" >/dev/null 2>&1 \
                            && mount -o "remount,$orig" "$param" >/dev/null 2>&1 \
                            && log info "rt" "mount $param remounted (orig opts)" || true ;;
            *)          log warn "rt" "unknown tweak kind: $kind" ;;
        esac
    done < "$NODE_RT_TWEAKS"
    rm -f "$NODE_RT_TWEAKS"
    ok "rt" "runtime tweaks restored"
}

# shellcheck source=lib/sysctl.sh
