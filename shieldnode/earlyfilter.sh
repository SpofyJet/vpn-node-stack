#!/bin/bash
# shieldnode — earlyfilter.sh: ранний фильтр на входе (spofy-guard) под управлением стека.
# 2026-11-14 (v1.2.11). Сам фильтр — скрипт spofy-guard: лежит рядом, ставится в /usr/local/sbin как есть.
# Его таблица nft стоит на сетевом устройстве (netdev) — раньше таблицы соединений и этого фаервола: флуд
# отбрасывается, не заводя записей о соединениях. Имена, пути и правила фильтра стек не меняет, поэтому на
# сервере, где фильтр уже включён руками, apply ничего не пересоздаёт: файл и юниты совпадают, остаётся
# `spofy-guard ensure`.
#
# Что делает стек (ENABLE_EARLY_FILTER=1):
#   фильтра нет           наблюдение (`observe`): ничего не отбрасывает, считает, что отбросил бы;
#   наблюдение            EARLY_FILTER_MODE=auto: LEARN секунд (настройка фильтра, по умолчанию 30) фильтр
#                         учится — запоминает свой исходящий; ответы на потоки, начатые до него, в это время
#                         выглядят «своими под отбросом» и в расчёт не идут. Затем счётчики обнуляются и идёт
#                         замер: не меньше SHIELD_EF_MEASURE_SEC секунд и SHIELD_EF_MIN_PKTS учтённых пакетов.
#                         Проверка: «своих» (пакетов живых соединений) под отбросом не больше 0,1 %, среди них
#                         ни одного SYN, сервер не отвечает с портов вне списков. Чисто — `sysctl on` +
#                         `enforce`. Нет — остаётся наблюдение, числа — в журнале (warn) и в status, замер
#                         начинается заново. Проверяют каждый apply и shieldnode-earlyfilter.timer (живёт,
#                         пока отброс не включён);
#                         EARLY_FILTER_MODE=observe: наблюдение и остаётся — отброс стек не включает, а
#                         включённый переводит в наблюдение (серверы, где свои пакеты под отбросом возможны);
#   отброс уже включён    только `ensure` (новые порты, память, настройки ядра) — режим не трогается;
#   скрипт другой версии  фильтр стоит, а файл на сервере отличается от встроенного: файл заменяется, правила
#                         ставятся заново в том же режиме и с теми же знакомыми адресами (`reload`) —
#                         наблюдение заново не начинается;
#   старый фильтр UDP     spofy-udp-guard снимается, если он есть и новый уже отбрасывает; rollback,
#                         ENABLE_EARLY_FILTER=0 и перевод в наблюдение включают его обратно;
#   идёт ручная проба     ничего: активен один из таймеров шагов установки руками (spofy-guard-observe-expire,
#                         spofy-guard-auto-rollback, spofy-guard-upg-rollback);
#   emergency on          фильтр снимается, emergency off возвращает прежний режим;
#   ENABLE_EARLY_FILTER=0 стек снимает фильтр, который ведёт сам; поставленный мимо стека не трогает;
#   rollback / uninstall  таблицы, две настройки ядра, юниты, файл и состояние фильтра снимаются.
# Настройки самого фильтра (/etc/spofy-guard.conf) стек не пишет и не удаляет.
set -euo pipefail

SHIELD_EF_T=spofy_guard                 # netdev: вход и выход на устройстве с маршрутом по умолчанию
SHIELD_EF_CT=spofy_guard_ct             # inet: пакеты без соединения и счёт «своих» в наблюдении
SHIELD_EF_BIN="${SHIELD_EF_BIN:-/usr/local/sbin/spofy-guard}"
SHIELD_EF_UNITS="${SHIELD_UNIT_DIR:-/etc/systemd/system}"
_ef_src() { echo "${SHIELD_EF_SRC:-$SHIELD_DIR/spofy-guard}"; }   # встроенный скрипт (переменная — для тестов)
# состояние и настройки самого скрипта: те же переменные окружения, что читает он (нужны тестам)
SHIELD_EF_GUARD_STATE="${GUARD_STATE:-/var/lib/spofy-guard}"
SHIELD_EF_GUARD_CONF="${GUARD_CONF:-/etc/spofy-guard.conf}"
SHIELD_EF_PENDING="$SHIELD_STATE_DIR/earlyfilter.observe"     # наблюдение ведёт стек: «время номер_таблицы [начало_замера]»
SHIELD_EF_NOTE="$SHIELD_STATE_DIR/earlyfilter.note"           # «ключ<TAB>текст» — что сейчас и почему
SHIELD_EF_SAVED="$SHIELD_STATE_DIR/earlyfilter.emergency"     # что стояло до аварийного режима: «режим<TAB>ядро»
SHIELD_EF_V1_MARK="$SHIELD_STATE_DIR/earlyfilter.v1"          # старый фильтр UDP снял стек — rollback вернёт
SHIELD_EF_UPFAIL="$SHIELD_STATE_DIR/earlyfilter.upgrade"      # обновление скрипта не удалось: текст для status
SHIELD_EF_V1_BIN="${SHIELD_EF_V1_BIN:-/usr/local/sbin/spofy-udp-guard}"
SHIELD_EF_EMERGENCY="${SHIELD_EF_EMERGENCY:-/run/shieldnode/emergency}"
# меньше пакетов — долю 0,1 % не посчитать: один пакет уже больше порога
SHIELD_EF_MIN_PKTS="${SHIELD_EF_MIN_PKTS:-1000}"
# замер после обучения — не короче (таймер проверяет раз в минуту)
SHIELD_EF_MEASURE_SEC="${SHIELD_EF_MEASURE_SEC:-20}"

# ---------------------------------------------------------------- чтение состояния (только nft list и файлы)
_ef_guard() { "$SHIELD_EF_BIN" "$@"; }
_ef_saved_mode() { cat "$SHIELD_EF_GUARD_STATE/mode" 2>/dev/null || true; }   # observe | enforce | пусто
_ef_sysctl_on() { [ -f "$SHIELD_EF_GUARD_STATE/sysctl.on" ]; }
# фильтр ведёт стек: файл скрипта записан в манифест (ставил или принял готовый)
shield_earlyfilter_managed() { [ -f "$SHIELD_STATE_DIR/applied-files.txt" ] && grep -qxF -- "$SHIELD_EF_BIN" "$SHIELD_STATE_DIR/applied-files.txt"; }

