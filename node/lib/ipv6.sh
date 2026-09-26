#!/bin/bash
# node — lib/ipv6.sh: IPv6 на ноде выключен ВСЕГДА (v1.2.0, DIAGNOSIS P1-4 / E6).
#
# Требование оператора: IPv6 отключён полностью на каждой ноде; это инвариант стека, а не
# настройка оптимизатора. Поэтому модуль:
#   * не зависит от HARDEN_IPV6 (значение 0 игнорируется с предупреждением);
#   * его файлы НЕ в манифесте node — rollback/uninstall их не удаляют и IPv6 не включают;
#   * ключи disable_ipv6 не попадают в реестр исходных значений (rollback нечего «вернуть»).
# Слои (каждый закрывает дыру предыдущего):
#   1. ядро: ipv6.disable=1 в cmdline (/etc/default/grub.d/99-vpn-node-ipv6.cfg + update-grub)
#      — после reboot стека IPv6 нет вовсе; до reboot — слои 2–4;
#   2. sysctl-файл 99-zz-vpn-ipv6-off.conf: all/default/lo + каждый существующий интерфейс;
#      runtime — disable_ipv6=1 на всех интерфейсах сразу;
#   3. systemd-networkd: drop-in LinkLocalAddressing=no/IPv6AcceptRA=no для каждого .network —
#      на лабе networkd после reboot вернул enp5s0 disable_ipv6=0 и fe80:: (прод E6);
#   4. Docker: "ipv6": false в /etc/docker/daemon.json (слияние JSON, без рестарта docker);
#   5. shieldnode: fail-safe «meta nfproto ipv6 drop» в prerouting/output (другой компонент).
set -euo pipefail

NODE_IPV6_SYSCTL="${NODE_IPV6_SYSCTL:-/etc/sysctl.d/99-zz-vpn-ipv6-off.conf}"
NODE_IPV6_GRUB="${NODE_IPV6_GRUB:-/etc/default/grub.d/99-vpn-node-ipv6.cfg}"
NODE_IPV6_NETWORKD_DIR="${NODE_IPV6_NETWORKD_DIR:-/etc/systemd/network}"
NODE_IPV6_DOCKER_JSON="${NODE_IPV6_DOCKER_JSON:-/etc/docker/daemon.json}"
NODE_IPV6_PROC="${NODE_IPV6_PROC:-/proc}"
NODE_IPV6_GRUBCFG="${NODE_IPV6_GRUBCFG:-/boot/grub/grub.cfg}"
NODE_IPV6_NETWORKD_SRC="${NODE_IPV6_NETWORKD_SRC:-/run/systemd/network /etc/systemd/network /usr/lib/systemd/network}"
NODE_IPV6_RUN="${NODE_IPV6_RUN:-/run/node}"

# ключ «disable_ipv6» — инвариант (rollback/restore_dropped его не трогают)
node_key_is_ipv6_invariant() { case "$1" in net.ipv6.conf.*.disable_ipv6) return 0 ;; esac; return 1; }

# ядро загружено с ipv6.disable=1 (стека IPv6 нет)
node_ipv6_kernel_off() { grep -qw 'ipv6.disable=1' "$NODE_IPV6_PROC/cmdline" 2>/dev/null; }

# _node_ipv6_ifaces — интерфейсы с /proc/sys/net/ipv6/conf/<if> (кроме all/default)
_node_ipv6_ifaces() {
    local d
    for d in "$NODE_IPV6_PROC"/sys/net/ipv6/conf/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"; d="${d##*/}"
        case "$d" in all|default) ;; *) echo "$d" ;; esac
    done
}

