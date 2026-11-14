#!/bin/bash
# node — lib/boot.sh: загрузка сервера — предел ожидания сети (v1.2.12, 2026-11-14).
#
# systemd-networkd-wait-online держит network-online.target (а за ним docker и ноду), пока ВСЕ
# интерфейсы networkd не настроены, — до 120 с. Стек выключает IPv6 в ядре (lib/ipv6.sh); если у
# хостера в netplan прописан IPv6, networkd после перезагрузки помечает интерфейс «failed» и
# служба висит весь таймаут: две ноды начинали принимать клиентов через 127–134 с после загрузки,
# остальные — через 5–14 с (замер 14.11).
#
# Решение: drop-in с пределом BOOT_NET_WAIT_SEC и «--any -o routable» — ждать, пока хотя бы
# один интерфейс получит маршрутизируемый адрес, но не дольше предела. Действует только на
# следующую загрузку: работающую сеть и службы не трогаем, daemon-reload — только при изменении.
# Файл в манифесте node: rollback его удаляет.
set -euo pipefail

NODE_WAIT_ONLINE_UNIT="systemd-networkd-wait-online.service"
NODE_WAIT_ONLINE_DROPIN="${NODE_WAIT_ONLINE_DROPIN:-/etc/systemd/system/systemd-networkd-wait-online.service.d/90-node-timeout.conf}"

# node_boot_net_wait_sec — BOOT_NET_WAIT_SEC: 0 (не ограничивать) или 1..120; мусор -> 10.
# Значение уходит в ExecStart чужого юнита — только число.
node_boot_net_wait_sec() {
    local v; v="$(node_conf_get BOOT_NET_WAIT_SEC 10)"
    if [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$v))" -le 120 ]; then
        echo "$((10#$v))"
    else
        warn "boot" "BOOT_NET_WAIT_SEC='$v' — нужно целое 0..120 (0 = не ограничивать), берём 10"
        echo 10
    fi
}

# путь к systemd-networkd-wait-online (Ubuntu 24.04: /usr/lib/systemd, раньше — /lib/systemd)
node_boot_net_wait_bin() {
    local b
    for b in ${NODE_WAIT_ONLINE_BIN:-/usr/lib/systemd/systemd-networkd-wait-online /lib/systemd/systemd-networkd-wait-online}; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}

# юнит включён — иначе ограничивать нечего (сеть через ifupdown / NetworkManager)
node_boot_net_wait_enabled() {
    local st
    st="$(systemctl is-enabled "$NODE_WAIT_ONLINE_UNIT" 2>/dev/null | head -1)" || true
    case "$st" in enabled|enabled-runtime) return 0 ;; esac
    return 1
}

node_boot_net_wait_plan() {
    local sec; sec="$(node_boot_net_wait_sec 2>/dev/null)"
    if [ "$sec" = 0 ]; then
        log info "boot" "plan: BOOT_NET_WAIT_SEC=0 — ожидание сети при загрузке не ограничиваем"
    else
        log info "boot" "plan: ожидание сети при загрузке — не дольше $sec с (BOOT_NET_WAIT_SEC; drop-in $NODE_WAIT_ONLINE_UNIT)"
    fi
}

# _node_boot_dropin_sig — отпечаток drop-in (нет файла — «none»): daemon-reload только при изменении
_node_boot_dropin_sig() { if [ -f "$NODE_WAIT_ONLINE_DROPIN" ]; then cksum < "$NODE_WAIT_ONLINE_DROPIN"; else echo none; fi; }

# _node_boot_dropin_remove <причина> — убрать СВОЙ drop-in (создан node по реестру происхождения)
_node_boot_dropin_remove() {
    local f="$NODE_WAIT_ONLINE_DROPIN" reg="$NODE_STATE_DIR/file-origins.tsv"
    [ -f "$f" ] || return 0
    if awk -F'\t' -v p="$f" '$1 == p && $2 == "created" { f = 1 } END { exit !f }' "$reg" 2>/dev/null; then
        rm -f -- "$f" "$f".pre-node-* 2>/dev/null || true
        rmdir "$(dirname "$f")" 2>/dev/null || true
        log info "boot" "убран $f ($1)"
    else
        log info "boot" "$f создан не node — оставлен ($1)"
    fi
}

node_boot_net_wait_apply() {
    local sec bin args help before f="$NODE_WAIT_ONLINE_DROPIN"
    sec="$(node_boot_net_wait_sec)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "boot: would limit $NODE_WAIT_ONLINE_UNIT to ${sec}s ($f)"
        return 0
    fi
    before="$(_node_boot_dropin_sig)"
    if [ "$sec" = 0 ]; then
        _node_boot_dropin_remove "BOOT_NET_WAIT_SEC=0"
    elif ! node_boot_net_wait_enabled; then
        _node_boot_dropin_remove "$NODE_WAIT_ONLINE_UNIT не включён"
        log info "boot" "$NODE_WAIT_ONLINE_UNIT не включён — ожидание сети при загрузке ограничивать нечем"
    elif ! bin="$(node_boot_net_wait_bin)"; then
        warn "boot" "systemd-networkd-wait-online не найден — предел ожидания сети не поставлен"
    else
        # --any/-o появились в systemd 242; на более старом — только предел времени
        args="--timeout=$sec"
        help="$("$bin" --help 2>/dev/null || true)"
        if grep -q -- '--any' <<<"$help" && grep -q -- '--operational-state' <<<"$help"; then
            args="--any -o routable --timeout=$sec"
        fi
        {
            echo "# node — managed by node, do not edit. Предел ожидания сети при загрузке: BOOT_NET_WAIT_SEC=$sec"
            echo "# (0 в /etc/node/node.conf — убрать файл). Без предела сбой одного интерфейса или адреса"
            echo "# держит network-online.target, docker и ноду до 120 с после перезагрузки."
            echo "[Service]"
            echo "ExecStart="
            echo "ExecStart=$bin $args"
        } | node_persist "$f"
    fi
    if [ "$(_node_boot_dropin_sig)" != "$before" ]; then
        # только перечитать юниты: работающую сеть и уже отработавшую службу не трогаем
        systemctl daemon-reload >/dev/null 2>&1 \
            || warn "boot" "systemctl daemon-reload не удался — drop-in подхватится при загрузке"
        if [ -f "$f" ]; then ok "boot" "ожидание сети при загрузке — не дольше $sec с (вступит со следующей загрузки)"; fi
    fi
    return 0
}

# строка для status (только чтение)
node_boot_net_wait_status() {
    local sec fact="нет"
    sec="$(node_boot_net_wait_sec 2>/dev/null)"
    if [ -f "$NODE_WAIT_ONLINE_DROPIN" ]; then
        fact="$(sed -n 's/^ExecStart=.*--timeout=\([0-9]*\).*/\1 с/p' "$NODE_WAIT_ONLINE_DROPIN" | head -1)"
        [ -n "$fact" ] || fact="есть"
    fi
    echo "boot net wait: план=$([ "$sec" = 0 ] && echo 'не ограничивать' || echo "$sec с") drop-in=$fact (юнит $(node_boot_net_wait_enabled && echo включён || echo 'не включён'))"
}