# _ef_probe — EF_STATE: absent | observe | enforce; EF_DEV — устройство. Одна короткая цепочка, без наборов.
_ef_probe() {
    local out
    EF_STATE=absent; EF_DEV=""
    command -v nft >/dev/null 2>&1 || return 0
    out="$(nft list chain netdev "$SHIELD_EF_T" miss 2>/dev/null || true)"
    if grep -qE '^[[:space:]]*drop[[:space:]]*$' <<<"$out"; then EF_STATE=enforce
    elif grep -qE '^[[:space:]]*accept[[:space:]]*$' <<<"$out"; then EF_STATE=observe
    else return 0; fi
    out="$(nft list chain netdev "$SHIELD_EF_T" in 2>/dev/null || true)"
    EF_DEV="$(sed -nE 's/.*hook ingress device "?([^" ;]+)"? priority.*/\1/p' <<<"$out" | head -1)"
    return 0
}
# номер таблицы: новый при каждом пересоздании (observe заново, перезагрузка) — по нему видно, что окно
# наблюдения началось заново. -t: без содержимого наборов
_ef_handle() {
    local out
    out="$(nft -a -t list table netdev "$SHIELD_EF_T" 2>/dev/null || true)"
    sed -nE '1s/.*# handle ([0-9]+).*/\1/p' <<<"$out"
}
_ef_set_elems() {   # <набор таблицы netdev> — элементы по одному в строке, без сроков
    local out
    out="$(nft list set netdev "$SHIELD_EF_T" "$1" 2>/dev/null || true)"
    tr -d '\n\t' <<<"$out" | sed -nE 's/.*elements = \{([^}]*)\}.*/\1/p' | sed -E 's/ (timeout|expires) [0-9a-z]+//g' | tr ',' '\n' | tr -d ' ' | sed '/^$/d'
}
# «имя пакеты» по обеим таблицам — той же командой, что сам скрипт
_ef_counters() {
    { nft list counters table netdev "$SHIELD_EF_T" 2>/dev/null || true
      nft list counters table inet "$SHIELD_EF_CT" 2>/dev/null || true
    } | awk '$1 == "counter" { n = $2 } $1 == "packets" { print n, $2 }' || true
}
# _ef_numbers — EF_PASS (пропущено), EF_MISS (под отброс), EF_TOTAL, EF_FP («своих» под отбросом),
# EF_FP_SYN (из них новых соединений), EF_PICKUP (продолжений без записи), EF_UNLISTED (порты вне списков).
# Счётчики — с создания таблицы; фильтр считает новые соединения, UDP, фрагменты и прочие протоколы
# (пакеты установленных TCP-соединений идут мимо счётчиков).
_ef_numbers() {
    local c out
    c="$(_ef_counters)"
    read -r EF_PASS EF_MISS EF_FP EF_PICKUP <<<"$(awk '
        BEGIN {
            n = split("syn_known syn_new syn_retry syn_spare udp_listen udp_reply q_known q_ip q_new q_other q_retry q_spare frag", a, " ")
            for (i = 1; i <= n; i++) pass["c_" a[i]] = 1
            n = split("syn_closed syn_first syn_over syn_src tcp_flags mgmt_over udp_miss q_ver q_small q_first q_over q_src icmp_over frag_over proto", b, " ")
            for (i = 1; i <= n; i++) miss["c_" b[i]] = 1
        }
        ($1 in pass) { p += $2 } ($1 in miss) { m += $2 } $1 == "c_fp" { f = $2 } $1 == "c_pickup" { k = $2 }
        END { printf "%d %d %d %d\n", p, m, f, k }' <<<"$c")"
    EF_TOTAL=$((EF_PASS + EF_MISS))
    # метки причин (младший байт): 01 SYN на закрытый порт, 02 первый SYN при атаке, 04 SSH/API сверх бюджета,
    # 0d SYN сверх всех бюджетов, 10 слишком много SYN с одного адреса
    out="$(nft list set inet "$SHIELD_EF_CT" fp 2>/dev/null || true)"
    EF_FP_SYN="$( { grep -oE '0x[0-9a-f]+ counter packets [0-9]+' <<<"$out" || true; } | awk '$1 ~ /5d(01|02|04|0d|10)$/ { s += $4 } END { print s + 0 }')"
    # порты, с которых сервер ответил на соединение, а в списках их не было (фильтр помнит такой порт час).
    # Порт, который с тех пор попал в списки (его дописал `ensure` или EXTRA_TCP), проверке уже не мешает
    EF_UNLISTED="$(_ef_set_elems unlisted | { grep -vxFf <(_ef_set_elems tcp_svc; _ef_set_elems tcp_mgmt) || true; } | paste -sd, -)"
    return 0
}
_ef_pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b <= 0) { print "0"; exit } s = sprintf("%.3f", a * 100 / b); sub(/\./, ",", s); print s }'; }
# LEARN из настроек фильтра: столько же он сам учится при загрузке сервера
_ef_learn() {
    local v=""
    if [ -r "$SHIELD_EF_GUARD_CONF" ]; then v="$(sed -nE "s/^[[:space:]]*LEARN=[\"']?([0-9]+)[\"']?[[:space:]]*(#.*)?\$/\1/p" "$SHIELD_EF_GUARD_CONF" | tail -1)"; fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=30
    echo "$v"
}
# идёт ручная проба (шаги установки руками): наблюдение с автоснятием, включение с автоснятием или
# обновление скрипта с автовозвратом
_ef_manual() {
    local u
    EF_MANUAL=""
    command -v systemctl >/dev/null 2>&1 || return 1
    for u in spofy-guard-observe-expire.timer spofy-guard-auto-rollback.timer spofy-guard-upg-rollback.timer; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then EF_MANUAL="$u"; return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------- пояснения, lock, отметки
_ef_note() {   # <ключ> <info|warn> <текст> — текст виден в status; в журнал — только при смене ключа
    local cur=""
    [ -f "$SHIELD_EF_NOTE" ] && cur="$(head -1 "$SHIELD_EF_NOTE" 2>/dev/null | cut -f1 || true)"
    printf '%s\t%s\n' "$1" "$3" > "$SHIELD_EF_NOTE" 2>/dev/null || true
    [ "$cur" = "$1" ] || log "$2" "earlyfilter" "$3"
    return 0
}
_ef_note_key()  { [ -f "$SHIELD_EF_NOTE" ] && head -1 "$SHIELD_EF_NOTE" 2>/dev/null | cut -f1 || true; }
_ef_note_text() { [ -f "$SHIELD_EF_NOTE" ] && head -1 "$SHIELD_EF_NOTE" 2>/dev/null | cut -f2- || true; }
# _ef_note_now — EF_NKEY / EF_NTEXT: пояснение, если оно ещё к месту. После смены EARLY_FILTER_MODE прежнее
# (оно живёт до ближайшего apply) не показываем
_ef_note_now() {
    local fmode; fmode="$(shield_conf_early_filter_mode)"
    EF_NKEY="$(_ef_note_key)"; EF_NTEXT="$(_ef_note_text)"
    case "$EF_NKEY" in
        mode-observe) [ "$fmode" = observe ] || { EF_NKEY=""; EF_NTEXT=""; } ;;
        mode-invalid) [ "$fmode" = invalid ] || { EF_NKEY=""; EF_NTEXT=""; } ;;
        wait|measure|few) [ "$fmode" = auto ] || { EF_NKEY=""; EF_NTEXT=""; } ;;
    esac
    return 0
}
_ef_lock() {   # <сек ожидания; 0 — не ждать>; rc 1 — занято (fd 7: 8 и 9 заняты в ports/blocklist/common)
    local lk="${SHIELD_EF_LOCK:-/run/shieldnode/earlyfilter.lock}"
    mkdir -p "$(dirname "$lk")" 2>/dev/null || true
    { exec 7>>"$lk"; } 2>/dev/null || return 0
    if [ "${1:-0}" -gt 0 ]; then flock -w "$1" 7; else flock -n 7; fi
}
_ef_unlock() { flock -u 7 2>/dev/null || true; { exec 7>&-; } 2>/dev/null || true; }
_ef_run() {   # запуск скрипта фильтра; его вывод — в журнал только при ошибке
    local out rc=0
    out="$(_ef_guard "$@" 2>&1)" || rc=$?
    [ "$rc" = 0 ] || log warn "earlyfilter" "spofy-guard $* — код $rc: $(tr '\n' ';' <<<"$out" | cut -c1-400)"
    return "$rc"
}
_ef_pending_start() {
    local now; printf -v now '%(%s)T' -1
    printf '%s %s\n' "$now" "$(_ef_handle)" > "$SHIELD_EF_PENDING"
}
# начало замера: счётчики и разбивка «своих» по причинам — с нуля (то же делает `spofy-guard measure`).
# Память фильтра (знакомые адреса, свой исходящий, порты) не трогается.
_ef_measure_start() {
    nft reset counters table netdev "$SHIELD_EF_T" >/dev/null 2>&1 || return 1
    nft reset counters table inet "$SHIELD_EF_CT" >/dev/null 2>&1 || true
    nft flush set inet "$SHIELD_EF_CT" fp 2>/dev/null || true
    return 0
}
_ef_pending_done() {
    rm -f "$SHIELD_EF_PENDING"
    if declare -F shield_persist_earlyfilter_timer_remove >/dev/null 2>&1; then shield_persist_earlyfilter_timer_remove || true; fi
}
_ef_units_on() { if declare -F shield_persist_earlyfilter_enable >/dev/null 2>&1; then shield_persist_earlyfilter_enable || true; fi; }
_ef_timer_on() { if declare -F shield_persist_earlyfilter_timer >/dev/null 2>&1; then shield_persist_earlyfilter_timer || true; fi; }
# Доверенные адреса: скрипт читает TRUSTED_IPS только при создании таблицы — новые дописываем сразу (так же он
# сам дописывает порты). Убранный из TRUSTED_IPS адрес уйдёт из набора при пересоздании таблицы (перезагрузка).
# Адрес SSH-сессии, из которой идёт apply, — туда же: SSH и API ноды ему открыты вне общего бюджета.
_ef_trusted_sync() {
    local a
    # скрипт берёт TRUSTED_IPS из /etc/shieldnode/config.conf — стек с другим конфигом (не по умолчанию)
    # отдал бы ему не те адреса
    if [ "${SHIELD_CONFIG:-/etc/shieldnode/config.conf}" != /etc/shieldnode/config.conf ]; then
        log warn "earlyfilter" "SHIELD_CONFIG=$SHIELD_CONFIG: фильтр при создании таблицы читает TRUSTED_IPS из /etc/shieldnode/config.conf — доверенные адреса берутся оттуда"
    fi
    for a in $(shield_conf_get TRUSTED_IPS "" | tr ',' ' ') ${SH_F_ADMIN_V4:-}; do
        [[ "$a" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || continue
        nft add element netdev "$SHIELD_EF_T" trusted "{ $a }" 2>/dev/null || true
    done
    return 0
}
# вернуть уже включавшийся фильтр: скрипт сам ставит таблицу, LEARN секунд учится и включает отброс.
# Через его службу — не задерживая apply; без systemd — сразу, с ожиданием.
_ef_boot() {
    if command -v systemctl >/dev/null 2>&1 && [ -e "$SHIELD_EF_UNITS/spofy-guard.service" ] \
        && systemctl start --no-block spofy-guard.service >/dev/null 2>&1; then return 0; fi
    _ef_run ensure
}

_ef_mode_ru() { case "${1:-}" in enforce) echo "отброс" ;; observe) echo "наблюдение" ;; *) echo "нет" ;; esac; }
_ef_script_ver() { sed -nE 's/^VER=([0-9.]+).*/\1/p' "${1:-$SHIELD_EF_BIN}" 2>/dev/null | head -1; }

