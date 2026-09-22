#!/bin/bash
# shieldnode — guard.sh: «пульт управления» — одна команда `guard`, read-only.
# Дашборд: состояние firewall, drop-counters (+дельты с прошлого запуска),
# наполненность наборов, conntrack (только чтение, владелец node), службы,
# алерты updater'а, быстрые проверки SSH. Ничего не пишет в nft/sysctl;
# единственная запись — снапшот счётчиков в state для дельт.
set -euo pipefail

SHIELD_GUARD_SNAPSHOT="${SHIELD_GUARD_SNAPSHOT:-$SHIELD_STATE_DIR/guard-snapshot.tsv}"

# --- счётчики: <name> <packets> <bytes> ---
guard_counters() {
    nft list counters inet shieldnode 2>/dev/null | \
        sed -E 's/^counter ([a-z0-9_]+) \{ packets ([0-9]+), bytes ([0-9]+) \}.*/\1 \2 \3/' | \
        awk 'NF==3' || true
}

# --- наборы: <name> <elements> (0 при недоступности) ---
guard_set_elems() {
    local s="$1" out
    out="$(nft -n list set inet shieldnode "$s" 2>/dev/null | sed -n 's/.*elements = { \(.*\) }/\1/p' || true)"
    if [ -z "$out" ]; then echo 0; else echo "$out" | tr ',' '\n' | awk 'NF' | wc -l; fi
}

