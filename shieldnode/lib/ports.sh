#!/bin/bash
# shieldnode — lib/ports.sh: 2026-09-25 (v1.2.0) — синхронизация защищаемых портов с реальностью
# и проверка «фаервол жив» (DIAGNOSIS P0-2).
#
# Раньше порты определялись ТОЛЬКО на apply: remnanode, запущенный/перенастроенный панелью
# позже, новые правила UFW, новый инбаунд — всё это оставалось без защиты до ручного apply
# (прод E3). Теперь служба shieldnode-ports.service (ports-watch) каждые 15 с сверяет:
#   нужные порты = SSH + инбаунды Xray (API) + API ноды + UFW + *_EXTRA (тот же код, что apply)
#   с живыми наборами protected_tcp/udp, node_api_port/node_api_allow_v4; при расхождении —
#   атомарная замена элементов наборов (одна транзакция nft), правка сохранённого ruleset'а
#   (boot), контракт для node и пересчёт ip_local_reserved_ports (node reserve-ports).
# Дорогой шаг (docker exec … api lsi) — только если изменился «отпечаток» (PID ядра, TCP-
# слушатели, файлы UFW, config.conf) или прошло 30 мин с полной проверки.
set -euo pipefail

# _ports_norm "<список через пробел/запятую>" -> отсортированный уникальный через запятую
_ports_norm() { tr ', ' '\n\n' <<<"${1:-}" | awk 'NF' | sort -u | sort -t- -k1,1n | paste -sd, -; }
_ports_live() { # элементы набора (как в health)
    nft -n list set inet shieldnode "$1" 2>/dev/null | awk '/elements = \{/ {f = 1; sub(/.*elements = \{/, "")}
        f { l = $0; e = sub(/\}.*/, "", l); print l; if (e) f = 0 }' | tr ',\t\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' || true
}

# _ports_patch_conf <file> — заменить элементы 4 наборов в сохранённом ruleset'е (для boot)
# env: PT PU AP AA — списки через запятую
_ports_patch_conf() {
    awk -v pt="$PT" -v pu="$PU" -v ap="$AP" -v aa="$AA" '
        function el(n) { return n == "protected_tcp" ? pt : (n == "protected_udp" ? pu : (n == "node_api_port" ? ap : aa)) }
        /^    set (protected_tcp|protected_udp|node_api_port|node_api_allow_v4) \{/ { cur = $2; print; next }
        cur != "" && /^        elements = / { next }
        cur != "" && /^    \}/ { e = el(cur); if (e != "") print "        elements = { " e " }"; cur = ""; print; next }
        { print }' "$1"
}

