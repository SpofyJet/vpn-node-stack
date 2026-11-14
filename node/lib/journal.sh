#!/bin/bash
# node — lib/journal.sh: журнал ядра без строки на каждый отброшенный пакет (v1.2.13, 2026-11-14).
#
# Нода Remnawave держит в таблице nft (`remnanode`) правила «адрес в списке — пакет отбросить» для
# заблокированных за торренты (torrent-blocker) и занесённых в списки панели (ingress-filter-ip).
# По умолчанию каждое такое правило ещё и пишет КАЖДЫЙ отброшенный пакет в журнал ядра, без
# предела, а rsyslog кладёт строку и в kern.log, и в syslog. Замер 14.11.2026: на одной ноде
# 962 821 строка и 253 МБ в kern.log за шесть суток (столько же в syslog), на другой — 1,58 млн
# строк и 425 МБ за неделю. Строка — около 260 байт в каждом из двух файлов: заблокированный
# адрес, который шлёт 10 000 пакетов в секунду по уже открытому соединению, пишет 19 ГБ в час —
# диск ноды кончается за несколько часов, и никакой предел его не останавливает (ротация раз в
# неделю).
#
#   QUIET_NFT_PACKET_LOG=1 (по умолчанию) -> /etc/rsyslog.d/10-node-nftlog.conf
#     Строки ядра с этими двумя префиксами в файлы /var/log не пишутся. В journald они остаются
#     (`journalctl -k`): у него свой предел размера, диск он не займёт.
#
# Источник строк — настройка самой ноды: `NFTABLES_LOGGING=false` в docker-compose remnanode
# убирает запись из правил (вступает при пересоздании контейнера). docker-compose — не файл
# стека, node его не правит; `status` показывает, пишет ли нода каждый пакет.
#
# Правила модуля:
#   * только свой файл в /etc/rsyslog.d (через node_persist: манифест, rollback его удаляет);
#   * rsyslogd -N1 до записи (чужая ошибка — rsyslog не трогаем) и после (наша — файл убирается);
#   * перезапуск rsyslog — только если файл изменился и служба работает;
#   * rsyslog не установлен — пропуск: файлов kern.log и syslog тогда нет.
set -euo pipefail

NODE_RSYSLOG_DIR="${NODE_RSYSLOG_DIR:-/etc/rsyslog.d}"
NODE_RSYSLOG_FILE="$NODE_RSYSLOG_DIR/10-node-nftlog.conf"

# путь к rsyslogd (тесты: NODE_RSYSLOGD_BIN); нет rsyslogd — rc 1
node_journal_rsyslogd() {
    local b="${NODE_RSYSLOGD_BIN:-}"
    [ -n "$b" ] || b="$(command -v rsyslogd 2>/dev/null || true)"
    [ -n "$b" ] || b=/usr/sbin/rsyslogd
    [ -x "$b" ] || return 1
    echo "$b"
}

# rsyslogd -N1: rc 0 — конфиг на диске верен; текст ошибки — в stdout вызывающему
_node_journal_test() { "$(node_journal_rsyslogd)" -N1 2>&1; }

# первая содержательная строка ошибки rsyslogd (без строки «version …, config validation run»)
_node_journal_err1() { printf '%s\n' "$1" | grep -vE 'config validation run|End of config validation' | head -n 1; }

_node_journal_text() {
    echo "# node — managed by node, do not edit (QUIET_NFT_PACKET_LOG=1; 0 в /etc/node/node.conf — убрать файл)."
    echo "# Нода Remnawave пишет в журнал ядра каждый отброшенный пакет заблокированного адреса"
    echo "# (правила таблицы nft remnanode с этими префиксами, без предела). В файлы /var/log такие"
    echo "# строки не кладём — иначе поток пакетов с одного адреса занимает диск; в journald они остаются."
    echo 'if $syslogfacility-text == "kern" and ($msg contains "torrent-blocker: " or $msg contains "ingress-filter-ip: ") then stop'
}

# отпечаток файла стека: rsyslog перезапускается, только если он изменился
_node_journal_sig() {
    if [ -f "$NODE_RSYSLOG_FILE" ]; then cksum < "$NODE_RSYSLOG_FILE"; else echo none; fi
}

# _node_journal_undo <был ли файл до записи: 0|1> <прежнее содержимое> — вернуть как было
_node_journal_undo() {
    if [ "$1" = 1 ]; then
        printf '%s\n' "$2" | node_persist "$NODE_RSYSLOG_FILE" >/dev/null 2>&1 || true
    else
        rm -f -- "$NODE_RSYSLOG_FILE" "$NODE_RSYSLOG_FILE".pre-node-* 2>/dev/null || true
    fi
}

# флаг выключен: убрать СВОЙ файл (создан node по реестру происхождения); rc 0 — убран
_node_journal_remove() {
    local f="$NODE_RSYSLOG_FILE" reg="$NODE_STATE_DIR/file-origins.tsv"
    [ -f "$f" ] || return 1
    if awk -F'\t' -v p="$f" '$1 == p && $2 == "created" { f = 1 } END { exit !f }' "$reg" 2>/dev/null; then
        rm -f -- "$f" "$f".pre-node-* 2>/dev/null || true
        return 0
    fi
    log info "journal" "$f создан не node — оставлен"
    return 1
}

