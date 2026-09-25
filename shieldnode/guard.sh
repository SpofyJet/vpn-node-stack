#!/bin/bash
# shieldnode — guard.sh: пульт `guard` — понятный дашборд защиты + меню действий.
# 2026-09-25 (v1.1.7): переписан по-русски и «по смыслу»: вместо 28 технических счётчиков
# (c_drops_*) — группы атак, текущие баны, блок-листы с человеческими именами, только
# проблемные службы/проверки. В терминале под дашбордом — меню действий (кто в бане,
# разбанить, доверенные IP, обновить блок-листы, полная проверка, аварийный режим).
#   guard           дашборд + меню (в терминале); без терминала — только снимок
#   guard --once    только снимок (cron/мониторинг)
#   guard --raw     технические счётчики nft (для отладки)
# Дашборд read-only; единственная запись — снапшот счётчиков в state (для «+N с прошлого
# просмотра»). Действия меню требуют root и меняют только то, что названо в пункте.
set -euo pipefail

SHIELD_GUARD_SNAPSHOT="${SHIELD_GUARD_SNAPSHOT:-$SHIELD_STATE_DIR/guard-snapshot.tsv}"

# --- совместимость: счётчики/наборы (парсинг `nft list counters` — в common.sh) ---
guard_counters() { nft_counters; }
guard_set_elems() { nft_set_elem_count "$1"; }

# --- источники проблем: health и verify (отдельные функции — тест подменяет их) ---
_g_health() { ( source "$SHIELD_DIR/ssh.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"; source "$SHIELD_DIR/status.sh"; shield_health ) 2>/dev/null || true; }
_g_verify() { ( source "$SHIELD_DIR/lib/ports.sh"; shield_verify ) 2>/dev/null || true; }