# ---------------------------------------------------------------- старый фильтр UDP (spofy-udp-guard)
# Его работу (ранний отброс UDP не к нам) делает новый фильтр. Снимается, только если он есть и только когда
# новый уже отбрасывает: в наблюдении сервер остался бы без раннего отброса UDP. Снимается так же, как при
# установке руками (`spofy-udp-guard remove`: таблицы и юниты); файлы остаются — rollback включает его обратно.
_ef_v1_remove() {
    local on=0
    if nft list table netdev spofy_udp >/dev/null 2>&1; then on=1
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet spofy-udp-guard.timer 2>/dev/null; then on=1; fi
    [ "$on" = 1 ] || return 0
    if [ -x "$SHIELD_EF_V1_BIN" ]; then "$SHIELD_EF_V1_BIN" remove >/dev/null 2>&1 || true; fi
    nft delete table netdev spofy_udp 2>/dev/null || true
    nft delete table inet spofy_udp_chk 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now spofy-udp-guard.timer spofy-udp-guard.service >/dev/null 2>&1 || true
    fi
    : > "$SHIELD_EF_V1_MARK" 2>/dev/null || true
    log info "earlyfilter" "старый фильтр UDP (spofy-udp-guard) снят — его работу делает ранний фильтр; rollback включит его обратно"
    return 0
}
# вернуть старый фильтр, если его снимал стек и его файлы на месте (rollback, ENABLE_EARLY_FILTER=0,
# перевод из отброса в наблюдение)
_ef_v1_restore() {
    [ -e "$SHIELD_EF_V1_MARK" ] || return 0
    rm -f "$SHIELD_EF_V1_MARK"
    [ -x "$SHIELD_EF_V1_BIN" ] && [ -e "$SHIELD_EF_UNITS/spofy-udp-guard.timer" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl enable spofy-udp-guard.service >/dev/null 2>&1 || true
    # у его таймера OnBootSec: включённый заново, он срабатывает сразу и ставит таблицу
    if systemctl enable --now spofy-udp-guard.timer >/dev/null 2>&1; then
        log info "earlyfilter" "старый фильтр UDP (spofy-udp-guard) включён обратно — как было до раннего фильтра"
    else
        log warn "earlyfilter" "старый фильтр UDP (spofy-udp-guard) не включился обратно: sudo systemctl enable --now spofy-udp-guard.timer"
    fi
    return 0
}

# ---------------------------------------------------------------- наблюдение по настройке
# EARLY_FILTER_MODE=observe (или опечатка в настройке): отброс стек не включает — пояснение для status
_ef_mode_note() {
    if [ "$1" = observe ]; then
        _ef_note mode-observe info "ранний фильтр в наблюдении по настройке EARLY_FILTER_MODE=observe: ничего не отбрасывает, отброс стек не включает"
    else
        _ef_note mode-invalid warn "EARLY_FILTER_MODE=$(shield_conf_get EARLY_FILTER_MODE auto) — ожидается auto или observe; ранний фильтр оставлен в наблюдении, отброс стек не включает"
    fi
}
# отброс → наблюдение (EARLY_FILTER_MODE=observe): командой самого скрипта — таблица ставится заново без
# отброса, знакомые адреса он берёт с диска. Две настройки ядра возвращаются: наблюдение не меняет работу сервера.
_ef_to_observe() {
    if ! _ef_run observe; then
        _ef_note "fail:observe" warn "ранний фильтр: перевести в наблюдение (EARLY_FILTER_MODE=observe) не удалось — режим прежний; текст ошибки — в журнале"
        return 1
    fi
    if _ef_sysctl_on; then _ef_run sysctl off || true; fi
    rm -f "$SHIELD_EF_SAVED"
    _ef_pending_done
    _ef_units_on
    _ef_trusted_sync
    log warn "earlyfilter" "ранний фильтр переведён из отброса в наблюдение (EARLY_FILTER_MODE=observe): отброс выключен, две настройки ядра возвращены"
    # новый фильтр больше не отбрасывает: старый фильтр UDP, если его снимал стек, включается обратно —
    # иначе сервер остался бы без раннего отброса UDP
    _ef_v1_restore
    _ef_mode_note observe
    return 0
}

# ---------------------------------------------------------------- обновление скрипта при стоящем фильтре
# Файл на сервере отличается от встроенного (другая версия), а фильтр стоит: правила в ядре поставлены прежним
# скриптом. Файл заменяется, правила ставятся заново новым скриптом в том же режиме и с теми же знакомыми
# адресами (`reload`; в отбросе он LEARN секунд учится — столько длится этот шаг apply). Наблюдение заново не
# начинается. Таймер фильтра на это время остановлен: его `ensure` включил бы отброс раньше, чем скрипт
# доучится; запускается обратно и тогда, когда apply оборвался посреди шага (обрыв SSH) — для этого подоболочка
# со своим trap. Правила ставятся одной транзакцией: не встали — в ядре прежние, возвращается и прежний файл.
_ef_upfail() { printf '%s\n' "$1" > "$SHIELD_EF_UPFAIL" 2>/dev/null || true; log warn "earlyfilter" "$1"; }
_ef_upgrade() {
    local was="$EF_STATE" smode want cmd=reload h0 rc=0 keep="$SHIELD_STATE_DIR/earlyfilter.prev" from to
    smode="$(_ef_saved_mode)"
    want="$was"; if [ "$smode" = enforce ]; then want=enforce; fi   # скрипт доучивается — отброс включит сам
    # наблюдение ставится заново тем же наблюдением: reload без отметки режима включил бы отброс без проверки
    if [ "$want" = observe ]; then cmd=observe; fi
    from="$(_ef_script_ver)"; to="$(_ef_script_ver "$(_ef_src)")"
    h0="$(_ef_handle)"
    if ! cp -p -- "$SHIELD_EF_BIN" "$keep" 2>/dev/null; then
        log warn "earlyfilter" "скрипт раннего фильтра отличается от встроенного, но копию прежнего сохранить не удалось ($keep) — не обновляю"
        return 1
    fi
    log info "earlyfilter" "скрипт раннего фильтра на сервере (${from:-?}) отличается от встроенного (${to:-?}): заменяю и ставлю правила заново в том же режиме ($(_ef_mode_ru "$want"))$([ "$cmd" = reload ] && echo ", до $(_ef_learn) с")"
    (
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet spofy-guard.timer 2>/dev/null; then
            trap 'systemctl start spofy-guard.timer >/dev/null 2>&1 || true' EXIT
            systemctl stop spofy-guard.timer >/dev/null 2>&1 || true
        fi
        ( shield_persist_earlyfilter ) || exit 3
        _ef_run "$cmd" || exit 4
    ) || rc=$?
    if [ "$rc" != 0 ]; then
        # номер таблицы тот же — правила в ядре прежние: прежний файл на место (иначе скрипт и правила разных версий)
        if [ "$(_ef_handle)" = "$h0" ]; then
            install -m 0755 -- "$keep" "$SHIELD_EF_BIN" 2>/dev/null || true
            rm -f "$keep"
            _ef_upfail "ранний фильтр: обновить скрипт не удалось — прежний скрипт (${from:-?}) и прежние правила на месте, режим тот же ($(_ef_mode_ru "$was")); текст ошибки — в журнале, повтор — следующий apply"
        else
            rm -f "$keep"
            _ef_upfail "ранний фильтр: скрипт обновлён (${to:-?}), правила поставлены заново, но прежний режим ($(_ef_mode_ru "$want")) не вернулся — текст ошибки в журнале"
        fi
        return 1
    fi
    rm -f "$keep"
    _ef_probe
    if [ "$EF_STATE" != "$want" ]; then
        _ef_upfail "ранний фильтр: скрипт обновлён (${to:-?}), правила поставлены заново, но режим не прежний: был $(_ef_mode_ru "$want"), стал $(_ef_mode_ru "$EF_STATE")"
        return 1
    fi
    rm -f "$SHIELD_EF_UPFAIL"
    ok "earlyfilter" "ранний фильтр обновлён: скрипт ${from:-?} → ${to:-?}, правила поставлены заново, режим прежний — $(_ef_mode_ru "$EF_STATE") (устройство $EF_DEV)"
    return 0
}

# ---------------------------------------------------------------- решение: включать ли отброс
# _ef_verdict — по числам _ef_numbers: EF_BAD пуст — под отброс не попадает ничего своего; иначе причина с
# числами (EF_BAD_KEY — её ключ)
_ef_verdict() {
    EF_BAD=""; EF_BAD_KEY=""
    if [ $((EF_FP * 1000)) -gt "$EF_TOTAL" ]; then
        EF_BAD_KEY="own"; EF_BAD="«своих» пакетов под отбросом $EF_FP из $EF_TOTAL учтённых ($(_ef_pct "$EF_FP" "$EF_TOTAL") %), допустимо 0,1 %"
    fi
    if [ "$EF_FP_SYN" -gt 0 ]; then
        EF_BAD_KEY="$EF_BAD_KEY+syn"; EF_BAD="${EF_BAD:+$EF_BAD; }среди «своих» новых соединений (SYN) $EF_FP_SYN, допустимо 0"
    fi
    if [ -n "$EF_UNLISTED" ]; then
        EF_BAD_KEY="$EF_BAD_KEY+ports"; EF_BAD="${EF_BAD:+$EF_BAD; }сервер отвечает с портов, которых нет в списках фильтра: $EF_UNLISTED"
    fi
    return 0
}
# _ef_decide — наблюдение ведёт стек. rc 0 — решение принято или отложено, 1 — включить не удалось.
# Две части: обучение (LEARN с от создания таблицы) и замер (от обнуления счётчиков). На живой ноде фильтр,
# поставленный на ходу, в первые секунды видит ответы на потоки, начатые до него: своего исходящего по ним он
# ещё не запомнил, и таблица соединений считает такие пакеты «своими под отбросом» (замер 14.11: 495 пакетов
# за 6 с, дальше +1 в 3 с). По ним судить нельзя — судим по пакетам после обучения.
_ef_decide() {
    local t0="" h0="" m0="" h now el mel learn keep
    read -r t0 h0 m0 < "$SHIELD_EF_PENDING" 2>/dev/null || true
    h="$(_ef_handle)"; printf -v now '%(%s)T' -1
    if ! [[ "$t0" =~ ^[0-9]+$ ]] || [ "$h" != "$h0" ] || [ "$now" -lt "$t0" ]; then
        _ef_pending_start; t0="$now"; m0=""   # таблицу пересоздали — память и счётчики с нуля, всё заново
    fi
    el=$((now - t0)); learn="$(_ef_learn)"
    if [ "$el" -lt "$learn" ]; then
        _ef_note wait info "ранний фильтр в наблюдении: учится $el с из $learn, затем замер и проверка"
        return 0
    fi
    if ! [[ "$m0" =~ ^[0-9]+$ ]] || [ "$now" -lt "$m0" ]; then
        if ! _ef_measure_start; then
            log warn "earlyfilter" "ранний фильтр: счётчики не обнулились (nft reset counters) — в замер попадут и пакеты времени обучения"
        fi
        printf '%s %s %s\n' "$t0" "$h" "$now" > "$SHIELD_EF_PENDING"
        _ef_note measure info "ранний фильтр в наблюдении: обучение ($learn с) закончено, идёт замер — отброс включится после проверки"
        return 0
    fi
    mel=$((now - m0))
    # после «не чисто» замер идёт заново; причина прошлого замера остаётся в status, пока новый не закончится —
    # и в журнал одна и та же причина пишется один раз, а не каждую минуту
    case "$(_ef_note_key)" in dirty:*) keep=1 ;; *) keep=0 ;; esac
    if [ "$mel" -lt "$SHIELD_EF_MEASURE_SEC" ]; then
        [ "$keep" = 1 ] || _ef_note measure info "ранний фильтр в наблюдении: идёт замер, $mel с из $SHIELD_EF_MEASURE_SEC — отброс включится после проверки"
        return 0
    fi
    _ef_numbers
    if [ "$EF_TOTAL" -lt "$SHIELD_EF_MIN_PKTS" ]; then
        [ "$keep" = 1 ] || _ef_note few info "ранний фильтр в наблюдении: за $mel с замера учтено $EF_TOTAL пакетов из $SHIELD_EF_MIN_PKTS нужных для проверки — отброс включится, когда наберётся"
        return 0
    fi
    _ef_verdict
    if [ -n "$EF_BAD" ]; then
        _ef_note "dirty:$EF_BAD_KEY" warn "ранний фильтр: отброс НЕ включён, остаётся наблюдение — за $mel с замера $EF_BAD. Разбивка по причинам: sudo spofy-guard measure 60; порты сервисов мимо списков — EXTRA_TCP / EXTRA_UDP в $SHIELD_EF_GUARD_CONF"
        # следующая проверка — по новому замеру: разовый всплеск не держит наблюдение вечно, постоянная причина
        # покажется снова
        _ef_measure_start || true
        printf '%s %s %s\n' "$t0" "$h" "$now" > "$SHIELD_EF_PENDING"
        return 0
    fi
    # чисто — как при установке руками: сначала две настройки ядра, потом отброс
    if ! _ef_run sysctl on; then
        _ef_run sysctl off || true
        _ef_note "fail:sysctl" warn "ранний фильтр: отброс не включён — ядро не приняло настройки (nf_conntrack_tcp_loose, tcp_synack_retries); остаётся наблюдение"
        return 1
    fi
    if ! _ef_run enforce; then
        _ef_run sysctl off || true
        _ef_note "fail:enforce" warn "ранний фильтр: отброс не включился (ошибка nft — в журнале); настройки ядра возвращены, остаётся наблюдение"
        return 1
    fi
    _ef_probe
    if [ "$EF_STATE" != enforce ]; then
        _ef_note "fail:enforce" warn "ранний фильтр: скрипт сообщил об успехе, но отброс не включён — остаётся наблюдение"
        return 1
    fi
    _ef_pending_done; rm -f "$SHIELD_EF_NOTE"
    ok "earlyfilter" "ранний фильтр: отброс включён (устройство $EF_DEV). После $learn с обучения за $mel с замера учтено $EF_TOTAL пакетов, под отброс попало бы $EF_MISS, из них «своих» $EF_FP ($(_ef_pct "$EF_FP" "$EF_TOTAL") %), новых соединений среди них 0, портов вне списков нет"
    _ef_v1_remove
    return 0
}

