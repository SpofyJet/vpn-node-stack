#!/bin/bash
# node — lib/network.sh: §11 MTU/PMTU (диагностика, без авто-изменений),
# ip_forward (auto по TUN), MSS-кламп (opt-in), §17 flowtable НЕ входит.
set -euo pipefail

# MTU/PMTU диагностика — только измерение и заметка в статусе
node_network_mtu_diag() {
    [ "$(node_conf_get ENABLE_MTU_CHECK 1)" = "1" ] || return 0
    local ifname mtu gw
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && return 0
    mtu="$(cat "/sys/class/net/$ifname/mtu" 2>/dev/null || echo '?')"
    gw="$(node_default_gw)"
    log info "network" "iface=$ifname mtu=$mtu gw=${gw:-none}"
    if [[ "$mtu" =~ ^[0-9]+$ ]] && [ -n "$gw" ] && command -v ping >/dev/null 2>&1; then
        # 2026-09-24 (v1.1.6): сначала обычный ping gw (-W 1, RTT до gw < 1мс): молчащий gw
        # раньше стоил 2с на DF-пробу + 2с на ping — ~5с каждого apply на облачных VPS
        if ping -c 1 -W 1 "$gw" >/dev/null 2>&1; then
            if ping -M "do" -s $((mtu - 28)) -c 1 -W 2 "$gw" >/dev/null 2>&1; then
                ok "network" "PMTU probe ${mtu}B to gw: OK"
            else
                warn "network" "PMTU probe ${mtu}B to gw: FAIL (пакет с DF не прошёл) — проверь MTU вручную; автоматически не понижаем"
            fi
        else
            # 2026-09-24 (v1.1.5): gw не отвечает на ICMP вовсе (виртуальный on-link gw у
            # облачных провайдеров) — это не PMTU-проблема; раньше здесь был ложный FAIL.
            # Пробуем внешний хост (MTU_PROBE_TARGET, по умолчанию 1.1.1.1).
            local tgt; tgt="$(node_conf_get MTU_PROBE_TARGET 1.1.1.1)"
            if ! ping -c 1 -W 2 "$tgt" >/dev/null 2>&1; then
                log info "network" "PMTU probe: ни gw $gw, ни $tgt не отвечают на ICMP — проверка невозможна"
            elif ping -M "do" -s $((mtu - 28)) -c 1 -W 2 "$tgt" >/dev/null 2>&1; then
                ok "network" "PMTU probe ${mtu}B to $tgt: OK (gw $gw не отвечает на ICMP)"
            else
                warn "network" "PMTU probe ${mtu}B to $tgt: FAIL (пакет с DF не прошёл; gw $gw не отвечает на ICMP) — проверь MTU вручную; автоматически не понижаем"
            fi
        fi
    fi
}

node_network_plan() {
    local ipfwd
    ipfwd="$(node_conf_get IP_FORWARD "")"
    if [ -z "$ipfwd" ]; then
        # auto: 1 только если есть TUN-интерфейс (userspace-прокси Xray не требует)
        if ip -o link show type tun 2>/dev/null | grep -q .; then ipfwd=1; else ipfwd=0; fi
    fi
    [ "$ipfwd" = "1" ] && node_sysctl_add "$NODE_SYSCTL_BASE" net.ipv4.ip_forward 1
    # 2026-09-23 (v1.1.3): x2 только если softnet_stat показывает дропы backlog
    declare -F node_softnet_read >/dev/null 2>&1 && node_softnet_read
    local nmb=8192
    declare -F node_softnet_value >/dev/null 2>&1 && nmb="$(node_softnet_value NETDEV_MAX_BACKLOG 8192 drop)"
    [ "$nmb" != 8192 ] && log info "network" "softnet: dropped=${_NODE_SN_DROP} — netdev_max_backlog -> $nmb (AUTO_SOFTNET_TUNE)"
    node_sysctl_add "$NODE_SYSCTL_DATAPATH" net.core.netdev_max_backlog "$nmb"
}