# --- оформление: цвета только в терминале, без NO_COLOR ---
_g_colors() {
    G_0="" G_B="" G_D="" G_G="" G_Y="" G_R="" G_C=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
        G_0=$'\033[0m' G_B=$'\033[1m' G_D=$'\033[2m' G_G=$'\033[32m' G_Y=$'\033[33m' G_R=$'\033[31m' G_C=$'\033[36m'
    fi
}
# 1234567 -> «1 234 567»
_g_num() { awk -v n="${1:-0}" 'BEGIN { s = sprintf("%d", n); o = ""; while (length(s) > 3) { o = " " substr(s, length(s) - 2) o; s = substr(s, 1, length(s) - 3) }; print s o }'; }
# секунды -> «7ч 23м» / «4м» / «2д 5ч»
_g_dur() {
    local s="${1:-0}"
    if   [ "$s" -ge 86400 ]; then printf '%dд %dч' $((s / 86400)) $((s % 86400 / 3600))
    elif [ "$s" -ge 3600 ];  then printf '%dч %dм' $((s / 3600)) $((s % 3600 / 60))
    elif [ "$s" -ge 60 ];    then printf '%dм' $((s / 60))
    else printf '%dс' "$s"; fi
}
# строка «метка ......... значение» с выравниванием по символам (кириллица = 2 байта)
_g_row() { # <отступ-символ ├/└> <метка (без escape-кодов)> <всего> <дельта> [bold]
    local pad=$((34 - ${#2})) b="" e=""; [ "$pad" -lt 1 ] && pad=1
    [ -n "${5:-}" ] && { b="$G_B"; e="$G_0"; }
    printf '  %s─ %s%s%s%*s%s%12s%s  %s\n' "$1" "$b" "$2" "$e" "$pad" "" "$b" "$3" "$e" "$4"
}

# --- группы счётчиков: метка|регулярка по имени счётчика ---
GUARD_GROUPS="Сканеры интернета|^c_drops_scanner
Известные вредоносные сети|^c_drops_(threat|spamhaus|cins)
CrowdSec (сообщество)|^c_drops_crowdsec
Ваш список (custom)|^c_drops_custom
Выходы Tor|^c_drops_tor
Подбор паролей SSH|^c_drops_ssh_abusers
Флуд соединениями TCP/SYN|^c_drops_(tcp_abusers|syn|global_tcp)
UDP-флуд|^c_drops_(udp_abusers|global_udp)
Временные баны|^c_drops_temp
Отражённые атаки (DNS/NTP)|^c_drops_amp
ICMP-флуд (ping)|^c_drops_icmp
Мусорные и поддельные пакеты|^c_drops_(invalid|antispoof)"

# --- сбор данных ---
_g_collect() {
    G_FW="ABSENT"
    if nft list table inet shieldnode >/dev/null 2>&1; then
        G_FW="ACTIVE"; [ -f /run/shieldnode/emergency ] && G_FW="EMERGENCY"
    fi
    G_COUNTERS="$(guard_counters 2>/dev/null || true)"
    G_NOW="$(date +%s)"
    # в меню база «+N» фиксируется на весь сеанс просмотра (иначе обнулялась бы при каждом обновлении)
    [ "${G_KEEP_PREV:-0}" = 1 ] && return 0
    G_PREV_TS=0; G_PREV=""
    if [ -f "$SHIELD_GUARD_SNAPSHOT" ]; then
        G_PREV_TS="$(head -1 "$SHIELD_GUARD_SNAPSHOT" 2>/dev/null || echo 0)"
        [[ "$G_PREV_TS" =~ ^[0-9]+$ ]] || G_PREV_TS=0
        G_PREV="$(tail -n +2 "$SHIELD_GUARD_SNAPSHOT" 2>/dev/null || true)"
    fi
}
_g_save_snapshot() { # только при живом фаерволе и непустых счётчиках
    [ "$G_FW" != "ABSENT" ] && [ -n "$G_COUNTERS" ] || return 0
    local gt; gt="$(mktemp "$SHIELD_GUARD_SNAPSHOT.XXXXXX" 2>/dev/null)" || return 0
    if { echo "$G_NOW"; printf '%s\n' "$G_COUNTERS"; } > "$gt" 2>/dev/null; then
        mv "$gt" "$SHIELD_GUARD_SNAPSHOT" 2>/dev/null || rm -f "$gt"
    else rm -f "$gt"; fi
}
_g_sum() { # <regex> <текст счётчиков> -> сумма packets
    awk -v re="$1" '$1 ~ re { s += $2 } END { printf "%d", s }' <<<"$2"
}
_g_set() { local n; n="$(guard_set_elems "$1" 2>/dev/null || echo 0)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; }
_g_set2() { echo $(( $(_g_set "$1") + $(_g_set "$2") )); }

# --- дашборд ---
_g_draw() {
    local host up ip
    host="$(hostname 2>/dev/null || echo '?')"
    ip="$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    up="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"
    # рамка по ширине заголовка — в символах (printf %-Ns считает байты кириллицы и «·»)
    local title="GUARD · защита ноды ${host:0:40}" bar
    bar="$(printf '─%.0s' $(seq 1 $((${#title} + 2))))"
    printf '%s╭%s╮%s\n' "$G_C" "$bar" "$G_0"
    printf '%s│%s %s%s%s %s│%s\n' "$G_C" "$G_0" "$G_B" "$title" "$G_0" "$G_C" "$G_0"
    printf '%s╰%s╯%s\n' "$G_C" "$bar" "$G_0"
    # 2026-09-25 (v1.1.8): без внутренних имён компонентов — только то, что важно оператору
    printf '  %s%s · сервер работает %s%s\n\n' "$G_D" "${ip:-?}" "$(_g_dur "$up")" "$G_0"

    # 1) состояние
    case "$G_FW" in
        ACTIVE)    printf '  Фаервол     %s● работает%s\n' "$G_G" "$G_0" ;;
        EMERGENCY) printf '  Фаервол     %s● АВАРИЙНЫЙ РЕЖИМ%s — пропускаются только SSH и белый список\n' "$G_R" "$G_0"
                   printf '              %sвыключить: пункт 6 ниже или sudo vpn-node emergency off%s\n' "$G_D" "$G_0" ;;
        *)         printf '  Фаервол     %s○ не применён%s — нода без защиты: sudo vpn-node (Установить)\n' "$G_R" "$G_0" ;;
    esac
    if [ "$G_FW" != "ABSENT" ]; then
        local pt pu
        pt="$(nft -n list set inet shieldnode protected_tcp 2>/dev/null | awk '/elements = \{/ {f = 1; sub(/.*elements = \{/, "")} f { l = $0; e = sub(/\}.*/, "", l); print l; if (e) f = 0 }' | tr ',\t\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' || true)"
        pu="$(nft -n list set inet shieldnode protected_udp 2>/dev/null | awk '/elements = \{/ {f = 1; sub(/.*elements = \{/, "")} f { l = $0; e = sub(/\}.*/, "", l); print l; if (e) f = 0 }' | tr ',\t\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' || true)"
        printf '  Под защитой %sTCP %s%s   %sUDP %s%s\n' "$G_B" "${pt:-—}" "$G_0" "$G_B" "${pu:-—}" "$G_0"
    fi
    echo

    # 2) отбито атак
    if [ "$G_FW" = "ABSENT" ]; then
        echo "  (счётчиков нет — фаервол не применён)"
        echo
    else
        local dt=0 dlabel="" label re cur prev d total=0 dtotal=0 shown=0 lines=""
        if [ "$G_PREV_TS" -gt 0 ] && [ "$G_NOW" -gt "$G_PREV_TS" ]; then dt=$((G_NOW - G_PREV_TS)); dlabel="за $(_g_dur "$dt")"; fi
        printf '  %sОтбито пакетов%s %s(с загрузки правил%s)%s\n' "$G_B" "$G_0" "$G_D" "${dlabel:+; +N — $dlabel}" "$G_0"
        if [ -z "$G_COUNTERS" ]; then
            echo "  └─ пока ничего — атак не было (это нормально)"
        else
            while IFS='|' read -r label re; do
                [ -n "$label" ] || continue
                cur="$(_g_sum "$re" "$G_COUNTERS")"
                d=""
                if [ "$dt" -gt 0 ]; then prev="$(_g_sum "$re" "$G_PREV")"; d=$((cur - prev)); [ "$d" -lt 0 ] && d="$cur"; dtotal=$((dtotal + d)); fi
                total=$((total + cur))
                # нулевые группы без изменений не показываем (кроме ключевых)
                if [ "$cur" -eq 0 ]; then case "$label" in Сканеры*|Подбор*|Флуд*|UDP*) : ;; *) continue ;; esac; fi
                if [ -n "$d" ] && [ "$d" -gt 0 ]; then d="${G_Y}+$(_g_num "$d")${G_0}"; elif [ -n "$d" ]; then d="${G_D}+0${G_0}"; fi
                lines="${lines}${label}|$(_g_num "$cur")|${d}"$'\n'
                shown=$((shown + 1))
            done <<<"$GUARD_GROUPS"
            while IFS='|' read -r label cur d; do
                [ -n "$label" ] && _g_row "├" "$label" "$cur" "$d"
            done <<<"$lines"
            local dt_s=""; [ "$dt" -gt 0 ] && dt_s="${G_Y}+$(_g_num "$dtotal")${G_0}"
            _g_row "└" "Итого" "$(_g_num "$total")" "$dt_s" bold
        fi
        echo

        # 3) сейчас в бане (временно, авто-снимается)
        local b_ssh b_tcp b_udp b_tmp
        b_ssh="$(_g_set2 ssh_abusers ssh_abusers_v6)"; b_tcp="$(_g_set2 tcp_abusers tcp_abusers_v6)"
        b_udp="$(_g_set2 udp_abusers udp_abusers_v6)"; b_tmp="$(_g_set2 temporary_blocklist temporary_blocklist_v6)"
        printf '  %sСейчас в бане%s %s(снимается сам по таймауту)%s\n' "$G_B" "$G_0" "$G_D" "$G_0"
        printf '  └─ SSH %s · TCP %s · UDP %s · временно %s\n\n' "$(_g_num "$b_ssh")" "$(_g_num "$b_tcp")" "$(_g_num "$b_udp")" "$(_g_num "$b_tmp")"

        # 4) блок-листы
        local part="" name st n
        for name in "Сканеры:scanner_blocklist" "Угрозы:threat_blocklist" "CINS:cins_blocklist" \
                    "Spamhaus:spamhaus_blocklist" "CrowdSec:crowdsec_blocklist" "Tor:tor_exit_blocklist" "Свой:custom_blocklist"; do
            st="${name#*:}"
            nft list set inet shieldnode "${st}_v4" >/dev/null 2>&1 || continue
            n=$(( $(_g_set "${st}_v4") + $(_g_set "${st}_v6") ))
            part="${part:+$part · }${name%%:*} $(_g_num "$n")"
        done
        printf '  %sБлок-листы%s %s(адресов и сетей в базе)%s\n' "$G_B" "$G_0" "$G_D" "$G_0"
        printf '  ├─ %s\n' "${part:-—}"
        local lg next ago nxt
        lg="$(ls -1t "$SHIELD_STATE_DIR"/blocklists/last-good-*.txt 2>/dev/null | head -1 || true)"
        ago="нет данных"; [ -n "$lg" ] && ago="$(_g_dur $(( G_NOW - $(stat -c %Y "$lg" 2>/dev/null || echo "$G_NOW") ))) назад"
        # у таймеров OnUnitActiveSec (монотонных) NextElapseUSecRealtime пуст — берём из list-timers
        next="$(systemctl list-timers --all --no-legend shieldnode-blocklist.timer 2>/dev/null | awk 'NF >= 4 && $1 != "-" {print $1, $2, $3, $4; exit}' || true)"
        nxt=""; [ -n "$next" ] && nxt="$(date -d "$next" +%s 2>/dev/null || true)"
        if [[ "$nxt" =~ ^[0-9]+$ ]] && [ "$nxt" -gt "$G_NOW" ]; then nxt="следующее через $(_g_dur $((nxt - G_NOW)))"; else nxt=""; fi
        printf '  └─ обновлены %s%s\n\n' "$ago" "${nxt:+, $nxt}"
    fi

    # 5) проблемы — 2026-09-25 (v1.2.0, E5): ЕДИНЫЙ источник — health (+ verify). Раньше guard
    # проверял своё подмножество и писал «Проблем не найдено» при health WARN=12.
    local probs="" f G_HEALTH="" admin_ip
    if [ "$G_FW" != "ABSENT" ]; then
        G_HEALTH="$(_g_health)"
        probs="$(sed -n 's/^  \[\(FAIL\|WARN\)\] \(.*\)$/\1: \2/p' <<<"$G_HEALTH" | sed 's/^FAIL: /✘ /; s/^WARN: //')"
        if [ -z "$(sed -n 's/^  health: \(FAIL=[0-9]* WARN=[0-9]*\).*/\1/p' <<<"$G_HEALTH")" ]; then
            probs="${probs:+$probs$'\n'}полная проверка не выполнилась — запусти: sudo vpn-node → «Полная проверка»"
        fi
        if [ "$G_FW" = ACTIVE ]; then
            local vout; vout="$(_g_verify)"
            while IFS= read -r f; do
                case "$f" in *✘*) probs="${probs:+$probs$'\n'}✘ ${f#*✘ }" ;; esac
            done <<<"$vout"
        fi
        admin_ip="$(shield_detect_admin_ip 2>/dev/null || true)"
        case "$admin_ip" in ''|*:*) ;; *) nft get element inet shieldnode whitelist_v4 "{ $admin_ip }" >/dev/null 2>&1 && G_ADMIN_OK="$admin_ip" ;; esac
    fi
    if [ -n "$probs" ]; then
        printf '  %s⚠ Требует внимания%s\n' "$G_Y" "$G_0"
        while IFS= read -r f; do [ -n "$f" ] && printf '  %s•%s %s\n' "$G_Y" "$G_0" "$f"; done <<<"$probs"
    elif [ "$G_FW" != "ABSENT" ]; then
        printf '  %s✔ Проблем не найдено%s%s\n' "$G_G" "$G_0" "${G_ADMIN_OK:+ · ваш IP ${G_ADMIN_OK} в белом списке}"
    fi
    printf '  %sv%s%s\n' "$G_D" "$SHIELD_VERSION" "$G_0"
    echo
}