# ---------------------------------------------------------------- шаг: привести фильтр к положенному
# _ef_step — под своим lock'ом. rc 1 — шаг не удался (apply от этого не падает).
_ef_step() {
    local prev="" psys="" smode dev fmode
    fmode="$(shield_conf_early_filter_mode)"   # auto | observe | invalid (опечатка: режим не меняем)
    _ef_probe
    smode="$(_ef_saved_mode)"
    if [ -s "$SHIELD_EF_SAVED" ]; then IFS=$'\t' read -r prev psys < "$SHIELD_EF_SAVED" || true; fi
    case "$EF_STATE" in
        enforce)
            # настройка сервера — наблюдение: включённый отброс выключается
            if [ "$fmode" = observe ]; then _ef_to_observe; return $?; fi
            # отброс включён (стеком раньше или руками) — режим не трогаем: только порты, память, настройки ядра
            rm -f "$SHIELD_EF_SAVED" "$SHIELD_EF_NOTE"
            _ef_pending_done
            _ef_units_on
            _ef_run ensure || return 1
            _ef_trusted_sync
            _ef_v1_remove
            return 0 ;;
        observe)
            # скрипт сам доучивается и включит отброс (загрузка сервера), а настройка сервера — наблюдение
            if [ "$fmode" = observe ] && [ "$smode" = enforce ]; then _ef_to_observe; return $?; fi
            _ef_units_on
            _ef_run ensure || return 1
            _ef_trusted_sync
            if [ "$smode" = enforce ]; then
                # отброс включает сам скрипт (загрузка сервера, возврат таблицы): он LEARN секунд учится
                log info "earlyfilter" "ранний фильтр включается: $(_ef_learn) с запоминает исходящие порты, затем отброс"
                return 0
            fi
            rm -f "$SHIELD_EF_SAVED"
            if [ "$fmode" != auto ]; then
                _ef_pending_done
                _ef_mode_note "$fmode"
                return 0
            fi
            if [ ! -s "$SHIELD_EF_PENDING" ]; then
                _ef_pending_start
                log info "earlyfilter" "ранний фильтр стоит в наблюдении (устройство $EF_DEV) — проверю и включу отброс, если под него не попадают свои пакеты"
            fi
            _ef_timer_on
            _ef_decide
            return $? ;;
    esac
    # фильтра нет
    dev="${GUARD_IF:-$(shield_default_iface)}"
    if [ -z "$dev" ]; then
        _ef_note noroute warn "ранний фильтр не поставлен: нет устройства с маршрутом по умолчанию (IPv4)"
        return 0
    fi
    if [ "$fmode" != observe ] && { [ "$prev" = enforce ] || { [ -z "$prev" ] && [ "$smode" = enforce ]; }; }; then
        # уже был включён и проверен (до аварийного режима или до сброса правил) — возвращает сам скрипт
        if [ "$psys" = 1 ] && ! _ef_sysctl_on; then _ef_run sysctl on || true; fi
        _ef_units_on
        if ! _ef_boot; then
            _ef_note "fail:boot" warn "ранний фильтр не вернулся: скрипт не поставил таблицу (ошибка — в журнале)"
            return 1
        fi
        # запомненное использовано: дальше режим виден по самому фильтру (не включится — следующий apply
        # начнёт с наблюдения)
        rm -f "$SHIELD_EF_SAVED"
        _ef_note boot info "ранний фильтр возвращается (устройство $dev): $(_ef_learn) с запоминает исходящие порты, затем отброс"
        return 0
    fi
    # первое включение — только через наблюдение. observe — РАНЬШЕ юнитов: таймер фильтра сразу зовёт
    # `ensure`, а тот без таблицы и без отметки «наблюдение» через LEARN секунд включил бы отброс без проверки
    if ! _ef_run observe; then
        _ef_note "fail:observe" warn "ранний фильтр не поставлен: nft не принял таблицу (нужны Linux ≥ 5.16 и nftables ≥ 1.0.1 — хук egress); текст ошибки — в журнале"
        return 1
    fi
    rm -f "$SHIELD_EF_SAVED"
    if [ "$fmode" = auto ]; then _ef_pending_start; fi
    _ef_units_on
    _ef_trusted_sync
    if [ "$fmode" != auto ]; then
        _ef_pending_done
        log info "earlyfilter" "ранний фильтр поставлен в наблюдении (устройство $dev)"
        _ef_mode_note "$fmode"
        return 0
    fi
    _ef_timer_on
    _ef_note wait info "ранний фильтр поставлен в наблюдении (устройство $dev): ничего не отбрасывает; $(_ef_learn) с учится, затем замер — отброс включится сам, если под него не попадают свои пакеты"
    return 0
}

