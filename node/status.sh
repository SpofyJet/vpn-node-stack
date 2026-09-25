#!/bin/bash
# node — status.sh: сверка «ожидаемое (auto-план) vs фактическое» + заметки.
set -euo pipefail

node_status() {
    # rebuild plan (dry, no writes)
    source "$NODE_DIR/apply.sh"          # node_rt_boot_needed (только определения)
    source "$NODE_DIR/lib/sysctl.sh";    node_sysctl_plan_init
    source "$NODE_DIR/lib/conntrack.sh"; node_conntrack_plan
    source "$NODE_DIR/lib/tcp.sh";       node_tcp_plan; node_tcp_perf_plan
    source "$NODE_DIR/lib/datapath.sh";  node_datapath_plan
    source "$NODE_DIR/lib/kernel.sh"
    source "$NODE_DIR/lib/udp.sh";       node_udp_plan
    source "$NODE_DIR/lib/network.sh";   node_network_plan
    source "$NODE_DIR/lib/limits.sh";    node_limits_plan
    source "$NODE_DIR/lib/ipv6.sh"

    echo "node v$NODE_VERSION status — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # 2026-09-23 (v1.1.4): ожидание reboot после XanMod — первым делом, заметно (stdout)
    if node_xanmod_reboot_pending; then
        node_reboot_notice "kernel: XanMod установлен ($(cut -f2 "$(node_xanmod_pending_file)" 2>/dev/null)), ОЖИДАЕТ REBOOT — активно $(uname -r). Выполни: sudo reboot" 1
    fi
    # 2026-09-25 (v1.2.0, P1-4): IPv6 — инвариант стека
    if node_ipv6_kernel_off; then echo "ipv6: выключен в ядре (ipv6.disable=1)"
    elif node_ipv6_reboot_pending; then node_reboot_notice "IPv6: ipv6.disable=1 добавлен в GRUB, активируется после reboot (сейчас выключен через sysctl)" 1
    else echo "ipv6: выключен через sysctl (ipv6.disable=1 в cmdline нет — повтори apply)"; fi
    echo "======================================================================"
    printf '%-46s %-14s %-14s %s\n' "parameter" "expected" "actual" "ok"
    echo "----------------------------------------------------------------------"
    local k v actual st
    while IFS=$'\t' read -r k v f; do
        actual="$(sysctl -n "$k" 2>/dev/null || echo '?')"
        # 2026-09-24 (v1.1.5): многозначные ключи ядро печатает через TAB, план — через пробел
        actual="${actual//$'\t'/ }"
        if [ "$actual" = "$v" ]; then st="✓"; else st="✗"; fi
        printf '%-46s %-14s %-14s %s\n' "$k" "$v" "$actual" "$st"
    done < "$NODE_PLAN_FILE"
    echo "----------------------------------------------------------------------"

    # заметки
    source "$NODE_DIR/lib/cpu.sh"; node_cpu_check
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        echo "note: docker active — node не изменяет его конфигурацию (INTEGRATION_DOCKER=$(node_conf_get INTEGRATION_DOCKER 0))"
    fi
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        echo "note: irqbalance active (node не отключает; конфликтует с ENABLE_RSS_BALANCE=1)"
    fi
    # conntrack: утилизация таблицы. Ранняя тревога задолго до «table full,
    # dropping packet» — к тому моменту новые VPN-подключения уже не встают.
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local ccnt cmax cpct
        ccnt="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
        cmax="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
        if [ "$cmax" -gt 0 ] 2>/dev/null; then
            cpct=$(( ccnt * 100 / cmax ))
            if [ "$cpct" -ge 80 ]; then
                echo "WARN: conntrack usage ${cpct}% (${ccnt}/${cmax}) — при 100% новые соединения будут дропаться; подними CONNTRACK_MAX или проверь утечки (LAST_ACK/CLOSE_WAIT)"
            else
                echo "conntrack usage: ${cpct}% (${ccnt}/${cmax})"
            fi
        fi
    fi
    if [ "$(node_conf_get ENABLE_MSS_CLAMP 0)" = "1" ]; then
        if nft list table inet node_mss_clamp >/dev/null 2>&1; then echo "note: MSS clamp: ON (inet node_mss_clamp)"; else echo "note: MSS clamp: enabled in config, table missing"; fi
    fi
    local snap
    snap="$(ls -1t "$NODE_DIAG_DIR"/*.txt 2>/dev/null | head -1 || true)"
    echo "note: last snapshot: ${snap:-none}"
    echo "note: contract: $NODE_PROFILE_DIR/stack.conf"
    echo "note: log: $NODE_LOG"

    # --- kernel/BBR/NIC-opt секция ---
    echo "----------------------------------------------------------------------"
    echo "kernel: $(uname -r) $(node_kernel_is_xanmod && echo '[XanMod]' || echo '[stock]')"
    echo "bbr: available=$(node_bbr_available && echo yes || echo no) active=$(node_bbr_active && echo yes || echo no) gen=$(node_bbr_generation) enabled_cfg=$(node_conf_get ENABLE_BBR 1)"
    echo "congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "xanmod: requested=$(node_conf_get ENABLE_XANMOD 1) cpu_level=$(node_cpu_xlevel) installed=$(dpkg -l 'linux-image*xanmod*' 2>/dev/null | awk '/^ii/{sub(/^linux-image-/, "", $2); o = o (o ? "," : "") $2} END{print o ? o : "none"}' || echo none)$( [ "$(node_bbr_generation)" = 3 ] && echo ' | BBRv3 в текущем ядре' || true)"
    # 2026-09-24 (v1.1.5): XanMod, поставленный НЕ по запросу (другим инструментом/вручную),
    # в записи GRUB по умолчанию — следующий reboot молча сменит ядро (ограничение №2)
    local gk; gk="$(node_grub_default_kernel)"
    if [ "$(node_conf_get ENABLE_XANMOD 1)" != "1" ] && [[ "$gk" == *xanmod* ]] && [ "$gk" != "$(uname -r)" ]; then
        warn "kernel" "ENABLE_XANMOD=0, но следующий reboot загрузит $gk (первая запись GRUB, GRUB_DEFAULT=0) вместо $(uname -r); node его не ставил. Нужен XanMod — ENABLE_XANMOD=1; не нужен — удали пакеты linux-*xanmod* и apt-репозиторий xanmod, затем update-grub"
    fi
    echo "perf_sysctl=$(node_conf_get ENABLE_PERFORMANCE_SYSCTL 0) nic_offload_opt=$(node_conf_get ENABLE_NIC_OFFLOAD_OPT 0) irq_affinity=$(node_conf_get ENABLE_IRQ_AFFINITY 0)"
    echo "datapath=$(node_conf_get ENABLE_DATAPATH 1) fq_tune=$(node_conf_get ENABLE_FQ_TUNE 1) busy_poll=$(node_conf_get ENABLE_BUSY_POLL 0) netdev_budget=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo '?')/$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo '?')"
    echo "runtime tweaks: $([ -f "$NODE_RT_TWEAKS" ] && wc -l < "$NODE_RT_TWEAKS" || echo 0) (откат: bash $NODE_DIR/install.sh rollback)"
    # runtime-твики и reboot-напоминание — против молчаливой потери после reboot
    if node_rt_boot_needed 2>/dev/null; then
        if systemctl is-enabled node-rt-tweaks.service >/dev/null 2>&1; then
            echo "rt boot re-apply: node-rt-tweaks.service enabled (runtime-твики переживут reboot)"
        else
            echo "rt boot re-apply: MISSING (runtime-твики испарятся после reboot — запусти apply)"
        fi
    else
        echo "rt boot re-apply: не нужен (runtime-твики выключены)"
    fi
    if { [ -f /run/node/reboot-required ] || node_xanmod_reboot_pending; } && ! node_kernel_is_xanmod; then
        echo "reboot: ТРЕБУЕТСЯ (новое ядро установлено $(cat /run/node/reboot-required 2>/dev/null), активно $(uname -r))"
    fi
    source "$NODE_DIR/lib/xray.sh"
    echo "xray/remnanode sockets: $(node_xray_sockets_summary) (по ss; конфиг не читается, ТЗ §30)"
    echo "----------------------------------------------------------------------"
    declare -F node_perf_report >/dev/null 2>&1 && node_perf_report "$NODE_STATE_DIR/perf-baseline.txt"
}
