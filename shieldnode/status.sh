#!/bin/bash
# shieldnode — status.sh: ожидаемое vs фактическое (read-only, ТЗ §27).
set -euo pipefail

# --- health: конфиг vs факт (v1.1.3, 2026-09-23) ---
# Раньше status только ПЕРЕЧИСЛЯЛ факты (цепочки, счётчики, счётчики сетов); теперь
# ещё и СВЕРЯЕТ их: accept (established/lo/whitelist) до первого drop, ENABLE_* <->
# сеты и drop-правила, SSH- и внешние xray-порты под защитой, PROTECTED_*_EXTRA в
# сетах, наполненность/свежесть/алерты блоклистов, таймер и boot-служба, emergency.
# Только чтение. Политика не меняется. Код возврата status — прежний.
# Таблица ниже ЗЕРКАЛИТ гейтинг lib/nft.sh (test-health сверяет её с генератором):
#   имя-в-updater : флаг : дефолт : v4-сет
SHIELD_HEALTH_LISTS="scanner:ENABLE_SCANNER_LIST:1:scanner_blocklist_v4
threat:ENABLE_THREAT_LIST:1:threat_blocklist_v4
tor:BLOCK_TOR:0:tor_exit_blocklist_v4
custom:ENABLE_CUSTOM_LIST:1:custom_blocklist_v4
crowdsec:ENABLE_CROWDSEC_LIST:1:crowdsec_blocklist_v4
spamhaus:ENABLE_SPAMHAUS_LIST:1:spamhaus_blocklist_v4
cins:ENABLE_CINS_LIST:1:cins_blocklist_v4"

_hc() { # <PASS|WARN|FAIL|INFO> <текст>
    case "$1" in PASS) _H_PASS=$((_H_PASS + 1)) ;; WARN) _H_WARN=$((_H_WARN + 1)) ;; FAIL) _H_FAIL=$((_H_FAIL + 1)) ;; esac
    printf '  [%s] %s\n' "$1" "$2"
}
_h_sum() { echo "  health: FAIL=$_H_FAIL WARN=$_H_WARN PASS=$_H_PASS"; echo; }
# порт внутри списка элементов set'а (учитывает интервалы a-b: flags interval + auto-merge)
_h_port_in() {
    local p="$1" e
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    for e in $2; do
        case "$e" in
            *-*) [[ "${e%-*}" =~ ^[0-9]+$ && "${e#*-}" =~ ^[0-9]+$ ]] && [ "$p" -ge "${e%-*}" ] && [ "$p" -le "${e#*-}" ] && return 0 ;;
            *)   [ "$p" = "$e" ] && return 0 ;;
        esac
    done
    return 1
}
_h_set_elems() { # <set> -> элементы через пробел (многострочный вывод nft)
    nft -n list set inet shieldnode "$1" 2>/dev/null | awk '/elements = \{/ {f = 1; sub(/.*elements = \{/, "")}
        f { l = $0; e = sub(/\}.*/, "", l); print l; if (e) f = 0 }' | tr ',\t\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' || true
}

