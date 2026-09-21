#!/bin/bash
# node — detect.sh: §7 снапшот окружения /var/lib/node/diagnostics/<ts>.txt.
set -euo pipefail

node_detect() {
    local ts snap
    ts="$(date '+%Y%m%d-%H%M%S')"
    snap="$NODE_DIAG_DIR/${ts}.txt"
    mkdir -p "$NODE_DIAG_DIR"

    {
        echo "# node diagnostics — $ts"
        echo "## system"
        uname -a
        cat /etc/os-release 2>/dev/null | head -4
        echo "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"
        echo "cpus: $(node_cpu_count)"
        awk '/MemTotal|MemAvailable/{print}' /proc/meminfo
        echo "ram_tier: T$(node_ram_tier)"
        echo
        echo "## nic"
        local ifname=""
        if command -v ip >/dev/null 2>&1; then
            ifname="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
        fi
        echo "default_iface: ${ifname:-none}"
        if [ -n "$ifname" ]; then
            echo "driver: $(basename "$(readlink -f "/sys/class/net/$ifname/device/driver" 2>/dev/null || echo none)")"
            echo "mtu: $(cat /sys/class/net/$ifname/mtu 2>/dev/null)"
            echo "queues_rx: $(ls -d /sys/class/net/"$ifname"/queues/rx-* 2>/dev/null | wc -l)"
        fi
        echo
        echo "## conntrack"
        for k in max count; do echo "nf_conntrack_$k: $(cat /proc/sys/net/netfilter/nf_conntrack_$k 2>/dev/null)"; done
        echo "hashsize: $(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null)"
        echo
        echo "## sysctl-managed-baseline (node owner keys at detect time)"
        # значения текущих наших ключей + всех потенциальных — основа точечного отката
        local keys_f="$NODE_STATE_DIR/owner-keys.txt"
        if [ -f "$keys_f" ]; then
            while read -r k; do
                [ -z "$k" ] && continue
                printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo '?')"
            done < "$keys_f"
        else
            echo "(owner-keys.txt ещё нет — первый запуск)"
        fi
        # «потенциальные» ключи — чтобы первый же apply мог их вернуть при rollback
        for k in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 \
                 net.ipv6.conf.lo.disable_ipv6 net.ipv4.tcp_congestion_control \
                 net.core.default_qdisc net.core.somaxconn \
                 net.core.netdev_budget net.ipv4.tcp_max_tw_buckets \
                 net.core.rmem_default vm.dirty_ratio \
                 net.netfilter.nf_conntrack_max; do
            printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo '?')"
        done
        echo
        echo "## environment"
        echo "docker: $(command -v docker >/dev/null 2>&1 && systemctl is-active docker 2>/dev/null || echo absent)"
        echo "irqbalance: $(systemctl is-active irqbalance 2>/dev/null || echo inactive)"
        echo "nft: $(command -v nft >/dev/null 2>&1 && echo present || echo MISSING)"
        echo "xray_units:"
        node_limits_detect_units 2>/dev/null | sed 's/^/  /' || true
        echo
        echo "## forbidden-cpu-params"
        local p found=0
        for p in idle=poll mitigations=off isolcpus nohz_full rcu_nocbs intel_idle.max_cstate=0 processor.max_cstate; do
            if grep -qw -- "$p" /proc/cmdline 2>/dev/null; then echo "  cmdline: $p"; found=1; fi
            if grep -qE "^[[:space:]]*GRUB_CMDLINE_LINUX.*${p//./\\.}" /etc/default/grub 2>/dev/null; then echo "  grub: $p"; found=1; fi
        done
        [ "$found" -eq 0 ] && echo "  none"
    } > "$snap"
    chmod 0640 "$snap"

    # ротация keep=10
    ls -1t "$NODE_DIAG_DIR"/*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f

    export NODE_LAST_SNAPSHOT="$snap"
    log info "detect" "snapshot: $snap"
}
