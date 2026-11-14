#!/bin/bash
# shieldnode — тест: ранний фильтр на входе (earlyfilter.sh + persist.sh) — что и в каком порядке делает стек.
# 2026-11-14 (v1.2.11). nft, systemctl и сам spofy-guard — заглушки с состоянием в $OUT (настоящие пакеты и
# настоящий nft — в test-earlyfilter-realnft.sh). Проверяется:
#   - скрипт в репозитории — тот же, что стоит на серверах (sha256), его имена и пути совпадают с ожиданиями
#     стека, а TRUSTED_IPS он читает из того же файла, что и стек;
#   - первое включение: только через наблюдение, observe раньше юнитов;
#   - EARLY_FILTER_MODE=observe: отброс не включается, включённый переводится в наблюдение; опечатка в настройке;
#   - скрипт на сервере другой версии при стоящем фильтре: таймер стоп, замена, reload, таймер старт — режим
#     прежний, наблюдение заново не начинается; не встали правила — прежний файл на место;
#   - старый spofy-udp-guard: снимается, только если есть и только при включённом отбросе; rollback возвращает;
#   - порог: «своих» ≤ 0,1 %, SYN среди них 0, портов вне списков нет, не меньше LEARN секунд и
#     SHIELD_EF_MIN_PKTS пакетов; при отказе — наблюдение и причина с числами;
#   - включённый фильтр не трогается (усыновление); ручная проба не трогается; сбой шага не валит apply;
#   - аварийный режим: снять и вернуть прежний режим; ENABLE_EARLY_FILTER=0 / мусор / --dry-run;
#   - persist: совпавшие файлы не переписываются, снятие забывает файл в манифесте.
# Root не нужен: все пути — под $OUT.
set -euo pipefail

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-earlyfilter
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/fake" "$OUT/state" "$OUT/sbin" "$OUT/units"
F="$OUT/fake"; EV="$OUT/events"
export SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/shield.log" DRY_RUN=0 LOG_LEVEL=info NO_COLOR=1
export SHIELD_CONFIG="$OUT/config.conf" SHIELD_UNIT_DIR="$OUT/units" SHIELD_EF_BIN="$OUT/sbin/spofy-guard"
export SHIELD_EF_LOCK="$OUT/ef.lock" SHIELD_EF_EMERGENCY="$OUT/emergency"
export GUARD_STATE="$OUT/gstate" GUARD_CONF="$OUT/spofy-guard.conf" GUARD_SYSCTL_D="$OUT/sysctl.d" GUARD_IF=wan9
# старый фильтр UDP — только заглушка под $OUT (настоящий /usr/local/sbin/spofy-udp-guard тест не зовёт никогда);
# «встроенный скрипт» для стека — заглушка: установленный файл совпадает с ним, пока тест его не изменит
export SHIELD_EF_V1_BIN="$OUT/sbin/spofy-udp-guard" SHIELD_EF_SRC="$OUT/guard.fake"
: > "$SHIELD_LOG"

# --- nft: состояние таблиц — файлы в $F (mode: accept|drop — правило цепочки miss; нет файла — таблицы нет)
cat > "$OUT/bin/nft" <<EOF
#!/bin/bash
F="$F"; echo "\$*" >> "\$F/nft.log"
blk() { printf 'table %s {\n' "\$1"; cat; printf '}\n'; }
case "\$*" in
    "list chain netdev spofy_guard miss") [ -s "\$F/mode" ] || exit 1; printf '\tchain miss {\n\t\t%s\n\t}\n' "\$(cat "\$F/mode")" | blk "netdev spofy_guard" ;;
    "list chain netdev spofy_guard in")   [ -s "\$F/mode" ] || exit 1; printf '\tchain in {\n\t\ttype filter hook ingress device "wan9" priority -480; policy accept;\n\t}\n' | blk "netdev spofy_guard" ;;
    "-a -t list table netdev spofy_guard") [ -s "\$F/mode" ] || exit 1; echo "table netdev spofy_guard { # handle \$(cat "\$F/handle")"; echo "}" ;;
    "list counters table netdev spofy_guard") [ -s "\$F/mode" ] || exit 1
        while read -r n v; do printf '\tcounter %s {\n\t\tpackets %s bytes 0\n\t}\n' "\$n" "\$v"; done < "\$F/counters" | blk "netdev spofy_guard" ;;
    "list counters table inet spofy_guard_ct") [ -s "\$F/mode" ] || exit 1
        while read -r n v; do printf '\tcounter %s {\n\t\tpackets %s bytes 0\n\t}\n' "\$n" "\$v"; done < "\$F/ct_counters" | blk "inet spofy_guard_ct" ;;
    "list set inet spofy_guard_ct fp") [ -s "\$F/mode" ] || exit 1
        { printf '\tset fp {\n\t\ttype mark\n\t\tsize 64\n\t\tflags dynamic\n\t\tcounter\n'
          [ -s "\$F/fp" ] && printf '\t\telements = { %s }\n' "\$(paste -sd, "\$F/fp")"; printf '\t}\n'; } | blk "inet spofy_guard_ct" ;;
    "list set netdev spofy_guard "*) [ -s "\$F/mode" ] || exit 1; s="\${@: -1}"
        { printf '\tset %s {\n\t\ttype inet_service\n' "\$s"
          [ -s "\$F/set.\$s" ] && printf '\t\telements = { %s }\n' "\$(cat "\$F/set.\$s")"; printf '\t}\n'; } | blk "netdev spofy_guard" ;;
    "reset counters table netdev spofy_guard") [ -s "\$F/mode" ] || exit 1; [ -e "\$F/reset_fails" ] && exit 1
        sed -i -E 's/ [0-9]+\$/ 0/' "\$F/counters"; echo "nft reset" >> "$EV" ;;
    "reset counters table inet spofy_guard_ct") [ -s "\$F/mode" ] || exit 1; sed -i -E 's/ [0-9]+\$/ 0/' "\$F/ct_counters" ;;
    "flush set inet spofy_guard_ct fp") : > "\$F/fp" ;;
    "delete table netdev spofy_guard") rm -f "\$F/mode" ;;
    "list table netdev spofy_udp") [ -e "\$F/v1" ] || exit 1 ;;      # таблица старого фильтра UDP
    "delete table netdev spofy_udp") rm -f "\$F/v1" ;;
    list\ *) exit 1 ;;                                               # чего нет в заглушке — того нет
