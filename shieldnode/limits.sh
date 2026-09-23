#!/bin/bash
# shieldnode — limits.sh: резолвинг числовых лимитов (пусто = авто, ТЗ §28),
# exclude.conf (§30), журнал abuse + cleanup-таймер (ТЗ §24).
set -euo pipefail

SHIELD_ABUSE_JOURNAL="$SHIELD_STATE_DIR/abuse.journal"

# shield_limit_num <key> <default> — число из конфига, fallback на default.
shield_limit_num() {
    local v; v="$(shield_conf_get "$1" "$2")"
    case "$v" in
        ''|*[!0-9]*) die "config $1: ожидалось положительное число, получено '$v'" ;;
    esac
    [ "$v" -ge 0 ] || die "config $1: отрицательное значение '$v'"
    echo "$v"
}

# shield_limits_resolve — выставить SH_R_* / SH_F_* для lib/nft.sh.
shield_limits_resolve() {
    export SH_R_SSH_CONN_MAX SH_R_SSH_NEW_RATE SH_R_SSH_NEW_BURST
    export SH_R_TCP_NEW_RATE SH_R_TCP_NEW_BURST SH_R_TCP_SYN_RATE SH_R_TCP_SYN_BURST SH_R_TCP_CONN_MAX SH_R_TCP_GLOBAL_CEIL
    export SH_R_UDP_RATE SH_R_UDP_BURST SH_R_UDP_GLOBAL_CEIL
    export SH_R_SSH_ABUSERS_TIMEOUT SH_R_SSH_ABUSERS_SIZE SH_R_TCP_ABUSERS_TIMEOUT SH_R_TCP_ABUSERS_SIZE
    export SH_R_UDP_ABUSERS_TIMEOUT SH_R_UDP_ABUSERS_SIZE SH_R_TEMP_BLOCKLIST_TIMEOUT SH_R_TEMP_BLOCKLIST_SIZE
    export SH_R_SCANNER_BLOCKLIST_SIZE SH_R_THREAT_BLOCKLIST_SIZE SH_R_TOR_BLOCKLIST_SIZE SH_R_CUSTOM_BLOCKLIST_SIZE SH_R_CROWDSEC_BLOCKLIST_SIZE
    export SH_R_SPAMHAUS_BLOCKLIST_SIZE SH_R_CINS_BLOCKLIST_SIZE

    SH_R_SSH_CONN_MAX="$(shield_limit_num SSH_CONN_MAX 8)"
    SH_R_SSH_NEW_RATE="$(shield_limit_num SSH_NEW_RATE 10)"
    SH_R_SSH_NEW_BURST="$(shield_limit_num SSH_NEW_BURST 20)"
    SH_R_TCP_NEW_RATE="$(shield_limit_num TCP_NEW_RATE 300)"
    SH_R_TCP_NEW_BURST="$(shield_limit_num TCP_NEW_BURST 600)"
    SH_R_TCP_SYN_RATE="$(shield_limit_num TCP_SYN_RATE 50)"
    SH_R_TCP_SYN_BURST="$(shield_limit_num TCP_SYN_BURST 100)"
    SH_R_TCP_CONN_MAX="$(shield_limit_num TCP_CONN_MAX 15000)"
    # Глобальные потолки: дефолт 0 (ВЫКЛЮЧЕНЫ) — опасны на CGNAT-нодах:
    # один NAT-пул клиентов набьёт общий потолок и положит защищённые порты
    # для всех. Включать осознанно, значением из конфига.
    SH_R_TCP_GLOBAL_CEIL="$(shield_limit_num TCP_GLOBAL_CEIL 0)"
    # UDP per-src: 20000/с (≈216 Мбит/с на source-IP при QUIC-датаграмме 1350B,
    # без учёта GRO). Асимметрия GRO в нашу пользу: легитимный Hysteria2-поток —
    # один flow, GRO склеивает датаграммы ДО nftables (гигабитный клиент ≈ 3-12k
    # посчитанных pps); флуд с рандомных портов/IP — каждый пакет отдельный flow,
    # GRO не склеивает, считается полный wire-pps (реальный флуд = 100k-1M pps,
    # ловится и под 20000). Стартовая точка — боевые 10000/с старого стека
    # (v3.20=1500 резало легитимных → v3.22=10000), поднято ×2 под гигабитных
    # одиночек. CGNAT-экстремум (4K на 50+ устройств за одним IP) — TRUSTED_IPS.
    SH_R_UDP_RATE="$(shield_limit_num UDP_RATE 20000)"
    SH_R_UDP_BURST="$(shield_limit_num UDP_BURST 40000)"
    SH_R_UDP_GLOBAL_CEIL="$(shield_limit_num UDP_GLOBAL_CEIL 0)"

    SH_R_SSH_ABUSERS_TIMEOUT="$(shield_limit_num SSH_ABUSERS_TIMEOUT 3600)"
    SH_R_SSH_ABUSERS_SIZE="$(shield_limit_num SSH_ABUSERS_SIZE 65536)"
    SH_R_TCP_ABUSERS_TIMEOUT="$(shield_limit_num TCP_ABUSERS_TIMEOUT 900)"
    SH_R_TCP_ABUSERS_SIZE="$(shield_limit_num TCP_ABUSERS_SIZE 131072)"
    SH_R_UDP_ABUSERS_TIMEOUT="$(shield_limit_num UDP_ABUSERS_TIMEOUT 900)"
    SH_R_UDP_ABUSERS_SIZE="$(shield_limit_num UDP_ABUSERS_SIZE 65536)"
    SH_R_TEMP_BLOCKLIST_TIMEOUT="$(shield_limit_num TEMP_BLOCKLIST_TIMEOUT 3600)"
    SH_R_TEMP_BLOCKLIST_SIZE="$(shield_limit_num TEMP_BLOCKLIST_SIZE 32768)"
    SH_R_SCANNER_BLOCKLIST_SIZE="$(shield_limit_num SCANNER_BLOCKLIST_SIZE 262144)"
    SH_R_THREAT_BLOCKLIST_SIZE="$(shield_limit_num THREAT_BLOCKLIST_SIZE 131072)"
    SH_R_TOR_BLOCKLIST_SIZE="$(shield_limit_num TOR_BLOCKLIST_SIZE 16384)"
    SH_R_CUSTOM_BLOCKLIST_SIZE="$(shield_limit_num CUSTOM_BLOCKLIST_SIZE 65536)"
    # crowdsec community blocklist (opt-in, нужны креды консоли): CAPI ~28k-350k записей
    SH_R_CROWDSEC_BLOCKLIST_SIZE="$(shield_limit_num CROWDSEC_BLOCKLIST_SIZE 262144)"
    # spamhaus DROP/EDROP (~2k диапазонов worst-of-the-worst, v4+v6) и CINS Army (~30k IP)
    SH_R_SPAMHAUS_BLOCKLIST_SIZE="$(shield_limit_num SPAMHAUS_BLOCKLIST_SIZE 8192)"
    SH_R_CINS_BLOCKLIST_SIZE="$(shield_limit_num CINS_BLOCKLIST_SIZE 65536)"

    # blocklists: мастер-флаг + per-list (агрегаторы scanner/threat/tor/custom/crowdsec/spamhaus/cins)
    export SH_F_ENABLE_BLOCKLISTS SH_F_ENABLE_SCANNER_LIST SH_F_ENABLE_THREAT_LIST
    export SH_F_BLOCK_TOR SH_F_ENABLE_CUSTOM_LIST SH_F_ENABLE_CROWDSEC_LIST
    export SH_F_ENABLE_SPAMHAUS_LIST SH_F_ENABLE_CINS_LIST
    SH_F_ENABLE_BLOCKLISTS="$(shield_conf_get ENABLE_BLOCKLISTS 1)"
    SH_F_ENABLE_SCANNER_LIST="$(shield_conf_get ENABLE_SCANNER_LIST 1)"
    SH_F_ENABLE_THREAT_LIST="$(shield_conf_get ENABLE_THREAT_LIST 1)"
    SH_F_BLOCK_TOR="$(shield_conf_get BLOCK_TOR 0)"
    SH_F_ENABLE_CUSTOM_LIST="$(shield_conf_get ENABLE_CUSTOM_LIST 1)"
    # crowdsec: opt-in (default 0) — без креденшелов консоли фид бессмысленен
    SH_F_ENABLE_CROWDSEC_LIST="$(shield_conf_get ENABLE_CROWDSEC_LIST 0)"
    # spamhaus/cins: бесплатные фиды без ключа — default 1 (worst-of-the-worst, ложных срабатываний почти нет)
    SH_F_ENABLE_SPAMHAUS_LIST="$(shield_conf_get ENABLE_SPAMHAUS_LIST 1)"
    SH_F_ENABLE_CINS_LIST="$(shield_conf_get ENABLE_CINS_LIST 1)"

    # amplification-guard (anti-reflection): NEW UDP от известных amplifier source-портов
    # (53/123/1900/11211/389) — неспрошенные ответы. Свои DNS-запросы = ESTABLISHED, не трогаем.
    export SH_F_ENABLE_AMP_GUARD SH_F_ENABLE_ICMP_GUARD
    SH_F_ENABLE_AMP_GUARD="$(shield_conf_get ENABLE_AMP_GUARD 1)"
    SH_F_ENABLE_ICMP_GUARD="$(shield_conf_get ENABLE_ICMP_GUARD 1)"

    # SSH-порты: config SSH_PORT (если задан) иначе авто-детект (ТЗ §19)
    local cfg_port; cfg_port="$(shield_conf_get SSH_PORT "")"
    if [ -n "$cfg_port" ]; then
        case "$cfg_port" in *[!0-9]*) die "config SSH_PORT: число, получено '$cfg_port'";; esac
        export SH_F_SSH_PORTS="$cfg_port"
    else
        export SH_F_SSH_PORTS; SH_F_SSH_PORTS="$(shield_detect_ssh_ports)"
    fi

    # защищаемые порты = auto-detect (ssh+xray) + EXTRA из конфига
    local det_t det_u
    det_t="$(shield_detect_protected_ports)"
    det_u=""
    if command -v ss >/dev/null 2>&1; then
        # 2026-09-23: у `ss -ulnp` есть колонка State (UNCONN) — $5 был Peer
        # ('0.0.0.0:*'), мусор уходил в protected_udp и nft -c отвергал ruleset
        # при ЛЮБОМ UDP-inbound xray. Local = первое поле вида адрес:порт.
        det_u="$(ss -ulnp 2>/dev/null | _ss_local_ports 'xray|remnanode' | sort -un | tr '\n' ' ' | sed 's/ $//' || true)"
    fi
    local extra_t extra_u
    extra_t="$(shield_conf_get PROTECTED_TCP_EXTRA "")"
    extra_u="$(shield_conf_get PROTECTED_UDP_EXTRA "")"

    # exclude.conf (ТЗ §30): строки "PORT n", "IP cidr", "IP6 cidr"
    local excl_ports_v4="" excl_v4="" excl_v6="" line op arg
    if [ -f "$SHIELD_EXCLUDE" ]; then
        while read -r line; do
            # CRLF: exclude.conf могли сохранить из Windows — срезаем \r,
            # иначе аргумент уезжает в nft с мусором (баг 2026-09-22)
            line="${line%$'\r'}"
            case "$line" in ''|\#*) continue ;; esac
            op="${line%%[[:space:]]*}"; arg="${line#*[[:space:]]}"
            # строка без аргумента ("PORT" без значения) — пропускаем с warn
            if [ "$arg" = "$op" ] || [ -z "$arg" ]; then
                log warn "exclude" "директива без значения, пропущена: $line"
                continue
            fi
            case "$op" in
                PORT)  excl_ports_v4="$excl_ports_v4 $arg" ;;
                IP)    case "$arg" in *:*) excl_v6="$excl_v6 $arg" ;; *) excl_v4="$excl_v4 $arg" ;; esac ;;
                IP6)   excl_v6="$excl_v6 $arg" ;;
                *)     log warn "exclude" "неизвестная директива: $line" ;;
            esac
        done < "$SHIELD_EXCLUDE"
    fi

    # вычитаем exclude-порты из protected
    local p out_t="" out_u=""
    for p in $det_t $extra_t; do
        case " $excl_ports_v4 " in *" $p "*) continue ;; esac
        case " $out_t " in *" $p "*) continue ;; esac
        out_t="$out_t $p"
    done
    for p in $det_u $extra_u; do
        case " $excl_ports_v4 " in *" $p "*) continue ;; esac
        case " $out_u " in *" $p "*) continue ;; esac
        out_u="$out_u $p"
    done
    export SH_F_PROTECTED_TCP="${out_t# }" SH_F_PROTECTED_UDP="${out_u# }"

    # TRUSTED_IPS (config.conf): доп. whitelist — например статический IP панели Remnawave,
    # чтобы sync/push никогда не попадал под rate-limit (входящие вызовы панели, если есть).
    local trusted t_v4="" t_v6=""
    trusted="$(shield_conf_get TRUSTED_IPS "")"
    local tip
    for tip in $trusted; do
        case "$tip" in
            *:*) t_v6="$t_v6 $tip" ;;
            *)   t_v4="$t_v4 $tip" ;;
        esac
    done
    export SH_F_EXCL_V4="${excl_v4# } ${t_v4# }" SH_F_EXCL_V6="${excl_v6# } ${t_v6# }"
    SH_F_EXCL_V4="${SH_F_EXCL_V4# }"; SH_F_EXCL_V6="${SH_F_EXCL_V6# }"

    # IPv6-флаг (читалка из детекта); node мог отключить IPv6 (HARDEN_IPV6=1) —
    # тогда v6-правила не генерируем: трафика нет, ruleset компактнее
    export SH_F_IPV6=0
    [ -r /proc/net/if_inet6 ] && SH_F_IPV6=1
    if [ "$SH_F_IPV6" = "1" ] && [ -f /etc/node-profile.d/stack.conf ] \
        && grep -q '^ipv6_disabled=1' /etc/node-profile.d/stack.conf 2>/dev/null; then
        SH_F_IPV6=0
        log info "limits" "node отключил IPv6 (stack.conf: ipv6_disabled=1) — v6-правила пропущены"
    fi

    # admin IP сессии (whitelist, §20) — только если не loopback
    local admin; admin="$(shield_detect_admin_ip || true)"
    export SH_F_ADMIN_V4="" SH_F_ADMIN_V6=""
    case "$admin" in
        ""|127.*|::1|localhost) : ;;  # loopback не добавляем
        *:*) SH_F_ADMIN_V6="$admin" ;;
        *)   SH_F_ADMIN_V4="$admin" ;;
    esac

    # enable-флаги секций (§28)
    export SH_F_ENABLE_SSH_PROTECTION SH_F_ENABLE_INVALID_DROP SH_F_ENABLE_LOOPBACK
    export SH_F_ENABLE_ESTABLISHED SH_F_ENABLE_ABUSE_LIMITING
    export SH_F_ENABLE_SYN_PROTECTION SH_F_ENABLE_ANTISPOOF SH_F_WAN_IFACE
    SH_F_ENABLE_SSH_PROTECTION="$(shield_conf_get ENABLE_SSH_PROTECTION 1)"
    SH_F_ENABLE_INVALID_DROP="$(shield_conf_get ENABLE_INVALID_DROP 1)"
    SH_F_ENABLE_LOOPBACK="$(shield_conf_get ENABLE_LOOPBACK 1)"
    SH_F_ENABLE_ESTABLISHED="$(shield_conf_get ENABLE_ESTABLISHED 1)"
    SH_F_ENABLE_ABUSE_LIMITING="$(shield_conf_get ENABLE_ABUSE_LIMITING 1)"
    SH_F_ENABLE_SYN_PROTECTION="$(shield_conf_get ENABLE_SYN_PROTECTION 1)"
    SH_F_ENABLE_ANTISPOOF="$(shield_conf_get ENABLE_ANTISPOOF 0)"
    SH_F_WAN_IFACE=""
    if command -v ip >/dev/null 2>&1; then
        SH_F_WAN_IFACE="$(shield_default_iface)"
    fi

    # расширения: include внутри таблицы только если есть файлы (иначе include глоб не матчится)
    export SH_F_EXTENSIONS=""
    if [ -d /etc/shieldnode/extensions.d ]; then
        if ls /etc/shieldnode/extensions.d/*.nft >/dev/null 2>&1; then
            SH_F_EXTENSIONS="/etc/shieldnode/extensions.d/*.nft"
        fi
    fi
    log info "limits" "resolved: ssh=[$SH_F_SSH_PORTS] tcp=[$SH_F_PROTECTED_TCP] udp=[$SH_F_PROTECTED_UDP] admin4=[$SH_F_ADMIN_V4] admin6=[$SH_F_ADMIN_V6] ipv6=$SH_F_IPV6"
}

# shield_abuse_journal_append — дамп abusers/temporary_blocklist в журнал (ТЗ §24).
shield_abuse_journal_append() {
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    {
        echo "### $ts"
        local s out
        for s in ssh_abusers ssh_abusers_v6 tcp_abusers tcp_abusers_v6 udp_abusers udp_abusers_v6 temporary_blocklist temporary_blocklist_v6; do
            # 2026-09-23 (v1.1.2): вывод читаем ОДИН раз. Было `nft list set | grep -q`
            # под pipefail: на большом сете grep -q выходит на первом совпадении, nft
            # получает SIGPIPE (rc 141) -> условие ложно, и именно КРУПНЫЕ сеты молча
            # выпадали из журнала (+ двойной list каждого сета).
            out="$(nft list set inet shieldnode "$s" 2>/dev/null)" || continue
            if [[ "$out" == *elements* ]]; then
                echo "## $s"
                printf '%s\n' "$out" | grep -A100 'elements = {' | sed -e 's/^elements = {//' -e 's/}.*$//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF'
            fi
        done
    } >> "$SHIELD_ABUSE_JOURNAL"
    # ротация журнала: держим последние 10000 строк (отдельно от ротации лога)
    # 2026-09-23 (v1.1.2): уникальный tmp — журнал пишут и apply (под lock), и
    # cleanup-таймер (без lock): общий «.tmp» давал гонку truncate/mv
    local jt; jt="$(mktemp "$SHIELD_ABUSE_JOURNAL.XXXXXX" 2>/dev/null)" || return 0
    if tail -n 10000 "$SHIELD_ABUSE_JOURNAL" > "$jt" 2>/dev/null; then mv "$jt" "$SHIELD_ABUSE_JOURNAL"; else rm -f "$jt"; fi
    chmod 0640 "$SHIELD_ABUSE_JOURNAL" 2>/dev/null || true
}

# shield_cleanup_timer_install — systemd timer для журнала+сборки (ТЗ §24).
shield_cleanup_timer_install() {
    [ "$(shield_conf_get PERSIST_ENABLED 1)" = "1" ] || { log info "limits" "PERSIST_ENABLED=0 — cleanup timer пропущен"; return 0; }
    command -v systemctl >/dev/null 2>&1 || { log warn "limits" "нет systemctl — timer пропущен"; return 0; }
    local svc="$SHIELD_STATE_DIR/shieldnode-cleanup.sh"
    shield_origin_record "$svc"
    printf '%s\n' \
        '#!/bin/bash' \
        "# cleanup: abuse journal append (ТЗ §24); сгенерировано shieldnode" \
        'SHIELD_DIR="'"$SHIELD_DIR"'"' \
        'SHIELD_STATE_DIR="'"$SHIELD_STATE_DIR"'"' \
        'SHIELD_LOG="/var/log/shieldnode.log"' \
        'DRY_RUN=0' \
        "source \"$SHIELD_DIR/lib/common.sh\" 2>/dev/null || exit 0" \
        "source \"$SHIELD_DIR/config.sh\" 2>/dev/null || exit 0" \
        'CONFIG_CACHE=""' \
        "source \"$SHIELD_DIR/limits.sh\" 2>/dev/null || exit 0" \
        'shield_abuse_journal_append || true' > "$svc"
    chmod 0755 "$svc"
    shield_manifest_record "$svc"
    shield_persist_stream /etc/systemd/system/shieldnode-cleanup.service 0644 <<EOF
[Unit]
Description=shieldnode abuse journal cleanup

[Service]
Type=oneshot
ExecStart=$svc
Nice=19
IOSchedulingClass=idle
EOF
    shield_persist_stream /etc/systemd/system/shieldnode-cleanup.timer 0644 <<'EOF'
[Unit]
Description=shieldnode cleanup timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload
        systemctl enable --now shieldnode-cleanup.timer
    fi
    ok "limits" "cleanup timer installed"
}
