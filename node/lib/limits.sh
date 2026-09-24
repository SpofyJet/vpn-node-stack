#!/bin/bash
# node — lib/limits.sh: §8 FD-лимиты через systemd drop-in LimitNOFILE.
# unit'ы не рестартуем (доступность > применение немедленно).
set -euo pipefail

node_limits_plan() {
    : # значение нужно только на persist-этапе
    export NODE_LIMIT_NOFILE="$(node_conf_get LIMIT_NOFILE 1048576)"
}

# Детект systemd-unit'ов, в которых живёт xray/remnanode (read-only)
node_limits_detect_units() {
    local units=() u
    while read -r u; do
        [ -z "$u" ] && continue
        if systemctl cat "$u" 2>/dev/null | grep -qiE 'xray|remnanode'; then
            units+=("$u")
        fi
    done < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')
    # fallback: по имени процесса (ps -o unit= уже даёт имя юнита; мёртвый
    # systemctl show -p Unit поверх него убран — он получал имя юнита как аргумент
    # и возвращал пусто)
    if [ "${#units[@]}" -eq 0 ]; then
        local pid
        for pid in $(pgrep -f 'xray|remnanode' 2>/dev/null || true); do
            u="$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')"
            [ -n "$u" ] && [ "$u" != "n/a" ] && units+=("$u")
        done
    fi
    printf '%s\n' "${units[@]:-}" | sort -u | sed '/^$/d'
}

node_limits_persist() {
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "limits drop-ins (skipped)"; return 0; }
    local u n=0
    while read -r u; do
        [ -z "$u" ] && continue
        case "$u" in *docker*|*containerd*) continue ;; esac # docker-контейнеры — не трогаем
        local d="/etc/systemd/system/${u}.d/10-node-limits.conf"
        mkdir -p "$(dirname "$d")"
        {
            echo "# node — §8 LimitNOFILE (managed by node)"
            echo "[Service]"
            echo "LimitNOFILE=$NODE_LIMIT_NOFILE"
        } | node_persist "$d"
        n=$((n + 1))
    done < <(node_limits_detect_units)
    [ "$n" -eq 0 ] && warn "limits" "systemd-unit'ы xray/remnanode не найдены (docker-only?). Drop-in не создан; примени LimitNOFILE вручную в compose/unit контейнера."
    # daemon-reload в chroot/контейнере без systemd падает — это не повод
    # ронять весь apply (drop-in'ы подхватятся при первом же boot/reload)
    systemctl daemon-reload 2>/dev/null || warn "limits" "systemctl daemon-reload не удался (chroot/контейнер?) — drop-in'ы применятся при boot"
    ok "limits" "daemon-reload done; drop-ins применятся при следующем рестарте сервисов (сейчас НЕ рестартуем)"
}