# ---------------------------------------------------------------- точки входа стека
# shield_earlyfilter_remove [причина] — снять фильтр целиком: таблицы, две настройки ядра, юниты, файл,
# состояние и отметки. Настройки оператора (/etc/spofy-guard.conf) остаются.
shield_earlyfilter_remove() {
    local why="${1:-}"
    if [ "${DRY_RUN:-0}" = "1" ]; then log info "dry-run" "would remove early filter (spofy-guard): tables, sysctl, units, state"; return 0; fi
    _ef_lock 10 || true   # не поперёк идущей проверки наблюдения
    _ef_probe
    if [ -x "$SHIELD_EF_BIN" ]; then
        _ef_run remove || true
        # remove возвращает настройки ядра сам; файл остался без отметки (прерванный sysctl on) — вернуть явно
        if [ -e "${GUARD_SYSCTL_D:-/etc/sysctl.d}/99-z9-spofy-guard.conf" ]; then _ef_run sysctl off || true; fi
    fi
    # скрипта нет или ему не на чём работать (нет маршрута по умолчанию) — таблицы снимаем сами
    if command -v nft >/dev/null 2>&1; then
        nft delete table netdev "$SHIELD_EF_T" 2>/dev/null || true
        nft delete table inet "$SHIELD_EF_CT" 2>/dev/null || true
    fi
    if declare -F shield_persist_earlyfilter_timer_remove >/dev/null 2>&1; then shield_persist_earlyfilter_timer_remove || true; fi
    if declare -F shield_persist_earlyfilter_remove >/dev/null 2>&1; then shield_persist_earlyfilter_remove || true; fi
    case "$SHIELD_EF_GUARD_STATE" in ''|/|/var|/var/lib) ;; *) rm -rf -- "$SHIELD_EF_GUARD_STATE" ;; esac
    rm -f "$SHIELD_EF_PENDING" "$SHIELD_EF_NOTE" "$SHIELD_EF_SAVED" "$SHIELD_EF_UPFAIL" "$SHIELD_STATE_DIR/earlyfilter.prev"
    _ef_v1_restore
    _ef_unlock
    [ "$EF_STATE" = absent ] || log warn "earlyfilter" "ранний фильтр снят${why:+ ($why)}: был $([ "$EF_STATE" = enforce ] && echo 'отброс' || echo 'наблюдение') на $EF_DEV"
    return 0
}