shield_guard() {
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "guard — shieldnode v$SHIELD_VERSION — $now"
    echo "==============================================================="

    # --- 1) состояние firewall ---
    local fw_state="ABSENT"
    if nft list table inet shieldnode >/dev/null 2>&1; then
        fw_state="ACTIVE"
        [ -f /run/shieldnode/emergency ] && fw_state="EMERGENCY"
    fi
    local host up
    host="$(hostname 2>/dev/null || echo '?')"
    up="$(awk '{printf "%dd %02d:%02d", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime 2>/dev/null || echo '?')"
    printf 'host: %-24s uptime: %s\n' "$host" "$up"
    printf 'firewall: %s\n' "$fw_state"
    [ "$fw_state" = "EMERGENCY" ] && echo '  !!! аварийный режим: только established/whitelist/SSH — "shieldnode emergency off" для выхода'
    echo

    # --- 2) drop-counters + дельты ---
    echo "--- drop counters (packets, delta с прошлого guard) ---"
    local prev_ts=0 now_ts; now_ts="$(date +%s)"
    local -A prev_p=()
    if [ -f "$SHIELD_GUARD_SNAPSHOT" ]; then
        prev_ts="$(head -1 "$SHIELD_GUARD_SNAPSHOT" 2>/dev/null || echo 0)"
        while read -r n p _b; do prev_p[$n]="$p"; done < <(tail -n +2 "$SHIELD_GUARD_SNAPSHOT" 2>/dev/null || true)
    fi
    local dt=$(( now_ts - prev_ts )); [ "$dt" -le 0 ] && dt=0
    local total_lines
    total_lines="$(guard_counters | wc -l)"
    if [ "$total_lines" -eq 0 ]; then
        echo "  (нет счётчиков — firewall не применён?)"
    else
        guard_counters | sort -k2,2nr | while read -r name packets bytes; do
            local d="-"
            if [ "$dt" -gt 0 ] && [ -n "${prev_p[$name]:-}" ]; then
                d="+$(( (packets - prev_p[$name]) / dt ))/s"
            fi
            printf '  %-26s %12s pkts  %18s bytes  %s\n' "$name" "$packets" "$bytes" "$d"
        done
        # ненулевые vs нулевые: сводка
        local nonzero
        nonzero="$(guard_counters | awk '$2>0' | wc -l)"
        if [ "$dt" -gt 0 ]; then
            echo "  --- $nonzero/$total_lines счётчиков ненулевые (дельта за ${dt}s) ---"
        else
            echo "  --- $nonzero/$total_lines счётчиков ненулевые ---"
        fi
        # снапшот для следующего запуска — только при живом firewall
        { echo "$now_ts"; guard_counters; } > "$SHIELD_GUARD_SNAPSHOT.tmp" 2>/dev/null \
            && mv "$SHIELD_GUARD_SNAPSHOT.tmp" "$SHIELD_GUARD_SNAPSHOT" 2>/dev/null || true
    fi
    echo

    # --- 3) наполненность наборов ---
    echo "--- sets (elements) ---"
    local s elems
    for s in whitelist_v4 whitelist_v6 ssh_abusers ssh_abusers_v6 tcp_abusers tcp_abusers_v6 \
             udp_abusers udp_abusers_v6 temporary_blocklist temporary_blocklist_v6 \
             scanner_blocklist_v4 scanner_blocklist_v6 threat_blocklist_v4 threat_blocklist_v6 \
             tor_exit_blocklist_v4 tor_exit_blocklist_v6 custom_blocklist_v4 custom_blocklist_v6 \
             crowdsec_blocklist_v4 crowdsec_blocklist_v6 spamhaus_blocklist_v4 spamhaus_blocklist_v6 \
             cins_blocklist_v4 protected_tcp protected_udp; do
        if elems="$(guard_set_elems "$s")"; then
            [ "$elems" -gt 0 ] || [ "$s" != "${s#whitelist}" ] || continue
            [ "$elems" -gt 0 ] || [ "$s" != "${s#protected}" ] || continue
            [ "$elems" -gt 0 ] || case "$s" in crowdsec_*|tor_*) continue ;; esac
            printf '  %-26s %s\n' "$s" "$elems"
        fi
    done
    echo

    # --- 4) conntrack: ТОЛЬКО чтение (владелец — node, §15) ---
    echo "--- conntrack (read-only, владелец node) ---"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local ccnt cmax cpct
        ccnt="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
        cmax="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
        cpct=$(( ccnt * 100 / cmax ))
        printf '  usage: %s%% (%s / %s)%s\n' "$cpct" "$ccnt" "$cmax" \
            "$([ "$cpct" -ge 80 ] && echo '  !!! >=80% — при 100% новые соединения дропаются')"
    else
        echo "  (nf_conntrack не доступен — модуль не загружен?)"
    fi
    echo

    # --- 5) службы ---
    echo "--- services ---"
    local svc st
    for svc in shieldnode.service shieldnode-blocklist.timer shieldnode-blocklist-custom.path; do
        if st="$(systemctl is-active "$svc" 2>/dev/null)"; then
            printf '  %-34s %s\n' "$svc" "$st"
        else
            printf '  %-34s %s\n' "$svc" "not-found"
        fi
    done
    # последний прогон updater'а по снапшотам списков
    local lg
    lg="$(ls -1t "$SHIELD_STATE_DIR"/blocklists/last-good-*.txt 2>/dev/null | head -1 || true)"
    [ -n "$lg" ] && printf '  %-34s %s\n' "last blocklist update" "$(basename "$lg") ($(date -r "$lg" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))"
    echo

    # --- 6) алерты updater'а (stale-фиды, fail counters) ---
    echo "--- updater alerts ---"
    local alerts=0 a f
    for f in "$SHIELD_STATE_DIR"/blocklists/.alert-*; do
        [ -e "$f" ] || continue
        printf '  STALE: %s (since %s)\n' "$(basename "$f" | sed 's/^\.alert-//')" "$(cat "$f" 2>/dev/null || echo '?')"
        alerts=$((alerts+1))
    done
    for f in "$SHIELD_STATE_DIR"/blocklists/fails-*.cnt; do
        [ -e "$f" ] || continue
        local n; n="$(cat "$f" 2>/dev/null || echo 0)"
        [ "$n" -gt 0 ] && { printf '  FAILS: %s = %s подряд\n' "$(basename "$f" | sed 's/^fails-//;s/\.cnt$//')" "$n"; alerts=$((alerts+1)); }
    done
    [ "$alerts" -eq 0 ] && echo "  none"
    echo

    # --- 7) быстрые проверки ---
    echo "--- quick checks ---"
    # sshd слушает?
    local ssh_port; ssh_port="$(shield_conf_get SSH_PORT "")"
    [ -z "$ssh_port" ] && ssh_port="$(shield_detect_ssh_ports 2>/dev/null | awk '{print $1}')" || true
    [ -z "$ssh_port" ] && ssh_port=22
    # pipefail-безопасно: сначала захват вывода, потом grep по переменной
    # (grep -q в пайпе закрывает pipe досрочно → SIGPIPE → ложный FAIL)
    local ss_out=""; command -v ss >/dev/null 2>&1 && ss_out="$(ss -tlnp 2>/dev/null || true)"
    if grep -q ":$ssh_port " <<<"$ss_out"; then
        printf '  sshd: слушает порт %s\n' "$ssh_port"
    else
        printf '  sshd: порт %s НЕ найден в ss — проверь вручную!\n' "$ssh_port"
    fi
    # admin в whitelist-сете?
    local admin_ip; admin_ip="$(shield_detect_admin_ip 2>/dev/null || true)"
    if [ -n "$admin_ip" ]; then
        local wl_out; wl_out="$(nft list set inet shieldnode whitelist_v4 2>/dev/null || true)"
        if grep -q "$admin_ip" <<<"$wl_out"; then
            printf '  admin-ip: %s в whitelist_v4 ✓\n' "$admin_ip"
        else
            printf '  admin-ip: %s НЕ в whitelist_v4 (риск lockout при apply!)\n' "$admin_ip"
        fi
    fi
    # loopback-правило на месте?
    local pr_out; pr_out="$(nft list chain inet shieldnode prerouting 2>/dev/null || true)"
    if grep -q 'iifname "lo" accept' <<<"$pr_out"; then
        echo "  loopback-accept: ✓"
    else
        echo "  loopback-accept: ОТСУТСТВУЕТ"
    fi
    echo
    echo "справка: shieldnode status | shieldnode emergency on|off | shieldnode rollback"
}
