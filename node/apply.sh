#!/bin/bash
# node — apply.sh: оркестрация модулей → persist → self-test → контракт стека.
set -euo pipefail

# node_persist <dst> — backup + atomic write stdin (индирекция; persist.sh может перезаписать)
node_persist() {
    node_persist_stream "$1"
}

node_contract_write() {
    local conf="$NODE_PROFILE_DIR/stack.conf"
    local tmp
    mkdir -p "$NODE_PROFILE_DIR" 2>/dev/null || true
    # mktemp в том же каталоге: mv атомарен только внутри одной ФС (/tmp часто tmpfs)
    tmp="$(mktemp "$NODE_PROFILE_DIR/.stack.conf.XXXXXX")"
    {
        if [ -f "$conf" ]; then
            awk '/^\[node\]/{skip=1; next} /^\[/{skip=0} !skip' "$conf"
        fi
        echo "[node]"
        echo "version=$NODE_VERSION"
        echo "updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "kernel=$(uname -r)"
        echo "ram_tier=T$(node_ram_tier)"
        echo "conntrack_max=${NODE_CONNTRACK_MAX:-unknown}"
        echo "mss_clamp=$(node_conf_get ENABLE_MSS_CLAMP 0)"
        echo "docker_integration=$(node_conf_get INTEGRATION_DOCKER 0)"
        echo "bbr=$(node_bbr_active && echo active || echo inactive)"
        echo "xanmod_requested=$(node_conf_get ENABLE_XANMOD 0)"
        echo "perf_sysctl=$(node_conf_get ENABLE_PERFORMANCE_SYSCTL 0)"
        echo "datapath=$(node_conf_get ENABLE_DATAPATH 1),fq_tune:$(node_conf_get ENABLE_FQ_TUNE 1),busy_poll:$(node_conf_get ENABLE_BUSY_POLL 0)"
        echo "nic_offload_opt=$(node_conf_get ENABLE_NIC_OFFLOAD_OPT 0)"
        echo "irq_affinity=$(node_conf_get ENABLE_IRQ_AFFINITY 0)"
        echo "ipv6_disabled=$(node_conf_get HARDEN_IPV6 1)"
        echo "hardening=bg:$(node_conf_get HARDEN_BG_SERVICES 1),unattended:$(node_conf_get HARDEN_UNATTENDED 1),packagekit:$(node_conf_get HARDEN_PACKAGEKIT 1),irqbalance:$(node_conf_get HARDEN_IRQBALANCE 1),rpcbind:$(node_conf_get HARDEN_RPCBIND 1),kdump:$(node_conf_get HARDEN_KDUMP 1),mta:$(node_conf_get HARDEN_MTA 0),snapd:$(node_conf_get HARDEN_SNAPD 0),thp:$(node_conf_get HARDEN_THP 1),sched_none:$(node_conf_get HARDEN_SCHED_NONE 1),noatime:$(node_conf_get HARDEN_NOATIME 1),low_latency_nic=$(node_conf_get ENABLE_LOW_LATENCY_NIC 0)"
        echo "owner_keys=$NODE_STATE_DIR/owner-keys.txt"
        echo "diagnostics=${NODE_LAST_SNAPSHOT:-none}"
    } > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$conf"
    ok "contract" "stack.conf [node] written"
}