_ef_ensure() {
    local flag rc=0
    flag="$(shield_conf_early_filter)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        _ef_probe
        log info "dry-run" "early filter (spofy-guard): ENABLE_EARLY_FILTER=$flag EARLY_FILTER_MODE=$(shield_conf_early_filter_mode), now: $EF_STATE — would install the script and units$( [ "$EF_STATE" != absent ] && [ -f "$SHIELD_EF_BIN" ] && ! cmp -s "$SHIELD_EF_BIN" "$(_ef_src)" && echo ' (script differs: replace + reload in the same mode)'), then observe/ensure"
        return 0
    fi
    case "$flag" in
        invalid)
            log warn "earlyfilter" "ENABLE_EARLY_FILTER=$(shield_conf_get ENABLE_EARLY_FILTER 1) — ожидается 0 или 1; ранний фильтр не трогаю"
            return 0 ;;
        0)
            if shield_earlyfilter_managed; then shield_earlyfilter_remove "ENABLE_EARLY_FILTER=0"; return 0; fi
            _ef_probe
            [ "$EF_STATE" = absent ] || log info "earlyfilter" "ENABLE_EARLY_FILTER=0: ранний фильтр стоит, но поставлен мимо стека — не трогаю (снять: sudo spofy-guard remove)"
            return 0 ;;
    esac
    if [ -f "$SHIELD_EF_EMERGENCY" ]; then
        log info "earlyfilter" "аварийный режим — ранний фильтр не ставится (вернёт emergency off)"
        return 0
    fi
    command -v nft >/dev/null 2>&1 || return 0
    if _ef_manual; then
        _ef_probe
        log info "earlyfilter" "идёт ручная проба раннего фильтра ($EF_MANUAL активен) — не трогаю; сейчас: $(shield_earlyfilter_brief)"
        return 0
    fi
    if [ "$(shield_conf_early_filter_mode)" = invalid ]; then
        log warn "earlyfilter" "EARLY_FILTER_MODE=$(shield_conf_get EARLY_FILTER_MODE auto) — ожидается auto или observe; режим раннего фильтра не меняю (отброс сам не включаю и не выключаю)"
    fi
    if ! _ef_lock 30; then log warn "earlyfilter" "ранний фильтр занят другим запуском — пропуск до следующего apply"; return 0; fi
    # файл и юниты — только когда фильтру есть на чём стоять или он уже стоит
    _ef_probe
    if [ "$EF_STATE" = absent ] && [ -z "${GUARD_IF:-$(shield_default_iface)}" ]; then
        _ef_note noroute warn "ранний фильтр не поставлен: нет устройства с маршрутом по умолчанию (IPv4)"
        _ef_unlock; return 0
    fi
    if [ "$EF_STATE" != absent ] && [ -f "$SHIELD_EF_BIN" ] && [ -s "$(_ef_src)" ] \
        && ! cmp -s "$SHIELD_EF_BIN" "$(_ef_src)"; then
        # фильтр стоит, а скрипт на сервере другой версии: заменить и поставить правила заново в том же режиме
        _ef_upgrade || rc=1
    elif ! shield_persist_earlyfilter; then _ef_unlock; return 1
    else rm -f "$SHIELD_EF_UPFAIL"; fi   # скрипт совпадает — прежний сбой обновления уже не про этот сервер
    _ef_step || rc=$?
    _ef_unlock
    return "$rc"
}
# shield_earlyfilter_ensure — конец apply (и emergency off). В подоболочке: сбой любого шага, включая die в
# persist, не роняет apply — фаервол уже применён и сохранён.
shield_earlyfilter_ensure() {
    local rc=0
    ( _ef_ensure ) || rc=$?
    [ "$rc" = 0 ] || log warn "earlyfilter" "ранний фильтр: шаг не выполнен (код $rc) — фаервол применён; состояние фильтра: sudo shieldnode early-filter"
    return 0
}

