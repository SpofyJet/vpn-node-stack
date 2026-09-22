#!/bin/bash
# shieldnode — status.sh: ожидаемое vs фактическое (read-only, ТЗ §27).
set -euo pipefail

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
        nft list chains inet shieldnode 2>/dev/null | sed 's/^/  /'
        echo
        echo "sets (elements):"
        local s elems
        for s in whitelist_v4 whitelist_v6 ssh_abusers ssh_abusers_v6 tcp_abusers tcp_abusers_v6 \
                 udp_abusers udp_abusers_v6 temporary_blocklist temporary_blocklist_v6 \
                 scanner_blocklist_v4 scanner_blocklist_v6 threat_blocklist_v4 threat_blocklist_v6 \
                 tor_exit_blocklist_v4 tor_exit_blocklist_v6 custom_blocklist_v4 custom_blocklist_v6 \
                 crowdsec_blocklist_v4 crowdsec_blocklist_v6 \
                 spamhaus_blocklist_v4 spamhaus_blocklist_v6 cins_blocklist_v4 \
                 protected_tcp protected_udp; do
            if elems="$(nft -n list set inet shieldnode "$s" 2>/dev/null | sed -n 's/.*elements = { \(.*\) }/\1/p')"; then
                [ -n "$elems" ] || elems=""
                local n; n="$(echo "$elems" | tr ',' '\n' | awk 'NF' | wc -l)"
                printf '  %-22s elements=%s\n' "$s" "$n"
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
        done < <(nft list counters inet shieldnode 2>/dev/null | sed -E 's/^counter ([a-z0-9_]+) \{ packets ([0-9]+), bytes ([0-9]+) \}.*/\1: packets=\2 bytes=\3/' | grep '^c_drops_')
        [ "$found" -eq 0 ] && echo "  (counters отсутствуют — apply не выполнялся после обновления?)"
    else
        echo "  (table отсутствует)"
    fi
    echo

    echo "--- crowdsec ---"
    if [ "${SH_F_ENABLE_CROWDSEC_LIST:-0}" = "1" ]; then
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
    echo "owner-keys: $([ -f "$SHIELD_STATE_DIR/owner-keys.txt" ] && wc -l < "$SHIELD_STATE_DIR/owner-keys.txt" || echo 0) ключей (net.netfilter.* там: $(grep -c 'netfilter' "$SHIELD_STATE_DIR/owner-keys.txt" 2>/dev/null || echo 0) — должно быть 0, §15)"
    echo "abuse journal: $([ -f "$SHIELD_STATE_DIR/abuse.journal" ] && wc -l < "$SHIELD_STATE_DIR/abuse.journal" || echo 0) строк"
    echo "nft boot file: $([ -f /etc/nftables.d/shieldnode.conf ] && echo present || echo absent)"
    echo "security sysctl: $([ -f /etc/sysctl.d/99-z5-shieldnode-security.conf ] && echo present || echo absent)"
}
