#!/bin/bash
# node — lib/sshd.sh: sshd — пределы на незавершённые входы и (по запросу) вход только по ключу
# (v1.2.12, 2026-11-14). До этой версии то же ставилось разовым скриптом на каждый сервер.
#
#   HARDEN_SSHD_LIMITS=1 (по умолчанию) -> /etc/ssh/sshd_config.d/01-node-limits.conf
#     Вход в SSH нельзя забить пустыми соединениями: по умолчанию у sshd 100 мест для
#     незавершённых входов и каждое держится 120 с. Ставим 30 с на вход, 200 мест и не больше 10
#     незавершённых входов с одной сети /24. Кто может войти — не меняется.
#   HARDEN_SSH_PASSWORD_OFF=1 (по запросу) -> /etc/ssh/sshd_config.d/00-node-keys-only.conf
#     Вход только по ключу. Замер на девяти нодах: 4 293 попытки с неверным паролем за сутки.
#     Выключаем, только если root точно войдёт по ключу, иначе сервер закроется от владельца.
#
# Правила модуля:
#   * основной sshd_config не трогаем — только свои файлы в sshd_config.d (через node_persist:
#     манифест, rollback их удаляет); нет Include на каталог — пропуск с предупреждением;
#   * sshd -t до записи (чужая ошибка — не наша, SSH не трогаем) и после (наша — файл возвращается
#     в прежнее состояние); reload, не restart, и только если файлы изменились;
#   * флаг выключен — свой файл убирается (как и остальные настройки стека).
# У sshd побеждает ПЕРВОЕ значение директивы: имена 00-/01- читаются раньше файлов хостера
# (50-cloud-init.conf) и строк основного конфига после Include.
set -euo pipefail

NODE_SSHD_CONFIG="${NODE_SSHD_CONFIG:-/etc/ssh/sshd_config}"
NODE_SSHD_DIR="${NODE_SSHD_DIR:-/etc/ssh/sshd_config.d}"
NODE_SSHD_LIMITS_FILE="$NODE_SSHD_DIR/01-node-limits.conf"
NODE_SSHD_KEYS_FILE="$NODE_SSHD_DIR/00-node-keys-only.conf"

# путь к sshd (тесты: NODE_SSHD_BIN); нет sshd — rc 1
node_sshd_bin() {
    local b="${NODE_SSHD_BIN:-}"
    [ -n "$b" ] || b="$(command -v sshd 2>/dev/null || true)"
    [ -n "$b" ] || b=/usr/sbin/sshd
    [ -x "$b" ] || return 1
    echo "$b"
}

# sshd -t: rc 0 — конфиг на диске верен; текст ошибки — в stdout вызывающему
_node_sshd_test() { "$(node_sshd_bin)" -t -f "$NODE_SSHD_CONFIG" 2>&1; }

# _node_sshd_eff <директива в нижнем регистре> — действующее значение (sshd -T); пусто — не узнали.
# awk читает вывод до конца (без exit): иначе sshd получил бы SIGPIPE и pipefail уронил бы вызов.
_node_sshd_eff() {
    { "$(node_sshd_bin)" -T -f "$NODE_SSHD_CONFIG" 2>/dev/null || true; } \
        | awk -v k="$1" '$1 == k && !d { sub(/^[^ ]+ /, ""); print; d = 1 }'
}

