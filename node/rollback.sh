#!/bin/bash
# node — rollback.sh: обратимость (ТЗ §16). Только свои файлы. Точечный
# runtime-откат из снапшота. sysctl --system ЗАПРЕЩЁН.
set -euo pipefail

NODE_MANIFEST="$NODE_STATE_DIR/applied-files.txt"

node_rollback() {
    local id="${1:-}" ts="" f b newest
    if [ -n "$id" ]; then
        ts="$id"
    else
        # последний backup-набор (|| true: pipefail+несовпавшие глобы → иначе set -e убьёт)
        b="$(ls -1 /etc/sysctl.d/*.pre-node-* /etc/modprobe.d/*.pre-node-* /etc/modules-load.d/*.pre-node-* /etc/systemd/system/*.pre-node-* /etc/nftables.d/*.pre-node-* /etc/apt/apt.conf.d/*.pre-node-* /etc/default/grub.d/*.pre-node-* 2>/dev/null | sed -E 's/.*\.pre-node-([0-9]{8}-[0-9]{6})$/\1/' | sort -u | tail -1 || true)"
        ts="$b"
    fi

    log info "rollback" "target backup set: ${ts:-<none — только удаление своих файлов>}"

    # 1. восстановление/удаление по манифесту
    local dropdirs=()
    if [ -f "$NODE_MANIFEST" ]; then
        while read -r f; do
            [ -e "$f" ] || continue
            # запоминаем наши drop-in каталоги (limits) для очистки ниже
            case "$f" in /etc/systemd/system/*.d/*.conf) dropdirs+=("$(dirname "$f")") ;; esac
            # Если есть хоть один .pre-node-* бэкап — файл существовал ДО node:
            # ВОССТАНАНВЛИВАЕМ, а не удаляем (раньше при пустом ts делался rm -f
            # и стирались чужие pre-existing файлы, напр. /etc/fstab, хотя рядом
            # лежал бэкап). rm -f — только когда бэкапов нет вообще (файл создан
            # node с нуля). При заданном ts сначала точный бэкап набора, иначе
            # fallback на newest + warn (ранее id набора фактически игнорировался).
            local exact=""
            [ -n "$ts" ] && [ -f "${f}.pre-node-${ts}" ] && exact="${f}.pre-node-${ts}"
            newest="$(ls -1t "${f}".pre-node-* 2>/dev/null | head -1 || true)"
            if [ -n "$exact" ]; then
                cp -a "$exact" "$f"
                log info "rollback" "restored $f <- $exact (backup-set $ts)"
            elif [ -n "$newest" ]; then
                cp -a "$newest" "$f"
                if [ -n "$ts" ]; then
                    warn "rollback" "для $f нет бэкапа набора $ts — восстановлен из newest: $newest"
                else
                    log info "rollback" "restored $f <- $newest (файл существовал до node — НЕ удаляем)"
                fi
            else
                rm -f "$f"
                log info "rollback" "removed own file $f (бэкапов нет — файл создан node с нуля)"
            fi
        done < "$NODE_MANIFEST"
        # очистка ТОЛЬКО своих опустевших drop-in каталогов (limits) из манифеста;
        # rmdir не тронет непустой/чужой каталог (раньше find -empty -delete
        # сносил ЛЮБЫЕ пустые *.d под /etc/systemd/system)
        local d
        for d in ${dropdirs[@]+"${dropdirs[@]}"}; do
            [ -n "$d" ] && rmdir "$d" 2>/dev/null || true
        done
        : > "$NODE_MANIFEST"
    fi

    # 2. runtime-откат ключей, которым больше не принадлежит файл
    local snap keys_f="$NODE_STATE_DIR/owner-keys.txt"
    snap="$(ls -1t "$NODE_DIAG_DIR"/*.txt 2>/dev/null | head -1 || true)"
    if [ -f "$keys_f" ] && [ -n "$snap" ]; then
        local k v
        while read -r k; do
            [ -z "$k" ] && continue
            # ключ ещё управляется оставшимися файлами node?
            # (точки ключа экранируем: regex-точка в «net.ipv4...» матчила любой символ)
            local kre="${k//./\\.}"
            if grep -rqsE "^${kre}[[:space:]]*=" /etc/sysctl.d/99-z[01234]-node-*.conf 2>/dev/null; then
                continue
            fi
            v="$(awk -v key="$k" 'found && /^## /{exit} /^## sysctl-managed-baseline/{found=1; next} found && $1==key {print $3; exit}' "$snap")"
            if [ -n "$v" ] && [ "$v" != "?" ]; then
                sysctl -w "$k=$v" >/dev/null 2>&1 && log info "rollback" "runtime restored $k=$v" || true
            fi
        done < "$keys_f"
    fi

    # 3. runtime-твики (ethtool/rings/offloads/txqueuelen/irq affinity) — явный откат
    node_rt_rollback

    # 3a. состояния отключённых сервисов (hardening §17) — restore из снапшота
    # shellcheck source=lib/services.sh
    source "$NODE_DIR/lib/services.sh"
    node_services_rollback

    # 4. службы
    systemctl daemon-reload 2>/dev/null || true
    if systemctl cat node-mss-clamp.service >/dev/null 2>&1; then
        systemctl disable --now node-mss-clamp.service >/dev/null 2>&1 || true
    fi
    if systemctl cat node-rt-tweaks.service >/dev/null 2>&1; then
        systemctl disable --now node-rt-tweaks.service >/dev/null 2>&1 || true
    fi
    rm -f /usr/local/sbin/node-rt-tweaks.sh /etc/udev/rules.d/99-node-rt-hotplug.rules
    udevadm control --reload >/dev/null 2>&1 || true
    nft delete table inet node_mss_clamp 2>/dev/null || true
    # grub-файл (если XanMod-установка правила /etc/default/grub) — восстанавливаем
    local g; g="$(ls -1t /etc/default/grub.pre-node-* 2>/dev/null | head -1 || true)"
    if [ -n "$g" ] && [ -w /etc/default/grub ]; then
        cp -a "$g" /etc/default/grub
        command -v update-grub >/dev/null 2>&1 && update-grub || true
        log info "rollback" "grub restored from $g (ядро не тронуто — удаление XanMod: bash -c 'source lib/kernel.sh; node_xanmod_remove' + reboot)"
    fi

    # 4. контракт
    local conf="$NODE_PROFILE_DIR/stack.conf"
    if [ -f "$conf" ]; then
        # mktemp в том же каталоге: mv атомарен только внутри одной ФС
        local tmp; tmp="$(mktemp "$NODE_PROFILE_DIR/.stack.conf.XXXXXX")"
        awk '/^\[node\]/{skip=1; next} /^\[/{skip=0} !skip' "$conf" > "$tmp" || true
        chmod 0644 "$tmp"; mv "$tmp" "$conf"
    fi

    ok "rollback" "rollback завершён (backup-set: ${ts:-none})"
}
