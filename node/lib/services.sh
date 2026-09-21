#!/bin/bash
# node — lib/services.sh: §17 hardening — отключение ПРОВЕРЕННОГО безопасного фона
# (по аналогии с поколением старых скриптов, но reversibility-first):
#   - состояние каждого юнита снапшотится ДО отключения (services-state.tsv)
#   - откат: node_services_rollback восстанавливает ТОЛЬКО то, что меняли мы
#   - drop-in'ы (apt, grub.d) идут через node_persist → backup + манифест
# IPv6 — через наш sysctl-файл (метод безопасный: boot не трогаем).
# Всё управляется флагами HARDEN_* (defaults.conf); 0 = не трогать.
set -euo pipefail

NODE_SVC_STATE="$NODE_STATE_DIR/services-state.tsv"

node_services_plan() {
    log info "services" "hardening plan: ipv6=$(node_conf_get HARDEN_IPV6 1) bg=$(node_conf_get HARDEN_BG_SERVICES 1) unattended=$(node_conf_get HARDEN_UNATTENDED 1) packagekit=$(node_conf_get HARDEN_PACKAGEKIT 1) irqbalance=$(node_conf_get HARDEN_IRQBALANCE 1) rpcbind=$(node_conf_get HARDEN_RPCBIND 1) kdump=$(node_conf_get HARDEN_KDUMP 1) mta=$(node_conf_get HARDEN_MTA 0) snapd=$(node_conf_get HARDEN_SNAPD 0)"
}

# --- снапшот состояния юнитов (основа точечного отката) ---
node_svc_snapshot() { # <unit>
    local u="$1"
    [ -f "$NODE_SVC_STATE" ] && cut -f1 "$NODE_SVC_STATE" | grep -qxF -- "$u" && return 0
    local en ac
    en="$(systemctl is-enabled "$u" 2>/dev/null || echo unknown)"
    ac="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
    printf '%s\t%s\t%s\n' "$u" "$en" "$ac" >> "$NODE_SVC_STATE"
    log debug "services" "snapshot $u: enabled=$en active=$ac"
}

node_svc_exists() { # <unit> — 0 если юнит установлен
    systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q .
}

# юнит имеет смысл трогать, если он не выключен полностью
node_svc_running_or_enabled() { # <unit>
    local st
    st="$(systemctl is-enabled "$1" 2>/dev/null || true)"
    case "$st" in
        enabled|enabled-runtime|static|alias|indirect|generated|transient|masked) return 0 ;;
    esac
    systemctl is-active --quiet "$1" 2>/dev/null
}

node_svc_disable() { # <unit...> — disable --now со снапшотом
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "services: would disable $*"
        return 0
    fi
    local u
    for u in "$@"; do
        node_svc_exists "$u" || continue
        node_svc_running_or_enabled "$u" || continue
        node_svc_snapshot "$u"
        if systemctl disable --now "$u" >/dev/null 2>&1; then
            ok "services" "disabled: $u"
        elif systemctl stop "$u" >/dev/null 2>&1; then
            # static-юниты нельзя disable — останавливаем (то же поведение для ноды)
            ok "services" "stopped (static, disable невозможен): $u"
        else
            warn "services" "$u не отключился — проверь вручную"
        fi
        # урок старой ветки (v5.10.3 BUG-STATIC-REVIVE): static/dbus-юниты
        # воскресают через dbus/timer-активацию — если выжил после stop, маскируем
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            if systemctl mask "$u" >/dev/null 2>&1; then
                ok "services" "$u выжил после stop — замаскирован (rollback: unmask)"
            else
                warn "services" "$u активен и не маскируется — проверь вручную"
            fi
        fi
    done
}

node_svc_enable() { # <unit...> — enable --now со снапшотом (для fstrim и подобных)
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "services: would enable $*"
        return 0
    fi
    local u
    for u in "$@"; do
        node_svc_exists "$u" || continue
        node_svc_snapshot "$u"
        if systemctl enable --now "$u" >/dev/null 2>&1; then
            ok "services" "enabled: $u"
        else
            warn "services" "$u не включился — проверь вручную"
        fi
    done
}

node_svc_mask() { # <unit...> — disable --now + mask со снапшотом
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "services: would disable+mask $*"
        return 0
    fi
    local u
    for u in "$@"; do
        node_svc_exists "$u" || continue
        node_svc_running_or_enabled "$u" || continue
        node_svc_snapshot "$u"
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        if systemctl mask "$u" >/dev/null 2>&1; then
            ok "services" "disabled+masked: $u (rollback: systemctl unmask $u)"
        else
            warn "services" "$u не замаскировался — проверь вручную"
        fi
    done
}

# --- IPv6: безопасный sysctl-метод (boot не трогаем; доказан старой веткой) ---
node_harden_ipv6() {
    [ "$(node_conf_get HARDEN_IPV6 1)" = "1" ] || return 0
    # probed: на ядрах без IPv6 просто пропускаем, apply не падает
    node_sysctl_add_probed "$NODE_SYSCTL_IPV6" net.ipv6.conf.all.disable_ipv6 1
    node_sysctl_add_probed "$NODE_SYSCTL_IPV6" net.ipv6.conf.default.disable_ipv6 1
    node_sysctl_add_probed "$NODE_SYSCTL_IPV6" net.ipv6.conf.lo.disable_ipv6 1
}