# 2. sysctl: файл + runtime
node_ipv6_sysctl_enforce() {
    local tmp i n=0
    tmp="$(mktemp)"
    {
        echo "# vpn-node-stack: IPv6 выключен (инвариант стека, rollback не удаляет). Не редактировать."
        echo "net.ipv6.conf.all.disable_ipv6 = 1"
        echo "net.ipv6.conf.default.disable_ipv6 = 1"
        # имена с точкой (eth0.100) — в sysctl.d через «/»
        for i in $(_node_ipv6_ifaces); do
            [ "$i" = lo ] && { echo "net.ipv6.conf.lo.disable_ipv6 = 1"; continue; }
            case "$i" in *.*) echo "net/ipv6/conf/$i/disable_ipv6 = 1" ;; *) echo "net.ipv6.conf.$i.disable_ipv6 = 1" ;; esac
        done
    } > "$tmp"
    # без стека IPv6 (ipv6.disable=1) ключей нет — файл всё равно держим (на случай отката cmdline)
    if ! cmp -s "$tmp" "$NODE_IPV6_SYSCTL" 2>/dev/null; then
        install -m 0644 "$tmp" "$NODE_IPV6_SYSCTL"
        log info "ipv6" "записан $NODE_IPV6_SYSCTL"
    fi
    rm -f "$tmp"
    [ -d "$NODE_IPV6_PROC/sys/net/ipv6" ] || return 0
    for i in all default $(_node_ipv6_ifaces); do
        local f="$NODE_IPV6_PROC/sys/net/ipv6/conf/$i/disable_ipv6"
        [ -w "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" != 1 ]; then echo 1 > "$f" 2>/dev/null && n=$((n + 1)) || true; fi
    done
    [ "$n" -gt 0 ] && log info "ipv6" "runtime: disable_ipv6=1 выставлен на $n интерфейс(ах)"
    return 0
}

# 3. systemd-networkd: drop-in для каждого .network (netplan: /run/systemd/network/10-netplan-*.network)
node_ipv6_networkd_enforce() {
    local f name dd n=0
    local src
    for f in $(for src in $NODE_IPV6_NETWORKD_SRC; do ls -1 "$src"/*.network 2>/dev/null; done); do
        [ -f "$f" ] || continue
        name="${f##*/}"
        # только «наши» линки: у штатных шаблонов systemd (80-container-*, 99-default) — пропуск
        case "$name" in 80-*|89-*|99-default*) continue ;; esac
        dd="$NODE_IPV6_NETWORKD_DIR/$name.d"
        [ -f "$dd/90-vpn-node-ipv6-off.conf" ] && continue
        mkdir -p "$dd"
        printf '# vpn-node-stack: IPv6 выключен (инвариант стека)\n[Network]\nLinkLocalAddressing=no\nIPv6AcceptRA=no\n' \
            > "$dd/90-vpn-node-ipv6-off.conf"
        chmod 0644 "$dd/90-vpn-node-ipv6-off.conf"
        n=$((n + 1))
    done
    # networkd НЕ перезапускаем (сеть живой ноды не дёргаем): drop-in вступит при reboot /
    # переконфигурации линка; до того runtime держит слой 2
    [ "$n" -gt 0 ] && log info "ipv6" "networkd: drop-in LinkLocalAddressing=no для $n .network (вступит при reboot)"
    return 0
}