# shield_ports_sync — один проход. rc 0 всегда, кроме ошибки применения.
shield_ports_sync() {
    [ -f /run/shieldnode/emergency ] && return 0
    nft list table inet shieldnode >/dev/null 2>&1 || return 0
    # основной lock: идёт apply/rollback — пропускаем (apply посчитает то же самое)
    exec 8>>"$SHIELD_LOCK"
    flock -n 8 || return 0

    # конфиг мог измениться (меню/оператор) — перечитываем кэш
    [ -n "${CONFIG_CACHE:-}" ] && rm -f "$CONFIG_CACHE"
    shield_load_config >/dev/null 2>&1 || true
    # порты — тем же кодом, что apply (логи resolve — не в журнал: проход каждые 15 с)
    local real_log="$SHIELD_LOG"
    SH_IB_DONE=0
    SHIELD_LOG=/dev/null shield_limits_resolve >/dev/null 2>&1 || { flock -u 8; return 0; }
    SHIELD_LOG="$real_log"

    local want_t want_u want_ap want_aa cur_t cur_u cur_ap cur_aa
    want_t="$(_ports_norm "$SH_F_PROTECTED_TCP")"; want_u="$(_ports_norm "$SH_F_PROTECTED_UDP")"
    want_ap="$(_ports_norm "${SH_F_NODE_API_PORT_SET:-}")"; want_aa="$(_ports_norm "${SH_F_NODE_API_ALLOW_V4:-}")"
    cur_t="$(_ports_norm "$(_ports_live protected_tcp)")"; cur_u="$(_ports_norm "$(_ports_live protected_udp)")"
    cur_ap="$(_ports_norm "$(_ports_live node_api_port)")"; cur_aa="$(_ports_norm "$(_ports_live node_api_allow_v4)")"

    if [ "$want_t|$want_u|$want_ap|$want_aa" = "$cur_t|$cur_u|$cur_ap|$cur_aa" ]; then
        flock -u 8; return 0
    fi

    # набор node_api_port/allow мог отсутствовать (таблица от v1.3.0) — тогда нужен полный apply
    if ! nft list set inet shieldnode node_api_port >/dev/null 2>&1; then
        log warn "ports" "в таблице нет наборов v1.2.0 — нужен полный apply (sudo vpn-node → «Применить фаервол»)"
        flock -u 8; return 0
    fi

    local batch; batch="$(mktemp)"
    {
        echo "flush set inet shieldnode protected_tcp"
        [ -n "$want_t" ] && echo "add element inet shieldnode protected_tcp { $want_t }"
        echo "flush set inet shieldnode protected_udp"
        [ -n "$want_u" ] && echo "add element inet shieldnode protected_udp { $want_u }"
        # порядок: сначала разрешённые адреса, потом порт — иначе миг «порт закрыт для всех»
        echo "flush set inet shieldnode node_api_allow_v4"
        [ -n "$want_aa" ] && echo "add element inet shieldnode node_api_allow_v4 { $want_aa }"
        echo "flush set inet shieldnode node_api_port"
        [ -n "$want_ap" ] && echo "add element inet shieldnode node_api_port { $want_ap }"
    } > "$batch"
    if ! nft -f "$batch" 2>"$batch.err"; then
        log error "ports" "обновление наборов не применилось: $(head -c 200 "$batch.err")"
        rm -f "$batch" "$batch.err"; flock -u 8; return 1
    fi
    rm -f "$batch" "$batch.err"

    # сохранённый ruleset (boot) — та же правка, проверка nft -c до замены
    local conf="${SHIELD_NFT_PERSIST:-/etc/nftables.d/shieldnode.conf}" tmp
    if [ -f "$conf" ]; then
        tmp="$(mktemp "$conf.XXXXXX")"
        if PT="$want_t" PU="$want_u" AP="$want_ap" AA="$want_aa" _ports_patch_conf "$conf" > "$tmp" \
           && nft -c -f "$tmp" >/dev/null 2>&1; then
            chmod --reference="$conf" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
            mv -f "$tmp" "$conf"
        else
            rm -f "$tmp"; log warn "ports" "сохранённый ruleset не обновлён (nft -c) — после reboot порты досинхронизируются"
        fi
    fi

    declare -F shield_contract_write >/dev/null && shield_contract_write >/dev/null 2>&1 || true
    local nodeinst="${SHIELD_NODE_INSTALL:-$SHIELD_DIR/../node/install.sh}"
    [ -f "$nodeinst" ] && bash "$nodeinst" reserve-ports >/dev/null 2>&1 || true
    log info "ports" "защищаемые порты обновлены: tcp [$cur_t] -> [$want_t], udp [$cur_u] -> [$want_u], API ноды [$cur_ap] -> [$want_ap] (источник: $SH_IB_SOURCE)"
    flock -u 8
    return 0
}

# _ports_fingerprint — дёшево: PID'ы ядра, TCP-слушатели ядра и rw-node, файлы UFW/конфига
_ports_fingerprint() {
    {
        pgrep -x 'xray|rw-core|sing-box|hysteria|v2ray' 2>/dev/null | sort | tr '\n' ' ' || true
        # все внешние TCP-слушатели без -p (обход fd всех процессов дорог; любой новый — повод проверить)
        { ss -tlnH 2>/dev/null || true; } | shield_ss_public_ports . | sort -u | tr '\n' ' '
        stat -c '%Y' "${SHIELD_UFW_DIR:-/etc/ufw}/user.rules" "${SHIELD_UFW_DIR:-/etc/ufw}/ufw.conf" "$SHIELD_CONFIG" 2>/dev/null | tr '\n' ' ' || true
    } | md5sum | cut -c1-16
}