node_services_apply() {
    # фоновые сервисы headless-VPS (доказанный список поколения старых скриптов)
    if [ "$(node_conf_get HARDEN_BG_SERVICES 1)" = "1" ]; then
        # список проверен на старой ветке; ModemManager/udisks2 — static/dbus,
        # их глушит mask-if-alive в node_svc_disable
        node_svc_disable \
            motd-news.timer accounts-daemon.service switcheroo-control.service \
            colord.service thermald.service avahi-daemon.service \
            ModemManager udisks2
    fi

    # автообновления: APT::Periodic=0 + таймеры (явное решение оператора:
    # security-апдейты ставятся вручную в окно обслуживания — как на старой ноде)
    if [ "$(node_conf_get HARDEN_UNATTENDED 1)" = "1" ]; then
        {
            echo "// node: автообновления отключены (HARDEN_UNATTENDED=1). Вернуть: удалить файл + enable apt-daily*.timer"
            echo "APT::Periodic::Update-Package-Lists \"0\";"
            echo "APT::Periodic::Unattended-Upgrade \"0\";"
        } | node_persist /etc/apt/apt.conf.d/99-node-no-unattended
        node_svc_disable apt-daily.timer apt-daily-upgrade.timer
    fi

    # packagekit: отключаем+маскируем (purge неверен — ломает переустановку)
    if [ "$(node_conf_get HARDEN_PACKAGEKIT 1)" = "1" ]; then
        node_svc_mask packagekit.service
    fi

    # irqbalance: конфликтует с нашей IRQ-affinity (перетирает smp_affinity ~каждые 10с)
    if [ "$(node_conf_get HARDEN_IRQBALANCE 1)" = "1" ]; then
        node_svc_disable irqbalance.service
    fi

    # rpcbind: portmapper NFS, лишний listener :111; только если NFS/CIFS маунтов нет
    if [ "$(node_conf_get HARDEN_RPCBIND 1)" = "1" ]; then
        if command -v findmnt >/dev/null 2>&1; then
            findmnt -t nfs,nfs4,cifs >/dev/null 2>&1 || node_svc_mask rpcbind.service rpcbind.socket
        else
            grep -qE ' (nfs|nfs4|cifs) ' /proc/mounts || node_svc_mask rpcbind.service rpcbind.socket
        fi
    fi

    # kdump: crashkernel резервирует 320–512MB RAM (Ubuntu 24.10+ по умолчанию)
    if [ "$(node_conf_get HARDEN_KDUMP 1)" = "1" ]; then
        node_svc_disable kdump-tools.service kdump.service
        if [ -d /etc/default/grub.d ] || mkdir -p /etc/default/grub.d 2>/dev/null; then
            {
                echo "# node: снятие crashkernel-резерва kdump (HARDEN_KDUMP=1); эффект после reboot"
                echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=0M"'
            } | node_persist /etc/default/grub.d/99-node-no-kdump.cfg
            if [ "${DRY_RUN:-0}" != "1" ]; then
                command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 || true
            fi
        fi
    fi

    # локальный MTA: opt-in (вдруг оператор шлёт почту с ноды)
    if [ "$(node_conf_get HARDEN_MTA 0)" = "1" ]; then
        node_svc_disable exim4.service postfix.service sendmail.service
    fi

    # snapd: opt-in (на Ubuntu Pro может быть связан с cloud-init)
    if [ "$(node_conf_get HARDEN_SNAPD 0)" = "1" ]; then
        node_svc_mask snapd.service snapd.socket snapd.refresh.timer
    fi
}

# node_services_rollback — восстановить состояние юнитов из снапшота
node_services_rollback() {
    [ -f "$NODE_SVC_STATE" ] || return 0
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "services rollback (skipped)"; return 0; }
    local u en ac cur
    while IFS=$'\t' read -r u en ac; do
        [ -n "$u" ] || continue
        # снимаем маску ТОЛЬКО если замаскировали мы (до нас юнит не был masked)
        cur="$(systemctl is-enabled "$u" 2>/dev/null || echo '?')"
        if [ "$cur" = "masked" ] && [ "$en" != "masked" ]; then
            systemctl unmask "$u" >/dev/null 2>&1 || true
            log info "services" "unmasked $u (был замаскирован node)"
        fi
        # симметричный restore: вернуть и «включённое», и «выключенное» состояния
        case "$en" in
            enabled|enabled-runtime|alias|indirect|generated|transient)
                systemctl enable "$u" >/dev/null 2>&1 \
                    && log info "services" "re-enabled $u" || true ;;
            disabled)
                if systemctl is-enabled --quiet "$u" 2>/dev/null; then
                    systemctl disable "$u" >/dev/null 2>&1 \
                        && log info "services" "re-disabled $u (мы его включали)" || true
                fi ;;
        esac
        if [ "$ac" = "active" ]; then
            systemctl start "$u" >/dev/null 2>&1 \
                && log info "services" "started $u" || true
        elif systemctl is-active --quiet "$u" 2>/dev/null; then
            systemctl stop "$u" >/dev/null 2>&1 \
                && log info "services" "stopped $u (мы его запускали)" || true
        fi
    done < "$NODE_SVC_STATE"
    rm -f "$NODE_SVC_STATE"
    # boot-конфигурация могла измениться (kdump drop-in) — синхронизируем grub
    command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 || true
    ok "services" "состояния сервисов восстановлены"
}
