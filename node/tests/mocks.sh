#!/bin/bash
# node — общие заглушки для тестов (v1.2.12): systemctl, sysctl, sshd. Не тест: файл подключают
# через source; заглушки — исполняемые файлы в <каталог bin>, его ставят первым в PATH.
#
#   mock_systemctl_install <каталог bin> <каталог состояния>
#       экспортирует MOCK_UNITS (состояние юнитов) и MOCK_SYSTEMCTL_LOG (журнал вызовов,
#       меняющих состояние).
#   mkunit <юнит> <is-enabled> <is-active> [static]   — завести юнит
#   ustate <юнит>                                      — «is-enabled/is-active»
#   mock_units_stock_node                              — юниты ноды «как от хостера» (до node)
#   mock_sysctl_install <каталог bin> <каталог состояния>
#       экспортирует SYSDB (значения ключей, key=value) и SYSCALLS (журнал всех вызовов).
#   mock_sshd_install <каталог bin>
#       sshd -V | -t -f CFG | -T -f CFG; журнал вызовов — в $SSHD_CALLS, если задан.
#
# --- systemctl ---
# Состояние юнита — файл $MOCK_UNITS/<юнит>: строка 1 — is-enabled, 2 — is-active, 3 — «static»
# для юнитов без [Install]. Поведение повторяет systemd там, где это важно коду node:
#   * имя — только полное: `list-unit-files ModemManager` (без .service) ничего не находит;
#   * disable не меняет static и masked; --now останавливает;
#   * unmask возвращает static/disabled (disable перед mask уже снял включение);
#   * start замаскированного юнита и reload неактивного — ошибка;
#   * MOCK_STUBBORN="юнит …" — юнит переживает stop (служба, которую D-Bus поднимает снова);
#   * MOCK_RELOAD_FAIL=1 — reload завершается ошибкой.
set -euo pipefail

mock_systemctl_install() {
    local bin="$1" state="$2"
    mkdir -p "$bin" "$state/units"
    export MOCK_UNITS="$state/units" MOCK_SYSTEMCTL_LOG="$state/systemctl.log"
    : > "$MOCK_SYSTEMCTL_LOG"
    cat > "$bin/systemctl" <<'MOCK'
#!/bin/bash
U="${MOCK_UNITS:?}"; LOG="${MOCK_SYSTEMCTL_LOG:-/dev/null}"
cmd="${1:-}"; [ $# -gt 0 ] && shift
quiet=0; now=0; units=()
for a in "$@"; do
    case "$a" in
        --quiet|-q) quiet=1 ;;
        --now) now=1 ;;
        -*) ;;
        *) units+=("$a") ;;
    esac
done
st() { sed -n "${2}p" "$U/$1" 2>/dev/null; }
say() { [ "$quiet" = 1 ] || echo "$1"; }
stubborn() { case " ${MOCK_STUBBORN:-} " in *" $1 "*) return 0 ;; esac; return 1; }
case "$cmd" in
    is-enabled)
        u="${units[0]:-}"
        [ -f "$U/$u" ] || { say not-found; exit 4; }
        e="$(st "$u" 1)"; say "$e"
        case "$e" in enabled|enabled-runtime|static|alias|indirect|generated) exit 0 ;; esac
        exit 1 ;;
    is-active)
        u="${units[0]:-}"
        [ -f "$U/$u" ] || { say inactive; exit 4; }
        a="$(st "$u" 2)"; say "$a"
        [ "$a" = active ] && exit 0
        exit 3 ;;
    list-unit-files)
        for u in ${units[@]+"${units[@]}"}; do
            if [ -f "$U/$u" ]; then echo "$u $(st "$u" 1) -"; fi
        done
        exit 0 ;;
    cat)
        [ -f "$U/${units[0]:-}" ] && exit 0
        exit 1 ;;
    daemon-reload)
        echo "daemon-reload" >> "$LOG"; exit 0 ;;
    disable|enable|mask|unmask|start|stop|reload|restart|try-reload-or-restart)
        echo "$cmd $*" >> "$LOG"
        rc=0
        for u in ${units[@]+"${units[@]}"}; do
            [ -f "$U/$u" ] || { rc=1; continue; }
            e="$(st "$u" 1)"; a="$(st "$u" 2)"; k="$(st "$u" 3)"
            case "$cmd" in
                disable)
                    if [ "$e" != masked ] && [ "$k" != static ]; then e=disabled; fi
                    if [ "$now" = 1 ] && ! stubborn "$u"; then a=inactive; fi ;;
                enable)
                    case "$e" in masked) rc=1 ;; static) ;; *) e=enabled ;; esac
                    if [ "$now" = 1 ] && [ "$e" != masked ]; then a=active; fi ;;
                mask)   e=masked ;;
                unmask) if [ "$e" = masked ]; then if [ "$k" = static ]; then e=static; else e=disabled; fi; fi ;;
                start)  if [ "$e" = masked ]; then rc=1; else a=active; fi ;;
                stop)   stubborn "$u" || a=inactive ;;
                reload|try-reload-or-restart)
                    if [ "${MOCK_RELOAD_FAIL:-0}" = 1 ] || [ "$a" != active ]; then rc=1; fi ;;
                restart) if [ "$e" = masked ]; then rc=1; else a=active; fi ;;
            esac
            printf '%s\n%s\n%s\n' "$e" "$a" "$k" > "$U/$u"
        done
        exit "$rc" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$bin/systemctl"
}