shield_health() {
    _H_PASS=0; _H_WARN=0; _H_FAIL=0
    echo "--- health (конфиг vs факт, read-only) ---"
    if ! command -v nft >/dev/null 2>&1; then _hc WARN "nft не найден — проверки фаервола пропущены"; _h_sum; return 0; fi
    if ! nft list table inet shieldnode >/dev/null 2>&1; then
        if [ "$(id -u)" -ne 0 ]; then _hc WARN "таблица не читается без root (нужен CAP_NET_ADMIN) — запусти status через sudo"
        else _hc FAIL "table inet shieldnode ОТСУТСТВУЕТ — фаервол не активен (apply или emergency on)"; fi
        _h_sum; return 0
    fi
    _hc PASS "table inet shieldnode присутствует"
    if [ -f /run/shieldnode/emergency ]; then
        _hc WARN "EMERGENCY ON с $(head -1 /run/shieldnode/emergency 2>/dev/null) — активен только аварийный путь; проверки нормальной политики пропущены (выход: emergency off)"
        _h_sum; return 0
    fi
    local pre ch n
    # 2026-09-23 (v1.1.4): без -n — nft 1.0.9 с -n печатает и ct state числами
    # (0x2,0x4), символьные шаблоны ниже не совпадали: ложные FAIL на живой ноде.
    # Порты и адреса числовые и без -n (имена сервисов — только с -S, DNS — с -N).
    pre="$(nft list chain inet shieldnode prerouting 2>/dev/null || true)"
    for ch in prerouting input; do
        if nft list chain inet shieldnode "$ch" >/dev/null 2>&1; then _hc PASS "chain $ch есть"; else _hc FAIL "chain $ch отсутствует"; fi
    done
    n="$(awk '/ drop( |$)/ {c++} END {print c + 0}' <<<"$pre")"
    if [ "$n" -gt 0 ]; then _hc PASS "prerouting: $n drop-правил"; else _hc FAIL "prerouting без drop-правил — политика пуста"; fi

    # порядок: accept'ы до первого drop
    local d est lo wl
    # 2026-09-25 (v1.2.0): IPv6 fail-safe и ограничение API ноды стоят ДО established/whitelist
    # намеренно — в «первый drop» не считаются
    d="$(awk '!f && / drop( |$)/ && !/c_drops_ipv6_failsafe|c_drops_nodeapi/ {print NR; f = 1}' <<<"$pre")"; d="${d:-999999}"
    est="$(awk '!f && /ct state established,related accept/ {print NR; f = 1}' <<<"$pre")"
    lo="$(awk '!f && /iifname "lo" accept/ {print NR; f = 1}' <<<"$pre")"
    wl="$(awk '!f && /@whitelist_v4 accept/ {print NR; f = 1}' <<<"$pre")"
    if [ "$(shield_conf_get ENABLE_ESTABLISHED 1)" = "1" ]; then
        if [ -n "$est" ] && [ "$est" -lt "$d" ]; then _hc PASS "established/related accept — до первого drop"; else _hc FAIL "established/related accept отсутствует или ПОСЛЕ drop — рвутся уже установленные сессии"; fi
    fi
    if [ "$(shield_conf_get ENABLE_LOOPBACK 1)" = "1" ]; then
        if [ -n "$lo" ] && [ "$lo" -lt "$d" ]; then _hc PASS "loopback accept — до первого drop"; else _hc FAIL "loopback accept отсутствует или ПОСЛЕ drop"; fi
    fi
    if [ -n "$wl" ] && [ "$wl" -lt "$d" ]; then _hc PASS "whitelist accept — до первого drop"; else _hc FAIL "whitelist accept отсутствует или ПОСЛЕ drop — TRUSTED_IPS/админ могут попасть под бан"; fi

    # 2026-09-25 (v1.2.0): IPv6 fail-safe (IPv6 на ноде выключен обязательно) и API ноды
    if grep -q 'meta nfproto ipv6 .*c_drops_ipv6_failsafe.* drop' <<<"$pre"; then _hc PASS "IPv6 fail-safe: любой IPv6-пакет отбрасывается"
    else _hc FAIL "нет IPv6 fail-safe в prerouting — повтори применение фаервола"; fi
    # 2026-09-25 (v1.2.0, P1-4): сам IPv6 на хосте — выключен в ядре или на каждом интерфейсе
    local p6="${SHIELD_PROC:-/proc}" v6on="" g6=""
    if grep -qw 'ipv6.disable=1' "$p6/cmdline" 2>/dev/null || [ ! -d "$p6/sys/net/ipv6" ]; then
        _hc PASS "IPv6 выключен в ядре (ipv6.disable=1)"
    else
        local fi6
        for fi6 in "$p6"/sys/net/ipv6/conf/*/disable_ipv6; do
            [ -f "$fi6" ] || continue
            [ "$(cat "$fi6" 2>/dev/null)" = 1 ] || { fi6="${fi6%/disable_ipv6}"; v6on="$v6on ${fi6##*/}"; }
        done
        g6="$(awk '$4 == "00" && $6 != "lo" {print $6}' "$p6/net/if_inet6" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
        if [ -n "$g6" ]; then _hc FAIL "на интерфейсах есть глобальный IPv6-адрес ($g6) — IPv6 должен быть выключен: sudo vpn-node → «Применить оптимизацию» и reboot"
        elif [ -n "$v6on" ]; then _hc FAIL "IPv6 включён на:$v6on — sudo vpn-node → «Применить оптимизацию» (выключит сразу) и reboot"
        else _hc WARN "IPv6 выключен через sysctl, но ядро загружено без ipv6.disable=1 — перезагрузи сервер (sudo reboot)"; fi
    fi
    local apiport apiallow
    apiport="$(_h_set_elems node_api_port)"; apiallow="$(_h_set_elems node_api_allow_v4)"
    SH_IB_DONE=0; shield_detect_inbounds
    if [ -n "${SH_IB_API_PORT:-}" ]; then
        if [ -n "$apiport" ] && [ -n "$apiallow" ]; then _hc PASS "API ноды :$SH_IB_API_PORT — только с [$apiallow]"
        else _hc WARN "API ноды :$SH_IB_API_PORT открыт ВСЕМ — укажи IP панели: sudo vpn-node → Безопасность → Доверенные IP"; fi
    fi

    # SSH: реальные порты (SSH_PORT пуст = авто-детект) в защитных правилах
    local p sp
    if [ "$(shield_conf_get ENABLE_SSH_PROTECTION 1)" = "1" ]; then
        sp="$(shield_conf_get SSH_PORT "")"
        [ -n "$sp" ] || sp="$(shield_detect_ssh_ports 2>/dev/null || true)"
        [ -n "$sp" ] || _hc WARN "SSH-порты не определены (sshd не найден, SSH_PORT пуст)"
        for p in $sp; do
            if grep -q "tcp dport $p ct state new" <<<"$pre"; then _hc PASS "SSH $p: rate/conn-limit активны ($( [ -n "$(shield_conf_get SSH_PORT "")" ] && echo 'SSH_PORT' || echo 'авто-детект'))"
            else _hc FAIL "SSH $p: защитных правил нет (порт сменился после apply?) — повтори apply"; fi
            # 2026-09-25 (v1.2.0): бывшие проверки guard — теперь здесь (guard = health)
            if command -v ss >/dev/null 2>&1 && ! ss -Htln 2>/dev/null | awk -v p=":$p" '{ a = $4; if (substr(a, length(a) - length(p) + 1) == p) f = 1 } END { exit !f }'; then
                _hc WARN "SSH не слушает порт $p — проверь sshd, иначе потеряешь доступ"
            fi
        done
    fi
    local admin; admin="$(shield_detect_admin_ip 2>/dev/null || true)"
    case "$admin" in ''|*:*) ;;
        *) nft get element inet shieldnode whitelist_v4 "{ $admin }" >/dev/null 2>&1 \
               && _hc PASS "IP SSH-сессии $admin в белом списке" \
               || _hc WARN "IP SSH-сессии $admin не в белом списке — его могут задеть лимиты SSH (guard → «Доверенные IP» или повтори apply)" ;;
    esac
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local cc cm; cc="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"; cm="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
        [ "$cm" -gt 0 ] && [ $((cc * 100 / cm)) -ge 80 ] && _hc WARN "таблица соединений заполнена на $((cc * 100 / cm))% — при 100% новые клиенты не подключатся"
    fi
    if [ "$(shield_conf_get ENABLE_ABUSE_LIMITING 1)" = "1" ]; then
        if grep -q "tcp dport @protected_tcp" <<<"$pre" && grep -q "udp dport @protected_udp" <<<"$pre"; then _hc PASS "abuse-лимиты tcp/udp ссылаются на protected_tcp/protected_udp"
        else _hc FAIL "ENABLE_ABUSE_LIMITING=1, но правил по @protected_tcp/@protected_udp нет — повтори apply"; fi
    fi

    # защищаемые порты: факт в сетах, EXTRA, внешние порты xray/remnanode
    local pt pu lt lu bad=0
    pt="$(_h_set_elems protected_tcp)"; pu="$(_h_set_elems protected_udp)"
    _hc INFO "protected_tcp = { ${pt:-пусто} }  protected_udp = { ${pu:-пусто} }"
    for p in $(shield_conf_get PROTECTED_TCP_EXTRA ""); do
        if _h_port_in "$p" "$pt"; then _hc PASS "PROTECTED_TCP_EXTRA $p — в protected_tcp"; else _hc FAIL "PROTECTED_TCP_EXTRA $p — НЕТ в protected_tcp (повтори apply)"; fi
    done
    for p in $(shield_conf_get PROTECTED_UDP_EXTRA ""); do
        if _h_port_in "$p" "$pu"; then _hc PASS "PROTECTED_UDP_EXTRA $p — в protected_udp"; else _hc FAIL "PROTECTED_UDP_EXTRA $p — НЕТ в protected_udp (повтори apply)"; fi
    done
    # 2026-09-24 (v1.1.6): порты, открытые в UFW, тоже должны быть под abuse-лимитами
    local ut uu
    ut="$(shield_detect_ufw_ports tcp)"; uu="$(shield_detect_ufw_ports udp)"
    if [ -n "$ut$uu" ]; then
        local miss=""
        for p in $ut; do _h_port_in "$p" "$pt" || miss="$miss $p/tcp"; done
        for p in $uu; do _h_port_in "$p" "$pu" || miss="$miss $p/udp"; done
        if [ -n "$miss" ]; then _hc WARN "открыты в UFW, но НЕ в protected_*:$miss — повтори apply"
        else _hc PASS "все порты, открытые в UFW, под защитой (tcp: ${ut:--}; udp: ${uu:--})"; fi
    fi
    # 2026-09-25 (v1.2.0): реальные инбаунды — тем же детектором, что apply/ports-sync (конфиг
    # Xray через API). Эфемерные UDP-сокеты исходящих потоков — НЕ слушатели (DIAGNOSIS P0-1).
    SH_IB_DONE=0; shield_detect_inbounds
    lt="$SH_IB_TCP${SH_IB_API_PORT:+ $SH_IB_API_PORT}"; lu="$SH_IB_UDP"
    for p in $lt; do _h_port_in "$p" "$pt" || { _hc WARN "инбаунд $p/tcp не в protected_tcp — без abuse-лимитов (подхватится автоматически за ≤1 мин; иначе: sudo vpn-node → «Применить фаервол»)"; bad=1; }; done
    for p in $lu; do _h_port_in "$p" "$pu" || { _hc WARN "инбаунд $p/udp не в protected_udp — без abuse-лимитов (подхватится автоматически за ≤1 мин)"; bad=1; }; done
    case "$SH_IB_SOURCE" in
        none) _hc INFO "VPN-ядро сейчас ничего не слушает (remnanode не запущен или панель ещё не прислала конфиг) — защищены последние известные порты" ;;
        *)    [ "$bad" = 0 ] && _hc PASS "все инбаунды под защитой (источник: $([ "$SH_IB_SOURCE" = api ] && echo 'конфиг Xray' || echo 'эвристика'); tcp: ${lt:--}; udp: ${lu:--})" ;;
    esac

    # блоклисты: ENABLE_* <-> сет+drop-правило; наполненность; свежесть; алерты
    local bl_on st now name flag def set want has_set has_rule cnt lg age_h iv alert waiting
    bl_on="$(shield_conf_get ENABLE_BLOCKLISTS 1)"
    st="${SHIELD_BLOCKLIST_STATE:-/var/lib/shieldnode/blocklists}"; now="$(date +%s)"
    while IFS=: read -r name flag def set; do
        [ -n "$name" ] || continue
        want=0; has_set=0; has_rule=0
        [ "$bl_on" = "1" ] && [ "$(shield_conf_get "$flag" "$def")" = "1" ] && want=1
        nft -n list set inet shieldnode "$set" >/dev/null 2>&1 && has_set=1
        grep -qE "saddr @$set .*drop" <<<"$pre" && has_rule=1
        if [ "$want" = 0 ]; then
            if [ "$has_set" = 1 ] || [ "$has_rule" = 1 ]; then _hc WARN "$name: выключен ($flag/ENABLE_BLOCKLISTS), но set/правило ещё в фаерволе (half-present) — повтори apply"
            else _hc PASS "$name: выключен и отсутствует (консистентно)"; fi
            continue
        fi
        if [ "$has_set" = 0 ] || [ "$has_rule" = 0 ]; then _hc FAIL "$name: включён, но set/drop-правила нет — повтори apply"; continue; fi
        cnt="$(nft_set_elem_count "$set")"; age_h=""; lg=""
        if [ -r "$st" ]; then
            lg="$st/last-good-$name.txt"
            [ -f "$lg" ] && age_h=$(( (now - $(stat -c %Y "$lg" 2>/dev/null || echo "$now")) / 3600 ))
            alert=""; [ -f "$st/.alert-$name" ] && alert="$(cat "$st/.alert-$name" 2>/dev/null)"
            waiting=0; grep -q '^waiting' "$st/status-$name" 2>/dev/null && waiting=1
        else alert=""; waiting=0; fi
        if [ "${cnt:-0}" -eq 0 ] && [ -n "${lg:-}" ] && [ -f "$lg" ] && [ ! -s "$lg" ] && [ -z "$alert" ]; then
            # 2026-09-25 (v1.1.7): последнее УСПЕШНОЕ обновление дало 0 записей — пустой set корректен
            # (custom без IP в custom.txt, свежий crowdsec без решений). Раньше — ложный WARN «ПУСТ».
            if [ "$name" = custom ]; then
                _hc PASS "custom: пуст — в /etc/shieldnode/lists/custom.txt и BLOCKLIST_CUSTOM_URLS нет записей (добавь IP/CIDR — применится сразу)"
            else
                _hc PASS "$name: пуст — источник сейчас не содержит записей (обновление успешно)"
            fi
        elif [ "${cnt:-0}" -eq 0 ] && [ "$waiting" = 1 ]; then
            # 2026-09-25 (v1.2.0, P1-3): cscli ответил «0 решений» — это не сбой фида
            _hc INFO "$name: CrowdSec работает, но community-список ещё не пришёл (обычно до 2 ч после установки) — ждём"
        elif [ "${cnt:-0}" -eq 0 ]; then
            local last="нет данных"; [ -n "$age_h" ] && last="${age_h}ч назад"
            _hc WARN "$name: set ПУСТ — updater ещё не отработал или фид недоступен (последний успех: $last)"
        else
            _hc PASS "$name: ${cnt} записей в наборе (после схлопывания CIDR; MIN проверяет updater на сыром фиде)"
        fi
        [ -n "$alert" ] && _hc WARN "$name: фид падает подряд — алерт с $alert (см. /var/log/shieldnode.log)"
        if [ "$name" != "custom" ] && [ -r "$st" ]; then
            iv="$(shield_conf_get BLOCKLIST_UPDATE_INTERVAL 360)"
            # 2026-09-25 (v1.1.7): agent-режим обновляется своим таймером (30 мин), feed — раз в сутки
            if [ "$name" = "crowdsec" ]; then
                if [ "$(shield_crowdsec_resolve_mode)" = agent ]; then iv="$(shield_conf_get CROWDSEC_AGENT_INTERVAL_MIN 30)"
                else iv="$(shield_conf_get CROWDSEC_UPDATE_INTERVAL_MIN 1440)"; fi
            fi
            [[ "$iv" =~ ^[0-9]+$ ]] || iv=360
            if [ "$waiting" = 1 ]; then :
            elif [ -z "$age_h" ]; then _hc WARN "$name: успешных обновлений ещё не было (last-good нет)"
            elif [ $((age_h * 60)) -gt $((iv * 2 + 60)) ]; then _hc WARN "$name: последнее успешное обновление ${age_h}ч назад (> 2 интервалов по ${iv} мин) — проверь таймер/сеть"; fi
        fi
    done <<<"$SHIELD_HEALTH_LISTS"
    [ -r "$st" ] || _hc INFO "нет доступа к $st — свежесть блоклистов не проверена (запусти через sudo)"

    # таймер и boot-служба
    if command -v systemctl >/dev/null 2>&1; then
        if [ "$bl_on" = "1" ]; then
            if systemctl is-active --quiet shieldnode-blocklist.timer 2>/dev/null; then _hc PASS "shieldnode-blocklist.timer активен"
            else _hc WARN "shieldnode-blocklist.timer НЕ активен — блоклисты не обновляются"; fi
        fi
        if systemctl is-enabled --quiet shieldnode.service 2>/dev/null; then _hc PASS "shieldnode.service enabled — фаервол поднимется после reboot"
        else _hc WARN "shieldnode.service не enabled — после reboot фаервола не будет"; fi
    fi

    # «делает ли работу»: последний apply, дропы, abuse-сеты, журнал
    local upd drops j
    upd="$(awk -F= '/^\[shieldnode\]/ {f = 1; next} /^\[/ {f = 0} f && $1 == "updated" {print $2}' /etc/node-profile.d/stack.conf 2>/dev/null || true)"
    _hc INFO "последний apply: ${upd:-неизвестно}"
    drops="$(nft_counters | awk '$1 ~ /^c_drops_/ {s += $2} END {print s + 0}')"
    if [ "${drops:-0}" -gt 0 ]; then _hc INFO "дропов с последнего apply: $drops пакетов (фаервол работает)"
    else _hc INFO "дропов с последнего apply: 0 — нода простаивает или атак не было (не ошибка)"; fi
    j="$(awk '/^### / {t = $2} END {print t}' "$SHIELD_STATE_DIR/abuse.journal" 2>/dev/null || true)"
    _hc INFO "abuse-сеты сейчас: ssh=$(nft_set_elem_count ssh_abusers) tcp=$(nft_set_elem_count tcp_abusers) udp=$(nft_set_elem_count udp_abusers) temp=$(nft_set_elem_count temporary_blocklist); журнал: ${j:-записей нет}"
    _h_sum
}

