#!/bin/bash
# shieldnode — emergency.sh: аварийный минимальный режим (ТЗ §25).
# Цель: сохранить SSH-доступ и ничего больше не гарантировать. Отключаем ВСЕ
# политики кроме established + whitelist + SSH. Маркер /run/shieldnode/emergency.
set -euo pipefail

SHIELD_EMERGENCY_MARKER=/run/shieldnode/emergency

# shield_emergency_ruleset — минимальная таблица (stdout).
shield_emergency_ruleset() {
    local admin_v4="${SH_F_ADMIN_V4:-}" admin_v6="${SH_F_ADMIN_V6:-}" ssh_ports="${SH_F_SSH_PORTS:-22}"
    cat <<EOF
#!/usr/sbin/nft -f
# EMERGENCY mode — $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Только SSH+whitelist.
table inet shieldnode {
    set whitelist_v4 {
        type ipv4_addr
        flags interval
        auto-merge
EOF
    [ -n "$admin_v4" ] && echo "        elements = { $admin_v4 }"
    # 2026-09-23 (v1.1.4): whitelist_v6 — admin v6 резолвился, но в ruleset не попадал
    cat <<'EOF'
    }
    set whitelist_v6 {
        type ipv6_addr
        flags interval
        auto-merge
EOF
    [ -n "$admin_v6" ] && echo "        elements = { $admin_v6 }"
    cat <<'EOF'
    }
    chain prerouting {
        type filter hook prerouting priority -150; policy accept;
        # loopback ПЕРВЫМ: без него emergency режет lo → мёртвый локальный DNS
        iifname "lo" accept
        # 2026-09-25 (v1.2.0): IPv6 fail-safe и в аварийном режиме (IPv6 выключен обязательно)
        meta nfproto ipv6 drop
        ct state established,related accept
        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept
EOF
    local p
    for p in $ssh_ports; do
        echo "        tcp dport $p ct state new accept"
    done
    # 2026-10-09 (v1.2.5): VPN продолжает принимать клиентов (EMERGENCY_KEEP_VPN=1, дефолт), API ноды —
    # только панели. Раньше новые подключения к инбаундам резались тоже: авто-emergency (apply упал и
    # backup не поднялся) превращался в отказ VPN для всех новых клиентов и потерю связи с панелью.
    [ -n "${EMERG_VPN_TCP:-}" ] && echo "        tcp dport { ${EMERG_VPN_TCP// /, } } ct state new accept"
    [ -n "${EMERG_VPN_UDP:-}" ] && echo "        udp dport { ${EMERG_VPN_UDP// /, } } accept"
    [ -n "${EMERG_API_PORT:-}" ] && [ -n "${EMERG_API_ALLOW:-}" ] && echo "        tcp dport ${EMERG_API_PORT} ip saddr { ${EMERG_API_ALLOW// /, } } accept"
    cat <<'EOF'
        ip protocol tcp drop
        ip protocol udp drop
        # 2026-09-23 (v1.1.4): паритет v6 — раньше весь IPv6 TCP/UDP оставался открыт.
        # meta l4proto (а не ip6 nexthdr) — корректно и с extension headers; ICMPv6/ND не трогаем
        meta nfproto ipv6 meta l4proto { tcp, udp } drop
    }
}
EOF
}

# shield_emergency_vpn_ports — порты, которые аварийный режим оставляет открытыми (EMERG_*):
# инбаунды VPN-ядра (детект как у apply; в контексте apply — уже готовый), иначе контракт
# [shieldnode] последнего apply; API ноды — только TRUSTED_IPS + источники UFW (как в apply).
shield_emergency_vpn_ports() {
    EMERG_VPN_TCP="" EMERG_VPN_UDP="" EMERG_API_PORT="" EMERG_API_ALLOW=""
    [ "$(shield_conf_get EMERGENCY_KEEP_VPN 1)" = "1" ] || { log warn "emergency" "EMERGENCY_KEEP_VPN=0 — новые подключения к VPN тоже режутся"; return 0; }
    [ "${SH_IB_DONE:-0}" = 1 ] || { declare -F shield_detect_inbounds >/dev/null && shield_detect_inbounds >/dev/null 2>&1 || true; }
    local t="${SH_IB_TCP:-}" u="${SH_IB_UDP:-}" api="${SH_IB_API_PORT:-}" c="${SHIELD_CONTRACT:-/etc/node-profile.d/stack.conf}" p a
    if [ -z "$t$u" ] && [ -r "$c" ]; then
        t="$(awk -F= '/^\[/{s=($0=="[shieldnode]")} s && $1=="inbound_tcp"{print $2}' "$c" | tr ',' ' ')"
        u="$(awk -F= '/^\[/{s=($0=="[shieldnode]")} s && $1=="inbound_udp"{print $2}' "$c" | tr ',' ' ')"
        [ -n "$api" ] || api="$(awk -F= '/^\[/{s=($0=="[shieldnode]")} s && $1=="node_api_port"{print $2}' "$c")"
    fi
    for p in $t; do shield_port_valid "$p" && [ "$p" != "$api" ] && EMERG_VPN_TCP="$EMERG_VPN_TCP $p"; done
    for p in $u; do shield_port_valid "$p" && EMERG_VPN_UDP="$EMERG_VPN_UDP $p"; done
    if [ -n "$api" ] && shield_port_valid "$api"; then
        EMERG_API_PORT="$api"
        for a in $(shield_conf_get TRUSTED_IPS "") $(shield_detect_ufw_sources tcp "$api" 2>/dev/null); do
            case "$a" in *:*) continue ;; esac
            shield_valid_cidr "$a" || continue
            case " $EMERG_API_ALLOW " in *" $a "*) ;; *) EMERG_API_ALLOW="$EMERG_API_ALLOW $a" ;; esac
        done
    fi
    EMERG_VPN_TCP="${EMERG_VPN_TCP# }" EMERG_VPN_UDP="${EMERG_VPN_UDP# }" EMERG_API_ALLOW="${EMERG_API_ALLOW# }"
    export EMERG_VPN_TCP EMERG_VPN_UDP EMERG_API_PORT EMERG_API_ALLOW
    log warn "emergency" "VPN остаётся доступен: tcp=[${EMERG_VPN_TCP}] udp=[${EMERG_VPN_UDP}]; API ноды :${EMERG_API_PORT:-—} — только [${EMERG_API_ALLOW}]"
}

