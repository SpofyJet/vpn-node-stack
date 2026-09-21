#!/bin/bash
# shieldnode — emergency.sh: аварийный минимальный режим (ТЗ §25).
# Цель: сохранить SSH-доступ и ничего больше не гарантировать. Отключаем ВСЕ
# политики кроме established + whitelist + SSH. Маркер /run/shieldnode/emergency.
set -euo pipefail

SHIELD_EMERGENCY_MARKER=/run/shieldnode/emergency

# shield_emergency_ruleset — минимальная таблица (stdout).
shield_emergency_ruleset() {
    local admin_v4="${SH_F_ADMIN_V4:-}" ssh_ports="${SH_F_SSH_PORTS:-22}"
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
    cat <<'EOF'
    }
    chain prerouting {
        type filter hook prerouting priority -150; policy accept;
        ct state established,related accept
        ip saddr @whitelist_v4 accept
EOF
    local p
    for p in $ssh_ports; do
        echo "        tcp dport $p ct state new accept"
    done
    cat <<'EOF'
        ip protocol tcp drop
        ip protocol udp drop
    }
}
EOF
}

shield_emergency() {
    local action="${1:-}" reason="${2:-manual}"
    case "$action" in
        on)
            log warn "emergency" "ВКЛЮЧЁН аварийный режим ($reason): только established/whitelist/SSH"
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
            local tmp bdump
            tmp="$(mktemp /run/shieldnode-emerg.XXXXXX.nft)"
            shield_emergency_ruleset > "$tmp"
            mkdir -p "$SHIELD_BACKUP_DIR" /run/shieldnode
            bdump="$SHIELD_BACKUP_DIR/emergency-$(date '+%Y%m%d-%H%M%S').nft"
            shield_table_dump "$bdump" || true
            if [ "${DRY_RUN:-0}" != "1" ]; then
                nft destroy table inet shieldnode 2>/dev/null || true
                nft -c -f "$tmp" && nft -f "$tmp"
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