# 1. ядро: cmdline через grub.d (основной /etc/default/grub не трогаем)
node_ipv6_grub_enforce() {
    local want
    want='# vpn-node-stack: IPv6 выключен в ядре (инвариант стека, rollback не удаляет)
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX ipv6.disable=1"'
    if ! command -v update-grub >/dev/null 2>&1 || [ ! -e "$NODE_IPV6_GRUBCFG" ]; then
        node_ipv6_kernel_off || log warn "ipv6" "GRUB не найден (контейнер или другой загрузчик) — ipv6.disable=1 в cmdline не добавлен; IPv6 держат sysctl + networkd + fail-safe shieldnode"
        return 0
    fi
    if [ "$(cat "$NODE_IPV6_GRUB" 2>/dev/null)" != "$want" ] || ! grep -q 'ipv6.disable=1' "$NODE_IPV6_GRUBCFG" 2>/dev/null; then
        mkdir -p "$(dirname "$NODE_IPV6_GRUB")"
        printf '%s\n' "$want" > "$NODE_IPV6_GRUB"; chmod 0644 "$NODE_IPV6_GRUB"
        if update-grub >/dev/null 2>&1 && grep -q 'ipv6.disable=1' "$NODE_IPV6_GRUBCFG" 2>/dev/null; then
            log info "ipv6" "GRUB: ipv6.disable=1 добавлен в cmdline ядра (вступит после reboot)"
        else
            log warn "ipv6" "update-grub не добавил ipv6.disable=1 в $NODE_IPV6_GRUBCFG — проверь вручную: sudo update-grub"
            return 0
        fi
    fi
    if ! node_ipv6_kernel_off; then
        mkdir -p "$NODE_IPV6_RUN" 2>/dev/null && echo "ipv6.disable=1" > "$NODE_IPV6_RUN/reboot-required-ipv6" 2>/dev/null || true
    else
        rm -f "$NODE_IPV6_RUN/reboot-required-ipv6" 2>/dev/null || true
    fi
    return 0
}

# 4. Docker: "ipv6": false (слияние; рестарт docker не делаем — вступит при следующем старте)
node_ipv6_docker_enforce() {
    local j="$NODE_IPV6_DOCKER_JSON" rc=0
    [ -d "$(dirname "$j")" ] || return 0            # docker не установлен — его дефолт и так ipv6=false
    command -v python3 >/dev/null 2>&1 || { log warn "ipv6" "нет python3 — $j не проверен"; return 0; }
    python3 - "$j" <<'PY' || rc=$?
import json, os, sys, tempfile
p = sys.argv[1]
cur = {}
if os.path.exists(p) and os.path.getsize(p) > 0:
    try:
        cur = json.load(open(p))
    except Exception:
        sys.exit(3)
    if not isinstance(cur, dict):
        sys.exit(3)
changed = False
if cur.get("ipv6") is not False:
    cur["ipv6"] = False; changed = True
if cur.get("ip6tables") is True:
    cur["ip6tables"] = False; changed = True
if not changed:
    sys.exit(0)
if os.path.exists(p):
    import shutil; shutil.copy2(p, p + ".pre-vpn-node")
fd, t = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(cur, f, indent=2); f.write("\n")
os.chmod(t, 0o644); os.replace(t, p)
sys.exit(10)
PY
    case "$rc" in
        0) ;;
        10) log info "ipv6" "docker: \"ipv6\": false записан в $j (вступит при следующем старте docker; рестарт не делаем)" ;;
        3) log warn "ipv6" "$j — невалидный JSON, не трогаем (docker его тоже не прочитает — проверь)" ;;
        *) log warn "ipv6" "$j не обновлён (rc=$rc)" ;;
    esac
    return 0
}

# node_ipv6_enforce — все слои; идемпотентно; ничего не перезапускает
node_ipv6_enforce() {
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "ipv6: would enforce (cmdline, sysctl, networkd, docker)"; return 0; }
    if [ "$(node_conf_get HARDEN_IPV6 1)" = "0" ]; then
        log warn "ipv6" "HARDEN_IPV6=0 игнорируется: IPv6 на нодах выключен всегда (требование стека)"
    fi
    node_ipv6_sysctl_enforce
    node_ipv6_networkd_enforce
    node_ipv6_grub_enforce
    node_ipv6_docker_enforce
    ok "ipv6" "IPv6 выключен: $(node_ipv6_kernel_off && echo 'в ядре (ipv6.disable=1)' || echo 'sysctl на всех интерфейсах; ipv6.disable=1 — после reboot')"
}

# node_ipv6_reboot_pending — cmdline ещё без ipv6.disable=1, а GRUB уже настроен
node_ipv6_reboot_pending() {
    node_ipv6_kernel_off && return 1
    [ -f "$NODE_IPV6_GRUB" ] && grep -q 'ipv6.disable=1' "$NODE_IPV6_GRUBCFG" 2>/dev/null
}