shield_emergency() {
    local action="${1:-}" reason="${2:-manual}"
    case "$action" in
        on)
            log warn "emergency" "ВКЛЮЧЁН аварийный режим ($reason): established/whitelist/SSH + инбаунды VPN, всё прочее новое — drop"
            shield_nft_available
            # резолвим минимум: SSH-порты и admin IP (если limits_resolve не отрабатывал)
            [ -z "${SH_F_SSH_PORTS:-}" ] && SH_F_SSH_PORTS="$(shield_detect_ssh_ports)"
            if [ -z "${SH_F_ADMIN_V4:-}" ] && [ -z "${SH_F_ADMIN_V6:-}" ]; then
                local a; a="$(shield_detect_admin_ip 2>/dev/null || true)"
                case "$a" in
                    ""|127.*|::1|localhost) : ;;
                    *:*) SH_F_ADMIN_V6="$a" ;;
                    *)   SH_F_ADMIN_V4="$a" ;;
                esac
            fi
            shield_emergency_vpn_ports
            local tmp bdump
            tmp="$(mktemp /run/shieldnode-emerg.XXXXXX.nft)"
            shield_emergency_ruleset > "$tmp"
            mkdir -p /run/shieldnode; shield_backup_dir_prep   # 2026-09-24 (v1.1.6): 0700/0600
            bdump="$SHIELD_BACKUP_DIR/emergency-$(date '+%Y%m%d-%H%M%S').nft"
            ( umask 077; shield_table_dump "$bdump" ) || true
            shield_backup_prune
            if [ "${DRY_RUN:-0}" != "1" ]; then
                # порядок: СНАЧАЛА проверка (таблица ещё жива), потом delete, потом apply.
                # delete решает и meter EBUSY, и дубли правил при повторном `emergency on`.
                if ! nft -c -f "$tmp"; then
                    rm -f "$tmp"
                    die "emergency: nft -c отклонил ruleset — аварийный режим НЕ включён, прежний firewall на месте"
                fi
                nft delete table inet shieldnode 2>/dev/null || true
                if ! nft -f "$tmp"; then
                    # apply после delete провалился — таблицы нет: восстанавливаем из backup
                    log error "emergency" "nft -f провалился после delete — восстановление из $bdump"
                    nft delete table inet shieldnode 2>/dev/null || true
                    if [ -s "$bdump" ] && nft -f "$bdump"; then
                        rm -f "$tmp"
                        die "emergency: apply провалился; восстановлен предыдущий ruleset (backup: $bdump)"
                    fi
                    rm -f "$tmp"
                    die "emergency: apply провалился И restore из backup тоже — firewall отсутствует (fail-open), нужен ручной доступ"
                fi
                date -u '+%Y-%m-%dT%H:%M:%SZ' > "$SHIELD_EMERGENCY_MARKER"
                echo "reason: $reason" >> "$SHIELD_EMERGENCY_MARKER"
            fi
            rm -f "$tmp"
            log warn "emergency" "маркер: $SHIELD_EMERGENCY_MARKER ; backup: $bdump"
            ;;
        off)
            log info "emergency" "выключение аварийного режима — полный apply"
            rm -f "$SHIELD_EMERGENCY_MARKER"
            # полный цикл apply (повторно соберёт детект/лимиты)
            shield_detect
            shield_limits_resolve
            shield_apply
            ;;
        status)
            if [ -f "$SHIELD_EMERGENCY_MARKER" ]; then
                echo "EMERGENCY ON since $(cat "$SHIELD_EMERGENCY_MARKER")"
            else
                echo "emergency off"
            fi
            ;;
        *)
            die "usage: shieldnode emergency on|off|status"
            ;;
    esac
}