shield_status() {
    echo "=== shieldnode v$SHIELD_VERSION status ==="
    echo

    echo "--- emergency ---"
    if [ -f /run/shieldnode/emergency ]; then
        echo "EMERGENCY ON since $(head -1 /run/shieldnode/emergency)"
    else
        echo "off"
    fi
    echo

    shield_health

    echo "--- config (effective: config.conf + defaults; пусто = авто) ---"
    local k
    for k in ENABLE_SSH_PROTECTION ENABLE_INVALID_DROP ENABLE_LOOPBACK ENABLE_ESTABLISHED ENABLE_ABUSE_LIMITING \
             ENABLE_BLOCKLISTS ENABLE_SCANNER_LIST ENABLE_THREAT_LIST BLOCK_TOR ENABLE_CUSTOM_LIST \
             ENABLE_CROWDSEC_LIST CROWDSEC_MODE CROWDSEC_UPDATE_INTERVAL_MIN \
             ENABLE_SPAMHAUS_LIST ENABLE_CINS_LIST ENABLE_AMP_GUARD ENABLE_ICMP_GUARD \
             BLOCKLIST_UPDATE_INTERVAL MIN_ENTRIES_SCANNER MIN_ENTRIES_THREAT \
             SSH_PORT SSH_CONN_MAX SSH_NEW_RATE SSH_NEW_BURST \
             TCP_NEW_RATE TCP_NEW_BURST TCP_SYN_RATE TCP_SYN_BURST TCP_CONN_MAX TCP_GLOBAL_CEIL \
             UDP_RATE UDP_BURST UDP_GLOBAL_CEIL \
             SSH_ABUSERS_TIMEOUT TCP_ABUSERS_TIMEOUT UDP_ABUSERS_TIMEOUT TEMP_BLOCKLIST_TIMEOUT \
             PROTECTED_TCP_EXTRA PROTECTED_UDP_EXTRA TRUSTED_IPS LOG_LEVEL BACKUP_KEEP PERSIST_ENABLED \
             ENABLE_ANTISPOOF; do
        printf '  %-24s = %s\n' "$k" "$(shield_conf_get "$k" "")"
    done
    echo

    echo "--- firewall (fact) ---"
    if command -v nft >/dev/null 2>&1 && nft list table inet shieldnode >/dev/null 2>&1; then
        echo "table inet shieldnode: present"
        # 2026-09-23 (v1.1.4): `nft list chains inet shieldnode` — синтаксическая ошибка
        # (list chains принимает только family) → под set -e/pipefail status умирал здесь
        { nft list table inet shieldnode 2>/dev/null || true; } | awk '$1 == "chain" {print "  chain " $2}'
        echo
        echo "sets (elements):"
        local s
        for s in whitelist_v4 whitelist_v6 ssh_abusers ssh_abusers_v6 tcp_abusers tcp_abusers_v6 \
                 udp_abusers udp_abusers_v6 temporary_blocklist temporary_blocklist_v6 \
                 ssh_connlimit ssh_connlimit_v6 tcp_connlimit tcp_connlimit_v6 \
                 scanner_blocklist_v4 scanner_blocklist_v6 threat_blocklist_v4 threat_blocklist_v6 \
                 tor_exit_blocklist_v4 tor_exit_blocklist_v6 custom_blocklist_v4 custom_blocklist_v6 \
                 crowdsec_blocklist_v4 crowdsec_blocklist_v6 \
                 spamhaus_blocklist_v4 spamhaus_blocklist_v6 cins_blocklist_v4 \
                 protected_tcp protected_udp; do
            # elements = { ... } nft печатает многострочно — счёт через common.sh
            if nft -n list set inet shieldnode "$s" >/dev/null 2>&1; then
                printf '  %-22s elements=%s\n' "$s" "$(nft_set_elem_count "$s")"
            fi
        done
    else
        echo "table inet shieldnode: ABSENT (не применён или сброшен)"
    fi
    echo

    echo "--- drop counters (zero-cost; сбрасываются при полном apply) ---"
    if command -v nft >/dev/null 2>&1 && nft list table inet shieldnode >/dev/null 2>&1; then
        local cnt found=0
        while read -r cnt; do
            [ -n "$cnt" ] || continue
            found=1
            printf '  %s\n' "$cnt"
        done < <(nft_counters | awk '$1 ~ /^c_drops_/ { printf "%s: packets=%s bytes=%s\n", $1, $2, $3 }')
        [ "$found" -eq 0 ] && echo "  (counters отсутствуют — apply не выполнялся после обновления?)"
    else
        echo "  (table отсутствует)"
    fi
    echo

    echo "--- crowdsec ---"
    # main.sh в ветке status НЕ source'ит limits.sh (SH_F_* unset) — читаем конфиг напрямую
    if [ "$(shield_conf_get ENABLE_CROWDSEC_LIST 1)" = "1" ]; then
        echo "mode: $(shield_crowdsec_resolve_mode)"
        echo "agent: $(shield_crowdsec_agent_status)"
    else
        echo "disabled (ENABLE_CROWDSEC_LIST=0)"
    fi
    echo

    echo "--- detect ---"
    echo "ssh ports (detected): $(shield_ssh_ports_summary)"
    echo "protected ports state: $([ -s "$SHIELD_PROTECTED_STATE" ] && cat "$SHIELD_PROTECTED_STATE" || echo '(none)')"
    echo "last snapshot: $(ls -1t "$SHIELD_STATE_DIR"/diagnostics/*.txt 2>/dev/null | head -1 || echo '(none)')"
    echo "admin session IP: ${SSH_CONNECTION:-<not an ssh session>}"
    echo

    echo "--- persist / ownership ---"
    echo "manifest files: $([ -f "$SHIELD_STATE_DIR/applied-files.txt" ] && wc -l < "$SHIELD_STATE_DIR/applied-files.txt" || echo 0)"
    echo "owner-keys: $([ -f "$SHIELD_STATE_DIR/owner-keys.txt" ] && wc -l < "$SHIELD_STATE_DIR/owner-keys.txt" || echo 0) ключей (net.netfilter.* там: $(cat "$SHIELD_STATE_DIR/owner-keys.txt" 2>/dev/null | grep -c 'netfilter' || true) — должно быть 0, §15)"
    echo "abuse journal: $([ -f "$SHIELD_STATE_DIR/abuse.journal" ] && wc -l < "$SHIELD_STATE_DIR/abuse.journal" || echo 0) строк"
    echo "nft boot file: $([ -f /etc/nftables.d/shieldnode.conf ] && echo present || echo absent)"
    echo "security sysctl: $([ -f /etc/sysctl.d/99-z5-shieldnode-security.conf ] && echo present || echo absent)"
}