node_network_mss_clamp() {
    [ "$(node_conf_get ENABLE_MSS_CLAMP 0)" = "1" ] || return 0
    local ifname mtu mss unit conf
    ifname="$(node_default_iface)"
    [ -z "$ifname" ] && { warn "network" "MSS clamp: нет default iface"; return 0; }
    mtu="$(cat "/sys/class/net/$ifname/mtu" 2>/dev/null || echo 1500)"
    [[ "$mtu" =~ ^[0-9]{3,5}$ ]] || mtu=1500
    mss="$(node_conf_get MSS_CLAMP_MTU $((mtu - 40)))"
    # 2026-09-24 (v1.1.8): значение идёт в $(( )) и в nft-правило — только число 536..9000
    # (bash вычислял бы содержимое переменной как выражение: 'x[$(cmd)]' исполнил бы cmd)
    if ! [[ "$mss" =~ ^[0-9]{3,4}$ ]] || [ "$mss" -lt 536 ] || [ "$mss" -gt 9000 ]; then
        warn "network" "MSS_CLAMP_MTU='$mss' — не число 536..9000, берём $((mtu - 40))"; mss=$((mtu - 40))
    fi
    # 2026-09-24 (v1.1.5): backlog #5 — IPv6-заголовок на 20 байт больше (40 vs 20):
    # для того же MTU v6-MSS = v4-MSS - 20 (mtu-60). Раньше v6 клампился v4-значением.
    # Поднимать MSS ядро само не даёт (nft_exthdr: только понижение) — проверено tcpdump.
    local mss6=$((mss - 20))
    conf="/etc/nftables.d/node-mss-clamp.conf"
    unit="/etc/systemd/system/node-mss-clamp.service"
    {
        echo "table inet node_mss_clamp {"
        echo "  chain forward {"
        echo "    type filter hook forward priority -150; policy accept;"
        echo "    oifname \"$ifname\" meta nfproto ipv4 tcp flags syn tcp option maxseg size set $mss"
        echo "    oifname \"$ifname\" meta nfproto ipv6 tcp flags syn tcp option maxseg size set $mss6"
        echo "  }"
        echo "  chain output {"
        echo "    type filter hook output priority -150; policy accept;"
        echo "    oifname \"$ifname\" meta nfproto ipv4 tcp flags syn tcp option maxseg size set $mss"
        echo "    oifname \"$ifname\" meta nfproto ipv6 tcp flags syn tcp option maxseg size set $mss6"
        echo "  }"
        echo "}"
    } | node_persist "$conf"
    {
        echo "[Unit]"
        echo "Description=node MSS clamp (managed by node)"
        echo "Before=network-pre.target"
        echo "After=nftables.service"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        echo "RemainAfterExit=yes"
        echo "ExecStartPre=/usr/sbin/nft -c -f $conf"
        echo "ExecStart=/usr/sbin/nft -f $conf"
        echo "ExecStop=-/usr/sbin/nft delete table inet node_mss_clamp"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } | node_persist "$unit"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        # daemon-reload может падать в chroot/контейнере — не роняем apply
        systemctl daemon-reload 2>/dev/null || warn "network" "systemctl daemon-reload не удался (chroot/контейнер?)"
        systemctl enable --now node-mss-clamp.service >/dev/null 2>&1 || \
            warn "network" "node-mss-clamp.service не поднялся (nft установлен?)"
    fi
    ok "network" "MSS clamp on: iface=$ifname mss=$mss mss6=$mss6"
}

# INTEGRATION_DOCKER=1 — единственная точка контакта с docker (opt-in)
node_network_docker_integration() {
    [ "$(node_conf_get INTEGRATION_DOCKER 0)" = "1" ] || return 0
    command -v docker >/dev/null 2>&1 || { warn "network" "INTEGRATION_DOCKER=1, но docker не найден"; return 0; }
    local dj="/etc/docker/daemon.json"
    if [ "${DRY_RUN:-0}" = "1" ]; then log info "dry-run" "docker daemon.json merge (skipped)"; return 0; fi
    [ -f "$dj" ] && backup "$dj"  # ротация по BACKUP_KEEP — единый механизм
    python3 - "$dj" <<'PY' || warn "network" "daemon.json merge failed (не тронут)"
import json, sys, os
path = sys.argv[1]
if os.path.exists(path):
    try:
        cfg = json.load(open(path))
        assert isinstance(cfg, dict)
    except Exception:
        print("daemon.json not a JSON object — not touching"); sys.exit(1)
else:
    cfg = {}
cfg["live-restore"] = True
opts = cfg.get("log-opts")
if not isinstance(opts, dict):
    opts = {"max-size": "10m", "max-file": "3"}
else:
    opts.setdefault("max-size", "10m"); opts.setdefault("max-file", "3")
cfg["log-opts"] = opts
tmp = path + ".tmp"
json.dump(cfg, open(tmp, "w"), indent=2)
os.replace(tmp, path)
print("daemon.json merged: live-restore=true, log-opts defaults (dockerd НЕ рестартован)")
PY
    warn "network" "daemon.json изменён — применится при следующем плановом рестарте dockerd (сам не рестартуем)"
}