# основной конфиг подключает наш каталог (Include …/sshd_config.d/*.conf) в глобальной части:
# Include после первого Match относится к этому Match — глобальные директивы там недопустимы
node_sshd_has_include() {
    [ -r "$NODE_SSHD_CONFIG" ] || return 1
    local kw rest p base parts
    base="$(dirname "$NODE_SSHD_DIR")"
    while read -r kw rest || [ -n "$kw" ]; do
        case "${kw,,}" in
            match) return 1 ;;
            include) ;;
            *) continue ;;
        esac
        read -r -a parts <<<"$rest"   # без подстановки путей: шаблон нужен как текст
        for p in ${parts[@]+"${parts[@]}"}; do
            p="${p//\"/}"
            case "$p" in /*) ;; *) p="$base/$p" ;; esac
            # shellcheck disable=SC2053  # справа — шаблон из Include, сравнение по шаблону намеренное
            [[ "$NODE_SSHD_LIMITS_FILE" == $p ]] && return 0
        done
    done < "$NODE_SSHD_CONFIG"
    return 1
}

# PerSourceMaxStartups/PerSourceNetBlockSize появились в OpenSSH 8.5. Версию не узнали — считаем,
# что есть: sshd -t после записи проверит, и при отказе файл перепишется без них.
node_sshd_persource_supported() {
    local v maj min
    v="$("$(node_sshd_bin)" -V 2>&1 | sed -n '/OpenSSH_[0-9]/{s/.*OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p;q}')" || true
    [ -n "$v" ] || return 0
    read -r maj min <<<"$v"
    [ "$maj" -gt 8 ] || { [ "$maj" -eq 8 ] && [ "$min" -ge 5 ]; }
}

# node_sshd_root_keys — сколько у root ключей, дающих вход с оболочкой. Ключ с command="…"
# выполняет только свою команду — войти им нельзя, не считаем.
node_sshd_root_keys() {
    local f="${NODE_SSH_ROOT_KEYS:-/root/.ssh/authorized_keys}" lines kg n
    [ -r "$f" ] || { echo 0; return 0; }
    lines="$(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE '^[[:space:]]*([A-Za-z-]+(="([^"\\]|\\.)*")?,)*command=' || true)"
    [ -n "$lines" ] || { echo 0; return 0; }
    kg="${NODE_SSH_KEYGEN_BIN:-$(command -v ssh-keygen 2>/dev/null || true)}"
    if [ -n "$kg" ] && [ -x "$kg" ]; then
        # ssh-keygen -l печатает строку на каждый ключ, который sshd сможет разобрать
        n="$(printf '%s\n' "$lines" | "$kg" -l -f /dev/stdin 2>/dev/null | grep -c . || true)"
    else
        n="$(printf '%s\n' "$lines" | grep -cE '(^|[[:space:]])(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+AAAA[0-9A-Za-z+/]+' || true)"
    fi
    echo "${n:-0}"
}

node_sshd_plan() {
    log info "sshd" "plan: limits=$(node_conf_get HARDEN_SSHD_LIMITS 1) (LoginGraceTime 30, MaxStartups 60:30:200, не больше 10 незавершённых входов с сети /24) password_off=$(node_conf_get HARDEN_SSH_PASSWORD_OFF 0)"
}

_node_sshd_limits_text() { # <1 — с PerSource*, 0 — без>
    echo "# node — managed by node, do not edit (HARDEN_SSHD_LIMITS=1; 0 в /etc/node/node.conf — убрать файл)."
    echo "# Незавершённые входы в SSH: 30 с на вход вместо 120; очередь 60 с отбросом до 200 мест"
    echo "# (у sshd по умолчанию 10:30:100); не больше 10 незавершённых входов с одной сети /24"
    echo "# (IPv6 — /64). Кто может войти — не меняется."
    echo "LoginGraceTime 30"
    echo "MaxStartups 60:30:200"
    if [ "$1" = 1 ]; then
        echo "PerSourceMaxStartups 10"
        echo "PerSourceNetBlockSize 24:64"
    fi
}

_node_sshd_keys_text() {
    echo "# node — managed by node, do not edit (HARDEN_SSH_PASSWORD_OFF=1). Вход в SSH только по ключу."
    echo "# Вернуть вход по паролю: HARDEN_SSH_PASSWORD_OFF=0 в /etc/node/node.conf и apply."
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
}

# отпечаток двух файлов стека: reload — только если он изменился
_node_sshd_sig() {
    local f
    for f in "$NODE_SSHD_LIMITS_FILE" "$NODE_SSHD_KEYS_FILE"; do
        if [ -f "$f" ]; then cksum < "$f"; else echo none; fi
    done
}

# _node_sshd_undo <файл> <был ли до записи: 0|1> <прежнее содержимое> — вернуть как было
_node_sshd_undo() {
    if [ "$2" = 1 ]; then
        printf '%s\n' "$3" | node_persist "$1" >/dev/null 2>&1 || true
    else
        rm -f -- "$1" "$1".pre-node-* 2>/dev/null || true
    fi
}

# _node_sshd_remove <файл> — флаг выключен: убрать СВОЙ файл (создан node по реестру происхождения)
_node_sshd_remove() {
    local f="$1" reg="$NODE_STATE_DIR/file-origins.tsv"
    [ -f "$f" ] || return 1
    if awk -F'\t' -v p="$f" '$1 == p && $2 == "created" { f = 1 } END { exit !f }' "$reg" 2>/dev/null; then
        rm -f -- "$f" "$f".pre-node-* 2>/dev/null || true
        return 0
    fi
    log info "sshd" "$f создан не node — оставлен"
    return 1
}

_node_sshd_limits_apply() {
    local f="$NODE_SSHD_LIMITS_FILE" prev="" had=0 full=1 err v
    if [ -f "$f" ]; then prev="$(cat "$f")"; had=1; fi
    node_sshd_persource_supported || full=0
    _node_sshd_limits_text "$full" | node_persist "$f" || { warn "sshd" "не удалось записать $f"; return 1; }
    if [ "$full" = 1 ] && ! err="$(_node_sshd_test)"; then
        # версию не узнали, а sshd новый файл отверг — пробуем без PerSource*
        full=0
        _node_sshd_limits_text 0 | node_persist "$f" || { _node_sshd_undo "$f" "$had" "$prev"; return 1; }
    fi
    if ! err="$(_node_sshd_test)"; then
        _node_sshd_undo "$f" "$had" "$prev"
        warn "sshd" "sshd -t отверг $f (${err%%$'\n'*}) — файл возвращён в прежнее состояние, пределы входа не поставлены"
        return 1
    fi
    [ "$full" = 1 ] || log info "sshd" "OpenSSH старше 8.5 — пределы записаны без PerSourceMaxStartups (предела на одну сеть нет)"
    # действует ли: файл с меньшим именем или строка до Include могли задать значение раньше
    v="$(_node_sshd_eff maxstartups)"
    if [ -n "$v" ] && [ "$v" != "60:30:200" ]; then
        warn "sshd" "MaxStartups задан раньше нашего файла: действует $v, а не 60:30:200 — проверь $NODE_SSHD_DIR и $NODE_SSHD_CONFIG"
    fi
    return 0
}

_node_sshd_keys_apply() {
    local f="$NODE_SSHD_KEYS_FILE" prev="" had=0 changed=0 want err p k prl n
    want="$(_node_sshd_keys_text)"
    if [ -f "$f" ]; then prev="$(cat "$f")"; had=1; fi
    if [ "$had" = 0 ] || [ "$prev" != "$want" ]; then
        # --- до записи: root обязан входить по ключу, иначе закроем сервер от владельца ---
        k="$(_node_sshd_eff pubkeyauthentication)"
        if [ "$k" != yes ]; then
            log error "sshd" "HARDEN_SSH_PASSWORD_OFF=1: вход по ключу выключен или sshd -T не читается (pubkeyauthentication='${k:-?}') — вход по паролю НЕ выключен"
            return 1
        fi
        prl="$(_node_sshd_eff permitrootlogin)"
        case "$prl" in
            yes|prohibit-password|without-password) ;;
            *)  log error "sshd" "HARDEN_SSH_PASSWORD_OFF=1: вход root по SSH запрещён или ограничен (PermitRootLogin ${prl:-?}) — ключ root не поможет войти; вход по паролю НЕ выключен"
                return 1 ;;
        esac
        n="$(node_sshd_root_keys)"
        if ! [ "${n:-0}" -ge 1 ] 2>/dev/null; then
            log error "sshd" "HARDEN_SSH_PASSWORD_OFF=1: у root нет ключа в ${NODE_SSH_ROOT_KEYS:-/root/.ssh/authorized_keys} — вход по паролю НЕ выключен (после этого на сервер было бы не войти). Добавь ключ, проверь вход по нему и повтори apply"
            return 1
        fi
        printf '%s\n' "$want" | node_persist "$f" || { warn "sshd" "не удалось записать $f"; return 1; }
        changed=1
        if ! err="$(_node_sshd_test)"; then
            _node_sshd_undo "$f" "$had" "$prev"
            log error "sshd" "sshd -t отверг $f (${err%%$'\n'*}) — файл возвращён в прежнее состояние, вход по паролю НЕ выключен"
            return 1
        fi
    fi
    p="$(_node_sshd_eff passwordauthentication)"; k="$(_node_sshd_eff pubkeyauthentication)"
    if [ "$p" != no ] || [ "$k" != yes ]; then
        [ "$changed" = 1 ] && _node_sshd_undo "$f" "$had" "$prev"
        log error "sshd" "HARDEN_SSH_PASSWORD_OFF=1 не действует: sshd -T показывает passwordauthentication=${p:-?} pubkeyauthentication=${k:-?} (значение задано раньше — файлом с меньшим именем или строкой до Include)$([ "$changed" = 1 ] && echo ' — файл возвращён в прежнее состояние')"
        return 1
    fi
    if [ "$(_node_sshd_eff kbdinteractiveauthentication)" = yes ]; then
        warn "sshd" "KbdInteractiveAuthentication остался yes (задан раньше нашего файла) — вход по паролю через PAM ещё возможен"
    fi
    [ "$changed" = 1 ] && ok "sshd" "вход по паролю выключен, только по ключу (ключей root: $n)"
    return 0
}

# node_sshd_reload — перечитать конфиг работающим sshd (reload, не restart: открытые сессии живут)
node_sshd_reload() {
    local u
    for u in ssh.service sshd.service; do
        systemctl is-active --quiet "$u" 2>/dev/null || continue
        if systemctl reload "$u" >/dev/null 2>&1; then
            ok "sshd" "sshd перечитал конфиг (systemctl reload $u), открытые сессии не затронуты"
            return 0
        fi
        warn "sshd" "systemctl reload $u не удался — файлы на диске верны (sshd -t), вступят при следующем запуске sshd; вручную: systemctl reload $u"
        return 1
    done
    log info "sshd" "служба sshd сейчас не запущена (socket-активация?) — настройки вступят при её запуске"
    return 0
}

node_sshd_apply() {
    local lim pw rc=0 before err
    lim="$(node_conf_get HARDEN_SSHD_LIMITS 1)"; pw="$(node_conf_get HARDEN_SSH_PASSWORD_OFF 0)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "sshd: would manage $NODE_SSHD_LIMITS_FILE (limits=$lim) and $NODE_SSHD_KEYS_FILE (password_off=$pw), sshd -t, reload"
        return 0
    fi
    if ! node_sshd_bin >/dev/null; then
        log info "sshd" "sshd не установлен — пропуск"
        return 0
    fi
    before="$(_node_sshd_sig)"
    # выключенный флаг — свой файл убрать (Include для этого не нужен)
    if [ "$lim" != 1 ] && _node_sshd_remove "$NODE_SSHD_LIMITS_FILE"; then
        log info "sshd" "HARDEN_SSHD_LIMITS=0 — убран $NODE_SSHD_LIMITS_FILE (пределы входа — как у sshd по умолчанию)"
    fi
    if [ "$pw" != 1 ] && _node_sshd_remove "$NODE_SSHD_KEYS_FILE"; then
        warn "sshd" "HARDEN_SSH_PASSWORD_OFF=0 — убран $NODE_SSHD_KEYS_FILE: вход по паролю снова определяется остальным конфигом sshd (сейчас passwordauthentication=$(_node_sshd_eff passwordauthentication))"
    fi
    if [ "$lim" = 1 ] || [ "$pw" = 1 ]; then
        if ! node_sshd_has_include; then
            warn "sshd" "в $NODE_SSHD_CONFIG нет Include $NODE_SSHD_DIR/*.conf (в глобальной части) — настройки sshd не ставим: основной конфиг стек не правит"
        elif ! err="$(_node_sshd_test)"; then
            warn "sshd" "sshd -t не проходит ещё до записи файлов node (${err%%$'\n'*}) — SSH не трогаем, сначала исправь конфиг"
        else
            if [ "$lim" = 1 ]; then _node_sshd_limits_apply || rc=1; fi
            if [ "$pw" = 1 ]; then _node_sshd_keys_apply || rc=1; fi
        fi
    fi
    if [ "$(_node_sshd_sig)" != "$before" ]; then
        if err="$(_node_sshd_test)"; then
            node_sshd_reload || rc=1
        else
            warn "sshd" "sshd -t не проходит (${err%%$'\n'*}) — sshd не перечитан, работает с прежними настройками"
            rc=1
        fi
    fi
    return "$rc"
}

# node_sshd_rollback_reload <отпечаток до отката> — rollback удалил/вернул файлы стека по манифесту:
# работающий sshd должен перечитать конфиг, иначе снятые настройки жили бы до его перезапуска
node_sshd_rollback_reload() {
    [ "$(_node_sshd_sig)" != "$1" ] || return 0
    node_sshd_bin >/dev/null || return 0
    local err
    if err="$(_node_sshd_test)"; then
        node_sshd_reload || true
    else
        warn "rollback" "sshd -t после отката не проходит (${err%%$'\n'*}) — sshd не перечитан; проверь $NODE_SSHD_DIR"
    fi
    return 0
}

# строка для status (только чтение; действующие значения видны только под root — sshd -T)
node_sshd_status() {
    local eff=""
    if [ "$(id -u)" -eq 0 ] && node_sshd_bin >/dev/null; then
        eff="$({ "$(node_sshd_bin)" -T -f "$NODE_SSHD_CONFIG" 2>/dev/null || true; } | awk '
            $1 == "logingracetime" || $1 == "maxstartups" || $1 == "persourcemaxstartups" || $1 == "passwordauthentication" { o = o (o ? " " : "") $1 "=" $2 }
            END { print o }')"
    fi
    echo "sshd: limits=$(node_conf_get HARDEN_SSHD_LIMITS 1) (файл: $([ -f "$NODE_SSHD_LIMITS_FILE" ] && echo есть || echo нет)) password_off=$(node_conf_get HARDEN_SSH_PASSWORD_OFF 0) (файл: $([ -f "$NODE_SSHD_KEYS_FILE" ] && echo есть || echo нет))${eff:+ | действует: $eff}"
}