node_apply() {
    local snapshot_before
    snapshot_before="$NODE_LAST_SNAPSHOT"

    log info "apply" "=== dry-run report ==="
    # ---- plan ----
    source "$NODE_DIR/lib/sysctl.sh";    node_sysctl_plan_init
    source "$NODE_DIR/lib/conntrack.sh"; node_conntrack_plan
    source "$NODE_DIR/lib/tcp.sh";       node_tcp_plan; node_tcp_perf_plan
    source "$NODE_DIR/lib/datapath.sh";  node_datapath_plan
    source "$NODE_DIR/lib/kernel.sh";    node_bbr_plan
    source "$NODE_DIR/lib/udp.sh";       node_udp_plan
    source "$NODE_DIR/lib/network.sh";   node_network_plan
    source "$NODE_DIR/lib/limits.sh";    node_limits_plan
    source "$NODE_DIR/lib/services.sh";  node_services_plan; node_harden_ipv6
    source "$NODE_DIR/lib/storage.sh";   node_storage_plan
    source "$NODE_DIR/lib/nic.sh"        # node_nic_* (диагностика обязательна §12)
    source "$NODE_DIR/lib/irq.sh"        # node_irq_*
    source "$NODE_DIR/lib/cpu.sh"        # node_cpu_check
    source "$NODE_DIR/lib/xray.sh"

    log info "apply" "sysctl keys planned: $(wc -l < "$NODE_PLAN_FILE")"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        # column — из bsdmainutils/util-linux, на минимальных образах может отсутствовать
        if command -v column >/dev/null 2>&1; then
            column -t -s$'\t' "$NODE_PLAN_FILE" | sed 's/^/  /'
        else
            sed 's/^/  /' "$NODE_PLAN_FILE"
        fi
        log info "apply" "--dry-run: запись не выполнялась"
        return 0
    fi

    # ---- xray metadata before ----
    node_xray_snapshot_meta "$NODE_XRAY_META_BEFORE"

    # ---- persist + apply ----
    # rc-аккумуляция: один упавший модуль (напр. systemctl daemon-reload в
    # chroot/контейнере) не должен ронять весь apply — фиксируем, продолжаем,
    # отчёт и ненулевой exit — в конце. Критичные этапы (sysctl write/apply,
    # self-test, контракт) остаются фатальными по текущей логике проекта.
    local rc=0 failed_steps=""
    node_run_step() { # <имя> <команда...> — subshell: set -e внутри шага работает, rc копим снаружи
        local name="$1"; shift
        ( "$@" ) || { rc=$((rc+1)); failed_steps+=" $name"; log error "apply" "шаг '$name' завершился с ошибкой — продолжаем, итог в конце"; }
    }

    ( node_conntrack_ensure_module ) || { rc=$((rc+1)); failed_steps+=" conntrack_ensure_module"; log error "apply" "шаг 'conntrack_ensure_module' завершился с ошибкой — продолжаем, итог в конце"; }  # до sysctl: nf_conntrack_max требует загруженного модуля
    node_sysctl_write
    node_sysctl_apply
    node_run_step conntrack_persist        node_conntrack_persist
    node_run_step conntrack_apply          node_conntrack_apply
    node_run_step services_apply           node_services_apply   # irqbalance выключаем ДО ручной IRQ-affinity
    node_run_step storage_apply            node_storage_apply
    node_run_step limits_persist           node_limits_persist

    node_run_step nic_diag                 node_nic_diag
    node_run_step nic_apply_rings          node_nic_apply_rings
    node_run_step nic_opt_apply            node_nic_opt_apply
    node_run_step nic_lro_off              node_nic_lro_off
    node_run_step nic_low_latency          node_nic_low_latency
    node_run_step irq_diag                 node_irq_diag
    node_run_step irq_apply                node_irq_apply
    node_run_step irq_affinity_apply       node_irq_affinity_apply
    node_run_step cpu_check                node_cpu_check
    node_run_step network_mtu_diag         node_network_mtu_diag
    node_run_step network_mss_clamp        node_network_mss_clamp
    node_run_step network_docker           node_network_docker_integration
    node_run_step fq_tune_apply            node_fq_tune_apply
    node_run_step xanmod_install           node_xanmod_install
    node_run_step logrotate_persist        node_logrotate_persist
    node_run_step rt_boot_persist          node_rt_boot_persist

    node_run_step sysctl_owner_dump        node_sysctl_owner_dump

    # ---- self-test ----
    node_self_test "$snapshot_before"

    node_contract_write
    if [ "$rc" -gt 0 ]; then
        die "apply завершён с ошибками в $rc модуле(ях):${failed_steps}. Система частично применена — смотри $NODE_LOG; при необходимости: bash install.sh rollback"
    fi
    ok "apply" "apply завершён. status: bash install.sh status"
}