esac
exit 0
EOF
# --- systemctl: is-active по файлам $F/active.<юнит>; остальное — в журнал
cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$F/systemctl.log"
if [ "\$1" = is-active ]; then [ -e "$F/active.\${*: -1}" ] && exit 0; exit 3; fi
case "\$*" in "stop spofy-guard.timer"|"start spofy-guard.timer") echo "guard-timer \$1" >> "$EV" ;; esac
exit 0
EOF
# --- ip: маршрут по умолчанию есть, пока нет файла $F/noroute
cat > "$OUT/bin/ip" <<EOF
#!/bin/bash
[ -e "$F/noroute" ] || echo "default via 192.0.2.1 dev wan9 proto static"
EOF
# --- spofy-guard: шаги пишет в общий журнал событий; режим — в $F/mode и \$GUARD_STATE/mode, как настоящий
cat > "$OUT/guard.fake" <<EOF
#!/bin/bash
F="$F"; echo "guard \$*" >> "$EV"; mkdir -p "\$GUARD_STATE"
case "\$1" in
    observe) [ -e "\$F/observe_fails" ] && { echo "НЕ ПОСТАВИЛОСЬ"; exit 1; }
             echo accept > "\$F/mode"; echo \$(( \$(cat "\$F/handle" 2>/dev/null || echo 0) + 1 )) > "\$F/handle"; echo observe > "\$GUARD_STATE/mode" ;;
    enforce) [ -e "\$F/enforce_fails" ] && exit 1; [ -s "\$F/mode" ] || { echo "сначала observe"; exit 1; }
             echo drop > "\$F/mode"; echo enforce > "\$GUARD_STATE/mode" ;;
    sysctl)  case "\$2" in
                 on)  [ -e "\$F/sysctl_fails" ] && exit 1; touch "\$GUARD_STATE/sysctl.on" ;;
                 off) rm -f "\$GUARD_STATE/sysctl.on" ;;
             esac ;;
    ensure)  if [ ! -s "\$F/mode" ]; then   # boot: наблюдение остаётся наблюдением, иначе — отброс
                 echo \$(( \$(cat "\$F/handle" 2>/dev/null || echo 0) + 1 )) > "\$F/handle"
                 if [ "\$(cat "\$GUARD_STATE/mode" 2>/dev/null)" = observe ]; then echo accept > "\$F/mode"; else echo drop > "\$F/mode"; echo enforce > "\$GUARD_STATE/mode"; fi
             fi ;;
    reload)  [ -s "\$F/mode" ] || { echo "не стоит"; exit 1; }
             [ -e "\$F/reload_fails" ] && { echo "НЕ ПОСТАВИЛОСЬ"; exit 1; }      # правила не встали: таблица прежняя
             echo \$(( \$(cat "\$F/handle") + 1 )) > "\$F/handle"; echo accept > "\$F/mode"   # таблица заново, без отброса
             [ "\$(cat "\$GUARD_STATE/mode" 2>/dev/null)" = observe ] && exit 0
             [ -e "\$F/reload_half" ] && exit 1                                  # отброс после обучения не включился
             echo drop > "\$F/mode"; echo enforce > "\$GUARD_STATE/mode" ;;
    remove)  rm -f "\$F/mode" "\$GUARD_STATE/mode" "\$GUARD_STATE/sysctl.on"; echo "снято" ;;
