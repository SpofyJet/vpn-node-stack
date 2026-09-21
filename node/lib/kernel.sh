#!/bin/bash
# node — lib/kernel.sh: BBR + (опц.) XanMod-ядро. Требование: авто-BBR когда ядро
# умеет; замена ядра — только явным ENABLE_XANMOD=1 (одна строчка в конфиге).
# Никогда не ребутаем сами; откат ядра — restore grub-файла + purge (документирован).
set -euo pipefail

XANMOD_REPO_LIST=/etc/apt/sources.list.d/xanmod-kernel.list
XANMOD_GPG=/etc/apt/trusted.gpg.d/xanmod-kpg.gpg

node_kernel_is_xanmod() { uname -r | grep -qi xanmod; }

# node_bbr_available — 0 если модуль tcp_bbr загружен/загружаем и доступен.
node_bbr_available() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr
}

node_bbr_active() {
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]
}

# node_bbr_plan — добавить BBR в sysctl-план, если ядро умеет (иначе warn, не ломаем).
node_bbr_plan() {
    [ "$(node_conf_get ENABLE_BBR 1)" = "1" ] || { log info "kernel" "ENABLE_BBR=0 — пропуск"; return 0; }
    if node_bbr_available; then
        node_sysctl_add "$NODE_SYSCTL_DATAPATH" net.ipv4.tcp_congestion_control bbr
        node_sysctl_add "$NODE_SYSCTL_DATAPATH" net.core.default_qdisc fq
        log info "kernel" "BBR доступен — план: congestion_control=bbr, qdisc=fq"
    else
        log warn "kernel" "BBR недоступен в текущем ядре ($(uname -r)). XanMod: ENABLE_XANMOD=1 в /etc/node/node.conf, затем reboot и повторный apply."
    fi
}

# node_cpu_xlevel — x86-64 уровень CPU: v3/v2/v1 (для выбора пакета XanMod).
node_cpu_xlevel() {
    local flags; flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)"
    if grep -qw avx2 <<<"$flags" && grep -qw bmi2 <<<"$flags" && grep -qw fma <<<"$flags" && grep -qw avx <<<"$flags"; then
        echo v3
    elif grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags"; then
        echo v2
    else
        echo v1
    fi
}

node_xanmod_supported() {
    [ "$(uname -m)" = "x86_64" ] || return 1
    if command -v apt-get >/dev/null 2>&1 && [ -r /etc/os-release ]; then
        grep -qiE 'debian|ubuntu' /etc/os-release
    else
        return 1
    fi
}

# node_xanmod_install — установка ядра XanMod (Debian/Ubuntu, apt).
# Безопасность: backup grub-файла, pin-файл apt, БЕЗ авто-ребута; после ребута
# повторный `node apply` доведёт BBR (модуль в комплекте ядра).
node_xanmod_install() {
    [ "$(node_conf_get ENABLE_XANMOD 0)" = "1" ] || return 0
    node_kernel_is_xanmod && { log info "kernel" "ядро уже XanMod ($(uname -r))"; return 0; }
    node_xanmod_supported || die "XanMod поддерживается только на Debian/Ubuntu x86_64 (тут: $(uname -m), $(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo '?'))"

    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "would install XanMod kernel (variant $(node_conf_get XANMOD_VARIANT auto))"; return 0; }

    local level variant
    level="$(node_conf_get XANMOD_VARIANT "")"; [ -z "$level" ] && level="$(node_cpu_xlevel)"
    case "$level" in v1|v2|v3) : ;; *) die "XANMOD_VARIANT: v1|v2|v3, получено '$level'" ;; esac

    require_root
    log info "kernel" "установка linux-xanmod-x64$level (CPU level $level)…"
    backup /etc/default/grub
    # репозиторий + ключ (backup + atomic + манифест — единые правила проекта)
    backup "$XANMOD_REPO_LIST"
    printf 'deb http://deb.xanmod.org releases main\n' | atomic_write "$XANMOD_REPO_LIST"
    node_manifest_record "$XANMOD_REPO_LIST"
    if command -v wget >/dev/null 2>&1; then
        wget -qO- https://dl.xanmod.org/gpg.key 2>/dev/null | gpg --dearmor | atomic_write "$XANMOD_GPG" \
            && node_manifest_record "$XANMOD_GPG" \
            || log warn "kernel" "gpg key import не удался — продолжаем (apt может ругаться)"
    else
        log warn "kernel" "wget отсутствует — добавьте ключ вручную: https://dl.xanmod.org/gpg.key"
    fi
    # сетевой сбой здесь НЕ должен убивать весь apply: система уже оптимизована,
    # контракт ещё не записан — warn + продолжаем (XanMod можно доустановить повторным apply)
    apt-get update -qq || { log warn "kernel" "apt update failed (deb.xanmod.org недоступен?) — XanMod пропущен, повторите apply после исправления сети"; return 0; }
    apt-get install -y --no-install-recommends "linux-xanmod-x64$level" || { log warn "kernel" "apt install linux-xanmod-x64$level failed — повторите apply"; return 0; }
    # pin: держим ядро при autoremove
    printf '%s\n' 'Package: linux-image*xanmod*' 'Pin: release o=XanMod' 'Pin-Priority: 1001' > /etc/apt/preferences.d/xanmod-kernel
    node_manifest_record /etc/apt/preferences.d/xanmod-kernel
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    log warn "kernel" "XanMod установлен. ТРЕБУЕТСЯ reboot: sudo reboot. После загрузки — повторный apply (BBR поднимется автоматически)."
}

# node_xanmod_remove — откат ядра (явный вызов, требует reboot для полного эффекта).
node_xanmod_remove() {
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "would purge XanMod kernel"; return 0; }
    apt-get purge -y 'linux-image*xanmod*' 2>/dev/null || true
    rm -f "$XANMOD_REPO_LIST" "$XANMOD_GPG" /etc/apt/preferences.d/xanmod-kernel
    # восстанавливаем grub-файл из нашего последнего backup (if-guard: &&-цепочка
    # под set -e убила бы скрипт при отсутствии бэкапа)
    local g; g="$(ls -1t /etc/default/grub.pre-node-* 2>/dev/null | head -1 || true)"
    if [ -n "$g" ]; then
        cp -a "$g" /etc/default/grub
        command -v update-grub >/dev/null 2>&1 && update-grub || true
        log info "kernel" "grub restored from $g"
    fi
    log warn "kernel" "XanMod удалён. Для полного отката: sudo reboot (загрузится стоковое ядро)."
}