node_self_test() {
    local snapshot_before="$1" fails=0
    log info "selftest" "=== self-test ==="

    # 1. sysctl файлы парсятся и значения соответствуют плану
    local f
    for f in "${NODE_SYSCTL_FILES[@]}"; do
        [ -f "$f" ] || continue
        if ! sysctl -p "$f" >/dev/null 2>&1; then warn "selftest" "FAIL: $f не парсится"; fails=$((fails+1)); fi
    done

    # 2. ключи применились фактически (выборочно: conntrack_max, somaxconn)
    local k v exp
    while IFS=$'\t' read -r k v f; do
        case "$k" in
            net.netfilter.nf_conntrack_max|net.core.somaxconn|net.ipv4.tcp_max_syn_backlog|net.ipv6.conf.all.disable_ipv6|net.core.netdev_budget)
                exp="$(sysctl -n "$k" 2>/dev/null)"
                if [ "$exp" != "$v" ]; then warn "selftest" "FAIL: $k=$exp ожидалось $v"; fails=$((fails+1)); fi
                ;;
        esac
    done < "$NODE_PLAN_FILE"

    # 3. shieldnode не владеет conntrack (перекрёстная проверка §15)
    if [ -f /var/lib/shieldnode/owner-keys.txt ] && grep -q '^net\.netfilter\.' /var/lib/shieldnode/owner-keys.txt; then
        warn "selftest" "FAIL: реестр shieldnode содержит net.netfilter.* ключи"; fails=$((fails+1))
    fi

    # 4. Xray неизменён и слушает
    if ! node_xray_verify_unchanged; then fails=$((fails+1)); fi

    # 5. SSH reachable via loopback (анти-локаут, информативно — node не рулит фаервол)
    local ssh_port=22
    ssh_port="$(ss -tlnp 2>/dev/null | awk '/sshd/{split($4,a,":"); print a[length(a)]; exit}' | grep -E '^[0-9]+$' || echo 22)"
    if command -v timeout >/dev/null && timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$ssh_port" 2>/dev/null; then
        ok "selftest" "sshd reachable on 127.0.0.1:$ssh_port"
    else
        warn "selftest" "sshd на 127.0.0.1:$ssh_port не отвечает (не критично для node, проверь)"
    fi

    # 6. снапшот существует
    [ -n "$snapshot_before" ] && [ -f "$snapshot_before" ] || { warn "selftest" "FAIL: снапшот детекта не найден"; fails=$((fails+1)); }

    if [ "$fails" -gt 0 ]; then
        die "self-test: $fails провалов — выполни rollback: bash install.sh rollback"
    fi
    ok "selftest" "all checks passed"
}

# ---------- runtime-твики: boot re-apply (переживаемость reboot) ----------
# Сильные режимы (rings/offloads/RPS/XPS/IRQ-affinity/fq-tune/mss) применяются
# runtime. Без этой службы они молча испарялись бы после reboot: unit
# перезапускает ТОЛЬКО runtime-функции (sysctl-файлы — на диске, их systemd
# применяет сам). Диспетчеризация: bash install.sh rt-reapply.

node_rt_boot_needed() {
    [ -n "$(node_conf_get NIC_RING_RX "")" ] && return 0
    [ -n "$(node_conf_get NIC_RING_TX "")" ] && return 0
    [ "$(node_conf_get ENABLE_NIC_OFFLOAD_OPT 0)" = "1" ] && return 0
    [ "$(node_conf_get ENABLE_RSS_BALANCE 0)"    = "1" ] && return 0
    [ "$(node_conf_get ENABLE_RPS 0)"            = "1" ] && return 0
    [ "$(node_conf_get ENABLE_XPS 0)"            = "1" ] && return 0
    [ "$(node_conf_get ENABLE_IRQ_AFFINITY 0)"   = "1" ] && return 0
    [ "$(node_conf_get ENABLE_FQ_TUNE 1)"        = "1" ] && return 0
    [ "$(node_conf_get ENABLE_MSS_CLAMP 0)"      = "1" ] && return 0
    return 1
}

node_logrotate_persist() {
    {
        echo "# node — ротация лога (managed by node)"
        echo "$NODE_LOG {"
        echo "    size 10M"
        echo "    rotate 4"
        echo "    compress"
        echo "    missingok"
        echo "    notifempty"
        echo "    copytruncate   # демон-переоткрытие лога не предусмотрено; race окна микроскопичны при нашем rate"
        echo "}"
    } | node_persist /etc/logrotate.d/node
}