# --- технический вид (прежний формат счётчиков, для отладки) ---
_g_raw() {
    echo "--- счётчики nft (пакеты / байты) ---"
    if [ -z "$G_COUNTERS" ]; then echo "  (нет)"; return 0; fi
    sort -k2,2nr <<<"$G_COUNTERS" | while read -r name packets bytes; do
        printf '  %-26s %12s пак.  %16s байт\n' "$name" "$packets" "$bytes"
    done
}

# --- действия меню ---
_g_need_root() { [ "$(id -u)" -eq 0 ] && return 0; printf '  %sНужен root: sudo guard%s\n' "$G_Y" "$G_0"; return 1; }
_g_pause() { printf '\n  %sEnter — назад%s' "$G_D" "$G_0"; IFS= read -r _ || true; }
_g_list_set() { # <set> <заголовок>
    local out
    out="$(nft -n list set inet shieldnode "$1" 2>/dev/null | awk '/elements = \{/ {f = 1; sub(/.*elements = \{/, "")} f { l = $0; e = sub(/\}.*/, "", l); print l; if (e) f = 0 }' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF' || true)"
    [ -n "$out" ] || return 0
    printf '  %s%s%s (%s)\n' "$G_B" "$2" "$G_0" "$(wc -l <<<"$out")"
    head -20 <<<"$out" | sed 's/ expires / — осталось /; s/ timeout [^ ]*//' | sed 's/^/    /'
    [ "$(wc -l <<<"$out")" -gt 20 ] && printf '    %s… и ещё %s%s\n' "$G_D" "$(( $(wc -l <<<"$out") - 20 ))" "$G_0"
    return 0
}
_g_act_bans() {
    echo; local any=0 s
    for s in "ssh_abusers:SSH (подбор паролей)" "ssh_abusers_v6:SSH IPv6" "tcp_abusers:TCP-флуд" "tcp_abusers_v6:TCP-флуд IPv6" \
             "udp_abusers:UDP-флуд" "udp_abusers_v6:UDP-флуд IPv6" "temporary_blocklist:Временные" "temporary_blocklist_v6:Временные IPv6"; do
        [ "$(_g_set "${s%%:*}")" -gt 0 ] && { _g_list_set "${s%%:*}" "${s#*:}"; any=1; }
    done
    [ "$any" = 1 ] || printf '  %sСейчас никто не в бане.%s\n' "$G_G" "$G_0"
    _g_pause
}
_g_act_unban() {
    _g_need_root || { _g_pause; return 0; }
    printf '\n  IP для разбана (Enter — отмена): '; local ip; IFS= read -r ip || return 0
    [ -n "$ip" ] || return 0
    shield_valid_ip "$ip" || { printf '  %s«%s» — не IP-адрес%s\n' "$G_Y" "$ip" "$G_0"; _g_pause; return 0; }
    local s n=0 sets="ssh_abusers tcp_abusers udp_abusers temporary_blocklist"
    case "$ip" in *:*) sets="ssh_abusers_v6 tcp_abusers_v6 udp_abusers_v6 temporary_blocklist_v6" ;; esac
    for s in $sets; do nft delete element inet shieldnode "$s" "{ $ip }" >/dev/null 2>&1 && n=$((n + 1)); done
    if [ "$n" -gt 0 ]; then printf '  %s✔ %s разбанен (наборов: %s)%s\n' "$G_G" "$ip" "$n" "$G_0"; log info "guard" "unban $ip ($n sets)"
    else printf '  %s не найден среди банов (блок-листы сканеров/угроз так не снимаются — для своего IP используй «Доверенные IP»)\n' "$ip"; fi
    _g_pause
}
_g_trusted_write() { # <новый список через пробел> — атомарно в config.conf, с backup
    local f="$SHIELD_CONFIG" tmp
    mkdir -p "$(dirname "$f")"; [ -f "$f" ] || { : > "$f"; chmod 0640 "$f"; }
    cp -p "$f" "$f.guard.bak" 2>/dev/null || true
    tmp="$(mktemp "$f.XXXXXX")"
    awk -v line="TRUSTED_IPS=\"$1\"" 'index($0, "TRUSTED_IPS=") == 1 { if (!d) { print line; d = 1 }; next } { print } END { if (!d) print line }' "$f" > "$tmp"
    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
    mv -f "$tmp" "$f"
}
_g_act_trusted() {
    local cur; cur="$(shield_conf_get TRUSTED_IPS "")"
    echo
    printf '  %sДоверенные IP%s — без лимитов и блок-листов (панель Remnawave, мониторинг, ваш офис)\n' "$G_B" "$G_0"
    printf '  сейчас: %s\n' "${cur:-нет}"
    [ -n "${G_ADMIN_OK:-}" ] || { local a; a="$(shield_detect_admin_ip 2>/dev/null || true)"; [ -n "$a" ] && printf '  %sваш текущий IP: %s%s\n' "$G_D" "$a" "$G_0"; }
    printf '\n  [a] добавить  [d] убрать  Enter — назад: '; local c; IFS= read -r c || return 0
    case "$c" in a|A|d|D) _g_need_root || { _g_pause; return 0; } ;; *) return 0 ;; esac
    printf '  IP или сеть (через пробел): '; local in p new="$cur" bad=""; IFS= read -r in || return 0
    for p in $in; do
        case "$c" in
            a|A) if shield_valid_cidr "$p"; then case " $new " in *" $p "*) ;; *) new="${new:+$new }$p" ;; esac; else bad="$bad $p"; fi ;;
            *)   new="$(for x in $new; do [ "$x" = "$p" ] || printf '%s ' "$x"; done | sed 's/ $//')" ;;
        esac
    done
    [ -n "$bad" ] && printf '  %sпропущено (не адрес или маска шире /8 для IPv4, /16 для IPv6):%s%s\n' "$G_Y" "$bad" "$G_0"
    [ "$new" = "$cur" ] && { _g_pause; return 0; }
    _g_trusted_write "$new"
    printf '  сохранено: TRUSTED_IPS="%s" — применяю фаервол…\n' "$new"
    if bash "$SHIELD_DIR/main.sh" apply >/dev/null 2>&1; then printf '  %s✔ применено%s\n' "$G_G" "$G_0"
    else printf '  %s✘ применение не удалось — прежние правила сохранены (подробности: sudo vpn-node → «Статус»)%s\n' "$G_R" "$G_0"; fi
    _g_pause
}
_g_act_update() {
    _g_need_root || { _g_pause; return 0; }
    printf '\n  Обновляю блок-листы (до минуты)…\n'
    if systemctl start shieldnode-blocklist.service 2>/dev/null; then printf '  %s✔ блок-листы обновлены%s\n' "$G_G" "$G_0"
    else printf '  %s✘ часть источников недоступна — старые списки продолжают работать%s\n' "$G_Y" "$G_0"; fi
    if [ -e "${SHIELD_UNIT_DIR:-/etc/systemd/system}/shieldnode-blocklist-crowdsec.service" ]; then
        systemctl start shieldnode-blocklist-crowdsec.service 2>/dev/null && printf '  %s✔ CrowdSec обновлён%s\n' "$G_G" "$G_0" || true
    fi
    _g_pause
}
_g_act_check() {
    echo
    ( source "$SHIELD_DIR/ssh.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"; source "$SHIELD_DIR/status.sh"; shield_health ) 2>/dev/null || true
    _g_pause
}
_g_act_emergency() {
    _g_need_root || { _g_pause; return 0; }
    echo
    if [ -f /run/shieldnode/emergency ]; then
        printf '  Выключить аварийный режим и вернуть обычную защиту? [Y/n] '; local a; IFS= read -r a || return 0
        case "$a" in n|N|н|Н) return 0 ;; esac
        bash "$SHIELD_DIR/main.sh" emergency off >/dev/null 2>&1 && printf '  %s✔ обычный режим%s\n' "$G_G" "$G_0" || printf '  %s✘ не удалось (журнал)%s\n' "$G_R" "$G_0"
    else
        printf '  Аварийный режим пропускает ТОЛЬКО SSH и белый список — VPN-клиенты отключатся.\n'
        printf '  Включать при атаке, которую не держат лимиты. Включить? [y/N] '; local a; IFS= read -r a || return 0
        case "$a" in y|Y|д|Д) ;; *) return 0 ;; esac
        bash "$SHIELD_DIR/main.sh" emergency on >/dev/null 2>&1 && printf '  %s✔ аварийный режим включён%s\n' "$G_R" "$G_0" || printf '  %s✘ не удалось (журнал)%s\n' "$G_R" "$G_0"
    fi
    _g_pause
}