esac
exit 0
EOF
chmod +x "$OUT/bin"/* "$OUT/guard.fake"; export PATH="$OUT/bin:$PATH"

# shellcheck source=../lib/common.sh
source "$SHIELD_DIR/lib/common.sh"
# shellcheck source=../config.sh
source "$SHIELD_DIR/config.sh"
# shellcheck source=../earlyfilter.sh
source "$SHIELD_DIR/earlyfilter.sh"
_hc() { echo "[$1] $2"; }
# health целиком в файл и только потом grep: `health | grep -q` при pipefail падает, когда grep закрывает трубу
# на первой совпавшей строке, а health ещё пишет следующую
hl() { shield_earlyfilter_health > "$OUT/health.out" 2>&1 || true; cat "$OUT/health.out"; }
has() { local o; o="$(hl)"; grep -q -- "$1" <<<"$o"; }

fails=0
t() { local name="$1"; shift
    if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
conf() { printf '%s\n' "$@" > "$SHIELD_CONFIG"; rm -f "${CONFIG_CACHE:-}"; shield_load_config; }
ev() { cat "$EV" 2>/dev/null | paste -sd'|' -; }                 # события одной строкой: «a|b|c»
note_key() { cut -f1 "$SHIELD_STATE_DIR/earlyfilter.note" 2>/dev/null || true; }
managed() { echo "$SHIELD_EF_BIN" > "$SHIELD_STATE_DIR/applied-files.txt"; }
# counters <пропущено> <под отброс> <«своих»> — учтённые пакеты; пропущенные — ответы на свой UDP, под отброс — UDP не к нам
counters() { printf 'c_udp_reply %s\nc_udp_miss %s\nc_syn_new 0\n' "$1" "$2" > "$F/counters"; printf 'c_invalid 0\nc_fp %s\nc_pickup 0\n' "$3" > "$F/ct_counters"; }
elapsed() { echo "$(( $(date +%s) - ${1:-100} )) $(cat "$F/handle")" > "$SHIELD_STATE_DIR/earlyfilter.observe"; }   # наблюдение стека идёт N с, замер не начат
# measured <сек наблюдения> <сек замера> — обучение позади, замер идёт M с
measured() { echo "$(( $(date +%s) - ${1:-100} )) $(cat "$F/handle") $(( $(date +%s) - ${2:-60} ))" > "$SHIELD_STATE_DIR/earlyfilter.observe"; }
# fresh <нет|observe|enforce> — чистое состояние: таблица, отметки, журналы
fresh() {
    rm -rf "$F" "$SHIELD_STATE_DIR" "$GUARD_STATE" "$EV" "$SHIELD_EF_EMERGENCY"; mkdir -p "$F" "$SHIELD_STATE_DIR" "$GUARD_STATE"
    echo 7 > "$F/handle"; counters 0 0 0; : > "$EV"
    mkdir -p "$OUT/sbin"; rm -f "$OUT/sbin/spofy-udp-guard" "$OUT/units/spofy-udp-guard.timer"
    cp "$OUT/guard.fake" "$SHIELD_EF_BIN"
    case "${1:-нет}" in
        observe) echo accept > "$F/mode"; echo observe > "$GUARD_STATE/mode" ;;
        enforce) echo drop > "$F/mode"; echo enforce > "$GUARD_STATE/mode"; touch "$GUARD_STATE/sysctl.on" ;;
    esac
}
# заглушки записи файлов (настоящие функции persist.sh — в конце теста)
shield_persist_earlyfilter() {   # как настоящая: отличающийся файл заменяется встроенным
    echo "persist files" >> "$EV"; [ ! -e "$F/persist_fails" ] || return 1
    cmp -s "$SHIELD_EF_SRC" "$SHIELD_EF_BIN" || install -m 0755 "$SHIELD_EF_SRC" "$SHIELD_EF_BIN"
}
shield_persist_earlyfilter_enable() { echo "units on" >> "$EV"; }
shield_persist_earlyfilter_timer() { echo "timer on" >> "$EV"; }
shield_persist_earlyfilter_timer_remove() { echo "timer off" >> "$EV"; }
shield_persist_earlyfilter_remove() { echo "persist remove" >> "$EV"; }
run() { "$@" > "$OUT/last.out" 2>&1 || echo "rc=$?" >> "$OUT/last.out"; }
conf "SSH_PORT=22"

# ================= скрипт в репозитории =================
G="$SHIELD_DIR/spofy-guard"
# совпадение по содержимому с тем, что стоит на серверах, = apply ничего не переписывает. Обновил скрипт — обнови и здесь
t "скрипт: тот же файл, что стоит на серверах (2.4, sha256)" \
    "[ \"\$(sha256sum < $G | cut -d' ' -f1)\" = d0fe30210f1b876c02e8114a29b1ef0332979dcefc330a7778b226fe0698dea9 ] && grep -q '^VER=2.4; T=spofy_guard; CT=spofy_guard_ct\$' $G"
t "скрипт: умеет reload («поставить заново в том же режиме»), observe, enforce, ensure, remove, sysctl" \
    "for c in observe enforce ensure reload remove sysctl; do grep -qE \"^  \$c\\)\" $G || exit 1; done"
t "скрипт: пути те же, что ждёт стек (/etc/spofy-guard.conf, /var/lib/spofy-guard, /etc/sysctl.d)" \
    "grep -qF 'CONF=\${GUARD_CONF:-/etc/spofy-guard.conf}; STATE=\${GUARD_STATE:-/var/lib/spofy-guard}; SYSD=\${GUARD_SYSCTL_D:-/etc/sysctl.d}' $G"
t "скрипт: TRUSTED_IPS читает из того же файла, что и стек по умолчанию" \
    "grep -qF \"grep -hs '^TRUSTED_IPS=' /etc/shieldnode/config.conf\" $G && ( unset SHIELD_CONFIG; source $SHIELD_DIR/config.sh; [ \"\$SHIELD_CONFIG\" = /etc/shieldnode/config.conf ] )"
t "стек: те же имена таблиц, то же место скрипта, встроенный скрипт — рядом с модулем" \
    "[ \"\$SHIELD_EF_T\" = spofy_guard ] && [ \"\$SHIELD_EF_CT\" = spofy_guard_ct ] && ( unset SHIELD_EF_BIN SHIELD_EF_SRC SHIELD_EF_V1_BIN; source $SHIELD_DIR/earlyfilter.sh; [ \"\$SHIELD_EF_BIN\" = /usr/local/sbin/spofy-guard ] && [ \"\$(_ef_src)\" = $SHIELD_DIR/spofy-guard ] && [ \"\$SHIELD_EF_V1_BIN\" = /usr/local/sbin/spofy-udp-guard ] )"
t "defaults: ENABLE_EARLY_FILTER=1, EARLY_FILTER_MODE=auto" \
    "grep -qx 'ENABLE_EARLY_FILTER=1' $SHIELD_DIR/shieldnode.defaults.conf && grep -qx 'EARLY_FILTER_MODE=auto' $SHIELD_DIR/shieldnode.defaults.conf"

# ================= флаг =================
t "флаг: по умолчанию 1" "[ \"\$(shield_conf_early_filter)\" = 1 ]"
conf "ENABLE_EARLY_FILTER=0";   t "флаг: 0" "[ \"\$(shield_conf_early_filter)\" = 0 ]"
conf "ENABLE_EARLY_FILTER=yes"; t "флаг: «yes» — не 0 и не 1" "[ \"\$(shield_conf_early_filter)\" = invalid ]"
conf "SSH_PORT=22";                 t "режим: по умолчанию auto" "[ \"\$(shield_conf_early_filter_mode)\" = auto ]"
conf "EARLY_FILTER_MODE=observe";   t "режим: observe" "[ \"\$(shield_conf_early_filter_mode)\" = observe ]"
conf "EARLY_FILTER_MODE=enforce";   t "режим: «enforce» — не auto и не observe" "[ \"\$(shield_conf_early_filter_mode)\" = invalid ]"
conf "ENABLE_EARLY_FILTER=yes"
fresh enforce; managed; run shield_earlyfilter_ensure
t "флаг с опечаткой: фильтр не тронут (ни снят, ни поставлен), предупреждение" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = drop ] && grep -q 'ожидается 0 или 1' $OUT/last.out"
t "флаг с опечаткой: health WARN" "has '^\[WARN\] ENABLE_EARLY_FILTER=yes'"
conf "SSH_PORT=22"

# ================= первое включение =================
fresh; run shield_earlyfilter_ensure
t "фильтра нет: ставится наблюдение — observe РАНЬШЕ включения юнитов, отброс не включается" \
    "[ \"\$(ev)\" = 'persist files|guard observe|units on|timer on' ] && [ \"\$(cat $F/mode)\" = accept ]"
t "фильтра нет: наблюдение записано за стеком (время и номер таблицы)" "grep -qE '^[0-9]+ 8\$' $SHIELD_STATE_DIR/earlyfilter.observe && [ \"\$(note_key)\" = wait ]"
t "brief: наблюдение, устройство, счётчики" "[ \"\$(shield_earlyfilter_brief)\" = 'наблюдение | устройство wan9 | под отброс попало бы 0 из 0 учтённых пакетов, из них «своих» 0 (0 %)' ]"
: > "$EV"; counters 519000 904 5; run shield_earlyfilter_tick
t "LEARN ещё не прошёл: решение отложено" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = accept ]"
# обучение позади: фильтр, поставленный на ходу, успел насчитать «своих» по ответам на прежние потоки
# (живая нода 14.11: 495 из 20 980 за первые 6 с) — по ним не судим: счётчики с нуля, начинается замер
elapsed 100; counters 20485 613 495; echo '0x00005d05 counter packets 495 bytes 60000' > "$F/fp"; run shield_earlyfilter_tick
t "обучение закончено: счётчики обнулены, начат замер — отброс ещё не включается и причиной «свои» не названы" \
    "[ \"\$(ev)\" = 'nft reset' ] && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = measure ] && ! grep -q 'НЕ включён' $OUT/last.out"
t "обучение закончено: время начала замера записано третьим полем, разбивка «своих» сброшена" \
    "grep -qE '^[0-9]+ 8 [0-9]+\$' $SHIELD_STATE_DIR/earlyfilter.observe && grep -qx 'c_fp 0' $F/ct_counters && grep -qx 'c_udp_miss 0' $F/counters && [ ! -s $F/fp ]"
: > "$EV"; counters 519000 904 5; run shield_earlyfilter_tick
t "замер короче ${SHIELD_EF_MEASURE_SEC} с: решение отложено" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = measure ]"
t "status: виден идущий замер" "o=\"\$(shield_earlyfilter_status 2>&1)\"; grep -q 'наблюдение ведёт стек: идёт замер' <<<\"\$o\""
measured 100 60; run shield_earlyfilter_tick
t "чисто (5 «своих» из 519904 = 0,001 %): sysctl on, затем enforce" "[ \"\$(ev)\" = 'guard sysctl on|guard enforce|timer off' ] && [ \"\$(cat $F/mode)\" = drop ]"
t "включено: отметка наблюдения и пояснение убраны, в журнале — числа замера" \
    "[ ! -e $SHIELD_STATE_DIR/earlyfilter.observe ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.note ] && grep -qE 'отброс включён \(устройство wan9\)\. После 30 с обучения за 6[01] с замера учтено 519904 пакетов, под отброс попало бы 904, из них «своих» 5 \(0,001 %\)' $OUT/last.out"
t "brief: отброс" "[ \"\$(shield_earlyfilter_brief)\" = 'отброс | устройство wan9 | под отброс попало 904 из 519904 учтённых пакетов' ]"
t "health: отброс — PASS" "has '^\[PASS\] ранний фильтр: отброс | устройство wan9'"

# ================= порог =================
gate() { fresh observe; managed; measured 100 60; "$@"; run shield_earlyfilter_tick; }
gate counters 999000 1000 1000
t "порог: ровно 0,1 % «своих» (1000 из 1000000) — включается" "[ \"\$(cat $F/mode)\" = drop ]"
gate counters 519000 904 600
t "порог: 0,115 % «своих» (600 из 519904) — НЕ включается, sysctl не тронут, замер начат заново" "[ \"\$(cat $F/mode)\" = accept ] && [ \"\$(ev)\" = 'nft reset' ] && [ \"\$(note_key)\" = dirty:own ]"
t "порог: причина с числами в журнале (warn) и в пояснении" \
    "grep -q '\[warn\] earlyfilter: .*«своих» пакетов под отбросом 600 из 519904 учтённых (0,115 %), допустимо 0,1 %' $OUT/last.out && grep -q '600 из 519904' $SHIELD_STATE_DIR/earlyfilter.note"
t "порог: health WARN с причиной" "has '^\[WARN\] ранний фильтр: отброс НЕ включён'"
: > "$OUT/last.out"; run shield_earlyfilter_tick
t "порог: новый замер идёт — причина прошлого остаётся в пояснении, в журнал ничего не пишется" "! grep -q 'earlyfilter' $OUT/last.out && [ \"\$(note_key)\" = dirty:own ]"
measured 200 60; counters 519000 904 600; : > "$OUT/last.out"; : > "$EV"; run shield_earlyfilter_tick
t "порог: причина держится и во втором замере — та же причина второй раз в журнал не пишется, отброс не включён" \
    "! grep -q 'earlyfilter' $OUT/last.out && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(ev)\" = 'nft reset' ]"
measured 300 60; counters 519000 904 5; : > "$EV"; run shield_earlyfilter_tick
t "порог: следующий замер чистый (разовый всплеск прошёл) — отброс включается" "[ \"\$(ev)\" = 'guard sysctl on|guard enforce|timer off' ] && [ \"\$(cat $F/mode)\" = drop ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.note ]"
gate eval "counters 999998 2 2; echo '0x00005d05 counter packets 1 bytes 60' > $F/fp; echo '0x00005d01 counter packets 1 bytes 60' >> $F/fp"
t "порог: среди «своих» есть SYN — НЕ включается, хотя доля мала" "[ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = dirty:+syn ] && grep -q 'новых соединений (SYN) 1, допустимо 0' $SHIELD_STATE_DIR/earlyfilter.note"
gate eval "counters 999998 2 2; echo '0x00005d05 counter packets 2 bytes 120' > $F/fp"
t "порог: «свои» только по UDP и в пределах доли — включается" "[ \"\$(cat $F/mode)\" = drop ]"
gate eval "counters 5000 0 0; echo '8080 timeout 1h expires 59m10s, 9090 timeout 1h expires 58m' > $F/set.unlisted; echo '443, 9090' > $F/set.tcp_svc"
t "порог: сервер отвечает с порта вне списков — НЕ включается, назван только порт, которого в списках нет" \
    "[ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = dirty:+ports ] && grep -q 'нет в списках фильтра: 8080\\.' $SHIELD_STATE_DIR/earlyfilter.note"
gate eval "counters 5000 0 0; echo '8080 timeout 1h expires 59m10s' > $F/set.unlisted; echo '443, 8080' > $F/set.tcp_svc"
t "порог: порт уже дописан в списки — проверке не мешает" "[ \"\$(cat $F/mode)\" = drop ]"
gate counters 999 0 0
t "порог: меньше 1000 учтённых пакетов — решение отложено" "[ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = few ] && [ -z \"\$(ev)\" ]"
gate eval "counters 5000 0 0; echo 9 > $F/handle"
t "таблицу пересоздали (номер другой): окно наблюдения начинается заново" \
    "[ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = wait ] && grep -qE '^[0-9]+ 9\$' $SHIELD_STATE_DIR/earlyfilter.observe"
echo 'LEARN=600' > "$GUARD_CONF"; gate counters 5000 0 0
t "LEARN берётся из настроек фильтра (600 с): 100 с наблюдения мало" "[ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = wait ] && [ -z \"\$(ev)\" ]"
rm -f "$GUARD_CONF"; fresh observe; managed; elapsed 100; counters 5000 0 0; touch "$F/reset_fails"; run shield_earlyfilter_tick
t "счётчики не обнулились: предупреждение в журнале, замер всё равно начат" \
    "grep -q 'счётчики не обнулились' $OUT/last.out && grep -qE '^[0-9]+ [0-9]+ [0-9]+\$' $SHIELD_STATE_DIR/earlyfilter.observe && [ \"\$(cat $F/mode)\" = accept ]"
rm -f "$F/reset_fails"
rm -f "$GUARD_CONF"
gate eval "counters 5000 0 0; touch $F/enforce_fails"
t "enforce не удался: настройки ядра возвращены, остаётся наблюдение" \
    "[ \"\$(ev)\" = 'guard sysctl on|guard enforce|guard sysctl off' ] && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = fail:enforce ] && [ ! -e $GUARD_STATE/sysctl.on ]"
gate eval "counters 5000 0 0; touch $F/sysctl_fails"
t "ядро не приняло настройки: отброс не включается" "[ \"\$(ev)\" = 'guard sysctl on|guard sysctl off' ] && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(note_key)\" = fail:sysctl ]"

# ================= включённый фильтр, ручная проба =================
fresh enforce; run shield_earlyfilter_ensure
t "усыновление: отброс уже включён — только ensure (ни observe, ни enforce, ни sysctl)" \
    "[ \"\$(ev)\" = 'persist files|timer off|units on|guard ensure' ] && [ \"\$(cat $F/mode)\" = drop ] && [ \"\$(cat $F/handle)\" = 7 ]"
conf "SSH_PORT=22" "TRUSTED_IPS=192.0.2.10, 192.0.2.0/28 2001:db8::1 мусор"; fresh enforce; SH_F_ADMIN_V4=198.51.100.7 run shield_earlyfilter_ensure
t "доверенные: TRUSTED_IPS и адрес SSH-сессии дописаны в набор (IPv4; IPv6 и мусор пропущены)" \
    "[ \"\$(grep -c 'add element netdev spofy_guard trusted' $F/nft.log)\" = 3 ] && grep -q 'trusted { 192.0.2.0/28 }' $F/nft.log && grep -q 'trusted { 198.51.100.7 }' $F/nft.log"
conf "SSH_PORT=22"
fresh observe; managed; elapsed 100; counters 5000 0 0; touch "$F/active.spofy-guard-observe-expire.timer"
run shield_earlyfilter_ensure; run shield_earlyfilter_tick
t "ручная проба (наблюдение с автоснятием): ни apply, ни таймер ничего не делают" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = accept ]"
t "ручная проба: health — INFO, не WARN" "has '^\[INFO\] ранний фильтр: ручная проба (spofy-guard-observe-expire.timer активен)' && ! has WARN"
fresh enforce; touch "$F/active.spofy-guard-auto-rollback.timer"; run shield_earlyfilter_ensure
t "ручная проба (включение с автоснятием): apply не трогает" "[ -z \"\$(ev)\" ]"
fresh observe; counters 5000 0 0; run shield_earlyfilter_ensure
t "наблюдение поставлено руками и без таймера автоснятия: стек берёт его на себя, LEARN — с этого момента" \
    "[ \"\$(ev)\" = 'persist files|units on|guard ensure|timer on' ] && [ \"\$(cat $F/mode)\" = accept ] && [ -s $SHIELD_STATE_DIR/earlyfilter.observe ]"
fresh observe; echo enforce > "$GUARD_STATE/mode"; counters 5000 0 0; run shield_earlyfilter_ensure
t "скрипт сам включает отброс (загрузка сервера): стек не вмешивается и наблюдение на себя не берёт" \
    "[ \"\$(ev)\" = 'persist files|units on|guard ensure' ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.observe ]"
fresh; echo enforce > "$GUARD_STATE/mode"; run shield_earlyfilter_ensure
t "таблица пропала, отброс был включён: возвращает служба фильтра (без observe и без ожидания)" \
    "[ \"\$(ev)\" = 'persist files|units on|guard ensure' ] && [ \"\$(cat $F/mode)\" = drop ] && [ \"\$(note_key)\" = boot ] && ! grep -q 'start --no-block' $F/systemctl.log"
fresh; touch "$F/noroute"; ( unset GUARD_IF; run shield_earlyfilter_ensure )
t "нет маршрута по умолчанию: ничего не ставится, причина записана" "[ -z \"\$(ev)\" ] && [ \"\$(note_key)\" = noroute ]"
fresh; touch "$F/observe_fails"; run shield_earlyfilter_ensure
t "nft не принял таблицу: юниты не включаются, apply не падает (rc 0, предупреждение)" \
    "[ \"\$(ev)\" = 'persist files|guard observe' ] && [ \"\$(note_key)\" = fail:observe ] && ! grep -q '^rc=' $OUT/last.out && grep -q 'шаг не выполнен' $OUT/last.out"
fresh; touch "$F/persist_fails"; run shield_earlyfilter_ensure
t "файл не записался: фильтр не запускается, apply не падает" "[ \"\$(ev)\" = 'persist files' ] && ! grep -q '^rc=' $OUT/last.out"
fresh; DRY_RUN=1 run shield_earlyfilter_ensure
t "--dry-run: ничего не делает" "[ -z \"\$(ev)\" ] && grep -q 'dry-run' $OUT/last.out"

# ================= аварийный режим =================
fresh enforce; managed; run shield_earlyfilter_emergency_on
t "emergency on: фильтр снят, запомнено «отброс + настройки ядра»" \
    "[ \"\$(ev)\" = 'guard remove|timer off' ] && [ ! -e $F/mode ] && [ \"\$(cat $SHIELD_STATE_DIR/earlyfilter.emergency)\" = \"\$(printf 'enforce\t1')\" ]"
: > "$EV"; run shield_earlyfilter_emergency_on
t "emergency on повторно: запомненное не затёрто" "[ \"\$(cut -f1 $SHIELD_STATE_DIR/earlyfilter.emergency)\" = enforce ]"
: > "$EV"; touch "$SHIELD_EF_EMERGENCY"; run shield_earlyfilter_ensure
t "аварийный режим: apply фильтр не ставит" "[ -z \"\$(ev)\" ] && [ ! -e $F/mode ]"
t "аварийный режим: brief — «снят на время аварийного режима»" "[ \"\$(shield_earlyfilter_brief)\" = 'нет (снят на время аварийного режима)' ]"
rm -f "$SHIELD_EF_EMERGENCY"; : > "$EV"; : > "$F/systemctl.log"; touch "$OUT/units/spofy-guard.service"; run shield_earlyfilter_ensure
rm -f "$OUT/units/spofy-guard.service"
t "emergency off: настройки ядра и отброс возвращает служба фильтра (без наблюдения заново, apply не ждёт)" \
    "[ \"\$(ev)\" = 'persist files|guard sysctl on|units on' ] && grep -q 'start --no-block spofy-guard.service' $F/systemctl.log && [ ! -e $SHIELD_STATE_DIR/earlyfilter.emergency ]"
fresh observe; managed; elapsed 5; run shield_earlyfilter_emergency_on
rm -f "$SHIELD_EF_EMERGENCY"; : > "$EV"; run shield_earlyfilter_ensure
t "emergency on/off из наблюдения: возвращается наблюдение, а не отброс" \
    "[ \"\$(ev)\" = 'persist files|guard observe|units on|timer on' ] && [ \"\$(cat $F/mode)\" = accept ]"
fresh observe; touch "$F/active.spofy-guard-observe-expire.timer"; run shield_earlyfilter_emergency_on
t "emergency on: ручное наблюдение с автоснятием не трогается" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = accept ]"
conf "ENABLE_EARLY_FILTER=0"; fresh enforce; run shield_earlyfilter_emergency_on
t "emergency on: фильтр мимо стека при ENABLE_EARLY_FILTER=0 не трогается" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = drop ]"

# ================= ENABLE_EARLY_FILTER=0, снятие =================
fresh enforce; run shield_earlyfilter_ensure
t "=0: фильтр поставлен мимо стека — не трогается" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = drop ] && grep -q 'поставлен мимо стека' $OUT/last.out"
t "=0: health — INFO" "has '^\[INFO\] ранний фильтр: отброс .* ENABLE_EARLY_FILTER=0, стек его не ведёт'"
fresh enforce; managed; touch "$SHIELD_STATE_DIR/earlyfilter.note"; run shield_earlyfilter_ensure
t "=0: фильтр, который ведёт стек, снимается целиком (таблицы, юниты, файл, состояние, отметки)" \
    "[ \"\$(ev)\" = 'guard remove|timer off|persist remove' ] && [ ! -e $F/mode ] && [ ! -e $GUARD_STATE ] && [ -z \"\$(ls $SHIELD_STATE_DIR/earlyfilter.* 2>/dev/null)\" ]"
fresh; run shield_earlyfilter_ensure
t "=0: фильтра нет — ничего не делается; health INFO «выключен»" "[ -z \"\$(ev)\" ] && has '^\[INFO\] ранний фильтр выключен (ENABLE_EARLY_FILTER=0)'"
conf "SSH_PORT=22"
fresh; t "health: фильтра нет при =1 — WARN" "has '^\[WARN\] ранний фильтр не стоит'"
fresh enforce; managed
t "health: отброс включён, а таймер фильтра не активен — WARN" "has '^\[WARN\] spofy-guard.timer не активен'"
touch "$F/active.spofy-guard.timer"
t "health: отброс включён и таймер активен — без WARN" "! has WARN"
t "команда early-filter: неизвестный аргумент — отказ" "! ( shield_earlyfilter_cmd bogus )"

# ================= EARLY_FILTER_MODE=observe =================
conf "SSH_PORT=22" "EARLY_FILTER_MODE=observe"
fresh; run shield_earlyfilter_ensure
t "режим observe, фильтра нет: ставится наблюдение, своего таймера проверки нет, окно стек не ведёт" \
    "[ \"\$(ev)\" = 'persist files|guard observe|units on|timer off' ] && [ \"\$(cat $F/mode)\" = accept ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.observe ] && [ \"\$(note_key)\" = mode-observe ]"
: > "$EV"; counters 519000 904 5; elapsed 100; run shield_earlyfilter_tick; run shield_earlyfilter_ensure
t "режим observe: числа чистые, LEARN прошёл — отброс НЕ включается ни таймером, ни apply" \
    "[ \"\$(cat $F/mode)\" = accept ] && ! grep -qE 'guard (enforce|sysctl)' $EV && [ ! -e $SHIELD_STATE_DIR/earlyfilter.observe ]"
t "режим observe: health — INFO с причиной, без WARN" "has '^\[INFO\] ранний фильтр в наблюдении по настройке EARLY_FILTER_MODE=observe' && ! has WARN"
t "режим observe: status говорит, попали бы под отброс свои пакеты (чисто)" \
    "shield_earlyfilter_status > $OUT/st.out 2>&1; grep -q 'EARLY_FILTER_MODE=observe' $OUT/st.out && grep -q 'по числам сейчас: чисто' $OUT/st.out"
counters 519000 904 600
t "режим observe: status — не чисто, с числами" "shield_earlyfilter_status > $OUT/st.out 2>&1; grep -q 'по числам сейчас: НЕ чисто — «своих» пакетов под отбросом 600 из 519904' $OUT/st.out"
counters 10 0 0
t "режим observe: status — пакетов мало, судить рано" "shield_earlyfilter_status > $OUT/st.out 2>&1; grep -q 'по числам судить рано: учтено 10 пакетов из 1000' $OUT/st.out"
fresh enforce; managed; run shield_earlyfilter_ensure
t "режим observe, отброс включён: переводится в наблюдение, настройки ядра возвращаются" \
    "[ \"\$(ev)\" = 'persist files|guard observe|guard sysctl off|timer off|units on' ] && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ] && [ ! -e $GUARD_STATE/sysctl.on ] && grep -q '\[warn\] earlyfilter: ранний фильтр переведён из отброса в наблюдение' $OUT/last.out"
fresh enforce; managed
t "режим observe, отброс ещё включён (apply не было): health WARN" "has '^\[WARN\] ранний фильтр: отброс .* а EARLY_FILTER_MODE=observe'"
fresh enforce; managed; touch "$F/active.spofy-guard-auto-rollback.timer"; run shield_earlyfilter_ensure
t "режим observe, идёт ручная проба: не трогается" "[ -z \"\$(ev)\" ] && [ \"\$(cat $F/mode)\" = drop ]"
fresh observe; echo enforce > "$GUARD_STATE/mode"; run shield_earlyfilter_ensure
t "режим observe, скрипт сам доучивается до отброса: возвращается в наблюдение" \
    "[ \"\$(ev)\" = 'persist files|guard observe|timer off|units on' ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ]"
fresh; echo enforce > "$GUARD_STATE/mode"; run shield_earlyfilter_ensure
t "режим observe, таблица пропала, а раньше был отброс: ставится наблюдение, а не отброс" \
    "[ \"\$(ev)\" = 'persist files|guard observe|units on|timer off' ] && [ \"\$(cat $F/mode)\" = accept ]"
fresh observe; managed; elapsed 100; counters 5000 0 0; run shield_earlyfilter_ensure
t "режим observe, наблюдение вёл стек (раньше был auto): окно закрыто, свой таймер снят, отброса нет" \
    "[ \"\$(ev)\" = 'persist files|units on|guard ensure|timer off' ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.observe ] && [ \"\$(cat $F/mode)\" = accept ]"
conf "SSH_PORT=22"; : > "$EV"; run shield_earlyfilter_ensure
t "снова auto: стек берёт наблюдение на себя, окно — с этого момента" \
    "[ \"\$(ev)\" = 'persist files|units on|guard ensure|timer on' ] && [ -s $SHIELD_STATE_DIR/earlyfilter.observe ] && [ \"\$(cat $F/mode)\" = accept ]"
t "снова auto: пояснение от прежней настройки в health не показывается" "! has 'EARLY_FILTER_MODE=observe'"
conf "SSH_PORT=22" "EARLY_FILTER_MODE=enforce"
fresh observe; managed; elapsed 100; counters 5000 0 0; run shield_earlyfilter_ensure; run shield_earlyfilter_tick
t "режим с опечаткой, наблюдение: отброс не включается, предупреждение" \
    "[ \"\$(cat $F/mode)\" = accept ] && ! grep -qE 'guard (enforce|sysctl|observe)' $EV && [ \"\$(note_key)\" = mode-invalid ]"
t "режим с опечаткой: health WARN (одной строкой)" "has '^\[WARN\] EARLY_FILTER_MODE=enforce — ожидается auto или observe' && [ \"\$(hl | grep -c WARN)\" = 1 ]"
fresh enforce; managed; run shield_earlyfilter_ensure
t "режим с опечаткой, отброс включён: режим не трогается (только ensure), предупреждение в журнале" \
    "[ \"\$(ev)\" = 'persist files|timer off|units on|guard ensure' ] && [ \"\$(cat $F/mode)\" = drop ] && grep -q 'EARLY_FILTER_MODE=enforce — ожидается auto или observe' $OUT/last.out"
conf "SSH_PORT=22"

# ================= скрипт на сервере другой версии =================
old() { echo '# прежняя версия' >> "$SHIELD_EF_BIN"; cp -p "$SHIELD_EF_BIN" "$OUT/old.script"; }   # установленный ≠ встроенный
fresh enforce; old; touch "$F/active.spofy-guard.timer"; run shield_earlyfilter_ensure
t "другая версия, отброс включён: таймер стоп → замена файла → reload → таймер старт; дальше как обычно" \
    "[ \"\$(ev)\" = 'guard-timer stop|persist files|guard reload|guard-timer start|timer off|units on|guard ensure' ]"
t "другая версия, отброс включён: режим прежний, таблица поставлена заново, наблюдение не начиналось" \
    "[ \"\$(cat $F/mode)\" = drop ] && [ \"\$(cat $GUARD_STATE/mode)\" = enforce ] && [ \"\$(cat $F/handle)\" = 8 ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.observe ] && ! grep -qE 'guard (observe|enforce|sysctl)' $EV"
t "другая версия: на сервере теперь встроенный скрипт, копии прежнего в состоянии стека не осталось, запись в журнале" \
    "cmp -s $SHIELD_EF_BIN $SHIELD_EF_SRC && [ ! -e $SHIELD_STATE_DIR/earlyfilter.prev ] && grep -q 'ранний фильтр обновлён: .* режим прежний — отброс' $OUT/last.out"
: > "$EV"; run shield_earlyfilter_ensure
t "другая версия: повторный apply — уже совпадает, ни reload, ни остановки таймера" "[ \"\$(ev)\" = 'persist files|timer off|units on|guard ensure' ]"
fresh observe; managed; elapsed 5; old; run shield_earlyfilter_ensure
t "другая версия, наблюдение ведёт стек: ставится заново наблюдением (не reload), окно начинается заново" \
    "[ \"\$(ev)\" = 'persist files|guard observe|units on|guard ensure|timer on' ] && [ \"\$(cat $F/mode)\" = accept ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ] && grep -qE '^[0-9]+ 8\$' $SHIELD_STATE_DIR/earlyfilter.observe"
fresh observe; rm -f "$GUARD_STATE/mode"; old; run shield_earlyfilter_ensure
t "другая версия, наблюдение без отметки режима: reload включил бы отброс без проверки — ставится наблюдением" \
    "grep -q 'guard observe' $EV && ! grep -q 'guard reload' $EV && [ \"\$(cat $F/mode)\" = accept ]"
fresh observe; echo enforce > "$GUARD_STATE/mode"; old; run shield_earlyfilter_ensure
t "другая версия, скрипт доучивался до отброса: reload доводит до отброса" \
    "grep -q 'guard reload' $EV && [ \"\$(cat $F/mode)\" = drop ] && [ \"\$(cat $GUARD_STATE/mode)\" = enforce ]"
fresh enforce; old; touch "$F/active.spofy-guard.timer" "$F/reload_fails"; run shield_earlyfilter_ensure
t "другая версия, правила не встали: прежний файл на месте, таблица и режим прежние, таймер запущен обратно" \
    "cmp -s $SHIELD_EF_BIN $OUT/old.script && [ \"\$(cat $F/handle)\" = 7 ] && [ \"\$(cat $F/mode)\" = drop ] && [ \"\$(ev)\" = 'guard-timer stop|persist files|guard reload|guard-timer start|timer off|units on|guard ensure' ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.prev ]"
t "другая версия, правила не встали: apply не падает, причина — в журнале и в health (WARN), обычный шаг её не затирает" \
    "! grep -q '^rc=' $OUT/last.out && grep -q 'обновить скрипт не удалось — прежний скрипт' $OUT/last.out && grep -q 'шаг не выполнен' $OUT/last.out && has '^\[WARN\] ранний фильтр: обновить скрипт не удалось' && has '^\[PASS\] ранний фильтр: отброс'"
rm -f "$F/reload_fails"; run shield_earlyfilter_ensure
t "другая версия: следующий apply повторяет обновление — удалось, предупреждение снято" \
    "cmp -s $SHIELD_EF_BIN $SHIELD_EF_SRC && [ \"\$(cat $F/handle)\" = 8 ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.upgrade ] && ! has 'обновить скрипт не удалось'"
fresh enforce; old; touch "$F/reload_half"; run shield_earlyfilter_ensure
t "другая версия, правила встали, а отброс не включился: файл остаётся новым (правила уже его), предупреждение" \
    "cmp -s $SHIELD_EF_BIN $SHIELD_EF_SRC && [ \"\$(cat $F/handle)\" = 8 ] && grep -q 'прежний режим (отброс) не вернулся' $OUT/last.out && [ -s $SHIELD_STATE_DIR/earlyfilter.upgrade ]"
fresh; old; run shield_earlyfilter_ensure
t "другая версия, фильтра нет: файл просто заменяется, первое включение — через наблюдение (без reload)" \
    "[ \"\$(ev)\" = 'persist files|guard observe|units on|timer on' ] && cmp -s $SHIELD_EF_BIN $SHIELD_EF_SRC"
fresh enforce; old; touch "$F/active.spofy-guard-upg-rollback.timer"; run shield_earlyfilter_ensure
t "другая версия, идёт обновление руками с автовозвратом (spofy-guard-upg-rollback.timer): стек не трогает ни файл, ни правила" \
    "[ -z \"\$(ev)\" ] && cmp -s $SHIELD_EF_BIN $OUT/old.script && [ \"\$(cat $F/handle)\" = 7 ]"
conf "SSH_PORT=22" "ENABLE_EARLY_FILTER=0"; fresh enforce; old; run shield_earlyfilter_ensure
t "другая версия, ENABLE_EARLY_FILTER=0 и фильтр мимо стека: файл не трогается" "[ -z \"\$(ev)\" ] && cmp -s $SHIELD_EF_BIN $OUT/old.script"
conf "SSH_PORT=22"; fresh enforce; old; DRY_RUN=1 run shield_earlyfilter_ensure
t "другая версия, --dry-run: только строка «replace + reload», ничего не меняется" \
    "[ -z \"\$(ev)\" ] && cmp -s $SHIELD_EF_BIN $OUT/old.script && grep -q 'script differs: replace + reload in the same mode' $OUT/last.out"

# ================= старый фильтр UDP (spofy-udp-guard) =================
# v1 <таблица: 0|1> <таймер активен: 0|1> — заглушка старого фильтра: его скрипт, юнит, таблица, таймер
v1() {
    printf '#!/bin/bash\necho "v1 $*" >> "%s"\n[ "$1" = remove ] && rm -f "%s/v1"\nexit 0\n' "$EV" "$F" > "$SHIELD_EF_V1_BIN"; chmod +x "$SHIELD_EF_V1_BIN"
    : > "$OUT/units/spofy-udp-guard.timer"
    if [ "$1" = 1 ]; then touch "$F/v1"; fi
    if [ "$2" = 1 ]; then touch "$F/active.spofy-udp-guard.timer"; fi
}
fresh; v1 1 1; run shield_earlyfilter_ensure
t "старый фильтр UDP: пока новый в наблюдении — не трогается" "! grep -q '^v1 ' $EV && [ -e $F/v1 ] && [ ! -e $SHIELD_STATE_DIR/earlyfilter.v1 ]"
: > "$EV"; counters 519000 904 600; measured 100 60; run shield_earlyfilter_tick
t "старый фильтр UDP: наблюдение не чисто, отброс не включён — не трогается" "! grep -q '^v1 ' $EV && [ -e $F/v1 ]"
: > "$EV"; counters 519000 904 5; measured 200 60; run shield_earlyfilter_tick
t "старый фильтр UDP: отброс включился — снят (его remove, таблица, юниты), отмечено для rollback" \
    "[ \"\$(ev)\" = 'guard sysctl on|guard enforce|timer off|v1 remove' ] && [ ! -e $F/v1 ] && [ -e $SHIELD_STATE_DIR/earlyfilter.v1 ] && grep -qx 'disable --now spofy-udp-guard.timer spofy-udp-guard.service' $F/systemctl.log"
fresh enforce; v1 1 1; run shield_earlyfilter_ensure
t "старый фильтр UDP: отброс уже включён (усыновление) — снят" "grep -q '^v1 remove' $EV && [ ! -e $F/v1 ] && [ -e $SHIELD_STATE_DIR/earlyfilter.v1 ]"
fresh enforce; v1 0 1; run shield_earlyfilter_ensure
t "старый фильтр UDP: таблицы нет, но таймер активен (вернул бы её) — снят" "grep -q '^v1 remove' $EV && grep -q 'disable --now spofy-udp-guard.timer' $F/systemctl.log"
fresh enforce; v1 0 0; run shield_earlyfilter_ensure
t "старого фильтра нет (файлы остались, не работает): ничего не делается и не отмечается" \
    "! grep -q '^v1 ' $EV && ! grep -q 'disable --now spofy-udp-guard' $F/systemctl.log && [ ! -e $SHIELD_STATE_DIR/earlyfilter.v1 ]"
fresh enforce; rm -f "$SHIELD_EF_V1_BIN"; touch "$F/v1"; run shield_earlyfilter_ensure
t "старый фильтр UDP без своего скрипта: таблица снимается самим стеком" "[ ! -e $F/v1 ] && grep -q 'delete table netdev spofy_udp' $F/nft.log"
conf "SSH_PORT=22" "EARLY_FILTER_MODE=observe"; fresh; v1 1 1; run shield_earlyfilter_ensure
t "старый фильтр UDP: EARLY_FILTER_MODE=observe — не трогается" "! grep -q '^v1 ' $EV && [ -e $F/v1 ]"
conf "SSH_PORT=22"; fresh enforce; managed; v1 1 1; run shield_earlyfilter_ensure
conf "SSH_PORT=22" "EARLY_FILTER_MODE=observe"; : > "$F/systemctl.log"; run shield_earlyfilter_ensure
t "старый фильтр UDP: отброс переведён в наблюдение (EARLY_FILTER_MODE=observe) — снятый стеком включается обратно" \
    "[ \"\$(cat $F/mode)\" = accept ] && grep -qx 'enable --now spofy-udp-guard.timer' $F/systemctl.log && [ ! -e $SHIELD_STATE_DIR/earlyfilter.v1 ] && grep -q 'включён обратно' $OUT/last.out"
fresh enforce; managed; v1 0 0; : > "$F/systemctl.log"; run shield_earlyfilter_ensure
t "старый фильтр UDP: перевод в наблюдение, а стек его не снимал — не включается" \
    "[ \"\$(cat $F/mode)\" = accept ] && ! grep -q 'spofy-udp-guard' $F/systemctl.log"
conf "SSH_PORT=22"
fresh enforce; managed; v1 1 1; run shield_earlyfilter_ensure; : > "$F/systemctl.log"; run shield_earlyfilter_remove rollback
t "rollback: старый фильтр UDP, снятый стеком, включается обратно; отметка убрана" \
    "grep -qx 'enable --now spofy-udp-guard.timer' $F/systemctl.log && [ ! -e $SHIELD_STATE_DIR/earlyfilter.v1 ] && grep -q 'включён обратно' $OUT/last.out"
fresh enforce; managed; v1 1 1; run shield_earlyfilter_ensure; rm -f "$SHIELD_EF_V1_BIN"; : > "$F/systemctl.log"; run shield_earlyfilter_remove rollback
t "rollback: файлов старого фильтра уже нет — не включается" "! grep -q 'spofy-udp-guard' $F/systemctl.log && [ ! -e $SHIELD_STATE_DIR/earlyfilter.v1 ]"
fresh enforce; managed; v1 0 0; run shield_earlyfilter_ensure; : > "$F/systemctl.log"; run shield_earlyfilter_remove rollback
t "rollback: старый фильтр стек не снимал — не включается" "! grep -q 'spofy-udp-guard' $F/systemctl.log"

# ================= persist.sh: настоящая запись файлов (под \$OUT) =================
unset SHIELD_EF_SRC   # дальше — настоящий встроенный скрипт
unset -f shield_persist_earlyfilter shield_persist_earlyfilter_enable shield_persist_earlyfilter_timer shield_persist_earlyfilter_timer_remove shield_persist_earlyfilter_remove
# shellcheck source=../persist.sh
source "$SHIELD_DIR/persist.sh"
pfresh() { rm -rf "$SHIELD_STATE_DIR" "$OUT/units" "$OUT/sbin" "$F"; mkdir -p "$SHIELD_STATE_DIR" "$OUT/units" "$OUT/sbin" "$F"; }
pfresh; run shield_persist_earlyfilter
t "persist: скрипт установлен как есть (0755), юниты записаны" \
    "cmp -s $SHIELD_EF_BIN $G && [ \"\$(stat -c %a $SHIELD_EF_BIN)\" = 755 ] && [ -f $OUT/units/spofy-guard.service ] && [ -f $OUT/units/spofy-guard.timer ]"
t "persist: юнит зовёт /usr/local/sbin/spofy-guard ensure, таймер — раз в минуту" \
    "grep -qx 'ExecStart=/usr/local/sbin/spofy-guard ensure' $OUT/units/spofy-guard.service && grep -qx 'OnUnitActiveSec=1min' $OUT/units/spofy-guard.timer"
t "persist: запись файлов сама ничего не включает" "! grep -qE '^(enable|start|restart)' $F/systemctl.log"
t "persist: файл числится за стеком" "shield_earlyfilter_managed"
run shield_persist_earlyfilter
t "persist: повтор — все три файла «без изменений», копий .pre-shieldnode нет" \
    "[ \"\$(grep -c '(без изменений)' $OUT/last.out)\" = 3 ] && [ -z \"\$(ls $OUT/sbin/*.pre-shieldnode-* $OUT/units/*.pre-shieldnode-* 2>/dev/null)\" ]"
# установка руками: те же три файла уже лежат — стек их не переписывает и берёт под управление
pfresh; cp "$G" "$SHIELD_EF_BIN"; chmod 755 "$SHIELD_EF_BIN"
printf '[Unit]\nDescription=Spofy guard: early filter at the node'"'"'s network entry\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/spofy-guard ensure\nTimeoutStartSec=180\n[Install]\nWantedBy=multi-user.target\n' > "$OUT/units/spofy-guard.service"
printf '[Unit]\nDescription=Spofy guard: keep the table, add new listening ports, save memory to disk\n[Timer]\nOnBootSec=20s\nOnUnitActiveSec=1min\n[Install]\nWantedBy=timers.target\n' > "$OUT/units/spofy-guard.timer"
touch -d '2026-11-13 12:00' "$SHIELD_EF_BIN" "$OUT/units/spofy-guard.service" "$OUT/units/spofy-guard.timer"
run shield_persist_earlyfilter
t "усыновление: файлы, поставленные руками, совпали — не переписаны (время изменения то же)" \
    "[ \"\$(grep -c '(без изменений)' $OUT/last.out)\" = 3 ] && [ \"\$(stat -c %Y $SHIELD_EF_BIN)\" = \"\$(date -d '2026-11-13 12:00' +%s)\" ] && [ \"\$(stat -c %Y $OUT/units/spofy-guard.timer)\" = \"\$(date -d '2026-11-13 12:00' +%s)\" ]"
t "усыновление: файл теперь числится за стеком" "shield_earlyfilter_managed"
: > "$F/systemctl.log"; run shield_persist_earlyfilter_enable
t "включение юнитов: enable службы и enable --now таймера, без restart" \
    "grep -qx 'enable spofy-guard.service' $F/systemctl.log && grep -qx 'enable --now spofy-guard.timer' $F/systemctl.log && ! grep -q restart $F/systemctl.log"
: > "$F/systemctl.log"; run shield_persist_earlyfilter_remove
t "снятие: юниты выключены, три файла убраны, из манифеста и реестра происхождения забыты" \
    "grep -qx 'disable --now spofy-guard.timer' $F/systemctl.log && [ ! -e $SHIELD_EF_BIN ] && [ ! -e $OUT/units/spofy-guard.service ] && [ ! -e $OUT/units/spofy-guard.timer ] && ! shield_earlyfilter_managed && ! grep -q spofy-guard $SHIELD_STATE_DIR/file-origins.tsv && [ -z \"\$(ls $SHIELD_STATE_DIR/origins 2>/dev/null)\" ]"
pfresh; run shield_persist_earlyfilter_timer
t "свой таймер стека: служба зовёт main.sh early-filter tick, таймер включён и перезапущен" \
    "grep -qx \"ExecStart=/bin/bash $SHIELD_DIR/main.sh early-filter tick\" $OUT/units/shieldnode-earlyfilter.service && grep -qx 'restart shieldnode-earlyfilter.timer' $F/systemctl.log"
run shield_persist_earlyfilter_timer_remove
t "свой таймер стека: снятие выключает и убирает оба файла" \
    "grep -qx 'disable --now shieldnode-earlyfilter.timer' $F/systemctl.log && [ -z \"\$(ls $OUT/units 2>/dev/null)\" ]"
pfresh; conf "PERSIST_ENABLED=0"; run shield_persist_earlyfilter; run shield_persist_earlyfilter_timer
t "PERSIST_ENABLED=0: только скрипт, юнитов нет" "[ -f $SHIELD_EF_BIN ] && [ -z \"\$(ls $OUT/units 2>/dev/null)\" ]"
conf "SSH_PORT=22"; pfresh; DRY_RUN=1 run shield_persist_earlyfilter
t "--dry-run: файлы не пишутся" "[ ! -e $SHIELD_EF_BIN ] && [ -z \"\$(ls $OUT/units 2>/dev/null)\" ]"
t "uninstall: свои юниты таймера в списке удаляемых" "grep -q 'shieldnode-earlyfilter\.service' $SHIELD_DIR/uninstall.sh && grep -q 'shieldnode-earlyfilter\.timer' $SHIELD_DIR/uninstall.sh"
rm -f "${CONFIG_CACHE:-}"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: earlyfilter (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