# shield_earlyfilter_tick — shieldnode-earlyfilter.timer: довести наблюдение, начатое стеком, до отброса
shield_earlyfilter_tick() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    if [ "$(shield_conf_early_filter)" != 1 ] || [ "$(shield_conf_early_filter_mode)" != auto ] || [ ! -s "$SHIELD_EF_PENDING" ]; then
        _ef_pending_done; return 0
    fi
    [ -f "$SHIELD_EF_EMERGENCY" ] && return 0
    _ef_manual && return 0
    _ef_lock 0 || return 0
    _ef_probe
    case "$EF_STATE" in
        enforce) _ef_pending_done; rm -f "$SHIELD_EF_NOTE"; _ef_v1_remove ;;
        observe) if [ "$(_ef_saved_mode)" != enforce ]; then _ef_decide || true; fi ;;
        *) : ;;   # таблицы нет (сброс правил) — в наблюдении её вернёт таймер самого фильтра
    esac
    _ef_unlock
    return 0
}

# shield_earlyfilter_emergency_on — аварийный режим = минимум: фильтр снимается; что стояло — запоминаем
shield_earlyfilter_emergency_on() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    if [ "$(shield_conf_early_filter)" != 1 ] && ! shield_earlyfilter_managed; then return 0; fi
    local prev sys=0 smode
    _ef_lock 10 || true   # не поперёк идущей проверки наблюдения
    _ef_probe; smode="$(_ef_saved_mode)"
    # ручное наблюдение с автоснятием ничего не отбрасывает — аварийному режиму не мешает, не ломаем
    if [ "$EF_STATE" = observe ] && _ef_manual; then _ef_unlock; return 0; fi
    case "$EF_STATE" in
        enforce) prev=enforce ;;
        observe) if [ "$smode" = enforce ]; then prev=enforce; else prev=observe; fi ;;
        *)       prev="$smode" ;;
    esac
    if _ef_sysctl_on; then sys=1; fi
    # повторный emergency on (фильтра уже нет, prev пуст) запомненное не затирает
    if [ -n "$prev" ]; then printf '%s\t%s\n' "$prev" "$sys" > "$SHIELD_EF_SAVED" 2>/dev/null || true; fi
    # remove сам выключает юниты фильтра — иначе его таймер через минуту поставил бы таблицу заново
    if [ -x "$SHIELD_EF_BIN" ]; then _ef_run remove || true; fi
    if command -v nft >/dev/null 2>&1; then
        nft delete table netdev "$SHIELD_EF_T" 2>/dev/null || true
        nft delete table inet "$SHIELD_EF_CT" 2>/dev/null || true
    fi
    if declare -F shield_persist_earlyfilter_timer_remove >/dev/null 2>&1; then shield_persist_earlyfilter_timer_remove || true; fi
    _ef_unlock
    [ "$EF_STATE" = absent ] || log warn "earlyfilter" "аварийный режим: ранний фильтр снят (был $([ "$prev" = enforce ] && echo 'отброс' || echo 'наблюдение')) — вернёт emergency off"
    return 0
}