node_rt_boot_persist() {
    local script="${NODE_RT_SCRIPT:-/usr/local/sbin/node-rt-tweaks.sh}" unit="${NODE_RT_UNIT:-/etc/systemd/system/node-rt-tweaks.service}" udev="${NODE_UDEV_RULE:-/etc/udev/rules.d/99-node-rt-hotplug.rules}"
    if ! node_rt_boot_needed; then
        # disable/rm на несуществующем unit безвредны — guard по файлу не нужен
        if [ "${DRY_RUN:-0}" != "1" ]; then
            systemctl disable --now node-rt-tweaks.service >/dev/null 2>&1 || true
            rm -f "$unit" "$script" "$udev" 2>/dev/null || true
            udevadm control --reload >/dev/null 2>&1 || true
            log info "rt" "node-rt-tweaks.service удалён (все runtime-твики выключены в конфиге)"
        fi
        return 0
    fi
    {
        echo '# node — re-apply runtime tweaks at boot (generated, managed by node; do not edit)'
        echo "cd '$NODE_DIR' && exec bash install.sh rt-reapply"
    } | node_persist "$script"
    chmod 0755 "$script" 2>/dev/null || true
    {
        echo "[Unit]"
        echo "Description=node runtime tweaks re-apply (managed by node)"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        echo "RemainAfterExit=yes"
        echo "ExecStart=$script"
        echo "NoNewPrivileges=yes"
        echo "ProtectSystem=strict"
        echo "ProtectHome=yes"
        echo "PrivateTmp=yes"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } | node_persist "$unit"
    # hotplug: новый NIC (virtio hot-add, USB-ethernet, sriov-vf) после boot
    # не получит rings/offloads/RPS/XPS. SYSTEMD_WANTS ловит add-ивент до
    # multi-user; для уже активного (RemainAfterExit) unit повторный триггер
    # не перезапустит его — поэтому RUN+=restart: твики идемпотентны, повторный
    # прогон дёшев. Правило ловит ЛЮБОЙ net-add, не только дефолтный iface —
    # tun/tap VPN-тоже (хуже не будет, persist-записи только по реальным iface).
    {
        echo '# node — re-apply runtime tweaks on NIC hotplug (managed by node; do not edit)'
        echo 'ACTION=="add", SUBSYSTEM=="net", TAG+="systemd", ENV{SYSTEMD_WANTS}="node-rt-tweaks.service", RUN+="/bin/systemctl restart node-rt-tweaks.service"'
    } | node_persist "$udev"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        udevadm control --reload >/dev/null 2>&1 || true
        systemctl enable node-rt-tweaks.service >/dev/null 2>&1 \
            && ok "rt" "node-rt-tweaks.service: runtime-твики переживут reboot и hotplug NIC" \
            || warn "rt" "systemctl enable node-rt-tweaks.service не удался"
    else
        log info "dry-run" "rt: would enable node-rt-tweaks.service + udev hotplug rule"
    fi
}

node_rt_reapply() {
    log info "rt" "=== rt-reapply: только runtime-твики (sysctl-файлы не трогаем) ==="
    # main.sh в режиме rt-reapply подключает ТОЛЬКО apply.sh — persist.sh здесь
    # не засурсен, и node_persist падал бы с «node_persist_stream: command not
    # found» на node_fq_tune_apply. Подключаем явно (идемпотентно).
    # shellcheck source=persist.sh
    if [ -f "$NODE_DIR/persist.sh" ]; then
        source "$NODE_DIR/persist.sh"
    else
        warn "rt" "$NODE_DIR/persist.sh не найден — persist-записи будут пропущены с ошибкой"
    fi
    source "$NODE_DIR/lib/sysctl.sh"
    source "$NODE_DIR/lib/conntrack.sh"
    source "$NODE_DIR/lib/nic.sh"
    source "$NODE_DIR/lib/irq.sh"
    source "$NODE_DIR/lib/network.sh"
    source "$NODE_DIR/lib/datapath.sh"
    # conntrack_plan НЕ вызывался → NODE_CONNTRACK_HASHSIZE был unbound (set -u)
    # на node_conntrack_apply. План здесь только вычисляет значения (sysctl-файлы
    # не трогаем — plan_init пишет во временный файл плана).
    node_sysctl_plan_init
    node_conntrack_plan
    node_conntrack_ensure_module
    node_conntrack_apply
    node_nic_apply_rings
    node_nic_opt_apply
    node_nic_lro_off
    node_nic_low_latency
    node_irq_apply
    node_irq_affinity_apply
    node_network_mss_clamp
    node_fq_tune_apply
    ok "rt" "rt-reapply завершён"
}