shield_guard() {
    # ширина рамок/колонок — в символах: нужна UTF-8 локаль (под sudo бывает C/POSIX)
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*utf8*) : ;; *) export LC_ALL=C.UTF-8 ;; esac
    _g_colors
    # 2026-09-25 (v1.1.8): правила фаервола читаются только root'ом — без него nft «не видит»
    # таблицу, и пульт ложно писал «фаервол не применён — нода без защиты»
    if [ "$(id -u)" -ne 0 ] && [ "${SHIELD_GUARD_ALLOW_NONROOT:-0}" != 1 ]; then
        printf '%sПульт защиты читает правила фаервола — запусти с правами root:%s sudo guard\n' "$G_Y" "$G_0" >&2
        return 1
    fi
    local mode="${SHIELD_GUARD_MODE:-auto}"
    [ "$mode" = auto ] && { if [ -t 0 ] && [ -t 1 ]; then mode=menu; else mode=once; fi; }
    G_ADMIN_OK=""
    if [ "$mode" = raw ]; then _g_collect; _g_raw; return 0; fi
    if [ "$mode" != menu ]; then
        _g_collect; _g_draw; _g_save_snapshot; return 0
    fi
    local c
    G_KEEP_PREV=0
    while :; do
        _g_collect; G_KEEP_PREV=1
        printf '\033[H\033[2J'
        _g_draw
        _g_save_snapshot
        printf '  %sДействия%s\n' "$G_B" "$G_0"
        printf '   %s1%s  Кто сейчас в бане          %s4%s  Обновить блок-листы\n' "$G_B" "$G_0" "$G_B" "$G_0"
        printf '   %s2%s  Разбанить IP               %s5%s  Полная проверка\n' "$G_B" "$G_0" "$G_B" "$G_0"
        printf '   %s3%s  Доверенные IP              %s6%s  Аварийный режим\n' "$G_B" "$G_0" "$G_B" "$G_0"
        printf '   %sEnter%s — обновить экран    %s0%s — выход\n\n  > ' "$G_B" "$G_0" "$G_B" "$G_0"
        IFS= read -r c || { echo; return 0; }
        case "$c" in
            1) _g_act_bans ;;
            2) _g_act_unban ;;
            3) _g_act_trusted ;;
            4) _g_act_update ;;
            5) _g_act_check ;;
            6) _g_act_emergency ;;
            0|q|Q|й|Й) echo; return 0 ;;
            *) : ;;
        esac
    done
}