# ---------------------------------------------------------------- показ: status / verify / guard / health
# shield_earlyfilter_brief — одна строка: режим (нет / наблюдение / отброс), устройство, счётчики
shield_earlyfilter_brief() {
    local flag note
    _ef_probe
    case "$EF_STATE" in
        enforce)
            _ef_numbers
            echo "отброс | устройство $EF_DEV | под отброс попало $EF_MISS из $EF_TOTAL учтённых пакетов" ;;
        observe)
            _ef_numbers
            echo "наблюдение | устройство $EF_DEV | под отброс попало бы $EF_MISS из $EF_TOTAL учтённых пакетов, из них «своих» $EF_FP ($(_ef_pct "$EF_FP" "$EF_TOTAL") %)" ;;
        *)
            flag="$(shield_conf_early_filter)"; note="$(_ef_note_text)"
            if [ "$flag" = 0 ]; then echo "нет (ENABLE_EARLY_FILTER=0)"
            elif [ -f "$SHIELD_EF_EMERGENCY" ]; then echo "нет (снят на время аварийного режима)"
            else echo "нет${note:+ — $note}"; fi ;;
    esac
    return 0
}
# shield_earlyfilter_status — раздел status и команда early-filter
shield_earlyfilter_status() {
    local t0="" h0="" m0="" now
    echo "ранний фильтр: $(shield_earlyfilter_brief)"
    _ef_probe   # brief выше — в подстановке, его переменные сюда не попадают
    if [ "$EF_STATE" != absent ]; then _ef_numbers; fi
    echo "  ENABLE_EARLY_FILTER=$(shield_conf_get ENABLE_EARLY_FILTER 1); EARLY_FILTER_MODE=$(shield_conf_get EARLY_FILTER_MODE auto); ведёт стек: $(shield_earlyfilter_managed && echo да || echo нет); скрипт: $( [ -x "$SHIELD_EF_BIN" ] && { cmp -s "$SHIELD_EF_BIN" "$(_ef_src)" && echo "$SHIELD_EF_BIN (как в стеке)" || echo "$SHIELD_EF_BIN (ОТЛИЧАЕТСЯ от версии стека — обновит apply)"; } || echo 'не установлен')"
    case "$EF_STATE" in
        enforce)
            echo "  настройки ядра фильтра: $(_ef_sysctl_on && echo включены || echo 'не тронуты'); продолжений без записи в таблице соединений: $EF_PICKUP" ;;
        observe)
            if _ef_manual; then echo "  ручная проба: активен $EF_MANUAL — стек режим не меняет"
            elif [ "$(shield_conf_early_filter_mode)" != auto ]; then
                # отброс стек не включает — но видно, попали бы под него свои пакеты (те же три проверки)
                if [ "$EF_TOTAL" -lt "$SHIELD_EF_MIN_PKTS" ]; then
                    echo "  по числам судить рано: учтено $EF_TOTAL пакетов из $SHIELD_EF_MIN_PKTS нужных для проверки"
                else
                    _ef_verdict
                    if [ -z "$EF_BAD" ]; then echo "  по числам сейчас: чисто — свои пакеты под отброс не попадают (отброс включит EARLY_FILTER_MODE=auto)"
                    else echo "  по числам сейчас: НЕ чисто — $EF_BAD"
                         echo "  (счётчики — с установки таблицы: первые $(_ef_learn) с фильтр ещё не знал прежних соединений; точный замер — sudo spofy-guard measure 60)"; fi
                fi
            elif [ -s "$SHIELD_EF_PENDING" ]; then
                read -r t0 h0 m0 < "$SHIELD_EF_PENDING" 2>/dev/null || true
                printf -v now '%(%s)T' -1
                if [[ "$m0" =~ ^[0-9]+$ ]]; then
                    echo "  наблюдение ведёт стек: идёт замер, $((now - m0)) с (нужно $SHIELD_EF_MEASURE_SEC с и $SHIELD_EF_MIN_PKTS пакетов; счётчики — с начала замера); допустимо «своих» 0,1 %, среди них SYN — 0, портов вне списков — 0"
                elif [[ "$t0" =~ ^[0-9]+$ ]]; then
                    echo "  наблюдение ведёт стек: фильтр учится, $((now - t0)) с из $(_ef_learn) (ответы на прежние соединения пока считаются «своими под отбросом» — в расчёт не идут), затем замер"
                fi
            fi
            echo "  среди «своих» новых соединений (SYN): $EF_FP_SYN; порты вне списков: ${EF_UNLISTED:-—}; продолжений без записи: $EF_PICKUP"
            _ef_note_now; [ -z "$EF_NTEXT" ] || echo "  $EF_NTEXT" ;;
    esac
    if [ -s "$SHIELD_EF_UPFAIL" ]; then echo "  $(head -1 "$SHIELD_EF_UPFAIL")"; fi
    if [ "$EF_STATE" != absent ]; then echo "  подробно: sudo spofy-guard status"
    elif [ "$(id -u)" -ne 0 ]; then echo "  без root таблицы nft не читаются — запусти через sudo"; fi
    return 0
}
# shield_earlyfilter_health — строки для health (status.sh; _hc — оттуда)
shield_earlyfilter_health() {
    local flag fmode note key
    flag="$(shield_conf_early_filter)"; fmode="$(shield_conf_early_filter_mode)"
    _ef_probe
    case "$flag" in
        invalid) _hc WARN "ENABLE_EARLY_FILTER=$(shield_conf_get ENABLE_EARLY_FILTER 1) — ожидается 0 или 1; ранний фильтр стек не трогает"; return 0 ;;
        0)  if [ "$EF_STATE" = absent ]; then _hc INFO "ранний фильтр выключен (ENABLE_EARLY_FILTER=0)"
            else _hc INFO "ранний фильтр: $(shield_earlyfilter_brief) — ENABLE_EARLY_FILTER=0, стек его не ведёт"; fi
            return 0 ;;
    esac
    if [ "$fmode" = invalid ]; then
        _hc WARN "EARLY_FILTER_MODE=$(shield_conf_get EARLY_FILTER_MODE auto) — ожидается auto или observe; режим раннего фильтра стек не меняет (отброс сам не включает)"
    fi
    if [ -s "$SHIELD_EF_UPFAIL" ]; then _hc WARN "$(head -1 "$SHIELD_EF_UPFAIL")"; fi
    _ef_note_now; note="$EF_NTEXT"; key="$EF_NKEY"
    case "$EF_STATE" in
        enforce)
            if [ "$fmode" = observe ] && ! _ef_manual; then
                _hc WARN "ранний фильтр: $(shield_earlyfilter_brief) — а EARLY_FILTER_MODE=observe: в наблюдение переведёт ближайший apply"
            else
                _hc PASS "ранний фильтр: $(shield_earlyfilter_brief)"
            fi
            if command -v systemctl >/dev/null 2>&1 && [ "$(shield_conf_get PERSIST_ENABLED 1)" = "1" ] && ! _ef_manual; then
                systemctl is-active --quiet spofy-guard.timer 2>/dev/null \
                    || _hc WARN "spofy-guard.timer не активен — после перезагрузки ранний фильтр не вернётся, новые порты в списки не допишутся (повтори apply)"
            fi ;;
        observe)
            _hc INFO "ранний фильтр: $(shield_earlyfilter_brief)"
            if _ef_manual; then _hc INFO "ранний фильтр: ручная проба ($EF_MANUAL активен) — стек режим не меняет"
            else case "$key" in
                dirty:*|fail:*) _hc WARN "$note" ;;
                mode-invalid)   : ;;   # сказано строкой выше
                "")             if [ "$fmode" = auto ]; then _hc INFO "ранний фильтр: отброс включится сам после проверки наблюдения (ближайший apply или таймер)"
                                elif [ "$fmode" = observe ]; then _hc INFO "ранний фильтр в наблюдении по настройке EARLY_FILTER_MODE=observe: отброс стек не включает"; fi ;;
                *)              _hc INFO "$note" ;;
            esac; fi ;;
        *)
            case "$key" in
                boot) _hc INFO "$note" ;;
                "")   _hc WARN "ранний фильтр не стоит (ENABLE_EARLY_FILTER=1) — поставит ближайший apply" ;;
                *)    _hc WARN "$note" ;;
            esac ;;
    esac
    return 0
}

# shield_earlyfilter_cmd [tick] — команда `shieldnode early-filter`
shield_earlyfilter_cmd() {
    case "${1:-}" in
        tick) shield_earlyfilter_tick ;;
        ""|status)
            shield_earlyfilter_status
            if [ "$EF_STATE" != absent ] && [ -x "$SHIELD_EF_BIN" ]; then echo; _ef_guard status || true; fi ;;
        *) die "usage: shieldnode early-filter [status|tick]" ;;
    esac
}