mkunit() { printf '%s\n%s\n%s\n' "$2" "$3" "${4:-}" > "$MOCK_UNITS/$1"; }
ustate() { printf '%s/%s\n' "$(sed -n 1p "$MOCK_UNITS/$1" 2>/dev/null)" "$(sed -n 2p "$MOCK_UNITS/$1" 2>/dev/null)"; }

# юниты ноды «как от хостера», до node и до разового скрипта (состояния — с живой ноды 14.11)
mock_units_stock_node() {
    mkunit ModemManager.service enabled active
    mkunit udisks2.service enabled active
    mkunit multipathd.service enabled active
    mkunit multipathd.socket disabled active
    mkunit fwupd.service static active static
    mkunit fwupd-refresh.timer enabled active
    mkunit upower.service disabled active
    mkunit networkd-dispatcher.service enabled active
    mkunit unattended-upgrades.service enabled active
    mkunit man-db.timer enabled active
    mkunit apport-autoreport.timer enabled inactive
    mkunit apport-autoreport.path enabled inactive
    mkunit update-notifier-download.timer enabled active
    mkunit update-notifier-motd.timer enabled active
    mkunit ua-timer.timer enabled inactive
    mkunit snapd.snap-repair.timer enabled inactive
    mkunit mdcheck_start.timer enabled active
    mkunit mdcheck_continue.timer enabled active
    mkunit mdmonitor-oneshot.timer enabled active
    mkunit apt-daily.timer enabled active
    mkunit apt-daily-upgrade.timer enabled active
    mkunit motd-news.timer disabled inactive
    # то, что должно остаться нетронутым при любых флагах
    mkunit ssh.service enabled active
    mkunit docker.service enabled active
    mkunit systemd-timesyncd.service enabled active
    mkunit cron.service enabled active
}

# --- sysctl ---
# -n KEY | -w KEY=VAL | -qw KEY=VAL | -p FILE по файлу $SYSDB. Настоящие значения ядра заглушка
# не пишет никогда. kernel.* не изолируются сетевым namespace — такие ключи тестам трогать нельзя.
#   ключа нет в $SYSDB          — «нет в ядре» (rc 255)
#   SYSCTL_RO="key …"           — ключ только для чтения (контейнер): запись — rc 255
#   SYSCTL_PASS=1               — ключ, которого нет в $SYSDB, ЧИТАТЬ настоящим sysctl (для status)
mock_sysctl_install() {
    local bin="$1" state="$2" real
    mkdir -p "$bin" "$state"
    export SYSDB="$state/sysdb" SYSCALLS="$state/sysctl.calls"
    : > "$SYSDB"; : > "$SYSCALLS"
    real="$(command -v sysctl 2>/dev/null || true)"
    case "$real" in "$bin"/*) real="" ;; esac
    cat > "$bin/sysctl" <<MOCK
#!/bin/bash
REAL="$real"
MOCK
    cat >> "$bin/sysctl" <<'MOCK'
echo "$*" >> "$SYSCALLS"
case "${1:-}" in -qw) set -- -w "$2" ;; esac
case "${1:-}" in
    -n) if grep -q "^$2=" "$SYSDB"; then awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print }' "$SYSDB"; exit 0; fi
        if [ "${SYSCTL_PASS:-0}" = 1 ] && [ -n "$REAL" ]; then exec "$REAL" -n "$2"; fi
        exit 255 ;;
    -w) k="${2%%=*}"; v="${2#*=}"
        case " ${SYSCTL_RO:-} " in *" $k "*) echo "sysctl: permission denied on key \"$k\"" >&2; exit 255 ;; esac
        grep -q "^$k=" "$SYSDB" || exit 255
        grep -v "^$k=" "$SYSDB" > "$SYSDB.t"; echo "$k=$v" >> "$SYSDB.t"; mv "$SYSDB.t" "$SYSDB" ;;
    -p) while IFS= read -r line; do
            case "$line" in '#'*|'') continue ;; esac
            k="$(printf '%s' "${line%%=*}" | tr -d ' ')"; v="$(printf '%s' "${line#*=}" | sed 's/^ *//')"
            "$0" -w "$k=$v" || exit 255
        done < "$2" ;;
esac
exit 0
MOCK
    chmod +x "$bin/sysctl"
}