# node_journal_restart — rsyslog перечитывает конфиг только при запуске (reload у него лишь
# переоткрывает файлы), поэтому restart; служба не работает — файл вступит при её запуске
node_journal_restart() {
    if ! systemctl is-active --quiet rsyslog.service 2>/dev/null; then
        log info "journal" "служба rsyslog сейчас не работает — файл вступит при её запуске"
        return 0
    fi
    if systemctl restart rsyslog.service >/dev/null 2>&1; then
        ok "journal" "rsyslog перезапущен (systemctl restart rsyslog.service)"
        return 0
    fi
    warn "journal" "systemctl restart rsyslog.service не удался — файл на диске верен (rsyslogd -N1), вступит при следующем запуске rsyslog"
    return 1
}

# node_journal_packet_log_rules — сколько правил nft пишут в журнал каждый пакет заблокированного
# адреса без предела (только чтение; nft -t — без содержимого наборов). Нет nft или прав — «?».
node_journal_packet_log_rules() {
    [ "$(id -u)" -eq 0 ] && command -v nft >/dev/null 2>&1 || { echo "?"; return 0; }
    { nft -t list ruleset 2>/dev/null || true; } \
        | awk '/log prefix "(torrent-blocker|ingress-filter-ip): "/ && !/limit rate/ { n++ } END { print n + 0 }'
}

node_journal_plan() {
    log info "journal" "plan: quiet_nft_log=$(node_conf_get QUIET_NFT_PACKET_LOG 1) (строки torrent-blocker / ingress-filter-ip не писать в файлы /var/log — $NODE_RSYSLOG_FILE)"
}

node_journal_apply() {
    local on f="$NODE_RSYSLOG_FILE" before prev="" had=0 err rc=0 n
    on="$(node_conf_get QUIET_NFT_PACKET_LOG 1)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "journal: would manage $f (quiet_nft_log=$on), rsyslogd -N1, restart rsyslog"
        return 0
    fi
    before="$(_node_journal_sig)"
    if [ "$on" != 1 ]; then
        if _node_journal_remove; then
            log info "journal" "QUIET_NFT_PACKET_LOG=0 — убран $f: строки об отброшенных пакетах снова пишутся в kern.log и syslog"
        fi
    elif [ ! -d "$NODE_RSYSLOG_DIR" ] || ! node_journal_rsyslogd >/dev/null; then
        log info "journal" "rsyslog не установлен — файлов kern.log и syslog нет, пропуск"
    elif ! err="$(_node_journal_test)"; then
        warn "journal" "rsyslogd -N1 не проходит ещё до записи файла node ($(_node_journal_err1 "$err")) — rsyslog не трогаем, сначала исправь его конфиг"
    else
        if [ -f "$f" ]; then prev="$(cat "$f")"; had=1; fi
        if ! _node_journal_text | node_persist "$f"; then
            warn "journal" "не удалось записать $f"
            rc=1
        elif ! err="$(_node_journal_test)"; then
            _node_journal_undo "$had" "$prev"
            warn "journal" "rsyslogd -N1 отверг $f ($(_node_journal_err1 "$err")) — файл возвращён в прежнее состояние, строки об отброшенных пакетах пишутся в файлы как раньше"
            rc=1
        fi
    fi
    if [ "$(_node_journal_sig)" != "$before" ]; then
        node_journal_restart || rc=1
    fi
    # источник строк — сама нода: скажем, если она всё ещё пишет каждый пакет
    n="$(node_journal_packet_log_rules)"
    case "$n" in
        "?"|0) ;;
        *) warn "journal" "нода пишет в журнал ядра каждый отброшенный пакет заблокированного адреса (правил: $n). В файлы это больше не попадает, но убрать совсем — NFTABLES_LOGGING=false в docker-compose remnanode и пересоздать контейнер" ;;
    esac
    return "$rc"
}

# node_journal_rollback_restart <отпечаток до отката> — rollback убрал файл стека по манифесту:
# работающий rsyslog должен перечитать конфиг, иначе фильтр действовал бы до его перезапуска
node_journal_rollback_restart() {
    [ "$(_node_journal_sig)" != "$1" ] || return 0
    node_journal_rsyslogd >/dev/null || return 0
    node_journal_restart || true
    return 0
}

# строка для status (только чтение)
node_journal_status() {
    local n src
    n="$(node_journal_packet_log_rules)"
    case "$n" in
        "?") src="не проверено (нужны root и nft)" ;;
        0)   src="нет" ;;
        *)   src="ДА, правил: $n — NFTABLES_LOGGING=false в docker-compose remnanode и пересоздать контейнер" ;;
    esac
    echo "журнал: quiet_nft_log=$(node_conf_get QUIET_NFT_PACKET_LOG 1) (файл rsyslog: $([ -f "$NODE_RSYSLOG_FILE" ] && echo есть || echo нет)); нода пишет в журнал каждый отброшенный пакет: $src"
}