# shield_ports_watch — цикл службы shieldnode-ports.service
shield_ports_watch() {
    local last_fp="" last_full=0 fp now
    log info "ports" "ports-watch запущен (проверка каждые ${SHIELD_PORTS_INTERVAL:-15} с)"
    while :; do
        now="$(date +%s)"; fp="$(_ports_fingerprint 2>/dev/null || echo x)"
        # полный проход (docker exec … api lsi, ~1-2 с CPU) — при смене отпечатка; страховочный — раз
        # в 30 мин: remnanode перезапускает ядро при каждой смене конфига (новый PID), UFW/конфиг —
        # mtime в отпечатке, API ноды — новый TCP-слушатель (v1.2.0, лаба: 120 с = ~1.5% CPU на 1 vCPU)
        if [ "$fp" != "$last_fp" ] || [ $((now - last_full)) -ge "${SHIELD_PORTS_FULL_EVERY:-1800}" ]; then
            shield_ports_sync || true
            last_fp="$fp"; last_full="$now"
        fi
        sleep "${SHIELD_PORTS_INTERVAL:-15}"
    done
}

# shield_verify — «фаервол жив»: не только «таблица есть» (DIAGNOSIS P0-2). rc 0 — всё на месте.
shield_verify() {
    local bad=0 pre chains n s admin
    _v() { if [ "$1" = ok ]; then printf '  ✔ %s\n' "$2"; else printf '  ✘ %s\n' "$2"; bad=1; fi; }
    if ! nft list table inet shieldnode >/dev/null 2>&1; then _v fail "таблица inet shieldnode отсутствует"; return 1; fi
    if [ -f /run/shieldnode/emergency ]; then _v ok "аварийный режим (минимальные правила)"; return 0; fi
    # «nft list chains» принимает только семейство, не таблицу — берём саму таблицу (-t: без элементов)
    chains="$(nft -t list table inet shieldnode 2>/dev/null | grep -E "^\s*(chain |type .* hook )" || true)"
    grep -q 'hook prerouting' <<<"$chains" && _v ok "цепочка prerouting подключена к хуку" || _v fail "prerouting не подключена к хуку"
    grep -q 'hook output' <<<"$chains" && _v ok "IPv6 fail-safe на выходе подключён" || _v fail "нет цепочки v6_output (IPv6 fail-safe)"
    pre="$(nft list chain inet shieldnode prerouting 2>/dev/null || true)"
    n="$(grep -cE ' (drop|accept)( |$)' <<<"$pre" || true)"
    [ "${n:-0}" -ge 10 ] && _v ok "prerouting: $n правил" || _v fail "prerouting: всего ${n:-0} правил — ruleset неполный"
    grep -q 'c_drops_ipv6_failsafe' <<<"$pre" && _v ok "IPv6 fail-safe в prerouting" || _v fail "нет IPv6 fail-safe в prerouting"
    grep -q 'ct state established,related accept' <<<"$pre" && _v ok "established/related accept" || _v fail "нет established/related accept"
    for s in whitelist_v4 protected_tcp protected_udp node_api_port node_api_allow_v4 ssh_abusers tcp_abusers udp_abusers; do
        nft list set inet shieldnode "$s" >/dev/null 2>&1 || { _v fail "нет набора $s"; }
    done
    [ -n "$(_ports_live protected_tcp)" ] && _v ok "protected_tcp: $(_ports_live protected_tcp)" || _v fail "protected_tcp пуст"
    admin="$(shield_detect_admin_ip 2>/dev/null || true)"
    if [ -n "$admin" ]; then
        case "$admin" in *:*) _v ok "SSH-сессия по IPv6 ($admin) — IPv6 на ноде выключен" ;;
            *) nft get element inet shieldnode whitelist_v4 "{ $admin }" >/dev/null 2>&1 \
                   && _v ok "IP SSH-сессии $admin в белом списке" || _v fail "IP SSH-сессии $admin НЕ в белом списке" ;; esac
    fi
    return "$bad"
}