# --- sshd ---
# -V | -t -f CFG | -T -f CFG. Конфиг разбирается как у sshd: Include раскрывается на месте, файлы
# каталога — по имени, действует ПЕРВОЕ значение директивы.
#   MOCK_SSHD_VER=8.2    версия (PerSource* при версии < 8.5 — «Bad configuration option»)
#   MOCK_SSHD_NOVER=1    версию узнать нельзя
#   MOCK_SSHD_REJECT="директива …"  sshd -t их не принимает
#   MOCK_SSHD_BROKEN=1   sshd -t не проходит при любом конфиге
mock_sshd_install() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/sshd" <<'MOCK'
#!/bin/bash
export LC_ALL=C
echo "$*" >> "${SSHD_CALLS:-/dev/null}"
mode=""; cfg=/nonexistent
while [ $# -gt 0 ]; do
    case "$1" in -V) mode=V ;; -t) mode=t ;; -T) mode=T ;; -f) shift; cfg="${1:-}" ;; esac
    shift
done
ver="${MOCK_SSHD_VER:-9.6}"
if [ "$mode" = V ]; then
    if [ "${MOCK_SSHD_NOVER:-0}" = 1 ]; then echo "sshd: illegal option -- V" >&2; exit 1; fi
    echo "OpenSSH_${ver}p1 Ubuntu-3ubuntu13.18, OpenSSL 3.0.13 30 Jan 2024" >&2; exit 0
fi
[ -r "$cfg" ] || { echo "$cfg: No such file or directory" >&2; exit 255; }
lines() { # <файл> — «<в Match: 0|1> <директива> <значение>» по порядку чтения
    local line kw rest f
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        kw="${line%%[[:space:]]*}"; rest="${line#"$kw"}"; rest="${rest#"${rest%%[![:space:]]*}"}"
        case "${kw,,}" in
            include)
                rest="${rest//\"/}"
                case "$rest" in /*) ;; *) rest="$(dirname "$cfg")/$rest" ;; esac
                for f in $rest; do [ -f "$f" ] && lines "$f"; done ;;
            match) inmatch=1 ;;
            *) echo "$inmatch ${kw,,} $rest" ;;
        esac
    done < "$1"
}
inmatch=0; all="$(lines "$cfg")"
if [ "$mode" = t ]; then
    [ "${MOCK_SSHD_BROKEN:-0}" = 1 ] && { echo "$cfg: line 1: Bad configuration option: Broken" >&2; echo "$cfg: terminating, 1 bad configuration options" >&2; exit 255; }
    old=0; case "$ver" in [0-7].*|8.[0-4]) old=1 ;; esac
    while read -r m kw _; do
        [ -n "$kw" ] || continue
        case " ${MOCK_SSHD_REJECT:-} " in *" $kw "*) echo "$cfg: Bad configuration option: $kw" >&2; exit 255 ;; esac
        case "$kw" in persource*) [ "$old" = 1 ] && { echo "$cfg: Bad configuration option: $kw" >&2; exit 255; } ;; esac
        case "$m:$kw" in 1:maxstartups|1:logingracetime|1:persource*) echo "Directive '$kw' is not allowed within a Match block" >&2; exit 255 ;; esac
    done <<<"$all"
    exit 0
fi
if [ "$mode" = T ]; then
    {   printf '%s\n' "$all" | awk '$1 == 0 { print $2, $3 }'
        printf '%s\n' "logingracetime 120" "maxstartups 10:30:100" "persourcemaxstartups none" "persourcenetblocksize 32:128" \
            "passwordauthentication yes" "pubkeyauthentication yes" "kbdinteractiveauthentication no" "permitrootlogin without-password"
    } | awk '!seen[$1]++ { if ($1 == "logingracetime") sub(/s$/, "", $2); print }'
    exit 0
fi
exit 0
MOCK
    chmod +x "$bin/sshd"
}
